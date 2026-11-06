//! P1-4 contract: every business failure answers the same JSON envelope
//! `{"success":false,"error":...,"kind":...}` and the HTTP status classes stay
//! as they were (400 for bad input, 500 for everything else).
//!
//! These tests go through the real dispatcher and the real loopback adapter,
//! against a scripted mock upstream, so the contract is pinned at the same
//! boundary the Dart layer consumes.

mod common;

use common::{build_server, pool_json, start_loopback, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use serde_json::{json, Value};
use std::sync::Arc;

async fn server_with(dir: &TempDir, origin: &str) -> Arc<fqapi_core::endpoints::Server> {
    build_server(dir, Some(origin.to_string()), &[], &[], &pool_json(5)).await
}

fn api_get(path: &str, query: &str) -> Request {
    Request {
        method: "GET".to_string(),
        path: path.to_string(),
        query: query.to_string(),
        body: Vec::new(),
        headers: Vec::new(),
    }
}

async fn json_body(resp: fqapi_core::dispatch::Response) -> (u16, Value) {
    let status = resp.status;
    let bytes = resp.into_bytes().await.expect("body");
    let value = serde_json::from_slice(&bytes).unwrap_or_else(|e| {
        panic!(
            "response is not JSON ({e}): {}",
            String::from_utf8_lossy(&bytes)
        )
    });
    (status, value)
}

/// A local parameter-validation failure: `bad_input`, still HTTP 400, and no
/// upstream request is made.
#[tokio::test]
async fn bad_input_answers_400_with_kind_bad_input() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("kind-bad-input");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/videos/VID-1/danmaku", "start_offset_time=0"),
        )
        .await,
    )
    .await;

    assert_eq!(status, 400, "bad input keeps its 400: {body}");
    assert_eq!(body["success"], false);
    assert_eq!(body["kind"], "bad_input");
    assert!(
        body["error"]
            .as_str()
            .unwrap_or_default()
            .contains("series_id"),
        "the message still says what is missing: {body}"
    );
    assert!(
        upstream.requests().is_empty(),
        "local validation must not reach upstream"
    );
    upstream.shutdown();
}

/// A 5xx upstream answer: `upstream_5xx`, still HTTP 500. The client retries
/// transient statuses twice on the same device, so the mock sees three calls.
#[tokio::test]
async fn upstream_5xx_answers_500_with_kind_upstream_5xx() {
    let upstream = MockUpstream::start(|_| MockReply::status(503)).await;
    let dir = TempDir::new("kind-upstream-5xx");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) =
        json_body(dispatch(&server, &api_get("/api/v1/search", "query=某个词")).await).await;

    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false);
    assert_eq!(body["kind"], "upstream_5xx");
    assert!(
        body["error"].as_str().unwrap_or_default().contains("503"),
        "{body}"
    );
    assert_eq!(upstream.requests().len(), 3, "2 transient retries");
    upstream.shutdown();
}

/// A 429 upstream answer: `rate_limited`, still HTTP 500. `Retry-After: 0`
/// keeps the test fast without changing the retry path.
#[tokio::test]
async fn rate_limited_answers_500_with_kind_rate_limited() {
    let upstream = MockUpstream::start(|_| MockReply {
        status: 429,
        headers: vec![("retry-after".to_string(), "0".to_string())],
        body: Vec::new(),
    })
    .await;
    let dir = TempDir::new("kind-rate-limited");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) =
        json_body(dispatch(&server, &api_get("/api/v1/search", "query=某个词")).await).await;

    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false);
    assert_eq!(body["kind"], "rate_limited");
    assert!(
        body["error"].as_str().unwrap_or_default().contains("429"),
        "{body}"
    );
    upstream.shutdown();
}

/// The loopback adapter returns the same envelope as the in-process
/// dispatcher, so a client parses one shape for both transports.
#[tokio::test]
async fn loopback_adapter_returns_the_same_error_envelope() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("kind-loopback");
    let server = server_with(&dir, &upstream.origin).await;
    let lb = start_loopback(server).await;
    let client = reqwest::Client::builder().build().expect("client");

    let resp = client
        .get(lb.url("/api/v1/videos/VID-1/danmaku"))
        .send()
        .await
        .expect("loopback request");
    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.expect("error body is JSON");
    assert_eq!(body["success"], false);
    assert_eq!(body["kind"], "bad_input");
    assert!(upstream.requests().is_empty());

    lb.task.abort();
    upstream.shutdown();
}

/// Adapter-level refusals (host/origin guard, oversized body) also carry a
/// kind: a client should not have to special-case them.
#[tokio::test]
async fn loopback_refusals_carry_a_kind() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("kind-loopback-refusal");
    let server = server_with(&dir, &upstream.origin).await;
    let lb = start_loopback(server).await;
    let client = reqwest::Client::builder().build().expect("client");

    // Foreign Origin: the Host/Origin guard refuses with 403.
    let resp = client
        .get(lb.bare_url("/health"))
        .header("origin", "http://evil.example")
        .send()
        .await
        .expect("loopback request");
    assert_eq!(resp.status().as_u16(), 403);
    let body: Value = resp.json().await.expect("refusal body is JSON");
    assert_eq!(body["kind"], "bad_input", "{body}");

    // Oversized account body: refused with 413 before buffering.
    let oversized = "x".repeat(fqapi_core::dispatch::ACCOUNT_REQUEST_BODY_LIMIT + 1);
    let resp = client
        .post(lb.url("/api/v1/account/fanqie/history"))
        .body(oversized)
        .send()
        .await
        .expect("loopback post");
    assert_eq!(resp.status().as_u16(), 413);
    let body: Value = resp.json().await.expect("refusal body is JSON");
    assert_eq!(body["kind"], "too_large", "{body}");

    lb.task.abort();
    upstream.shutdown();
}
