//! The single request dispatcher shared by the FFI bridge and the loopback
//! HTTP adapter. Port of `router.go` `Server.ServeHTTP`.
//!
//! Architecture decision and consequences: see `CONTRACTS.md` and
//! `docs/architecture-review.md`.
//!
//! There is exactly one business implementation: Flutter reaches it over
//! flutter_rust_bridge and external HTTP clients (local tooling) reach it over
//! the loopback adapter. The loopback surface is deliberately narrowed to the
//! routes this app uses (see [`APP_APIS`]); the rest of the fqapp/Legado
//! compatibility table stays reachable only for capability-carrying callers.

use std::path::{Path, PathBuf};

use serde_json::json;

use crate::endpoints::{router, Params, RawOut, Server};
use crate::error::ApiError;

#[derive(Debug, Clone, Default)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: String,
    pub body: Vec<u8>,
    /// Request headers, lower-cased by the adapter. Only the static file path
    /// consumes them today (Range/HEAD); business endpoints are unaffected.
    pub headers: Vec<(String, String)>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// Response body: either bytes already in memory, or a byte range of a file
/// the loopback adapter streams without reading it into memory.
#[derive(Debug, Clone)]
pub enum ResponseBody {
    Bytes(Vec<u8>),
    File {
        path: PathBuf,
        offset: u64,
        length: u64,
        total: u64,
    },
    /// A byte range of a CENC-encrypted cache file, to be transformed with
    /// the file's index and content key while it is materialised/streamed
    /// (P1-7): the bytes on disk stay encrypted, the decrypted view exists
    /// only in the response.
    FileDecrypted {
        path: PathBuf,
        offset: u64,
        length: u64,
        total: u64,
        index: std::sync::Arc<crate::endpoints::video::CencIndex>,
        key: Vec<u8>,
    },
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub content_type: String,
    pub headers: Vec<(String, String)>,
    pub body: ResponseBody,
}

const JSON_CT: &str = "application/json; charset=utf-8";

impl Response {
    pub fn json(status: u16, value: &serde_json::Value) -> Self {
        Response {
            status,
            content_type: JSON_CT.to_string(),
            headers: Vec::new(),
            body: ResponseBody::Bytes(serde_json::to_vec(value).unwrap_or_default()),
        }
    }

    pub fn text(status: u16, content_type: impl Into<String>, body: Vec<u8>) -> Self {
        Response {
            status,
            content_type: content_type.into(),
            headers: Vec::new(),
            body: ResponseBody::Bytes(body),
        }
    }

    pub fn not_found(message: String) -> Self {
        Response::json(404, &json!({ "success": false, "error": message }))
    }

    /// Materialises the body into bytes. Used by the FFI transport and by
    /// tests; the loopback adapter streams `File` bodies instead.
    pub async fn into_bytes(self) -> Result<Vec<u8>, String> {
        match self.body {
            ResponseBody::Bytes(b) => Ok(b),
            ResponseBody::File {
                path,
                offset,
                length,
                ..
            } => {
                if length > crate::static_files::FFI_BODY_LIMIT {
                    return Err(format!(
                        "resource too large for the in-process transport: {length} bytes"
                    ));
                }
                read_range(&path, offset, length).await
            }
            ResponseBody::FileDecrypted {
                path,
                offset,
                length,
                index,
                key,
                ..
            } => {
                if length > crate::static_files::FFI_BODY_LIMIT {
                    return Err(format!(
                        "resource too large for the in-process transport: {length} bytes"
                    ));
                }
                let mut buf = read_range(&path, offset, length).await?;
                crate::endpoints::video::apply_cenc_index(&mut buf, offset, &index, &key)?;
                Ok(buf)
            }
        }
    }
}

async fn read_range(path: &Path, offset: u64, length: u64) -> Result<Vec<u8>, String> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    if offset > 0 {
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| e.to_string())?;
    }
    let mut out = vec![0u8; length as usize];
    file.read_exact(&mut out).await.map_err(|e| e.to_string())?;
    Ok(out)
}

