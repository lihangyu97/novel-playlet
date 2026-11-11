//! M1 loopback streaming: `mode=stream` starts a background download and the
//! `/src` loopback serves Range requests out of the in-progress `.part`.
//!
//! A local TCP server stands in for the upstream host (the mock-origin seam
//! rewrites every absolute URL onto it), and the CENC fixture is re-keyed to
//! the content key a `spade_a` resolves to, so the whole path — source
//! resolution, progress reporting, range waiting, per-range decryption and the
//! completion rename — is exercised without network access.

use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
use std::time::Duration;

use super::*;

/// A `spade_a` whose derived CENC key differs from the fixture's.
const SPADE_A: &str = "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==";
const FIXTURE: &str = include_str!("../../../testdata/cenc_sample_fixture.json");
/// Fixture `moov` ends at 346; a prefix past it makes the moov readable while
/// the tail of the file is still missing.
const PARTIAL_PREFIX: usize = 380;
/// Second stage: past the tail range requested below, so it is served while
/// the body is still incomplete.
const PARTIAL_SECOND: usize = 421;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "fqapp-stream-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn fixture() -> serde_json::Value {
    serde_json::from_str(FIXTURE).expect("cenc_sample_fixture.json")
}

fn b64(f: &serde_json::Value, key: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(f[key].as_str().expect(key))
        .expect("fixture base64")
}

/// The CENC fixture re-keyed to the content key `SPADE_A` resolves to, plus
/// the decrypted view the serve path must produce for it.
fn streaming_cenc_payloads() -> (Vec<u8>, Vec<u8>) {
    let fixture = fixture();
    let cenc = &fixture["cenc"];
    let original = b64(cenc, "full_sample_b64");
    let fixture_key = hex::decode(cenc["key_hex"].as_str().expect("key_hex")).expect("fixture key");
    let index = build_cenc_index(&original, 0, original.len() as u64)
        .expect("build index")
        .expect("fixture must be encrypted");
    let mut decrypted = original.clone();
    apply_cenc_index(&mut decrypted, 0, &index, &fixture_key).expect("reference decrypt");

    let key = derive_spade_content_key(SPADE_A);
    assert_eq!(key.len(), 16, "SPADE_A must yield a 16-byte CENC key");
    assert_ne!(key, fixture_key, "the fixture must be re-keyed below");

    // Re-key by XORing the sample ranges with the fixture keystream and then
    // with the spade keystream. The header patches are excluded so the served
    // bytes stay a valid encrypted MP4: the serve path must apply them itself.
    let mut ranges_only = index;
    ranges_only.patches.clear();
    let mut ciphertext = original;
    apply_cenc_index(&mut ciphertext, 0, &ranges_only, &fixture_key).expect("strip fixture key");
    apply_cenc_index(&mut ciphertext, 0, &ranges_only, &key).expect("apply spade key");
    (ciphertext, decrypted)
}

/// A shortplay `video_model` response pointing at `video_url`.
fn shortplay_body(video_url: &str) -> Value {
    let model = json!({
        "key_seed": "e/sKbv4roNA/4Xm/6oFbFjBm6AIBteh9Z0EddXTl7yI=",
        "video_list": {
            "video_1": {
                "definition": "720p",
                "main_url": base64::engine::general_purpose::STANDARD.encode(video_url),
                "spade_a": SPADE_A,
                "vwidth": 720,
                "vheight": 1280,
            }
        }
    });
    json!({
        "data": {
            "vid_stream": {
                "video_model": serde_json::to_string(&model).expect("model json"),
                "vertical": true,
            }
        }
    })
}

