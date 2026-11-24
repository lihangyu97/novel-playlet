//! 播放门健康度与身份轮换节流。
//!
//! 短剧取流的主门（v5 播放门）在上游判定「这次请求不放行」时，回的是
//! `HTTP 200` + 0 字节：不带状态码、不带错误码、不带任何说明。在同一个身份上
//! 重试这扇门永远不会恢复——它不是在过载，是在拒绝。所以失败的处理方式不是
//! 重试，而是换门，必要时换身份。这套阶梯移植自 novel-sound（其原型是
//! `N3urda/hongguoTV` 的 `streamLadderWithCompatibility`）。
//!
//! 每扇门各记一份健康度：空实体停 30 秒，其他失败停 5 秒，成功清零并排到最前；
//! 连续两轮全空才值得花一次身份轮换。状态是进程级的、基于单调时钟，只存门标签
//! 与时间戳——不存请求参数、身份、地址或响应字节。需要确定性时序的测试自己传
//! `now_ms`，这里不读挂钟。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// 空实体停足够久，让重试循环没法一直撞同一扇门。
pub(crate) const EMPTY_COOLDOWN: Duration = Duration::from_secs(30);
/// 非空的失败（超时、5xx、验签不过）只短暂停一下。
pub(crate) const ERROR_COOLDOWN: Duration = Duration::from_secs(5);
/// 轮换后仍然没有模型，隔这么久才允许再轮换：备用身份是稀缺资源。
pub(crate) const ROTATE_COOLDOWN_SETTLED: Duration = Duration::from_secs(30);
/// 轮换连注册都没成功时，下次可以早一点再试。
pub(crate) const ROTATE_COOLDOWN_FAILED: Duration = Duration::from_secs(5);
/// 连续全空的轮数达到这个值，才值得为一次前台请求轮换身份。
pub(crate) const EMPTY_ROTATE_ROUNDS: u32 = 2;

/// v5 播放门：`multi_video_model/player/v1`，v5 签名 POST，带 gzip 请求体。
pub(crate) const V5_PLAYER_URL: &str =
    "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1";
/// 官方 `GET video_tab` 兜底门：同一套 v5 播放器信封，不带 body。
///
/// 这扇门是唯一实测能在主门回空体时给出模型的路径，所以放在第二位：
/// 死掉的旧签名门（shortplay/phoenix）排在它后面只作最后兜底。
pub(crate) const VIDEO_TAB_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/";

/// 一扇播放门的身份与地址。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Door {
    /// v5 增强播放门（`multi_video_model/player/v1`）。
    V5Player,
    /// 官方 `GET video_tab` 门，需把响应重写成取流器认识的形状。
    VideoTab,
}

impl Door {
    /// 请求地址（不含 query）。
    pub fn url(self) -> &'static str {
        match self {
            Door::V5Player => V5_PLAYER_URL,
            Door::VideoTab => VIDEO_TAB_URL,
        }
    }

    /// 诊断用短标签；不放域名，日志里也不出现地址。
    pub fn tag(self) -> &'static str {
        match self {
            Door::V5Player => "v5",
            Door::VideoTab => "tab-b",
        }
    }
}

/// 取流阶梯的顺序。主门优先，兜底门第二。
pub(crate) fn doors() -> [Door; 2] {
    [Door::V5Player, Door::VideoTab]
}

#[derive(Debug, Clone, Copy, Default)]
struct Health {
    last_success_ms: Option<u64>,
    blocked_until_ms: u64,
    empty: bool,
}

/// 进程级播放门健康度 + 身份轮换节流。
#[derive(Debug, Default)]
pub(crate) struct PlaybackRouteState {
    health: HashMap<Door, Health>,
    empty_rounds: u32,
    last_rotate_ms: Option<u64>,
    rotate_result: Option<bool>,
    rotations: u32,
}

impl PlaybackRouteState {
    /// 健康门在前，冷却门整条跳过。
    ///
    /// 只有前台请求会在全部冷却时退化成「按恢复时间顺序把所有门都探一遍」；
    /// 预取（speculative）永远只探一条且不探冷却门——后台不得消耗前台需要的
    /// 失败预算。
    pub fn plan(&self, now_ms: u64, speculative: bool) -> Vec<Door> {
        let all = doors();
        let mut available: Vec<Door> = all
            .iter()
            .copied()
            .filter(|door| self.health_for(*door).blocked_until_ms <= now_ms)
            .collect();
        available.sort_by(|a, b| {
            self.health_for(*b)
                .last_success_ms
                .cmp(&self.health_for(*a).last_success_ms)
        });
        if speculative {
            return available.into_iter().take(1).collect();
        }
        if available.is_empty() {
            let mut cooling = all.to_vec();
            cooling.sort_by_key(|door| self.health_for(*door).blocked_until_ms);
            return cooling;
        }
        available
    }