/// Routes whose handler reads the POST body rather than URL/query arguments.
const ACCOUNT_HISTORY_PATH: &str = "/api/v1/account/fanqie/history";
const ACCOUNT_LIBRARY_PATH: &str = "/api/v1/account/fanqie/library";

/// Largest body the account routes accept. Both handlers reject anything
/// above this, so the loopback adapter refuses it before buffering.
pub const ACCOUNT_REQUEST_BODY_LIMIT: usize = 16 * 1024;

/// Routes that read the request body. The loopback adapter retains and
/// forwards the body for exactly these paths; every other route ignores
/// bodies, so draining them is enough.
pub fn request_body_limit(path: &str) -> Option<usize> {
    match path {
        ACCOUNT_HISTORY_PATH | ACCOUNT_LIBRARY_PATH => Some(ACCOUNT_REQUEST_BODY_LIMIT),
        _ => None,
    }
}

/// APIs that submit user actions under the device identity (comments add /
/// digg / reply; the danmaku add route reuses `playlet_comment_add`). The
/// loopback adapter is callable by other local HTTP clients, so a GET must
/// never turn into an upstream POST just because the path matched one of
/// these. New device-bound write routes must be added here and to the
/// contract test; the list lives apart from router.rs's route table on
/// purpose.
const DEVICE_BOUND_WRITE_APIS: &[&str] = &[
    "playlet_comment_add",
    "playlet_comment_digg",
    "playlet_comment_reply",
];

/// The only read APIs the Flutter app actually calls (over FRB; the loopback
/// adapter serves the same set to local tooling).
///
/// The core still carries the whole fqapp/Legado compatibility table, but
/// exposing it over `127.0.0.1` is a free attack surface: on iOS the loopback
/// address is shared by every app on the device, and a sibling app that spoofs
/// `Host: 127.0.0.1:<port>` could otherwise read all 40+ compat routes. Only
/// these seven APIs plus `/health` and `/src/*` stay capability-free.
pub const APP_APIS: &[&str] = &[
    "homepage_recommend",
    "search",
    "book_detail_legacy",
    "directory",
    "content",
    "video_detail",
    "video",
];

/// Whether `path` may be served to a loopback client that carries no
/// capability (no `/_session/<token>` prefix, Bearer header or session cookie).
///
/// Everything else is treated as non-existent for such a caller: the
/// dispatcher's 404 is indistinguishable from a path that was never routed.
/// The FFI transport bypasses this gate entirely, so extra APIs consumed in
/// process (tests, future features) do not need to be added here unless they
/// must also be reachable from outside the app.
pub fn is_public_loopback_path(path: &str) -> bool {
    if path == "/health" || path == "/src" || path.starts_with("/src/") {
        return true;
    }
    // The query string cannot change which API a path maps to (every matcher
    // keys off the path segments), so an empty query is enough to classify it.
    match router::match_rest_path(path, &Params::parse("")) {
        Some(m) => APP_APIS.contains(&m.api),
        None => false,
    }
}

/// Whether `path` addresses a device-bound write route.
///
/// These routes stay behind the capability even though most other routes are
/// now capability-free: they submit actions as this installation's device
/// identity, and a sibling app on the same phone must not be able to post
/// comments or danmaku on the user's behalf. (Every other non-app route is
/// refused with 404 by [`is_public_loopback_path`] before it is dispatched.)
pub fn requires_capability(path: &str) -> bool {
    let params = Params::parse("");
    match router::match_rest_path(path, &params) {
        Some(m) => DEVICE_BOUND_WRITE_APIS.contains(&m.api),
        None => false,
    }
}

