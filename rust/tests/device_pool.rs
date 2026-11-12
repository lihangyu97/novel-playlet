//! Device pool contract tests: Go-compatible persistence, LRU selection,
//! concurrent access, and registration against a mock upstream.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use common::{pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::device::{DevicePool, MIN_POOL_SIZE};

/// From rust/testdata/device_vectors.json: a registerkey response payload that
/// decrypts to `SECRETKEY_16byte` under the reference implementation.
const REGISTERKEY_INPUT_B64: &str =
    "ABEiM0RVZneImaq7zN3u//NnA1PPLklvy0VWJ2Qnd45A/zarUCjsToTdr+Zm34ab";
const REGISTERKEY_HEX: &str = "5345435245544B45595F313662797465";

#[tokio::test]
async fn loads_the_go_compatible_pool_json() {
    let dir = TempDir::new("pool-load");
    let path = dir.write("device_pool.json", &pool_json(3));

    let pool = DevicePool::new(&path).await.expect("pool loads");
    assert_eq!(pool.count().await, 3);

    let device = pool.get_by_id("0000000000000002").await.expect("device 2");
    assert_eq!(device.secret_key, format!("{:032x}", 2));
    assert_eq!(device.cdid, "cdid-2");
    assert_eq!(device.platform, "android");
    // Unknown ids are reported, not silently replaced.
    assert!(pool.get_by_id("missing").await.is_err());
}

#[tokio::test]
async fn missing_and_corrupt_pool_files_start_empty() {
    let dir = TempDir::new("pool-empty");
    let missing = dir.join("missing.json");
    let pool = DevicePool::new(&missing).await.expect("pool");
    assert_eq!(pool.count().await, 0);

    let corrupt = dir.write("corrupt.json", "{not json");
    let pool = DevicePool::new(&corrupt).await.expect("pool");
    assert_eq!(pool.count().await, 0);
}

#[tokio::test]
async fn get_rotates_through_the_least_recently_used_device() {
    let dir = TempDir::new("pool-lru");
    // pool_json orders last_used ascending, so device 0 is the LRU first.
    let path = dir.write("device_pool.json", &pool_json(5));
    let pool = DevicePool::new(&path).await.expect("pool");

    for expected in [0usize, 1, 2] {
        let device = pool.get().await.expect("device");
        assert_eq!(
            device.device_id,
            format!("{expected:016}"),
            "LRU rotation step {expected}"
        );
    }
}

#[tokio::test]
async fn concurrent_gets_do_not_corrupt_the_pool_file() {
    let dir = TempDir::new("pool-concurrent");
    let path = dir.write("device_pool.json", &pool_json(5));
    let pool = DevicePool::new(&path).await.expect("pool");

    let mut handles = Vec::new();
    for _ in 0..8 {
        let pool = pool.clone();
        handles.push(tokio::spawn(async move {
            pool.get().await.map(|d| d.device_id)
        }));
    }
    for handle in handles {
        assert!(handle.await.expect("join").is_ok(), "concurrent get failed");
    }

    // Usage counters are written back at most every 30s; a structural save
    // commits whatever the concurrent picks left in memory.
    pool.refill(0).await.expect("flush usage counters");

    // The file must still be valid Go-compatible JSON with every device intact.
    let text = std::fs::read_to_string(&path).expect("pool file");
    let parsed: serde_json::Value = serde_json::from_str(&text).expect("valid JSON after races");
    let devices = parsed["android"].as_array().expect("android array");
    assert_eq!(devices.len(), 5, "no device may be lost");
    for device in devices {
        assert!(device["use_count"].as_i64().unwrap_or(0) >= 1);
        assert!(!device["device_id"].as_str().unwrap_or("").is_empty());
    }
    assert!(parsed["last_update"].is_string());
}

