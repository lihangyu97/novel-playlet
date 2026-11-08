//! Loopback HTTP adapter.
//!
//! Serves `/src/*` cache resources (manga images, clear media, and
//! CENC-encrypted videos decrypted range by range — P1-7) and the
//! `/api/v1/*` business routes to the same dispatcher the FFI bridge uses,
//! so there is exactly one business implementation. Local tooling uses this
//! adapter; there is no built-in Web UI.
//!
//! Static file bodies are streamed from disk (with Range support) instead of
//! being read into memory, so serving a large media file costs a bounded
//! buffer rather than its full size.
//!
//! Binding to 127.0.0.1 alone does not keep web pages out. Every request must
//! name this listener in `Host` (defeats DNS rebinding, which would otherwise
//! let a foreign page read responses) and, when it carries an `Origin`, come
//! from this listener too (defeats cross-site form POSTs to the device-bound
//! write routes, which read their arguments from the query string and so need
//! no CORS preflight).
//!
//! The loopback surface is further narrowed by [`crate::dispatch::APP_APIS`]:
//! a caller without this launch's capability only reaches `/health`, `/src/*`
//! and the seven APIs the app itself uses. Everything else (the fqapp/Legado
//! compatibility table, the account routes) answers 404, and device-bound
//! writes answer 401, so a sibling app on the same phone cannot read the compat
//! surface or act as this installation. Capability-carrying callers (the
//! `/_session/<token>` prefix, a Bearer header, or the session cookie) reach
//! every route. The FFI transport bypasses this adapter and is unaffected.

use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Router;
use rand::RngCore;
use serde_json::json;
use tokio_util::io::ReaderStream;
use tokio_util::sync::CancellationToken;

use crate::dispatch::{dispatch, Request, ResponseBody};
use crate::endpoints::Server;

/// Upper bound for any request body the adapter drains. Only the routes that
/// read a body retain it, under the smaller per-route cap from
/// [`crate::dispatch::request_body_limit`].
pub const MAX_REQUEST_BODY: usize = 64 * 1024 * 1024;

pub struct LoopbackHandle {
    pub port: u16,
    pub token: String,
    pub task: tokio::task::JoinHandle<()>,
}

/// Which address family the listener accepts connections on.
///
/// `Loopback` is the default and keeps the API private to this device.
/// `Lan` binds every interface so another machine on the same network can
/// reach the read routes; the Host/Origin guard widens with it (see
/// [`is_own_authority`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ListenMode {
    #[default]
    Loopback,
    Lan,
}

#[derive(Clone)]
struct AppState {
    server: Arc<Server>,
    /// The bound port, not the requested one: `serve(_, 0, _)` picks it at bind.
    port: u16,
    token: String,
    mode: ListenMode,
}

/// How often the supervisor probes its own listener (a plain TCP connect to
/// the bound port).
///
/// This interval must stay small. `std::time::Instant` on Apple platforms is
/// backed by `mach_absolute_time`, which does **not** advance while the device
/// is asleep (screen locked): an app suspended with the screen off can resume
/// with most of the interval still ahead of it, so a large interval would delay
/// the first post-resume probe. The reported bug is exactly a long screen-off
/// background stay, so 2 s bounds resume healing to <= 2 s. Cost is negligible:
/// one loopback connect plus immediate EOF is microseconds, and it only runs
/// while the app is running. Do not "optimize" this into tens of seconds.
const LOOPBACK_PROBE_INTERVAL: Duration = Duration::from_secs(2);
/// Upper bound on one probe. A reclaimed port refuses `connect()` immediately;
/// the timeout only stops a wedged (but still bound) socket from stalling the
/// supervisor.
const LOOPBACK_PROBE_TIMEOUT: Duration = Duration::from_secs(1);
const LOOPBACK_REBIND_BACKOFF_MIN: Duration = Duration::from_millis(250);
const LOOPBACK_REBIND_BACKOFF_MAX: Duration = Duration::from_secs(5);
/// Listen backlog for the adapter; matches the old `TcpListener::bind` default.
const LOOPBACK_BACKLOG: u32 = 1024;