    fn health_for(&self, door: Door) -> Health {
        self.health.get(&door).copied().unwrap_or_default()
    }

    /// 这扇门是否还在冷却里。
    pub fn parked(&self, door: Door, now_ms: u64) -> bool {
        self.health_for(door).blocked_until_ms > now_ms
    }

    /// 所有门都因为空实体被停用了。
    pub fn exhausted(&self, now_ms: u64) -> bool {
        doors().iter().all(|door| {
            let health = self.health_for(*door);
            health.empty && health.blocked_until_ms > now_ms
        })
    }

    pub fn success(&mut self, door: Door, now_ms: u64) {
        let health = self.health.entry(door).or_default();
        health.last_success_ms = Some(now_ms);
        health.blocked_until_ms = 0;
        health.empty = false;
    }

    pub fn failed(&mut self, door: Door, now_ms: u64, empty: bool) {
        let cooldown = if empty {
            EMPTY_COOLDOWN
        } else {
            ERROR_COOLDOWN
        };
        let health = self.health.entry(door).or_default();
        health.blocked_until_ms = now_ms.saturating_add(cooldown.as_millis() as u64);
        health.empty = empty;
    }

    /// 一轮结束：这一轮是不是每次都拿回空实体。
    pub fn note_round(&mut self, all_empty: bool) {
        if all_empty {
            self.empty_rounds = self.empty_rounds.saturating_add(1);
        } else {
            self.empty_rounds = 0;
        }
    }

    pub fn empty_rounds(&self) -> u32 {
        self.empty_rounds
    }

    /// 只看轮换节流：前台调用、且上一次轮换已经过去足够久。
    ///
    /// 与「空轮数」分开，是为了让轮内提前退出（全部门已冷却）也能复用这条闸。
    pub fn rotation_paced(&self, now_ms: u64, speculative: bool) -> bool {
        if speculative {
            return false;
        }
        let cooldown = match self.rotate_result {
            Some(false) => ROTATE_COOLDOWN_FAILED,
            _ => ROTATE_COOLDOWN_SETTLED,
        };
        match self.last_rotate_ms {
            None => true,
            Some(last) => now_ms.saturating_sub(last) >= cooldown.as_millis() as u64,
        }
    }

    /// 空轮数够了、且上一次轮换已经结算，才允许为这个请求轮换身份。
    pub fn rotate_due(&self, now_ms: u64, speculative: bool) -> bool {
        self.empty_rounds >= EMPTY_ROTATE_ROUNDS && self.rotation_paced(now_ms, speculative)
    }

    pub fn note_rotate(&mut self, now_ms: u64, registered: bool) {
        self.last_rotate_ms = Some(now_ms);
        self.rotate_result = Some(registered);
        if registered {
            self.rotations = self.rotations.saturating_add(1);
        }
    }

    pub fn rotations(&self) -> u32 {
        self.rotations
    }
}

fn state() -> &'static Mutex<PlaybackRouteState> {
    static STATE: OnceLock<Mutex<PlaybackRouteState>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(PlaybackRouteState::default()))
}

fn process_start() -> Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    *START.get_or_init(Instant::now)
}

/// 进程启动以来的单调毫秒数；永不读挂钟。
pub(crate) fn now_ms() -> u64 {
    process_start().elapsed().as_millis() as u64
}

/// 在共享状态上跑一段逻辑。
pub(crate) fn with_state<R>(f: impl FnOnce(&mut PlaybackRouteState) -> R) -> R {
    let mut guard = state().lock().unwrap_or_else(|error| error.into_inner());
    f(&mut guard)
}

