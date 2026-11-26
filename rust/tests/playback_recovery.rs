//! 播放门阶梯的恢复语义（移植自 novel-sound）。
//!
//! 上游对 v5 播放门的拒绝形态是 `HTTP 200` + 0 字节：不带状态、不带错误码。
//! 在同一个身份上重试这扇门永远不会恢复，所以主门回空体时必须**换门**——
//! 先换到官方 `GET video_tab` 门（同一身份），两扇门都空才回落到旧的
//! shortplay/phoenix 双请求。这里用本地 mock 上游把这三条语义钉住。

mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, Recorded, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use fqapi_core::upstream::reset_playback_route_state_for_tests;
use serde_json::{json, Map, Value};

const MEDIA_URL: &str = "https://example.invalid/h264.mp4";
/// 一档可播放的密钥种子（与 video_codec_gate 用的是同一份样本）。
const SPADE_A: &str = "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==";

fn video_model() -> Value {
    json!({
        "key_seed": "AAAA",
        "video_list": {"video_1": {
            "main_url": MEDIA_URL,
            "codec_type": "h264",
            "spade_a": SPADE_A,
        }},
    })
}

/// v5 主门正常时的响应形状。
fn primary_payload() -> Value {
    json!({"data": {"video_model": video_model()}})
}

/// `video_tab` 门的原生形状：模型挂在 `data.video_model_data.<id>` 上。
fn tab_payload(video_id: &str) -> Value {
    let mut rows = Map::new();
    rows.insert(video_id.to_string(), json!({"video_model": video_model()}));
    let mut data = Map::new();
    data.insert("video_model_data".to_string(), Value::Object(rows));
    let mut root = Map::new();
    root.insert("code".to_string(), json!(0));
    root.insert("data".to_string(), Value::Object(data));
    Value::Object(root)
}

async fn request_video(server: &Server) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: "/api/v1/videos/episode".to_string(),
            query: "mode=stream".to_string(),
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

fn device_id(record: &Recorded) -> String {
    common::query_map(&record.query)
        .get("device_id")
        .cloned()
        .unwrap_or_default()
}

fn is_primary_door(record: &Recorded) -> bool {
    record.path.contains("/multi_video_model/player/")
}

fn is_tab_door(record: &Recorded) -> bool {
    record.path.contains("/video_tab/")
}

fn is_legacy_door(record: &Recorded) -> bool {
    record.path.contains("/novel/player/multi_video_model/v1/")
        || record.path.contains("/novel/player/video_model/v1/")
}

fn door_requests(requests: &[Recorded]) -> Vec<&Recorded> {
    requests
        .iter()
        .filter(|r| is_primary_door(r) || is_tab_door(r) || is_legacy_door(r))
        .collect()
}

/// 主门回空体时，同一身份改问 `video_tab` 门并拿到可播地址。
async fn empty_primary_falls_back_to_video_tab() {
    reset_playback_route_state_for_tests();
    let upstream = MockUpstream::start(|req| {
        if req.path.contains("/multi_video_model/player/") {
            // 门拒绝请求的形态：状态 200，零字节。
            return MockReply::status(200);
        }
        if req.path.contains("/video_tab/") {
            return MockReply::json(tab_payload("episode"));
        }
        MockReply::json(json!({}))
    })
    .await;
    let dir = TempDir::new("playback-tab-fallback");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["streaming"], json!(true), "{body}");

    let requests = upstream.requests();
    let doors = door_requests(&requests);
    let primary: Vec<&&Recorded> = doors.iter().filter(|r| is_primary_door(r)).collect();
    let tab: Vec<&&Recorded> = doors.iter().filter(|r| is_tab_door(r)).collect();
    assert!(!primary.is_empty(), "主门必须被问过");
    assert_eq!(tab.len(), 1, "兜底门只问一次: {doors:?}");

    // 兜底门必须是同一身份：否则事后分不清是门的问题还是身份的问题。
    let pinned = device_id(tab[0]);
    assert!(!pinned.is_empty(), "兜底门必须带 device_id");
    assert!(
        primary.iter().all(|record| device_id(record) == pinned),
        "两次尝试必须落在同一身份上: {:?} vs {pinned}",
        primary.iter().map(|r| device_id(r)).collect::<Vec<_>>()
    );

    // 兜底门是签名 GET：没有 body，也不能带 body 头——带了 body 头却没 body
    // 正是当初被判 200+0 的形态。
    assert!(tab[0].method.eq_ignore_ascii_case("GET"));
    assert!(tab[0].body.is_empty(), "GET 门不能带请求体");
    assert!(tab[0].header("content-type").is_none());
    assert!(tab[0].header("content-encoding").is_none());
    assert!(tab[0].header("x-ss-stub").is_none());
    // 但必须带播放器族验签头。
    assert!(tab[0].header("x-medusa").is_some());
    assert!(tab[0].header("x-khronos").is_some());
}

/// 主门给了非空模型时，绝不去碰兜底门：多一次往返就是多一次失败机会。
async fn healthy_primary_never_touches_the_fallback() {
    reset_playback_route_state_for_tests();
    let upstream = MockUpstream::start(|req| {
        if is_primary_url(&req.path) {
            return MockReply::json(primary_payload());
        }
        MockReply::json(json!({}))
    })
    .await;
    let dir = TempDir::new("playback-primary-ok");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["streaming"], json!(true), "{body}");
    assert_eq!(door_requests(&upstream.requests()).len(), 1);
    assert!(upstream.requests().iter().all(|r| !is_tab_door(r)));
}

/// 两扇门都回空体时：先做一次有界身份轮换再重问，仍为空才回落到旧链路。
async fn two_empty_doors_rotate_then_fall_back_to_legacy() {
    reset_playback_route_state_for_tests();
    let upstream = MockUpstream::start(|req| {
        if is_primary_url(&req.path) || req.path.contains("/video_tab/") {
            return MockReply::status(200);
        }
        if req.path.contains("/multi_video_model/v1/")
            || req.path.contains("/novel/player/video_model/v1/")
        {
            return MockReply::json(primary_payload());
        }
        MockReply::json(json!({}))
    })
    .await;
    let dir = TempDir::new("playback-legacy-fallback");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["streaming"], json!(true), "{body}");

    let requests = upstream.requests();
    assert!(
        requests.iter().any(is_legacy_door),
        "两扇门都空时必须回落到旧链路: {requests:?}"
    );
    // 轮换过一次之后才会重问，所以主门至少被问了两轮。
    let primary_rounds = requests.iter().filter(|r| is_primary_door(r)).count();
    assert!(
        primary_rounds >= 2,
        "全部门空时应先轮换身份再重问，实际只有 {primary_rounds} 次"
    );
}

fn is_primary_url(path: &str) -> bool {
    path.contains("/multi_video_model/player/")
}

/// 三条场景串行跑在同一个测试里。
///
/// 门健康度是**进程级**的，而 cargo 默认并行跑同一二进制里的用例：并行时一条
/// 用例的重置/冷却会污染另一条（`video_tab` 被停用 30 秒就会让别的用例直接跳过
/// 兜底门）。串行是这里唯一确定的写法。
#[tokio::test]
async fn playback_door_ladder_contract() {
    empty_primary_falls_back_to_video_tab().await;
    healthy_primary_never_touches_the_fallback().await;
    two_empty_doors_rotate_then_fall_back_to_legacy().await;
}