/// A test seam for the supervisor: `probe(port)` returns `true` while the
/// listener still answers, `false` when its socket must be considered
/// reclaimed (that is what the OS does to the socket of a suspended iOS app).
type Probe = Box<dyn Fn(u16) -> futures::future::BoxFuture<'static, bool> + Send + Sync + 'static>;

fn default_probe() -> Probe {
    Box::new(|port| Box::pin(probe_loopback(port)))
}

pub async fn serve(
    server: Arc<Server>,
    port: u16,
    mode: ListenMode,
) -> Result<LoopbackHandle, String> {
    serve_with_probe(server, port, mode, LOOPBACK_PROBE_INTERVAL, default_probe()).await
}

/// Binds the listening socket with an explicit `SO_REUSEADDR` and backlog.
///
/// Both the initial bind and every supervisor rebind go through here. It has to
/// be explicit: accepted connections that a reclaimed listener still had in
/// flight can leave `TIME_WAIT` sockets on the same local port, and rebinding
/// without `SO_REUSEADDR` can fail `EADDRINUSE` for the platform's TIME_WAIT
/// interval (~15 s on Darwin) - the backoff loop would then just spin instead of
/// restoring service in one attempt. (`mio`/`std` set `SO_REUSEADDR` on some
/// platforms today, but that is a transitive detail, not a guarantee this
/// recovery path may rely on.)
fn bind_listener(addr: &'static str, port: u16) -> Result<tokio::net::TcpListener, String> {
    let ip = addr
        .parse::<std::net::IpAddr>()
        .map_err(|e| format!("listen {addr}:{port}: {e}"))?;
    let socket =
        tokio::net::TcpSocket::new_v4().map_err(|e| format!("listen {addr}:{port}: {e}"))?;
    socket
        .set_reuseaddr(true)
        .map_err(|e| format!("listen {addr}:{port}: {e}"))?;
    socket
        .bind(std::net::SocketAddr::new(ip, port))
        .map_err(|e| format!("listen {addr}:{port}: {e}"))?;
    socket
        .listen(LOOPBACK_BACKLOG)
        .map_err(|e| format!("listen {addr}:{port}: {e}"))
}

/// [`serve`] with the supervisor's probe interval and probe implementation
/// injectable, so tests can force "the socket was reclaimed" without asking the
/// OS to reclaim one.
async fn serve_with_probe(
    server: Arc<Server>,
    port: u16,
    mode: ListenMode,
    probe_interval: Duration,
    probe: Probe,
) -> Result<LoopbackHandle, String> {
    let addr = match mode {
        ListenMode::Loopback => "127.0.0.1",
        ListenMode::Lan => "0.0.0.0",
    };
    let listener = bind_listener(addr, port)?;
    let local = listener
        .local_addr()
        .map_err(|e| format!("local addr: {e}"))?;
    let mut entropy = [0u8; 32];
    rand::rngs::OsRng
        .try_fill_bytes(&mut entropy)
        .map_err(|_| "session entropy unavailable")?;
    let token = hex::encode(entropy);
    // The adapter must outlive the init call, so the supervisor observes the
    // core's lifetime token instead of being tied to one request.
    let lifetime = server.lifetime.clone();
    let state = AppState {
        server,
        port: local.port(),
        token: token.clone(),
        mode,
    };
    let app = Router::new().fallback(handler).with_state(state);
    let bound_port = local.port();
    let task = tokio::spawn(supervise_listener(
        listener,
        app,
        addr,
        bound_port,
        lifetime,
        probe_interval,
        probe,
    ));
    Ok(LoopbackHandle {
        port: bound_port,
        token,
        task,
    })
}

