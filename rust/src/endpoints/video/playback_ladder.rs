//! 取流门契约：`video_tab` 响应重写、门参数、取流用途白名单。
//!
//! 这三件事都是「改错也不报错」的类型：重写形状一变，兜底门拿到模型也解析不出；
//! 门参数一变，上游直接回 `200` + 0 字节；用途白名单一松，后台预取就会开始
//! 消耗前台要用的失败预算与身份预算。所以用纯本地断言钉住。

use super::{playback_purpose, video_tab_player_shape, video_tab_query, ParsedVideoResponse};
use serde_json::{json, Value};

const VIDEO_ID: &str = "7600000000000000001";

fn model() -> Value {
    json!({
        "key_seed": "AAAA",
        "video_list": {"video_1": {
            "main_url": "https://example.invalid/h264.mp4",
            "codec_type": "h264",
        }},
    })
}

#[test]
fn rewrites_the_native_tab_shape_into_the_player_shape() {
    let raw = json!({
        "code": 0,
        "data": {"video_model_data": {VIDEO_ID: {"video_model": model()}}},
    });
    let shaped = video_tab_player_shape(&serde_json::to_vec(&raw).unwrap(), VIDEO_ID)
        .expect("native tab shape must be rewritable");
    let root: Value = serde_json::from_slice(&shaped).expect("rewritten body is JSON");
    assert_eq!(
        root["data"][VIDEO_ID]["video_model"],
        model(),
        "重写后的形状必须是取流器已支持的 data.<id>.video_model"
    );
    let parsed = ParsedVideoResponse::parse(&shaped).expect("player parser accepts it");
    assert_eq!(parsed.models.len(), 1);
}

#[test]
fn accepts_a_body_that_already_uses_the_player_shape() {
    let raw = json!({"data": {VIDEO_ID: {"video_model": model()}}});
    let shaped = video_tab_player_shape(&serde_json::to_vec(&raw).unwrap(), VIDEO_ID)
        .expect("already-canonical body must survive the rewrite");
    let parsed = ParsedVideoResponse::parse(&shaped).expect("player parser accepts it");
    assert_eq!(parsed.models.len(), 1);
}

#[test]
fn a_business_rejection_is_a_failed_door_not_an_empty_body() {
    // 上游给了明确拒绝时，这扇门是「坏了」而不是「在拒绝你」，冷却时间不同。
    for raw in [
        json!({"code": 10001, "data": {}}),
        json!({"Code": 110001, "message": "未知异常"}),
    ] {
        assert!(
            video_tab_player_shape(&serde_json::to_vec(&raw).unwrap(), VIDEO_ID).is_none(),
            "{raw}"
        );
    }
}

#[test]
fn a_body_without_a_model_is_rejected() {
    for raw in [
        json!({"code": 0, "data": {}}),
        json!({"code": 0, "data": {"video_model_data": {}}}),
        json!({"code": 0, "data": {"video_model_data": {VIDEO_ID: {}}}}),
        json!({"code": 0}),
    ] {
        assert!(
            video_tab_player_shape(&serde_json::to_vec(&raw).unwrap(), VIDEO_ID).is_none(),
            "{raw}"
        );
    }
    assert!(video_tab_player_shape(b"", VIDEO_ID).is_none());
    assert!(video_tab_player_shape(b"not json", VIDEO_ID).is_none());
}

#[test]
fn the_tab_query_carries_the_official_field_bag() {
    let query = video_tab_query(VIDEO_ID);
    let map: std::collections::HashMap<&str, String> = query
        .iter()
        .map(|(key, value)| (*key, value.clone()))
        .collect();
    assert_eq!(map.get("video_id"), Some(&VIDEO_ID.to_string()));
    assert_eq!(map.get("video_id_type"), Some(&"0".to_string()));
    // 播放器档位：与 v5 主门同族的 1024 / device_level 1。
    assert_eq!(map.get("video_platform"), Some(&"1024".to_string()));
    assert_eq!(map.get("device_level"), Some(&"1".to_string()));
    assert_eq!(map.get("need_all_video_definition"), Some(&"1".to_string()));
    assert_eq!(map.get("from_video_id"), Some(&String::new()));
    assert_eq!(query.len(), 9);
}

#[test]
fn the_purpose_allowlist_never_upgrades_an_unknown_value() {
    assert_eq!(playback_purpose("foreground"), "foreground");
    assert_eq!(playback_purpose("prefetch"), "prefetch");
    assert_eq!(playback_purpose("other"), "other");
    // 未知值必须退化成 other：把拼错的 "prefetch " 当成预取会让前台失去轮换。
    assert_eq!(playback_purpose("prefetch "), "other");
    assert_eq!(playback_purpose("PREFETCH"), "other");
    assert_eq!(playback_purpose(""), "other");
}