/// How the mock upstream answers the video GET.
#[derive(Clone)]
enum VideoPlan {
    /// The whole body in one go.
    Full(Vec<u8>),
    /// Headers + `first` bytes, then `second` bytes, then the rest, each
    /// stage driven by the test. While the second stage is held the response
    /// body is incomplete (so the session is still `Downloading`) even though
    /// all requested range bytes are on disk.
    Gated {
        body: Vec<u8>,
        first: usize,
        second: usize,
        prefix_sent: Arc<tokio::sync::Notify>,
        release_all: Arc<tokio::sync::Notify>,
        all_sent: Arc<tokio::sync::Notify>,
        finish: Arc<tokio::sync::Notify>,
    },
    /// A chunked body without `Content-Length`: stream mode cannot compute
    /// ranges and must fall back to the whole-episode behaviour.
    Chunked(Vec<u8>),
    /// Advertise `advertised` bytes but send `send` and close: a truncated
    /// body the download must treat as a failure.
    Broken {
        advertised: u64,
        send: usize,
        delay: Duration,
    },
}

struct MockUpstream {
    origin: String,
    video_requests: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl MockUpstream {
    async fn spawn(shortplay: Value, plan: VideoPlan) -> Self {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind mock upstream");
        let port = listener.local_addr().expect("mock address").port();
        let video_requests = Arc::new(AtomicUsize::new(0));
        let counter = video_requests.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let shortplay = shortplay.clone();
                let plan = plan.clone();
                let counter = counter.clone();
                tokio::spawn(async move {
                    let mut buffer = [0u8; 16 * 1024];
                    let Ok(read) = socket.read(&mut buffer).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buffer[..read]).to_string();
                    let path = request
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().nth(1))
                        .unwrap_or("")
                        .to_string();
                    if path.contains("/video_model/") {
                        let body = serde_json::to_vec(&shortplay).unwrap_or_default();
                        write_response(&mut socket, "application/json", &body).await;
                        return;
                    }
                    if !path.contains("/example") {
                        // The phoenix auxiliary request: an unusable envelope
                        // is non-fatal (quality tiers are not requested here).
                        write_response(&mut socket, "application/json", b"{}").await;
                        return;
                    }
                    counter.fetch_add(1, AtomicOrdering::SeqCst);
                    match plan {
                        VideoPlan::Full(body) => {
                            write_response(&mut socket, "video/mp4", &body).await;
                        }
                        VideoPlan::Gated {
                            body,
                            first,
                            second,
                            prefix_sent,
                            release_all,
                            all_sent,
                            finish,
                        } => {
                            let header = format!(
                                "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\n\r\n",
                                body.len()
                            );
                            let _ = socket.write_all(header.as_bytes()).await;
                            let first = first.min(body.len());
                            let _ = socket.write_all(&body[..first]).await;
                            let _ = socket.flush().await;
                            prefix_sent.notify_one();
                            release_all.notified().await;
                            let second = second.min(body.len()).max(first);
                            let _ = socket.write_all(&body[first..second]).await;
                            let _ = socket.flush().await;
                            all_sent.notify_one();
                            finish.notified().await;
                            let _ = socket.write_all(&body[second..]).await;
                            let _ = socket.shutdown().await;
                        }
                        VideoPlan::Chunked(body) => {
                            let header = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: video/mp4\r\nTransfer-Encoding: chunked\r\n\r\n";
                            let _ = socket.write_all(header.as_bytes()).await;
                            for chunk in body.chunks(64) {
                                let size = format!("{:x}\r\n", chunk.len());
                                let _ = socket.write_all(size.as_bytes()).await;
                                let _ = socket.write_all(chunk).await;
                                let _ = socket.write_all(b"\r\n").await;
                            }
                            let _ = socket.write_all(b"0\r\n\r\n").await;
                            let _ = socket.shutdown().await;
                        }
                        VideoPlan::Broken {
                            advertised,
                            send,
                            delay,
                        } => {
                            tokio::time::sleep(delay).await;
                            let header = format!(
                                "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: video/mp4\r\nContent-Length: {advertised}\r\n\r\n"
                            );
                            let _ = socket.write_all(header.as_bytes()).await;
                            let _ = socket.write_all(&vec![0u8; send]).await;
                            let _ = socket.flush().await;
                            let _ = socket.shutdown().await;
                        }
                    }
                });
            }
        });
        MockUpstream {
            origin: format!("http://127.0.0.1:{port}"),
            video_requests,
            task,
        }
    }
}

