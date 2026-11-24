//! v5 播放门的形态约束。
//!
//! 上游在 2026-11 中旬把短剧取流换成 v5 签名（`x-medusa` + SM3），旧的 argus
//! 签名请求会被直接拒掉——症状是整片短剧无法起播。这里用纯本地断言锁住三件
//! 事，避免以后重构把协议悄悄改回去：
//!
//! 1. 送签的字节必须是 gzip（压缩在签名之前，签名后不得再改）；
//! 2. `x-ss-stub` 必须是对**线上字节**的 MD5，而不是明文 JSON 的 MD5；
//! 3. 走 v5 的请求不带 `x-argus`（那是旧门的东西），但必须带 `x-medusa`；
//! 4. 兜底门 `GET video_tab` 用**同一套**播放器信封，但不带任何 body 头
//!    ——带了 body 头却没有 body，正是当初被判 `200` + 0 字节的形态。

use super::{v5_playback_body, V5_PLAYER_URL};
use crate::sign::v5::{sign_playback_v5, sign_playback_v5_get, V5Identity};
use crate::upstream::playback_routes::VIDEO_TAB_URL;

fn identity<'a>() -> V5Identity<'a> {
    V5Identity {
        device_id: "7000000000000000001",
        install_id: "7000000000000000002",
        cdid: "7000000000000000003",
    }
}

#[test]
fn body_is_gzipped_before_signing() {
    let body = v5_playback_body("7600000000000000001").expect("marshal v5 body");
    let plain = crate::crypto::gunzip(&body).expect("v5 body must be gzip on the wire");

    // 明文里必须能读出这一集，否则签名和请求体对不上游商的预期。
    let parsed: serde_json::Value = serde_json::from_slice(&plain).expect("v5 body is JSON");
    assert_eq!(
        parsed["mixed_video_id_map"]["1004"][0],
        serde_json::json!("7600000000000000001")
    );
    assert_eq!(parsed["dr_scene"], serde_json::json!("player"));
    assert_eq!(
        parsed["biz_param"]["video_platform"],
        serde_json::json!(1024)
    );
}

#[test]
fn signed_request_carries_v5_headers_and_hashes_the_wire_bytes() {
    let body = v5_playback_body("7600000000000000002").expect("marshal v5 body");
    let signed = sign_playback_v5(V5_PLAYER_URL, &body, &identity()).expect("sign v5 playback");

    // 播放门与产品身份：v5 门属于 phoenix（aid=8662）而不是 novelapp（aid=1967）。
    assert!(signed.url.starts_with(V5_PLAYER_URL), "{}", signed.url);
    assert!(!signed.url.contains(' '), "query must be encoded");
    let query = signed.url.split_once('?').expect("query present").1;
    let param = |name: &str| {
        query
            .split('&')
            .find_map(|pair| pair.strip_prefix(&format!("{name}=")))
            .unwrap_or_default()
            .to_string()
    };
    assert_eq!(param("aid"), "8662");
    assert_eq!(param("version_code"), "74332");
    assert_eq!(param("device_id"), identity().device_id);
    assert_eq!(param("iid"), identity().install_id);

    let header = |name: &str| {
        signed
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    };
    assert![header("x-medusa").is_some_and(|v| !v.is_empty())];
    assert_eq!(header("Content-Encoding"), Some("gzip"));
    assert!(
        header("x-argus").is_none(),
        "v5 must not carry the legacy argus header"
    );

    // x-ss-stub 是“线上字节”的 MD5：拿明文去算会得到不同的值，这条断言就是
    // 为了锁住“压缩发生在签名之前”。
    let wire_md5 = hex::encode_upper(<md5::Md5 as md5::Digest>::digest(&body));
    assert_eq!(header("x-ss-stub"), Some(wire_md5.as_str()));
    let plain_md5 = hex::encode_upper(<md5::Md5 as md5::Digest>::digest(
        crate::crypto::gunzip(&body).unwrap(),
    ));
    assert_ne!(
        wire_md5, plain_md5,
        "wire hash must differ from the plaintext hash"
    );
}

#[test]
fn signing_refuses_incomplete_identity_and_dirty_base() {
    let body = v5_playback_body("7600000000000000003").expect("marshal v5 body");
    let empty = V5Identity {
        device_id: "",
        install_id: "",
        cdid: "",
    };
    assert!(sign_playback_v5(V5_PLAYER_URL, &body, &empty).is_err());
    assert!(sign_playback_v5("", &body, &identity()).is_err());
    assert!(sign_playback_v5(&format!("{V5_PLAYER_URL}?a=1"), &body, &identity()).is_err());
}

#[test]
fn the_get_door_uses_the_player_envelope_and_no_body_headers() {
    let extra = [
        ("video_id", "7600000000000000004"),
        ("video_platform", "1024"),
    ];
    let signed = sign_playback_v5_get(VIDEO_TAB_URL, &extra, &identity()).expect("sign tab door");

    assert!(signed.url.starts_with(VIDEO_TAB_URL), "{}", signed.url);
    let query = signed.url.split_once('?').expect("query present").1;
    let names: Vec<&str> = query
        .split('&')
        .map(|pair| pair.split('=').next().unwrap())
        .collect();
    let param = |name: &str| {
        query
            .split('&')
            .find_map(|pair| pair.strip_prefix(&format!("{name}=")))
            .unwrap_or_default()
            .to_string()
    };

    // 与 v5 主门同一套身份包：预取/兜底必须是同一个匿名身份。
    assert_eq!(param("aid"), "8662");
    assert_eq!(param("app_name"), "novelread");
    assert_eq!(param("version_code"), "74332");
    assert_eq!(param("device_id"), identity().device_id);
    assert_eq!(param("video_id"), "7600000000000000004");
    // 门参数夹在身份包与 ticket 之间：POST 门的字节顺序因此一字不变。
    let ticket_at = names.iter().position(|name| *name == "_rticket").unwrap();
    let video_at = names.iter().position(|name| *name == "video_id").unwrap();
    assert!(
        video_at < ticket_at,
        "门参数必须在 _rticket 之前: {names:?}"
    );

    let header = |name: &str| {
        signed
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    };
    assert!(header("x-medusa").is_some_and(|v| !v.is_empty()));
    assert!(header("x-khronos").is_some());
    assert!(header("x-helios").is_some());
    assert!(
        header("x-argus").is_none(),
        "兜底门属于播放器族，不能用通用 argus 签名"
    );
    for forbidden in ["content-type", "content-encoding", "x-ss-stub"] {
        assert!(
            header(forbidden).is_none(),
            "GET 门不能带 {forbidden}：带了 body 头却没有 body 会被判空体"
        );
    }
}