#[tokio::test]
async fn refill_registers_a_device_and_decrypts_its_secret_key() {
    let upstream = MockUpstream::start(|recorded| match recorded.path.as_str() {
        "/service/2/device_register/" => MockReply::json(serde_json::json!({
            "device_id_str": "7276663560427471412",
            "install_id_str": "7276663560427471000",
        })),
        "/reading/crypt/registerkey" => MockReply::json(serde_json::json!({
            "data": { "key": REGISTERKEY_INPUT_B64 },
        })),
        _ => MockReply::status(200),
    })
    .await;

    let dir = TempDir::new("pool-refill");
    let pool = DevicePool::with_mock_origin(dir.join("device_pool.json"), upstream.origin.clone())
        .await
        .expect("pool");

    // The registration flow intentionally waits 2s after app_alert_check;
    // this is the one test that pays that cost.
    pool.refill(1).await.expect("refill");
    assert_eq!(pool.count().await, 1);

    let device = pool
        .get_by_id("7276663560427471412")
        .await
        .expect("new device");
    assert_eq!(
        device.secret_key, REGISTERKEY_HEX,
        "the registerkey response must decrypt to the reference secret key"
    );
    assert_eq!(device.install_id, "7276663560427471000");
    assert_eq!(device.status, "active");

    // Registration really hit the mock endpoints in order.
    let paths: Vec<String> = upstream.requests().iter().map(|r| r.path.clone()).collect();
    assert!(paths.contains(&"/service/2/device_register/".to_string()));
    assert!(paths.contains(&"/reading/crypt/registerkey".to_string()));
    upstream.shutdown();
}

#[tokio::test]
async fn a_retired_pool_refuses_further_writes() {
    let dir = TempDir::new("pool-retired");
    let path = dir.write("device_pool.json", &pool_json(5));
    let pool = DevicePool::new(&path).await.expect("pool");

    // Simulate the new core having written its own state.
    let marker = "{\"android\":[],\"last_update\":\"new-core\"}";
    std::fs::write(&path, marker).expect("overwrite");

    pool.retire().await;
    assert!(pool.is_retired());

    // Every path that would persist (get -> save) must leave the file alone.
    let device = pool
        .get()
        .await
        .expect("the retired pool is still readable");
    assert!(!device.device_id.is_empty());
    assert_eq!(
        std::fs::read_to_string(&path).expect("pool file"),
        marker,
        "a retired pool must not overwrite the new instance's device state"
    );
}

/// A pool whose `secret_key`s are all empty - the state a failing `registerKey`
/// leaves behind, since `register()` still returns `Ok` in that case.
fn empty_key_pool_json(count: usize) -> String {
    let devices: Vec<serde_json::Value> = (0..count)
        .map(|i| {
            serde_json::json!({
                "device_id": format!("{i:016}"),
                "install_id": format!("{}", 9_000_000_000_000_000_000u64 + i as u64),
                "secret_key": "",
                "platform": "android",
                "status": "active",
                "created_time": "2026-01-01 00:00:00",
                "last_used": format!("2026-01-01 00:00:{i:02}"),
                "use_count": i,
                "cdid": format!("cdid-{i}"),
            })
        })
        .collect();
    serde_json::json!({ "android": devices, "last_update": "2026-01-01 00:00:00" }).to_string()
}

/// A mock upstream whose `registerKey` never yields a key, so every
/// registration comes back with an empty `secret_key`.
async fn register_key_fails_upstream() -> MockUpstream {
    MockUpstream::start(|recorded| match recorded.path.as_str() {
        "/service/2/device_register/" => MockReply::json(serde_json::json!({
            "device_id_str": "7276663560427471412",
            "install_id_str": "7276663560427471000",
        })),
        "/reading/crypt/registerkey" => MockReply::status(500),
        _ => MockReply::status(200),
    })
    .await
}

