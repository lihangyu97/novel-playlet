//! Loopback listener lifecycle contract: the iOS background bug (TN2277).
//!
//! Apple TN2277 "Networking and Multitasking" documents that while an iOS app
//! is suspended the system may reclaim the resources underneath its listening
//! socket, and that after resume the app "will no longer be listening for
//! connections". The kernel keeps running (FFI still answers, files still
//! download), but nothing accepts on `127.0.0.1:<port>` any more, so the
//! player's `connect()` is refused: `NSURLErrorCannotConnectToHost` (-1004),
//! which AVPlayer surfaces as "Could not connect to the server." on
//! `http://127.0.0.1:18931/src/<id>.mp4`. Only a process restart rebinds.
//!
//! `server.rs` therefore supervises its listener: a probe of its own port, and
//! a rebind of the same port when the probe is refused. These tests pin the
//! client-visible contract that recovery depends on:
//!
//! * a healthy adapter serves `/health` and its task never ends by itself;
//! * a dead listener gives **TCP connect refused**, never an HTTP 5xx (the two
//!   are different failures: a 5xx means the request reached the adapter);
//! * rebinding the same port brings `/health` back, which is what the
//!   supervisor does automatically after a reclaim.
//!
//! Run: cargo test --manifest-path rust/Cargo.toml --test loopback_reclaim

mod common;

use std::io::ErrorKind;
use std::time::Duration;

use common::{build_server, pool_json, start_loopback, TempDir};
use fqapi_core::server::{serve, ListenMode};

/// `GET path` against the adapter, returning its status code. `/health` is on
/// the capability-free loopback surface, so no session prefix is needed; the
/// `Host` header is the one the adapter validates, and `Connection: close`
/// keeps the read finite.
async fn http_status(port: u16, path: &str) -> Option<u16> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

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
    let text = String::from_utf8_lossy(&response);
    text.lines().next()?.split_whitespace().nth(1)?.parse().ok()
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

/// Waits until `connect()` to the port is refused.
async fn wait_until_refused(port: u16, limit: Duration) -> bool {
    tokio::time::timeout(limit, async {
        loop {
            match tokio::net::TcpStream::connect(("127.0.0.1", port)).await {
                Err(err) if err.kind() == ErrorKind::ConnectionRefused => return,
                _ => tokio::time::sleep(Duration::from_millis(5)).await,
            }
        }
    })
    .await
    .is_ok()
}

async fn fixture(tag: &str) -> (TempDir, std::sync::Arc<fqapi_core::endpoints::Server>) {
    let dir = TempDir::new(tag);
    let server = build_server(&dir, None, &[], &[("ok.txt", "x")], &pool_json(1)).await;
    (dir, server)
}

/// A healthy adapter keeps serving and its task never ends by itself:
/// `axum::serve` (0.8) "will never actually complete or return an error", so a
/// running listener can only stop via the supervisor.
#[tokio::test]
async fn idle_listener_keeps_serving_and_its_task_never_finishes() {
    let (_dir, server) = fixture("reclaim-idle").await;
    let lb = start_loopback(server).await;

    assert!(
        wait_until_health(lb.port, "/health", Duration::from_secs(2)).await,
        "a fresh adapter must answer /health"
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !lb.task.is_finished(),
        "the listener task must still be running after idle time"
    );
    assert!(
        wait_until_health(lb.port, "/health", Duration::from_secs(2)).await,
        "the adapter must still answer /health after idle time"
    );

    lb.task.abort();
    let _ = lb.task.await;
}

/// The device symptom, modelled exactly: once the listening socket is gone,
/// clients see **connection refused** (-1004), not an HTTP response. A 5xx here
/// would mean the request reached the adapter, which is a different bug.
#[tokio::test]
async fn a_dead_listener_refuses_connections_instead_of_answering_http() {
    let (_dir, server) = fixture("reclaim-refused").await;
    let lb = start_loopback(server).await;
    let port = lb.port;
    assert!(wait_until_health(port, "/health", Duration::from_secs(2)).await);

    // Aborting the handle drops the `TcpListener`, the in-process model of the
    // system reclaiming the socket while the app process stays alive.
    lb.task.abort();
    let _ = lb.task.await;

    assert!(
        wait_until_refused(port, Duration::from_secs(2)).await,
        "connect() must be refused once the listener is gone"
    );
    let error = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .expect_err("nothing must accept on the dead port");
    assert_eq!(
        error.kind(),
        ErrorKind::ConnectionRefused,
        "the device symptom is ECONNREFUSED (-1004), not an HTTP error status"
    );
}

/// Rebinding the same port after the listener died restores service on the
/// URL the player already has. This is the mechanical half of the supervisor's
/// recovery (the supervisor decides *when* to run it; its unit tests force the
/// probe to fail so the whole reclaim -> rebind loop is covered in `server.rs`).
#[tokio::test]
async fn rebinding_the_same_port_restores_service_after_the_listener_dies() {
    let (_dir, server) = fixture("reclaim-rebind").await;
    let lb = start_loopback(server.clone()).await;
    let port = lb.port;
    lb.task.abort();
    let _ = lb.task.await;
    assert!(
        wait_until_refused(port, Duration::from_secs(2)).await,
        "the port must be refused before the heal"
    );

    let rebound = serve(server, port, ListenMode::Loopback)
        .await
        .expect("rebind the published port");
    assert_eq!(rebound.port, port, "the advertised URL must keep its port");
    assert!(
        wait_until_health(rebound.port, "/health", Duration::from_secs(2)).await,
        "the rebound adapter must answer /health again"
    );

    rebound.task.abort();
    let _ = rebound.task.await;
}
