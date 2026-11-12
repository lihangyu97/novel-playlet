//! `main_url` 有两种形态，混淆它们会让 fallback 列表（含 1080p）整片解不出来。

use super::*;
use serde_json::json;

fn entry(main_url: String) -> Map<String, Value> {
    json!({
        "main_url": main_url,
        "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw==",
    })
    .as_object()
    .unwrap()
    .clone()
}

#[test]
fn spade_encrypted_main_url_reaches_the_decryptor_intact() {
    // spade 密文：base64 解出来以 a8 00 01 00 开头。旧实现无条件先解一层
    // base64 再交给 decrypt_spade_url，密文被毁成不可再解的字节串——面板
    // 会拿到一个不是 URL 的垃圾串（实测就是 1080P 那一档）。
    let mut blob = vec![0xa8u8, 0x00, 0x01, 0x00];
    blob.extend(0u8..32);
    let main_url = base64::engine::general_purpose::STANDARD.encode(&blob);
    let seed = b"AAAA".to_vec();

    let (url, _) = decrypt_variant_entry(&entry(main_url.clone()), Some(&seed)).unwrap();
    assert_eq!(
        url,
        decrypt_spade_url(&main_url, &seed),
        "spade ciphertext must not be pre-decoded before decrypt_spade_url"
    );
}

#[test]
fn base64_wrapped_plain_url_still_decodes() {
    // 明文地址：base64 解出来直接以 http 开头，必须照旧解出来。
    let main_url =
        base64::engine::general_purpose::STANDARD.encode(b"https://example.test/1080.mp4");
    let (url, key) = decrypt_variant_entry(&entry(main_url), Some(b"AAAA")).unwrap();
    assert_eq!(url, "https://example.test/1080.mp4");
    assert_eq!(key.len(), 16);
}

#[test]
fn fallback_list_uses_the_same_base64_plain_url_resolution() {
    // P1-11：1080P 只可能来自 fallback_api 列表。fallback 副本曾缺 base64 明文
    // 分支，会把 base64 串原样当 URL 交给下载（整集失败）。这里锁住 fallback
    // 走共享的 decrypt_variant_entry，而不是自己的那份拷贝。
    let plain = "https://example.test/fallback-1080.mp4";
    let main_url = base64::engine::general_purpose::STANDARD.encode(plain);
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {
                    "main_url": main_url,
                    "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw==",
                    "vwidth": 1080,
                    "vheight": 1920,
                }
            }
        } }
    });

    match extract_fallback_video_source(root.as_object().unwrap()) {
        VideoSourceResolution::Found(url, key) => {
            assert_eq!(
                url, plain,
                "the fallback list must decode the base64 plain URL, not return the raw base64"
            );
            assert_eq!(key.len(), 16);
        }
        other => panic!("expected a playable fallback source, got {other:?}"),
    }
}

#[test]
fn fallback_list_still_resolves_spade_ciphertext() {
    // 共享解析器的另一条分支：fallback 列表里的 spade 密文照常解密。
    let mut blob = vec![0xa8u8, 0x00, 0x01, 0x00];
    blob.extend(0u8..32);
    let main_url = base64::engine::general_purpose::STANDARD.encode(&blob);
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": { "main_url": main_url.clone() }
            }
        } }
    });

    let seed = audio_b64_decode("AAAA").expect("key_seed");
    match extract_fallback_video_source(root.as_object().unwrap()) {
        VideoSourceResolution::Found(url, _) => assert_eq!(
            url,
            decrypt_spade_url(&main_url, &seed),
            "fallback entries must keep using the shared spade decryptor"
        ),
        other => panic!("expected a playable fallback source, got {other:?}"),
    }
}
