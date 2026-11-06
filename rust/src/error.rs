//! Error boundary for the Rust core.
//!
//! HTTP statuses mirror the Go router: `BadRequest` is the only 400 class and
//! every other class stays a 500, so existing clients and integration tests
//! keep their status-code expectations (P1-4). The semantic difference is
//! carried by a stable `kind` in the JSON envelope instead:
//!
//! ```json
//! {"success": false, "error": "HTTP 500", "kind": "upstream_5xx"}
//! ```
//!
//! The `kind` strings are a contract with the Dart layer
//! (`ApiException.kind`). Append new values; never rename an existing one.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    /// Deterministic bad input from the caller. HTTP 400; never retried.
    BadRequest(String),
    /// Upstream rejected the device identity (HTTP 401/403) or device
    /// registration failed. HTTP 500 to keep the existing status contract.
    DeviceFailed(String),
    /// Upstream asked us to slow down (HTTP 429). Kept at HTTP 500.
    RateLimited(String),
    /// Upstream server fault (HTTP 5xx). Kept at HTTP 500.
    Upstream5xx(String),
    /// A transport or request deadline expired. Kept at HTTP 500.
    Timeout(String),
    /// A request or response exceeded a local size bound. Kept at HTTP 500.
    TooLarge(String),
    /// Anything the classifier does not recognise yet (parse failures, local
    /// I/O, budget cut-offs). Kept at HTTP 500; `kind` is `unknown`.
    Internal(String),
}

impl ApiError {
    /// Stable `kind` values carried in the error JSON. This is the contract
    /// with the Dart layer: only append, never rename.
    pub const KIND_BAD_INPUT: &'static str = "bad_input";
    pub const KIND_DEVICE_FAILED: &'static str = "device_failed";
    pub const KIND_RATE_LIMITED: &'static str = "rate_limited";
    pub const KIND_UPSTREAM_5XX: &'static str = "upstream_5xx";
    pub const KIND_TIMEOUT: &'static str = "timeout";
    pub const KIND_TOO_LARGE: &'static str = "too_large";
    pub const KIND_UNKNOWN: &'static str = "unknown";

    pub fn bad_request(msg: impl Into<String>) -> Self {
        ApiError::BadRequest(msg.into())
    }

    pub fn device_failed(msg: impl Into<String>) -> Self {
        ApiError::DeviceFailed(msg.into())
    }

    pub fn rate_limited(msg: impl Into<String>) -> Self {
        ApiError::RateLimited(msg.into())
    }

    pub fn upstream_5xx(msg: impl Into<String>) -> Self {
        ApiError::Upstream5xx(msg.into())
    }

    pub fn timeout(msg: impl Into<String>) -> Self {
        ApiError::Timeout(msg.into())
    }

    pub fn too_large(msg: impl Into<String>) -> Self {
        ApiError::TooLarge(msg.into())
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        ApiError::Internal(msg.into())
    }

    pub fn status(&self) -> u16 {
        match self {
            ApiError::BadRequest(_) => 400,
            ApiError::DeviceFailed(_)
            | ApiError::RateLimited(_)
            | ApiError::Upstream5xx(_)
            | ApiError::Timeout(_)
            | ApiError::TooLarge(_)
            | ApiError::Internal(_) => 500,
        }
    }

    /// Stable machine-readable class. Persisted/logged by callers, so the
    /// string values are a contract rather than an implementation detail.
    pub fn kind(&self) -> &'static str {
        match self {
            ApiError::BadRequest(_) => Self::KIND_BAD_INPUT,
            ApiError::DeviceFailed(_) => Self::KIND_DEVICE_FAILED,
            ApiError::RateLimited(_) => Self::KIND_RATE_LIMITED,
            ApiError::Upstream5xx(_) => Self::KIND_UPSTREAM_5XX,
            ApiError::Timeout(_) => Self::KIND_TIMEOUT,
            ApiError::TooLarge(_) => Self::KIND_TOO_LARGE,
            ApiError::Internal(_) => Self::KIND_UNKNOWN,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            ApiError::BadRequest(m)
            | ApiError::DeviceFailed(m)
            | ApiError::RateLimited(m)
            | ApiError::Upstream5xx(m)
            | ApiError::Timeout(m)
            | ApiError::TooLarge(m)
            | ApiError::Internal(m) => m,
        }
    }

    /// Whether retrying the same request could plausibly succeed.
    ///
    /// The retry policy itself is unchanged by the kind split: only bad input
    /// is deterministic and must never be retried. `DeviceFailed`,
    /// `RateLimited`, `Upstream5xx`, `Timeout` and `TooLarge` replaced errors
    /// that used to be `Internal` (and therefore retryable) on the paths that
    /// classify them, so they keep that behaviour; the decision lives with the
    /// callers that own a retry loop (`endpoints/audio.rs`).
    pub fn is_retryable(&self) -> bool {
        !matches!(self, ApiError::BadRequest(_))
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for ApiError {}

impl From<serde_json::Error> for ApiError {
    fn from(e: serde_json::Error) -> Self {
        ApiError::Internal(format!("parse upstream json: {e}"))
    }
}

impl From<std::io::Error> for ApiError {
    fn from(e: std::io::Error) -> Self {
        ApiError::Internal(e.to_string())
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_strings_are_the_dart_contract() {
        let cases = [
            (ApiError::bad_request("x"), "bad_input"),
            (ApiError::device_failed("x"), "device_failed"),
            (ApiError::rate_limited("x"), "rate_limited"),
            (ApiError::upstream_5xx("x"), "upstream_5xx"),
            (ApiError::timeout("x"), "timeout"),
            (ApiError::too_large("x"), "too_large"),
            (ApiError::internal("x"), "unknown"),
        ];
        for (err, kind) in cases {
            assert_eq!(err.kind(), kind, "kind of {err:?}");
        }
    }

    #[test]
    fn only_bad_input_changes_the_http_status() {
        assert_eq!(ApiError::bad_request("x").status(), 400);
        for err in [
            ApiError::device_failed("x"),
            ApiError::rate_limited("x"),
            ApiError::upstream_5xx("x"),
            ApiError::timeout("x"),
            ApiError::too_large("x"),
            ApiError::internal("x"),
        ] {
            assert_eq!(err.status(), 500, "status of {err:?}");
        }
    }

    #[test]
    fn bad_input_is_the_only_non_retryable_kind() {
        assert!(!ApiError::bad_request("x").is_retryable());
        assert!(ApiError::internal("x").is_retryable());
        assert!(ApiError::upstream_5xx("x").is_retryable());
    }

    #[test]
    fn display_is_the_human_message() {
        assert_eq!(ApiError::rate_limited("HTTP 429").to_string(), "HTTP 429");
    }
}
