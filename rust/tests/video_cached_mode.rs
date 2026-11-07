//! `mode=cached`：只查本地 src 缓存、不打上游；`variants=0`：跳过合并清晰度
//! 列表（播放页不需要它，省一个 fallback 请求）。

mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use serde_json::{json, Value};

async fn request_video(server: &Server, query: &str) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: "/api/v1/videos/episode".to_string(),
            query: query.to_string(),
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

fn stream_payload() -> Value {
    json!({
        "data": {
            "video_model": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {
                        "main_url": "https://example.invalid/v.mp4",
                        "codec_type": "h264",
                        "vwidth": 720,
                        "vheight": 1280
                    }
                },
                "fallback_api": "https://example.invalid/fallback"
            }
        }
    })
}

#[tokio::test]
async fn cached_mode_hit_serves_local_src_without_touching_upstream() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({}))).await;
    let dir = TempDir::new("video-cached-hit");
    let server = build_server(
        &dir,
        Some(upstream.origin.clone()),
        &[],
        &[("episode.mp4", "fake-mp4-bytes")],
        &pool_json(5),
    )
    .await;

    let (status, body) = request_video(&server, "mode=cached").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["cached"], true, "{body}");
    assert_eq!(body["video_url"], "/src/episode.mp4", "{body}");
    assert!(
        upstream.requests().is_empty(),
        "mode=cached 命中时不应请求上游：{:?}",
        upstream.requests()
    );
}

#[tokio::test]
async fn cached_mode_miss_reports_false_without_touching_upstream() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({}))).await;
    let dir = TempDir::new("video-cached-miss");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server, "mode=cached").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["cached"], false, "{body}");
    assert!(
        upstream.requests().is_empty(),
        "mode=cached 未命中也不应请求上游：{:?}",
        upstream.requests()
    );
}

#[tokio::test]
async fn variants_zero_skips_fallback_quality_list() {
    let payload = stream_payload();
    let upstream = MockUpstream::start(move |req| {
        if req.path == "/fallback" {
            return MockReply::json(json!({
                "video_info": {"data": {
                    "key_seed": "AAAA",
                    "video_list": {"video_1": {
                        "main_url": "https://example.invalid/fallback.mp4",
                        "codec_type": "h264",
                        "vwidth": 1080,
                        "vheight": 1920
                    }}
                }}
            }));
        }
        MockReply::json(payload.clone())
    })
    .await;
    let dir = TempDir::new("video-variants-skip");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server, "mode=stream&variants=0").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["variants"], json!([]), "{body}");
    assert!(
        !upstream.requests().iter().any(|r| r.path == "/fallback"),
        "variants=0 不应再拉 fallback 列表：{:?}",
        upstream.requests()
    );

    let (status, body) = request_video(&server, "mode=stream").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        upstream.requests().iter().any(|r| r.path == "/fallback"),
        "默认（要 variants）应拉 fallback 列表：{:?}",
        upstream.requests()
    );
    assert!(!body["variants"].as_array().unwrap_or(&vec![]).is_empty());
}
