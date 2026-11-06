# 本地质量门禁：命令与 .github/workflows/ci.yml 一一对应，提交前跑 `make check`。
#
# 依赖：flutter / dart 在 PATH；cargo / rustfmt / clippy 在 PATH；
#       flutter_rust_bridge_codegen 2.13.0（cargo install flutter_rust_bridge_codegen --version 2.13.0）。
.PHONY: check dart rust codegen format help

check: dart rust codegen ## 跑全部门禁（等价于 CI 的三个 job）

dart: ## Dart：格式 / 静态分析 / 测试
	dart format --output=none --set-exit-if-changed lib test
	flutter analyze --fatal-infos
	flutter test

rust: ## Rust：格式 / clippy / 测试
	cargo fmt --manifest-path rust/Cargo.toml --check
	cargo clippy --all-targets --manifest-path rust/Cargo.toml -- -D warnings
	cargo test --manifest-path rust/Cargo.toml

codegen: ## 重新生成绑定并校验入库版本没有漂移
	flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
	git diff --exit-code

format: ## 就地格式化（改完代码后跑）
	dart format lib test
	cargo fmt --manifest-path rust/Cargo.toml

help: ## 列出可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "%-10s %s\n", $$1, $$2}'