async fn write_response(socket: &mut tokio::net::TcpStream, content_type: &str, body: &[u8]) {
    use tokio::io::AsyncWriteExt;
    let header = format!(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    let _ = socket.write_all(header.as_bytes()).await;
    let _ = socket.write_all(body).await;
    let _ = socket.flush().await;
    let _ = socket.shutdown().await;
}

/// A `Ctx` over `dir` whose upstream traffic goes to `origin`. The device pool
/// is pre-seeded so signed calls do not trigger a real registration round trip.
async fn test_ctx(origin: &str, dir: &Path) -> Ctx {
    let devices: Vec<Value> = (0..5)
        .map(|index| {
            json!({
                "device_id": format!("70000000000000{index:04}"),
                "install_id": format!("40000000000000{index:04}"),
                "secret_key": format!("stream-test-secret-{index}"),
                "platform": "android",
                "status": "active",
                "created_time": "2026-01-01 00:00:00",
                "last_used": "2026-01-01 00:00:00",
                "use_count": 0,
            })
        })
        .collect();
    std::fs::write(
        dir.join("pool.json"),
        serde_json::to_vec(&json!({ "android": devices })).expect("pool json"),
    )
    .expect("write pool");
    let pool =
        crate::device::DevicePool::with_mock_origin(dir.join("pool.json"), origin.to_string())
            .await
            .expect("device pool");
    let up = crate::upstream::UpstreamClient::with_mock_origin(
        pool.clone(),
        crate::sign::Manager::new(),
        origin.to_string(),
    )
    .expect("upstream client");
    Ctx {
        up: Arc::new(up),
        pool,
        cfg: Arc::new(crate::config::Config::default()),
        src_dir: dir.to_string_lossy().into_owned(),
    }
}

fn get_request(filename: &str, range: Option<&str>) -> crate::dispatch::Request {
    let mut headers = Vec::new();
    if let Some(range) = range {
        headers.push(("range".to_string(), range.to_string()));
    }
    crate::dispatch::Request {
        method: "GET".to_string(),
        path: format!("/src/{filename}"),
        query: String::new(),
        body: Vec::new(),
        headers,
    }
}

fn head_request(filename: &str, range: Option<&str>) -> crate::dispatch::Request {
    let mut request = get_request(filename, range);
    request.method = "HEAD".to_string();
    request
}

fn response_header<'a>(response: &'a crate::dispatch::Response, name: &str) -> Option<&'a str> {
    response
        .headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