/// Owns the listening socket for the life of the core and rebinds it when the
/// system takes it away.
///
/// The kernel half of the iOS `AVPlayer -1004` bug lives here. On iOS the
/// system may reclaim the resources of a listening socket while the app is
/// suspended (Apple TN2277, "Networking and Multitasking"): when the app is
/// resumed the socket is dead, every `connect()` to the port is refused
/// (`NSURLErrorCannotConnectToHost`, what AVPlayer reports as "Could not
/// connect to the server"), and the app keeps running normally otherwise. A
/// bare `axum::serve` cannot recover: its accept loop retries accept errors
/// forever (it never returns), so the task stays alive, poll'ing a descriptor
/// the system took away, and the port is never listened on again. Only a
/// process restart re-creates it - exactly what the bug report observed.
///
/// This supervisor probes its own bound port and, when the probe is refused,
/// drops the dead task and binds the same port again (with backoff, logging
/// both events so `rust.log` has the trace). The advertised port, capability
/// and `base_url()` never change, so `/src` URLs already handed to AVPlayer and
/// to the app stay valid.
async fn supervise_listener(
    mut listener: tokio::net::TcpListener,
    app: Router,
    bind_addr: &'static str,
    port: u16,
    lifetime: CancellationToken,
    probe_interval: Duration,
    probe: Probe,
) {
    loop {
        log::info!("loopback listener accepting on {bind_addr}:{port}");
        let mut serving = AbortOnDrop::new(tokio::spawn({
            let app = app.clone();
            async move {
                // axum 0.8's serve future never resolves and never yields an
                // error (it retries accept errors itself), so there is no
                // result to inspect: this task can only end by being aborted.
                let _ = axum::serve(listener, app).await;
            }
        }));

        tokio::select! {
            _ = lifetime.cancelled() => {
                serving.stop().await;
                log::info!("loopback listener on {bind_addr}:{port} stopped");
                return;
            }
            _ = wait_until_deaf(probe_interval, &probe, port) => {}
        }

        // The socket died (OS reclaim) while the accept loop kept "running";
        // abort it and drop the listener before rebinding the same port.
        serving.stop().await;
        log::warn!(
            "loopback listener on {bind_addr}:{port} stopped accepting (socket reclaimed); rebinding"
        );
        match rebind_loop(bind_addr, port, &lifetime).await {
            Some(fresh) => listener = fresh,
            None => return,
        }
    }
}

/// Polls the listener until it stops answering.
async fn wait_until_deaf(probe_interval: Duration, probe: &Probe, port: u16) {
    loop {
        tokio::time::sleep(probe_interval).await;
        if !probe(port).await {
            return;
        }
    }
}

/// `true` while something accepts TCP connections on the published port.
async fn probe_loopback(port: u16) -> bool {
    matches!(
        tokio::time::timeout(
            LOOPBACK_PROBE_TIMEOUT,
            tokio::net::TcpStream::connect(("127.0.0.1", port))
        )
        .await,
        Ok(Ok(_))
    )
}

/// Rebinds the same port, backing off until it is free again or the core shuts
/// down. The advertised `base_url()` keeps its port, so this must be the same
/// one every time. The first attempt is immediate: after a resume the port is
/// expected to be free, and an extra sleep would only delay recovery.
async fn rebind_loop(
    bind_addr: &'static str,
    port: u16,
    lifetime: &CancellationToken,
) -> Option<tokio::net::TcpListener> {
    let mut delay = LOOPBACK_REBIND_BACKOFF_MIN;
    loop {
        if lifetime.is_cancelled() {
            return None;
        }
        match bind_listener(bind_addr, port) {
            Ok(listener) => {
                log::info!("loopback listener rebound on {bind_addr}:{port}");
                return Some(listener);
            }
            Err(err) => {
                log::warn!(
                    "loopback rebind on {bind_addr}:{port} failed: {err}; retrying in {delay:?}"
                );
                tokio::select! {
                    _ = lifetime.cancelled() => return None,
                    _ = tokio::time::sleep(delay) => {}
                }
                delay = (delay * 2).min(LOOPBACK_REBIND_BACKOFF_MAX);
            }
        }
    }
}

