//! 上游播放接口回 `200 + 空 body` 时的重试与错误归类。
//!
//! 背景：2026-11 起 `/novel/player/video_model/v1/` 与
//! `/novel/player/multi_video_model/v1/` 会回 HTTP 200、`content-length: 0`，
//! serde 报 `EOF while parsing a value at line 1 column 0`。这里锁住：
//! - 空响应重试一次后能成功；
//! - 一直空 → `kind=upstream_5xx` + 人话，且只打两次上游；
//! - 非空但不是 JSON（格式变化）→ 保持 `kind=unknown`，不重试。

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use serde_json::{json, Value};

const VIDEO_URL: &str = "https://example.invalid/h264.mp4";

fn source_payload() -> Value {
    json!({"data": {"episode": {"video_model": {
        "video_list": [{"main_url": VIDEO_URL, "codec_type": "h264"}]
    }}}})
}

async fn request_video(server: &Server) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: "/api/v1/videos/episode".to_string(),
            query: String::new(),
            ..Default::default()
        },
    )
    .await;
    let status = response.status;
    let body = response.into_bytes().await.expect("response body");
    (
        status,
        serde_json::from_slice(&body).expect("JSON response"),
    )
}

/// 播放接口请求数（下载 CDN 的 `.mp4` 不算）。
fn model_requests(upstream: &MockUpstream) -> usize {
    upstream
        .requests()
        .iter()
        .filter(|request| !request.path.ends_with(".mp4"))
        .count()
}

fn empty_ok() -> MockReply {
    MockReply {
        status: 200,
        headers: vec![("content-type".to_string(), "application/json".to_string())],
        body: Vec::new(),
    }
}

#[tokio::test]
async fn an_empty_body_is_retried_and_can_still_succeed() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(move |request| {
        if request.path.ends_with(".mp4") {
            return MockReply {
                status: 200,
                headers: Vec::new(),
                body: b"video fixture".to_vec(),
            };
        }
        let first = counter.fetch_add(1, Ordering::SeqCst) == 0;
        if first {
            empty_ok()
        } else {
            MockReply::json(source_payload())
        }
    })
    .await;
    let dir = TempDir::new("video-empty-retry");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server).await;

    assert_eq!(status, 200, "{body}");
    assert_eq!(body["video_url"], "/src/episode.mp4", "{body}");
    assert_eq!(
        model_requests(&upstream),
        2,
        "empty body must be retried once"
    );
}

#[tokio::test]
async fn a_persistent_empty_body_is_a_retryable_upstream_error() {
    let upstream = MockUpstream::start(|request| {
        if request.path.ends_with(".mp4") {
            return MockReply::status(200);
        }
        empty_ok()
    })
    .await;
    let dir = TempDir::new("video-empty-persistent");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server).await;

    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false, "{body}");
    assert_eq!(body["kind"], "upstream_5xx", "{body}");
    let message = body["error"].as_str().unwrap_or_default();
    assert!(message.contains("空响应"), "{message}");
    assert!(
        !message.contains("parse upstream json"),
        "内部解析文案不能透给用户: {message}"
    );
    assert_eq!(
        model_requests(&upstream),
        2,
        "one empty body must not spin more than one retry"
    );
}

#[tokio::test]
async fn a_non_json_body_is_not_retried() {
    let upstream = MockUpstream::start(|request| {
        if request.path.ends_with(".mp4") {
            return MockReply::status(200);
        }
        MockReply {
            status: 200,
            headers: vec![("content-type".to_string(), "text/html".to_string())],
            body: b"<html>gateway page</html>".to_vec(),
        }
    })
    .await;
    let dir = TempDir::new("video-not-json");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server).await;

    assert_eq!(status, 500, "{body}");
    assert_eq!(body["kind"], "unknown", "{body}");
    assert!(
        body["error"]
            .as_str()
            .unwrap_or_default()
            .starts_with("parse upstream json:"),
        "{body}"
    );
    assert_eq!(
        model_requests(&upstream),
        1,
        "format changes must not retry"
    );
}