async fn wait_until(mut condition: impl FnMut() -> bool, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    while tokio::time::Instant::now() < deadline {
        if condition() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    condition()
}

fn shortplay_params(video_id: &str) -> Params {
    Params::parse(&format!("video_id={video_id}&mode=stream&variants=0"))
}

/// Whether this process still has a streaming session for `final_path`
/// (other tests run in parallel and may hold their own sessions).
fn session_registered(final_path: &Path) -> bool {
    let key = stream_session_key(final_path);
    STREAM_SESSIONS
        .lock()
        .map(|sessions| sessions.contains_key(&key))
        .unwrap_or(true)
}

/// Streaming start → a Range past the downloaded prefix waits → the arrived
/// bytes decrypt correctly → the completion rename lands the final file and
/// later requests take the completed-file path.
#[tokio::test]
async fn stream_range_waits_then_serves_decrypted_bytes_and_commits() {
    let (ciphertext, plaintext) = streaming_cenc_payloads();
    let total = ciphertext.len();
    let prefix_sent = Arc::new(tokio::sync::Notify::new());
    let release_all = Arc::new(tokio::sync::Notify::new());
    let all_sent = Arc::new(tokio::sync::Notify::new());
    let finish = Arc::new(tokio::sync::Notify::new());
    let mock = MockUpstream::spawn(
        shortplay_body("https://v26-reading-video.fqnovelvod.com/example.mp4"),
        VideoPlan::Gated {
            body: ciphertext.clone(),
            first: PARTIAL_PREFIX,
            second: PARTIAL_SECOND,
            prefix_sent: prefix_sent.clone(),
            release_all: release_all.clone(),
            all_sent: all_sent.clone(),
            finish: finish.clone(),
        },
    )
    .await;
    let dir = temp_dir("stream-range");
    let ctx = test_ctx(&mock.origin, &dir).await;
    let filename = "vid-range.mp4";

    let response = handle_video(&ctx, &shortplay_params("vid-range"))
        .await
        .expect("mode=stream must answer immediately");
    assert_eq!(response["streaming"], true);
    assert_eq!(response["cached"], false);
    assert_eq!(response["video_url"], format!("/src/{filename}"));
    assert_eq!(response["video_id"], "vid-range");

    tokio::time::timeout(Duration::from_secs(5), prefix_sent.notified())
        .await
        .expect("mock must deliver the prefix");
    assert_eq!(mock.video_requests.load(AtomicOrdering::SeqCst), 1);

    // HEAD answers headers only and must not wait for the missing tail.
    let head = serve_src_file(
        &ctx.src_dir,
        filename,
        &head_request(filename, Some("bytes=0-27")),
    )
    .await
    .expect("streaming HEAD");
    assert_eq!(head.status, 206);
    assert_eq!(response_header(&head, "content-length"), Some("28"));
    assert_eq!(
        response_header(&head, "content-range"),
        Some(format!("bytes 0-27/{total}").as_str())
    );
    assert_eq!(response_header(&head, "accept-ranges"), Some("bytes"));
    assert!(matches!(head.body, crate::dispatch::ResponseBody::Bytes(ref body) if body.is_empty()));

    // A range in the not-yet-downloaded tail must wait.
    let tail_range = "bytes=400-420";
    let pending = tokio::time::timeout(
        Duration::from_millis(250),
        serve_src_file(
            &ctx.src_dir,
            filename,
            &get_request(filename, Some(tail_range)),
        ),
    )
    .await;
    assert!(
        pending.is_err(),
        "a range past the download frontier must wait, not answer"
    );
    assert!(
        dir.join(format!("{filename}.part")).exists(),
        "the waiting request must not disturb the in-progress part"
    );

    // Let the rest arrive but keep the body open: the session is still
    // downloading, so the range below is necessarily served from `.part`.
    release_all.notify_one();
    tokio::time::timeout(Duration::from_secs(5), all_sent.notified())
        .await
        .expect("mock must deliver the rest");

    let response = serve_src_file(
        &ctx.src_dir,
        filename,
        &get_request(filename, Some(tail_range)),
    )
    .await
    .expect("streaming range");
    assert_eq!(response.status, 206);
    assert!(response_header(&head, "content-length").is_some());
    assert_eq!(
        response_header(&response, "content-range"),
        Some(format!("bytes 400-420/{total}").as_str())
    );
    assert_eq!(response_header(&response, "content-length"), Some("21"));
    match &response.body {
        crate::dispatch::ResponseBody::FileDecrypted { path, .. } => {
            assert!(
                path.file_name()
                    .map(|name| name.to_string_lossy().starts_with(".stream-snap-"))
                    .unwrap_or(false),
                "the in-progress response must read a stable snapshot, got {}",
                path.display()
            );
        }
        other => panic!("expected a decrypted body, got {other:?}"),
    }
    let body = response.into_bytes().await.expect("streamed range body");
    assert_eq!(body, plaintext[400..=420]);

    // Several range connections at once (what the players do) must all answer
    // from the same in-progress part without 5xx.
    let ranges = [
        "bytes=0-27",
        "bytes=28-199",
        "bytes=200-345",
        "bytes=346-420",
    ];
    let mut handles = Vec::new();
    for range in ranges {
        let src_dir = ctx.src_dir.clone();
        let request = get_request(filename, Some(range));
        handles.push(tokio::spawn(async move {
            serve_src_file(&src_dir, filename, &request).await
        }));
    }
    for (index, handle) in handles.into_iter().enumerate() {
        let response = handle.await.expect("range task").expect("range response");
        assert!(
            response.status == 200 || response.status == 206,
            "concurrent range {index} failed: {}",
            response.status
        );
    }

    // Complete the download: `.part` becomes the final file and the completed
    // path takes over.
    finish.notify_one();
    let part_path = dir.join(format!("{filename}.part"));
    let final_path = dir.join(filename);
    assert!(
        wait_until(
            || !part_path.exists() && final_path.exists(),
            Duration::from_secs(5)
        )
        .await,
        "the finished download must rename .part to the final name"
    );
    assert_eq!(std::fs::read(&final_path).expect("final file"), ciphertext);
    let key_sidecar = PathBuf::from(format!("{}.key", final_path.display()));
    assert_eq!(
        std::fs::read_to_string(&key_sidecar).expect("key sidecar"),
        hex::encode(derive_spade_content_key(SPADE_A)),
    );
    assert_eq!(mock.video_requests.load(AtomicOrdering::SeqCst), 1);

    // The session must be unregistered once it committed.
    assert!(
        wait_until(|| !session_registered(&final_path), Duration::from_secs(5)).await,
        "a committed session must be unregistered"
    );

    let response = serve_src_file(&ctx.src_dir, filename, &get_request(filename, None))
        .await
        .expect("completed file");
    assert_eq!(response.status, 200);
    match &response.body {
        crate::dispatch::ResponseBody::FileDecrypted { path, .. } => {
            assert_eq!(
                path.file_name().and_then(|name| name.to_str()),
                Some(filename),
                "a completed request must take the final-file path"
            );
        }
        other => panic!("expected the completed CENC path, got {other:?}"),
    }
    let body = response.into_bytes().await.expect("completed body");
    assert_eq!(body, plaintext);

    mock.task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

/// The client's whole-episode fallback while a stream session is running must
/// wait for that session (same per-entry lock) instead of deleting or
/// truncating its `.part`, and must then hit the completed cache without a
/// second download.
#[tokio::test]
async fn whole_episode_download_waits_for_the_streaming_session() {
    let (ciphertext, plaintext) = streaming_cenc_payloads();
    let prefix_sent = Arc::new(tokio::sync::Notify::new());
    let release_all = Arc::new(tokio::sync::Notify::new());
    let all_sent = Arc::new(tokio::sync::Notify::new());
    let finish = Arc::new(tokio::sync::Notify::new());
    let mock = MockUpstream::spawn(
        shortplay_body("https://v26-reading-video.fqnovelvod.com/example.mp4"),
        VideoPlan::Gated {
            body: ciphertext.clone(),
            first: PARTIAL_PREFIX,
            second: PARTIAL_SECOND,
            prefix_sent: prefix_sent.clone(),
            release_all: release_all.clone(),
            all_sent: all_sent.clone(),
            finish: finish.clone(),
        },
    )
    .await;
    let dir = temp_dir("stream-coexist");
    let ctx = test_ctx(&mock.origin, &dir).await;
    let filename = "vid-coexist.mp4";

    let response = handle_video(&ctx, &shortplay_params("vid-coexist"))
        .await
        .expect("mode=stream");
    assert_eq!(response["streaming"], true);
    tokio::time::timeout(Duration::from_secs(5), prefix_sent.notified())
        .await
        .expect("prefix delivered");

    let part_path = dir.join(format!("{filename}.part"));
    assert!(
        wait_until(
            || std::fs::metadata(&part_path)
                .map(|meta| meta.len() > 0)
                .unwrap_or(false),
            Duration::from_secs(5)
        )
        .await,
        "the download must have written the prefix into the part"
    );
    let prefix_len = std::fs::metadata(&part_path).expect("part exists").len();

    let key = derive_spade_content_key(SPADE_A);
    // A second Ctx over the same runtime directory/origin: the per-entry lock
    // is process-wide, which is exactly the coordination under test.
    let fallback_ctx = test_ctx(&mock.origin, &dir).await;
    let fallback = tokio::spawn(async move {
        download_and_save(
            &fallback_ctx,
            "vid-coexist",
            "https://v26-reading-video.fqnovelvod.com/example.mp4",
            &key,
            false,
            None,
            None,
        )
        .await
    });
    // While the stream session holds the entry, the default request must be
    // blocked: no second upstream GET, no truncated part.
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert!(
        !fallback.is_finished(),
        "the fallback must wait for the stream session"
    );
    assert_eq!(
        std::fs::metadata(&part_path).expect("part survives").len(),
        prefix_len,
        "the fallback must not truncate the in-progress part"
    );
    assert_eq!(mock.video_requests.load(AtomicOrdering::SeqCst), 1);

    release_all.notify_one();
    tokio::time::timeout(Duration::from_secs(5), all_sent.notified())
        .await
        .expect("rest delivered");
    finish.notify_one();

    let saved = tokio::time::timeout(Duration::from_secs(10), fallback)
        .await
        .expect("fallback must finish once the session commits")
        .expect("fallback task")
        .expect("fallback download");
    assert_eq!(saved, format!("/src/{filename}"));
    assert_eq!(mock.video_requests.load(AtomicOrdering::SeqCst), 1);
    assert_eq!(
        std::fs::read(dir.join(filename)).expect("final file"),
        ciphertext
    );
    assert!(!part_path.exists());
    let completed = serve_src_file(&ctx.src_dir, filename, &get_request(filename, None))
        .await
        .expect("completed serve");
    assert_eq!(completed.into_bytes().await.expect("body"), plaintext);

    mock.task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A failed background download must fail requests that are already waiting
/// with a 5xx JSON (never hang), and must clean up the partial file.
#[tokio::test]
async fn failed_stream_download_answers_waiting_ranges_with_502() {
    let mock = MockUpstream::spawn(
        json!({}),
        VideoPlan::Broken {
            advertised: 500,
            send: 100,
            delay: Duration::from_millis(300),
        },
    )
    .await;
    let dir = temp_dir("stream-failure");
    let ctx = test_ctx(&mock.origin, &dir).await;
    let filename = "vid-failure.mp4";

    let _session = start_stream_session(
        &ctx,
        "vid-failure",
        "https://v26-reading-video.fqnovelvod.com/example.mp4",
        &[],
        false,
        None,
    );

    let response = tokio::time::timeout(
        Duration::from_secs(10),
        serve_src_file(
            &ctx.src_dir,
            filename,
            &get_request(filename, Some("bytes=200-300")),
        ),
    )
    .await
    .expect("a failed download must answer waiting ranges, not hang")
    .expect("a session exists, so the request is handled");
    assert_eq!(response.status, 502);
    let body = response.into_bytes().await.expect("error body");
    let error: Value = serde_json::from_slice(&body).expect("error json");
    assert_eq!(error["success"], false);
    assert!(
        error["error"]
            .as_str()
            .unwrap_or("")
            .contains("streaming video unavailable"),
        "unexpected error body: {error}"
    );

    // The failed session removes its `.part` and its registry entry.
    assert!(
        wait_until(
            || !dir.join(format!("{filename}.part")).exists(),
            Duration::from_secs(5)
        )
        .await,
        "the failed download must remove the part file"
    );
    assert!(
        wait_until(
            || !session_registered(&dir.join(filename)),
            Duration::from_secs(5)
        )
        .await,
        "a failed session must be unregistered"
    );

    mock.task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Only `.mp4` streams: a `.m4s` source keeps the pre-M1 whole-episode
/// download and reports `streaming: false` with the local URL.
#[tokio::test]
async fn non_mp4_source_falls_back_to_the_whole_episode_download() {
    let (ciphertext, _plaintext) = streaming_cenc_payloads();
    let mock = MockUpstream::spawn(
        shortplay_body("https://v26-reading-video.fqnovelvod.com/example.m4s"),
        VideoPlan::Full(ciphertext.clone()),
    )
    .await;
    let dir = temp_dir("stream-m4s");
    let ctx = test_ctx(&mock.origin, &dir).await;

    let response = handle_video(&ctx, &shortplay_params("vid-m4s"))
        .await
        .expect("mode=stream fallback");
    assert_eq!(response["streaming"], false);
    assert_eq!(response["video_url"], "/src/vid-m4s.m4s");
    assert!(dir.join("vid-m4s.m4s").exists());
    assert_eq!(
        std::fs::read(dir.join("vid-m4s.m4s")).expect("downloaded m4s"),
        ciphertext
    );

    mock.task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Without an upstream `Content-Length` there is no resource size to serve
/// ranges against, so `mode=stream` keeps the pre-M1 behaviour: it waits for
/// the whole-episode download and answers the finished local URL.
#[tokio::test]
async fn missing_content_length_falls_back_to_whole_episode_download() {
    let (ciphertext, plaintext) = streaming_cenc_payloads();
    let mock = MockUpstream::spawn(
        shortplay_body("https://v26-reading-video.fqnovelvod.com/example.mp4"),
        VideoPlan::Chunked(ciphertext.clone()),
    )
    .await;
    let dir = temp_dir("stream-no-length");
    let ctx = test_ctx(&mock.origin, &dir).await;

    let response = handle_video(&ctx, &shortplay_params("vid-nolen"))
        .await
        .expect("mode=stream fallback");
    assert_eq!(response["streaming"], false, "{response}");
    assert_eq!(response["video_url"], "/src/vid-nolen.mp4", "{response}");
    assert_eq!(
        std::fs::read(dir.join("vid-nolen.mp4")).expect("downloaded file"),
        ciphertext
    );
    assert_eq!(mock.video_requests.load(AtomicOrdering::SeqCst), 1);

    let served = serve_src_file(
        &ctx.src_dir,
        "vid-nolen.mp4",
        &get_request("vid-nolen.mp4", None),
    )
    .await
    .expect("completed serve");
    assert_eq!(served.into_bytes().await.expect("body"), plaintext);

    mock.task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A complete cache entry makes `mode=stream` answer the finished file without
/// starting an upstream video download.
#[tokio::test]
async fn complete_cache_answers_mode_stream_without_downloading() {
    let fixture = fixture();
    let cenc = &fixture["cenc"];
    let encrypted = b64(cenc, "full_sample_b64");
    let fixture_key = hex::decode(cenc["key_hex"].as_str().expect("key_hex")).expect("key");
    let mock = MockUpstream::spawn(
        shortplay_body("https://v26-reading-video.fqnovelvod.com/example.mp4"),
        VideoPlan::Full(encrypted.clone()),
    )
    .await;
    let dir = temp_dir("stream-cached");
    let ctx = test_ctx(&mock.origin, &dir).await;
    let final_path = dir.join("vid-cached.mp4");
    std::fs::write(&final_path, &encrypted).expect("cached video");
    std::fs::write(
        PathBuf::from(format!("{}.key", final_path.display())),
        hex::encode(&fixture_key),
    )
    .expect("cached key");
    let cached_body = encrypted.clone();
    let cached_key = fixture_key.clone();

    let response = handle_video(&ctx, &shortplay_params("vid-cached"))
        .await
        .expect("mode=stream cached");
    assert_eq!(response["streaming"], false);
    assert_eq!(response["cached"], true);
    assert_eq!(response["video_url"], "/src/vid-cached.mp4");
    assert_eq!(
        mock.video_requests.load(AtomicOrdering::SeqCst),
        0,
        "a complete cache must not start a download"
    );

    // The cached entry still serves decrypted ranges through the completed
    // path (fixture key, not the spade key).
    let response = serve_src_file(
        &ctx.src_dir,
        "vid-cached.mp4",
        &get_request("vid-cached.mp4", None),
    )
    .await
    .expect("cached serve");
    let mut expected = cached_body;
    let index = build_cenc_index(&expected, 0, expected.len() as u64)
        .expect("index")
        .expect("encrypted");
    apply_cenc_index(&mut expected, 0, &index, &cached_key).expect("decrypt");
    assert_eq!(response.into_bytes().await.expect("body"), expected);

    mock.task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}