/// Aborts the supervised accept task whenever the supervisor leaves its loop -
/// normally, on cancellation, or by being aborted itself (the handle `shutdown`
/// holds is this supervisor's).
struct AbortOnDrop(Option<tokio::task::JoinHandle<()>>);

impl AbortOnDrop {
    fn new(handle: tokio::task::JoinHandle<()>) -> Self {
        Self(Some(handle))
    }

    async fn stop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
            let _ = handle.await;
        }
    }
}

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}

fn is_loopback_name(host: &str) -> bool {
    host == "127.0.0.1" || host.eq_ignore_ascii_case("localhost")
}

/// `authority` (a `Host` value or the part of an `Origin` after the scheme)
/// names this listener. Hosts compare case-insensitively; the port must be
/// explicit because the listener never runs on 80.
///
/// In `Lan` mode another device addresses this listener by one of the phone's
/// interface addresses, which the core cannot enumerate without holding the
/// list stale across a network change. It therefore accepts any **IP
/// literal** and still refuses every domain name - which is what keeps DNS
/// rebinding out: an attacker page resolves its own domain to this address, but
/// the browser then sends that domain in `Host`, and a name never matches.
fn is_own_authority(authority: &str, port: u16, mode: ListenMode) -> bool {
    let Some((host, p)) = authority.rsplit_once(':') else {
        return false;
    };
    if p.parse::<u16>().ok() != Some(port) {
        return false;
    }
    if is_loopback_name(host) {
        return true;
    }
    mode == ListenMode::Lan && host.parse::<std::net::IpAddr>().is_ok()
}

fn is_own_origin(origin: &str, port: u16, mode: ListenMode) -> bool {
    origin
        .get(..7)
        .filter(|scheme| scheme.eq_ignore_ascii_case("http://"))
        .is_some_and(|_| is_own_authority(&origin[7..], port, mode))
}

/// Refusal reason, or `None` when the request may be dispatched. A missing
/// `Host` is refused (HTTP/1.1 requires it; every real client sends it). A
/// missing `Origin` is allowed: native clients and same-origin GETs omit it.
/// `Origin: null` (sandboxed frames, file pages) is foreign.
fn refusal(headers: &HeaderMap, port: u16, mode: ListenMode) -> Option<&'static str> {
    let host = headers.get(header::HOST).and_then(|v| v.to_str().ok());
    if !host.is_some_and(|h| is_own_authority(h, port, mode)) {
        return Some("host not allowed");
    }
    if let Some(origin) = headers.get(header::ORIGIN) {
        if !origin.to_str().is_ok_and(|o| is_own_origin(o, port, mode)) {
            return Some("origin not allowed");
        }
    }
    None
}

/// Maps an infrastructure refusal (the adapter answers before the dispatcher
/// ever runs) to the same stable `kind` names the dispatcher emits (P1-4).
///
/// The status code is unchanged; only the JSON body gains the field:
/// - 413 is the only local size refusal -> `too_large`;
/// - 504 is the request deadline -> `timeout`;
/// - 499 (client closed the connection) matches no caller-input class, so it
///   stays `unknown`;
/// - 400/401/403/404/405 all mean "this request is not acceptable" ->
///   `bad_input`.
fn refusal_kind(status: StatusCode) -> &'static str {
    match status.as_u16() {
        413 => crate::error::ApiError::KIND_TOO_LARGE,
        504 => crate::error::ApiError::KIND_TIMEOUT,
        499 => crate::error::ApiError::KIND_UNKNOWN,
        _ => crate::error::ApiError::KIND_BAD_INPUT,
    }
}

fn refuse(status: StatusCode, message: &str) -> Response {
    let body = serde_json::to_vec(&json!({
        "success": false,
        "error": message,
        "kind": refusal_kind(status),
    }))
    .unwrap_or_default();
    Response::builder()
        .status(status)
        .header(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json; charset=utf-8"),
        )
        .body(Body::from(body))
        .unwrap_or_else(|_| status.into_response())
}