#[tokio::test]
async fn a_registration_without_a_secret_key_does_not_take_a_pool_slot() {
    let upstream = register_key_fails_upstream().await;
    let dir = TempDir::new("pool-empty-key-refill");
    let pool = DevicePool::with_mock_origin(dir.join("device_pool.json"), upstream.origin.clone())
        .await
        .expect("pool");

    let err = pool
        .refill(1)
        .await
        .expect_err("the degradation must be reported, not hidden");
    assert!(err.contains("no secret key"), "unexpected error: {err}");
    assert_eq!(
        pool.count().await,
        0,
        "a device that cannot decrypt must not occupy a pool slot"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn get_never_delivers_a_device_without_a_secret_key() {
    let upstream = register_key_fails_upstream().await;
    let dir = TempDir::new("pool-empty-key-get");
    let path = dir.write("device_pool.json", &empty_key_pool_json(MIN_POOL_SIZE));
    let pool = DevicePool::with_mock_origin(path, upstream.origin.clone())
        .await
        .expect("pool");

    let err = pool
        .get()
        .await
        .expect_err("an unusable device must not be handed to a caller");
    assert!(err.contains("no secret key"), "unexpected error: {err}");
    assert_eq!(
        pool.count().await,
        MIN_POOL_SIZE,
        "the failed replacement is put back so the pool is no worse off"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn concurrent_gets_on_a_degraded_pool_stay_safe() {
    // `get()` on a pool whose selected device has no secret key retires that
    // device and re-registers it, which leaves the pool empty for the duration
    // of the call. A concurrent `get()` used to index `devices[0]` on that
    // emptied vec and panic; neither call may return the unusable device
    // either. Registration is made to fail here so the check stays fast - the
    // point is the invariant, not a reproduction of one interleaving.
    let upstream = MockUpstream::start(|_| MockReply::status(500)).await;
    let dir = TempDir::new("pool-empty-key-race");
    let path = dir.write("device_pool.json", &empty_key_pool_json(1));
    let pool = DevicePool::with_mock_origin(path, upstream.origin.clone())
        .await
        .expect("pool");

    let (a, b, c, d) = tokio::join!(pool.get(), pool.get(), pool.get(), pool.get());
    for device in [a, b, c, d].into_iter().flatten() {
        assert!(
            !device.secret_key.is_empty(),
            "get() must never return a device that cannot decrypt"
        );
    }
    upstream.shutdown();
}

// --- Cold start: one synchronous registration on the caller's path (P1-8) ---

/// Mock upstream that completes the whole registration flow, handing out a
/// unique device id per `device_register` and the reference registerkey.
async fn registering_upstream() -> MockUpstream {
    let next = Arc::new(AtomicUsize::new(0));
    MockUpstream::start(move |recorded| match recorded.path.as_str() {
        "/service/2/device_register/" => {
            let index = next.fetch_add(1, Ordering::SeqCst) as u64;
            MockReply::json(serde_json::json!({
                "device_id_str": (7_276_663_560_427_471_412u64 + index).to_string(),
                "install_id_str": (7_276_663_560_427_471_000u64 + index).to_string(),
            }))
        }
        "/reading/crypt/registerkey" => MockReply::json(serde_json::json!({
            "data": { "key": REGISTERKEY_INPUT_B64 },
        })),
        _ => MockReply::status(200),
    })
    .await
}

/// How many full registrations the mock upstream has served so far.
fn device_registration_count(upstream: &MockUpstream) -> usize {
    upstream
        .requests()
        .iter()
        .filter(|recorded| recorded.path == "/service/2/device_register/")
        .count()
}

/// Number of devices in the on-disk pool file (0 when it is missing or not
/// parseable as plaintext JSON; these tests run without a pool key).
fn persisted_device_count(path: &std::path::Path) -> usize {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|value| value["android"].as_array().map(Vec::len))
        .unwrap_or(0)
}

/// P1-8: first install copies `device_pool.example.json`, which holds one
/// empty-key placeholder. The first `get()` must register **one** device and
/// persist it, then return - not queue behind the background top-up (the old
/// code waited for 4 background registrations and then one of its own).
///
/// The single-threaded runtime is part of the assertion: the top-up task
/// spawned by `get()` cannot be polled before `get()` returns, so the recorded
/// requests are exactly the synchronous registration's.
#[tokio::test(flavor = "current_thread")]
async fn first_get_on_the_shipped_placeholder_registers_one_device() {
    let upstream = registering_upstream().await;
    let dir = TempDir::new("pool-placeholder-first-get");
    let path = dir.write("device_pool.json", &empty_key_pool_json(1));
    let pool = DevicePool::with_mock_origin(path.clone(), upstream.origin.clone())
        .await
        .expect("pool");

    let device = pool.get().await.expect("first get");
    assert!(!device.secret_key.is_empty(), "the placeholder is unusable");
    assert_eq!(
        device_registration_count(&upstream),
        1,
        "the first get() must register exactly one device synchronously"
    );

    // Requirement: the device is committed before the caller is served, so an
    // aborted request cannot leave it in memory only.
    let text = std::fs::read_to_string(&path).expect("pool file written");
    let file: serde_json::Value = serde_json::from_str(&text).expect("valid pool json");
    let devices = file["android"].as_array().expect("android array");
    assert_eq!(devices.len(), 1, "the placeholder is replaced, not kept");
    assert_eq!(
        devices[0]["device_id"].as_str().unwrap_or(""),
        device.device_id
    );
    assert!(!devices[0]["secret_key"].as_str().unwrap_or("").is_empty());

    upstream.shutdown();
}

/// A missing/corrupt pool file starts empty; the first `get()` still waits for
/// exactly one registration.
#[tokio::test(flavor = "current_thread")]
async fn first_get_on_an_empty_pool_registers_one_device() {
    let upstream = registering_upstream().await;
    let dir = TempDir::new("pool-empty-first-get");
    let pool = DevicePool::with_mock_origin(dir.join("device_pool.json"), upstream.origin.clone())
        .await
        .expect("pool");
    assert_eq!(pool.count().await, 0);

    let device = pool.get().await.expect("first get");
    assert!(!device.secret_key.is_empty());
    assert_eq!(
        device_registration_count(&upstream),
        1,
        "an empty pool must register exactly one device synchronously"
    );
    assert!(pool.get_by_id(&device.device_id).await.is_ok());
    assert_eq!(pool.count().await, 1);

    upstream.shutdown();
}

/// Concurrent first callers register once in total: the second one waits for
/// the registration lock and reuses the device the first one just admitted.
#[tokio::test(flavor = "current_thread")]
async fn concurrent_first_gets_register_once() {
    let upstream = registering_upstream().await;
    let dir = TempDir::new("pool-concurrent-first-get");
    let path = dir.write("device_pool.json", &empty_key_pool_json(1));
    let pool = DevicePool::with_mock_origin(path, upstream.origin.clone())
        .await
        .expect("pool");

    let (first, second) = tokio::join!(pool.get(), pool.get());
    let first = first.expect("first concurrent get");
    let second = second.expect("second concurrent get");
    assert!(!first.secret_key.is_empty() && !second.secret_key.is_empty());
    assert_eq!(
        device_registration_count(&upstream),
        1,
        "a registration storm on the first request must be prevented"
    );

    upstream.shutdown();
}

/// The rest of the pool is topped up in the background, without blocking the
/// first caller: the pool ends at MIN_POOL_SIZE and the file matches memory.
#[tokio::test(flavor = "current_thread")]
async fn background_top_up_fills_the_pool_from_the_placeholder() {
    let upstream = registering_upstream().await;
    let dir = TempDir::new("pool-background-topup");
    let path = dir.write("device_pool.json", &empty_key_pool_json(1));
    let pool = DevicePool::with_mock_origin(path.clone(), upstream.origin.clone())
        .await
        .expect("pool");

    let first = pool.get().await.expect("first get");
    assert_eq!(
        device_registration_count(&upstream),
        1,
        "only the synchronous device may be registered on the critical path"
    );

    // Each background registration pays the deliberate 2s pacing, so poll for
    // the fill (and for the final commit that lands after the last device).
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    while pool.count().await < MIN_POOL_SIZE || persisted_device_count(&path) < MIN_POOL_SIZE {
        assert!(
            std::time::Instant::now() < deadline,
            "background top-up did not reach MIN_POOL_SIZE: memory={}, file={}",
            pool.count().await,
            persisted_device_count(&path),
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    assert_eq!(pool.count().await, MIN_POOL_SIZE);
    assert_eq!(
        device_registration_count(&upstream),
        MIN_POOL_SIZE,
        "one synchronous registration plus the background top-up"
    );
    assert!(
        pool.get_by_id(&first.device_id).await.is_ok(),
        "the device handed to the first caller must stay in the pool"
    );
    let text = std::fs::read_to_string(&path).expect("pool file");
    let file: serde_json::Value = serde_json::from_str(&text).expect("valid pool json");
    for device in file["android"].as_array().expect("android array") {
        assert!(
            !device["secret_key"].as_str().unwrap_or("").is_empty(),
            "no empty-key placeholder may survive the top-up"
        );
    }

    upstream.shutdown();
}