/// 清空全部健康度与节流状态。
///
/// 只给集成测试用：同一个测试二进制里多条用例共享进程，一条用例留下的冷却
/// 不应污染下一条。生产代码永远不调。
#[doc(hidden)]
pub fn reset_state_for_tests() {
    with_state(|state| *state = PlaybackRouteState::default());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(duration: Duration) -> u64 {
        duration.as_millis() as u64
    }

    #[test]
    fn empty_body_parks_a_door_for_thirty_seconds_and_success_clears_it() {
        let mut state = PlaybackRouteState::default();
        let v5 = Door::V5Player;
        state.failed(v5, 1_000, true);
        assert!(!state
            .plan(1_000 + ms(EMPTY_COOLDOWN) - 1, false)
            .contains(&v5));
        assert!(state.plan(1_000 + ms(EMPTY_COOLDOWN), false).contains(&v5));
        state.success(v5, 2_000);
        let health = state.health_for(v5);
        assert_eq!(health.blocked_until_ms, 0);
        assert!(!health.empty);
        // 成功的门排在第一条。
        assert_eq!(state.plan(3_000, false).first(), Some(&v5));
    }

    #[test]
    fn non_empty_failures_only_park_a_door_briefly() {
        let mut state = PlaybackRouteState::default();
        let tab = Door::VideoTab;
        state.failed(tab, 10_000, false);
        assert!(!state.plan(10_000, false).contains(&tab));
        assert!(state
            .plan(10_000 + ms(ERROR_COOLDOWN), false)
            .contains(&tab));
        // 短暂停用不等于「全部门空实体」。
        assert!(!state.exhausted(10_000));
    }

    #[test]
    fn speculative_planning_never_probes_a_cooling_door() {
        let mut state = PlaybackRouteState::default();
        for door in doors() {
            state.failed(door, 0, true);
        }
        assert!(state.plan(1, true).is_empty());
        let cooling = state.plan(1, false);
        assert_eq!(cooling.len(), doors().len());
        assert!(state.exhausted(1));
    }

    #[test]
    fn a_foreground_plan_orders_cooling_doors_by_recovery_time() {
        let mut state = PlaybackRouteState::default();
        let all = doors();
        // 最后一条最早恢复，因此前台应先探它。
        for (index, door) in all.iter().enumerate() {
            let failed_at = if index == all.len() - 1 {
                0
            } else {
                5_000 + index as u64 * 1_000
            };
            state.failed(*door, failed_at, true);
        }
        let mut expected = vec![*all.last().unwrap()];
        expected.extend_from_slice(&all[..all.len() - 1]);
        assert_eq!(state.plan(8_000, false), expected);
    }

    #[test]
    fn exhausted_needs_every_door_empty_and_blocked() {
        let mut state = PlaybackRouteState::default();
        let all = doors();
        for door in &all[..all.len() - 1] {
            state.failed(*door, 0, true);
        }
        assert!(!state.exhausted(1));
        state.failed(*all.last().unwrap(), 0, true);
        assert!(state.exhausted(1));
    }

    #[test]
    fn rotation_needs_two_empty_rounds_and_a_foreground_caller() {
        let mut state = PlaybackRouteState::default();
        state.note_round(true);
        assert!(!state.rotate_due(1_000, false), "一轮全空不足以轮换身份");
        assert!(!state.rotate_due(1_000, true), "预取永不轮换");
        state.note_round(true);
        assert!(state.rotate_due(1_000, false));
        // 非全空的一轮把连续计数清零。
        state.note_round(false);
        assert_eq!(state.empty_rounds(), 0);
        assert!(!state.rotate_due(1_000, false));
    }

    #[test]
    fn a_settled_rotation_costs_thirty_seconds_and_a_failed_one_five() {
        let mut state = PlaybackRouteState::default();
        state.note_round(true);
        state.note_round(true);

        state.note_rotate(5_000, false);
        assert!(!state.rotate_due(5_000 + ms(ROTATE_COOLDOWN_FAILED) - 1, false));
        assert!(state.rotate_due(5_000 + ms(ROTATE_COOLDOWN_FAILED), false));
        assert_eq!(state.rotations(), 0);

        state.note_rotate(20_000, true);
        assert!(!state.rotate_due(20_000 + ms(ROTATE_COOLDOWN_SETTLED) - 1, false));
        assert!(state.rotate_due(20_000 + ms(ROTATE_COOLDOWN_SETTLED), false));
        assert_eq!(state.rotations(), 1);
    }

    #[test]
    fn pacing_alone_blocks_a_second_in_round_rotation() {
        // 全部门停用的一轮可以自己轮换，但冷却是硬闸：身份池有上限，身份
        // 周转必须罕见。
        let mut state = PlaybackRouteState::default();
        state.note_rotate(1_000, true);
        assert!(!state.rotation_paced(1_000, false));
        assert!(!state.rotation_paced(1_000 + ms(ROTATE_COOLDOWN_SETTLED) - 1, false));
        assert!(state.rotation_paced(1_000 + ms(ROTATE_COOLDOWN_SETTLED), false));
        assert!(!state.rotation_paced(9_999_999, true));
    }

    #[test]
    fn a_door_is_parked_exactly_until_its_cooldown_lapses() {
        let mut state = PlaybackRouteState::default();
        let v5 = Door::V5Player;
        assert!(!state.parked(v5, 1_000));
        state.failed(v5, 1_000, true);
        assert!(state.parked(v5, 1_001));
        assert!(!state.parked(v5, 1_000 + ms(EMPTY_COOLDOWN)));
    }

    #[test]
    fn door_tags_stay_short_and_address_free() {
        let tags: Vec<&str> = doors().iter().map(|door| door.tag()).collect();
        assert_eq!(tags, vec!["v5", "tab-b"]);
        assert!(tags.iter().all(|tag| !tag.contains("fqnovel")));
        assert!(doors()
            .iter()
            .all(|door| door.url().starts_with("https://api5-normal-sinfonline")));
    }
}