async fn handler(State(state): State<AppState>, req: axum::extract::Request) -> Response {
    use crate::api::{race_dispatch, RaceOutcome};
    use futures::StreamExt;

    let token = state.server.lifetime.child_token();
    // Body collection, dispatch, retries and file setup share this deadline.
    // The returned stream observes shutdown, not a whole-file time limit.
    match race_dispatch(
        &token,
        Some(crate::upstream::budget::HTTP_REQUEST_TIMEOUT),
        handle_request(state, req),
    )
    .await
    {
        RaceOutcome::Cancelled => refuse(StatusCode::from_u16(499).unwrap(), "request cancelled"),
        RaceOutcome::TimedOut => refuse(StatusCode::GATEWAY_TIMEOUT, "request deadline exceeded"),
        RaceOutcome::Done(response) => {
            let (parts, body) = response.into_parts();
            let stream = body.into_data_stream().take_until(token.cancelled_owned());
            Response::from_parts(parts, Body::from_stream(stream))
        }
    }
}

async fn handle_request(state: AppState, req: axum::extract::Request) -> Response {
    // Refuse before touching the body so a foreign page cannot make us read it.
    if let Some(reason) = refusal(req.headers(), state.port, state.mode) {
        return refuse(StatusCode::FORBIDDEN, reason);
    }
    let prefix = format!("/_session/{}", state.token);
    let path = req.uri().path();
    let scoped = path
        .strip_prefix(&prefix)
        .filter(|rest| rest.is_empty() || rest.starts_with('/'));
    let bearer = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok());
    let cookie_name = format!("fq_session_{}", state.port);
    let cookie_ok = req
        .headers()
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|h| h.to_str().ok())
        .flat_map(|h| h.split(';'))
        .filter_map(|part| part.trim().split_once('='))
        .any(|(name, value)| name == cookie_name && value == state.token);
    let request_path = scoped.unwrap_or(path).to_string();
    let capability_ok =
        scoped.is_some() || bearer == Some(format!("Bearer {}", state.token).as_str()) || cookie_ok;
    // 设备写接口单独用 401：它们是「需要能力才能调用」，语义比 404 更准确。
    // 其余不在 App 白名单里的路由对无能力调用者直接当不存在（404），
    // 这样同机其他 App 既读不到兼容面数据，也无法枚举有哪些路由。
    if !capability_ok && crate::dispatch::requires_capability(&request_path) {
        return refuse(StatusCode::UNAUTHORIZED, "session required");
    }
    // 免能力的 loopback 面只剩 App 自己用的 7 个读接口 + /src + /health；
    // 兼容面（听书、漫画、评论、排行榜……）与 account 路由都要求能力。
    // 这个判断放在读 body 之前：被拒的请求连 body 都不会被读入内存。
    if !capability_ok && !crate::dispatch::is_public_loopback_path(&request_path) {
        return refuse(StatusCode::NOT_FOUND, "not found");
    }
    let declared = req
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    if declared.is_some_and(|len| len > MAX_REQUEST_BODY as u64) {
        return refuse(StatusCode::PAYLOAD_TOO_LARGE, "request body too large");
    }

    let method = req.method().to_string();
    let uri = req.uri().clone();
    let headers: Vec<(String, String)> = req
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                String::from_utf8_lossy(v.as_bytes()).into_owned(),
            )
        })
        .collect();
    // Only the account routes read a request body; every other route takes
    // its arguments from the URL, so those bodies are drained in bounded
    // frames without being retained.
    let body = match crate::dispatch::request_body_limit(&request_path) {
        Some(limit) => match read_request_body(req.into_body(), limit).await {
            Ok(body) => body,
            Err(status) => return refuse(status, body_error_message(status)),
        },
        None => {
            if let Err(status) = discard_request_body(req.into_body()).await {
                return refuse(status, body_error_message(status));
            }
            Vec::new()
        }
    };
    let server = state.server;
    let request = Request {
        method,
        path: request_path,
        query: uri.query().unwrap_or("").to_string(),
        body,
        headers,
    };
    let resp = dispatch(&server, &request).await;

    let status = StatusCode::from_u16(resp.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut builder = Response::builder()
        .status(status)
        .header(header::REFERRER_POLICY, "no-referrer")
        .header(header::CACHE_CONTROL, "no-store")
        .header(
            header::CONTENT_TYPE,
            HeaderValue::from_str(&resp.content_type)
                .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
        );
    for (name, value) in &resp.headers {
        if let (Ok(n), Ok(v)) = (
            header::HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            builder = builder.header(n, v);
        }
    }

    match resp.body {
        ResponseBody::Bytes(bytes) => builder
            .body(Body::from(bytes))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
        ResponseBody::File {
            path,
            offset,
            length,
            ..
        } => match stream_file(&path, offset, length).await {
            Ok(body) => builder
                .body(body)
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        },
        ResponseBody::FileDecrypted {
            path,
            offset,
            length,
            index,
            key,
            ..
        } => match stream_decrypted_file(&path, offset, length, index, &key).await {
            Ok(body) => builder
                .body(body)
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        },
    }
}