pub async fn dispatch(server: &Server, req: &Request) -> Response {
    let path = req.path.as_str();
    let ctx = &server.ctx;

    // Account credentials belong in a bounded POST body, never in route/query
    // parameters, endpoint error logs, or the anonymous rotating device pool.
    if path == ACCOUNT_HISTORY_PATH {
        return crate::endpoints::account_history::handle(ctx, req).await;
    }
    if path == ACCOUNT_LIBRARY_PATH {
        return crate::endpoints::account_library::handle(ctx, req).await;
    }

    if path == "/health" {
        let devices = ctx.pool.count().await;
        return Response::json(200, &json!({ "status": "ok", "devices": devices }));
    }

    // static file server for the runtime cache directory (manga images,
    // clear media, and — via the video hook — CENC-encrypted videos whose
    // ranges are decrypted on demand, P1-7)
    if !ctx.src_dir.is_empty() && (path == "/src" || path.starts_with("/src/")) {
        let rest = path.strip_prefix("/src/").unwrap_or("");
        if let Some(resp) = crate::endpoints::video::serve_src_file(&ctx.src_dir, rest, req).await {
            return resp;
        }
        return crate::static_files::serve(Path::new(&ctx.src_dir), rest, req).await;
    }

    let mut params = Params::parse(&req.query);
    let m = match router::match_rest_path(path, &params) {
        Some(m) => m,
        None => {
            if ctx.cfg.anti_crawler.enabled && !ctx.cfg.anti_crawler.redirect_url.is_empty() {
                // A 302 without Location is not a redirect; clients just show
                // the body. The URL stays in the body for the FFI transport,
                // which surfaces status and body only.
                let url = ctx.cfg.anti_crawler.redirect_url.clone();
                let mut response =
                    Response::text(302, "text/plain; charset=utf-8", url.clone().into_bytes());
                response.headers.push(("location".to_string(), url));
                return response;
            }
            return Response::json(
                404,
                &json!({ "success": false, "error": format!("not found: {path}") }),
            );
        }
    };
    params = m.params;

    // Method enforcement for device-bound writes: see DEVICE_BOUND_WRITE_APIS.
    // The loopback adapter already refuses capability-free callers, but the FFI
    // transport reaches this code without a method gate, so GET must not turn
    // into an upstream POST there either.
    if DEVICE_BOUND_WRITE_APIS.contains(&m.api) && !req.method.eq_ignore_ascii_case("POST") {
        let mut response = Response::json(
            405,
            &json!({ "success": false, "error": "method not allowed" }),
        );
        response
            .headers
            .push(("allow".to_string(), "POST".to_string()));
        return response;
    }

    // HTML page endpoints write their own response and bypass the envelope.
    if let Some(raw) = server.raw_handler(m.api) {
        return match raw(ctx, &params).await {
            Ok(RawOut {
                status,
                content_type,
                body,
            }) => Response::text(status, content_type, body),
            Err(e) => {
                log::warn!("api {} failed: {}", m.api, e.message());
                error_response(&e)
            }
        };
    }

    let Some(ep) = server.handler(m.api) else {
        return Response::json(
            404,
            &json!({ "success": false, "error": format!("unsupported api type: {}", m.api) }),
        );
    };

    // Sessions opened by recommend pagination are bound to the device that
    // opened them; pin it so page N+1 does not rotate to a different device.
    if let Some(pin) = router::pin_from_session(&mut params, &ctx.pool).await {
        params.set(crate::endpoints::INTERNAL_DEVICE_PIN_KEY, pin);
    }

    match ep(ctx, &params).await {
        Ok(data) => Response::json(200, &data),
        Err(e) => {
            // Release builds have no console; this is the only trace a
            // business failure leaves in logcat (tag fqapi_core).
            log::warn!("api {} failed: {}", m.api, e.message());
            error_response(&e)
        }
    }
}

fn error_response(e: &ApiError) -> Response {
    Response::json(
        e.status(),
        &json!({ "success": false, "error": e.message() }),
    )
}

/// Minimal extension table for the bundled Web UI assets.
pub fn mime_for(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "html" | "htm" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "application/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "txt" => "text/plain; charset=utf-8",
        "ico" => "image/x-icon",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "eot" => "application/vnd.ms-fontobject",
        "mp4" => "video/mp4",
        "m4s" => "video/iso.segment",
        "mp3" => "audio/mpeg",
        _ => "application/octet-stream",
    }
}