fn body_error_message(status: StatusCode) -> &'static str {
    if status == StatusCode::PAYLOAD_TOO_LARGE {
        "request body too large"
    } else {
        "failed to read request body"
    }
}

/// Reads a request body into memory, refusing once it exceeds `limit`.
async fn read_request_body(mut body: Body, limit: usize) -> Result<Vec<u8>, StatusCode> {
    use http_body_util::BodyExt;

    let mut out = Vec::new();
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| StatusCode::BAD_REQUEST)?;
        if let Ok(data) = frame.into_data() {
            if out.len().saturating_add(data.len()) > limit {
                return Err(StatusCode::PAYLOAD_TOO_LARGE);
            }
            out.extend_from_slice(&data);
        }
    }
    Ok(out)
}

async fn discard_request_body(mut body: Body) -> Result<(), StatusCode> {
    use http_body_util::BodyExt;

    let mut consumed = 0usize;
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| StatusCode::BAD_REQUEST)?;
        if let Ok(data) = frame.into_data() {
            consumed = consumed.saturating_add(data.len());
            if consumed > MAX_REQUEST_BODY {
                return Err(StatusCode::PAYLOAD_TOO_LARGE);
            }
        }
    }
    Ok(())
}

async fn stream_file(path: &std::path::Path, offset: u64, length: u64) -> Result<Body, String> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    if offset > 0 {
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| e.to_string())?;
    }
    let limited = file.take(length);
    Ok(Body::from_stream(ReaderStream::with_capacity(
        limited,
        64 * 1024,
    )))
}

/// Streams a range of a CENC-encrypted cache file, decrypting each chunk at
/// its absolute file offset as it passes (P1-7). Chunks arrive sequentially,
/// and the transform is position-exact, so chunk boundaries do not matter.
async fn stream_decrypted_file(
    path: &std::path::Path,
    offset: u64,
    length: u64,
    index: Arc<crate::endpoints::video::CencIndex>,
    key: &[u8],
) -> Result<Body, String> {
    use futures::StreamExt;
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    if offset > 0 {
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| e.to_string())?;
    }
    let limited = file.take(length);
    let key = key.to_vec();
    let mut pos = offset;
    let stream = ReaderStream::with_capacity(limited, 64 * 1024).map(move |chunk| {
        chunk.map(|bytes| {
            let mut buf = bytes.to_vec();
            // The key was validated when the response was built; a failure
            // here can only come from a torn read, and passing the chunk
            // through untransformed is no worse than the I/O error path.
            let _ = crate::endpoints::video::apply_cenc_index(&mut buf, pos, &index, &key);
            pos += buf.len() as u64;
            axum::body::Bytes::from(buf)
        })
    });
    Ok(Body::from_stream(stream))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Bytes;
    use futures::stream;
    use std::convert::Infallible;

    #[tokio::test]
    async fn chunked_body_over_limit_is_rejected_without_buffering_the_whole_body() {
        let chunk = Bytes::from(vec![0; 1024 * 1024]);
        let chunks =
            (0..=MAX_REQUEST_BODY / chunk.len()).map(move |_| Ok::<_, Infallible>(chunk.clone()));
        let body = Body::from_stream(stream::iter(chunks));

        assert_eq!(
            discard_request_body(body).await,
            Err(StatusCode::PAYLOAD_TOO_LARGE)
        );
    }

    /// P1-4: adapter-level refusals use the same JSON shape as dispatcher
    /// errors, so a client parses one envelope for both paths.
    #[tokio::test]
    async fn infrastructure_refusals_carry_a_kind() {
        let cases = [
            (StatusCode::FORBIDDEN, "bad_input"),
            (StatusCode::UNAUTHORIZED, "bad_input"),
            (StatusCode::NOT_FOUND, "bad_input"),
            (StatusCode::PAYLOAD_TOO_LARGE, "too_large"),
            (StatusCode::BAD_REQUEST, "bad_input"),
            (StatusCode::GATEWAY_TIMEOUT, "timeout"),
            (StatusCode::from_u16(499).unwrap(), "unknown"),
        ];
        for (status, kind) in cases {
            let bytes = axum::body::to_bytes(refuse(status, "probe").into_body(), 1024)
                .await
                .expect("refusal body");
            let value: serde_json::Value =
                serde_json::from_slice(&bytes).expect("refusal body is JSON");
            assert_eq!(value["success"], false, "status {status}");
            assert_eq!(value["error"], "probe", "status {status}");
            assert_eq!(value["kind"], kind, "status {status}");
        }
    }

    // --- loopback supervisor: iOS TN2277 socket reclaim -------------------

    use crate::config::Config;
    use crate::device::DevicePool;
    use crate::endpoints::Ctx;
    use crate::sign::Manager;
    use crate::upstream::UpstreamClient;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::sync::Notify;

    fn runtime_dir(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "fqapi-loopback-{tag}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(dir.join("config")).expect("config dir");
        std::fs::create_dir_all(dir.join("src")).expect("src dir");
        std::fs::write(dir.join("config/config.json"), r#"{"port":0}"#).expect("config json");
        dir
    }

    /// A real dispatcher `Server` over a temporary runtime directory, so the
    /// supervisor is exercised end to end (capability, `/health`, `/src`
    /// router) rather than against a stand-in.
    async fn test_server(dir: &Path) -> Arc<Server> {
        let config_path = dir.join("config/config.json");
        let cfg = Arc::new(
            Config::load(config_path.to_str().expect("utf-8 config path")).expect("config"),
        );
        let pool = DevicePool::new(dir.join("config/device_pool.json"))
            .await
            .expect("device pool");
        let up = Arc::new(UpstreamClient::new(pool.clone(), Manager::new()).expect("upstream"));
        Arc::new(Server::new(Arc::new(Ctx {
            up,
            pool,
            cfg,
            src_dir: dir.join("src").to_string_lossy().into_owned(),
        })))
    }

    /// `GET path` against the adapter, returning its status code. The request
    /// carries the `Host` the adapter requires, and `Connection: close` keeps
    /// the read finite.
    async fn http_status(port: u16, path: &str) -> Option<u16> {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .ok()?;
        let request =
            format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).await.ok()?;
        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), stream.read_to_end(&mut response))
            .await
            .ok()?
            .ok()?;
        let status_line = String::from_utf8_lossy(&response);
        status_line
            .lines()
            .next()?
            .split_whitespace()
            .nth(1)?
            .parse()
            .ok()
    }

    /// Waits until the adapter answers `200` for `path`.
    async fn wait_until_health(port: u16, path: &str, limit: Duration) -> bool {
        tokio::time::timeout(limit, async {
            loop {
                if http_status(port, path).await == Some(200) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .is_ok()
    }

    /// Waits until `connect()` is refused: the exact client-visible state of a
    /// reclaimed listening socket (`ECONNREFUSED` / `-1004`).
    async fn wait_until_refused(port: u16, limit: Duration) -> bool {
        tokio::time::timeout(limit, async {
            loop {
                match tokio::net::TcpStream::connect(("127.0.0.1", port)).await {
                    Err(err) if err.kind() == std::io::ErrorKind::ConnectionRefused => return,
                    _ => tokio::time::sleep(Duration::from_millis(5)).await,
                }
            }
        })
        .await
        .is_ok()
    }

    /// TN2277 regression: when the listening socket is reclaimed while the app
    /// is suspended, the supervisor must rebind the **same** port and keep the
    /// **same** capability, so `/src` URLs already handed to AVPlayer start
    /// working again without an app restart. The probe seam forces "reclaimed"
    /// on the first probe and "healthy" afterwards; the OS is never involved.
    #[tokio::test]
    async fn supervisor_rebinds_the_same_port_and_keeps_the_capability_after_reclaim() {
        let dir = runtime_dir("reclaim");
        let server = test_server(&dir).await;
        let probes = Arc::new(AtomicUsize::new(0));
        let probed = Arc::new(Notify::new());
        let counter = Arc::clone(&probes);
        let notify = Arc::clone(&probed);
        let probe: Probe = Box::new(move |_port: u16| {
            let seen = counter.fetch_add(1, Ordering::SeqCst);
            if seen == 0 {
                notify.notify_one();
            }
            // First probe: reclaimed. The rebound listener answers the rest.
            Box::pin(async move { seen > 0 })
        });
        let handle = serve_with_probe(
            server.clone(),
            0,
            ListenMode::Loopback,
            Duration::from_millis(10),
            probe,
        )
        .await
        .expect("serve");
        let port = handle.port;
        let scoped_health = format!("/_session/{}/health", handle.token);

        assert!(
            wait_until_health(port, &scoped_health, Duration::from_secs(2)).await,
            "the adapter must serve before the reclaim"
        );
        tokio::time::timeout(Duration::from_secs(2), probed.notified())
            .await
            .expect("the supervisor must run its first probe");
        assert!(
            wait_until_health(port, &scoped_health, Duration::from_secs(5)).await,
            "same port + same capability must answer after the rebind"
        );
        tokio::time::timeout(Duration::from_secs(2), async {
            while probes.load(Ordering::SeqCst) < 2 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("the probe must run again against the rebound listener");

        server.lifetime.cancel();
        let _ = handle.task.await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `shutdown()` first cancels `server.lifetime`; that path alone must drop
    /// the listening socket (the port becomes refused).
    #[tokio::test]
    async fn lifetime_cancellation_releases_the_port() {
        let dir = runtime_dir("cancel");
        let server = test_server(&dir).await;
        let handle = serve_with_probe(
            server.clone(),
            0,
            ListenMode::Loopback,
            Duration::from_secs(60),
            default_probe(),
        )
        .await
        .expect("serve");
        let port = handle.port;
        assert!(
            wait_until_health(port, "/health", Duration::from_secs(2)).await,
            "the adapter must serve before shutdown"
        );

        server.lifetime.cancel();
        let _ = handle.task.await;
        assert!(
            wait_until_refused(port, Duration::from_secs(2)).await,
            "lifetime cancellation must release the port"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `shutdown()` also aborts the supervisor handle; that path must release
    /// the port as well (the inner accept task is aborted by its guard).
    #[tokio::test]
    async fn aborting_the_handle_releases_the_port() {
        let dir = runtime_dir("abort");
        let server = test_server(&dir).await;
        let handle = serve_with_probe(
            server.clone(),
            0,
            ListenMode::Loopback,
            Duration::from_secs(60),
            default_probe(),
        )
        .await
        .expect("serve");
        let port = handle.port;
        assert!(
            wait_until_health(port, "/health", Duration::from_secs(2)).await,
            "the adapter must serve before shutdown"
        );

        handle.task.abort();
        let _ = handle.task.await;
        assert!(
            wait_until_refused(port, Duration::from_secs(2)).await,
            "aborting the supervisor must release the port"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
