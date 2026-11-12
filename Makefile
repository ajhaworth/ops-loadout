# Loadout checks. `make verify` is the gate an agent runs before calling work
# done, and the `verify` job in .github/workflows/release.yml runs the same
# target before any installer is built.
#
# Every check is offline. A missing toolchain fails the gate rather than being
# skipped silently; for a change that cannot touch that side, opt out
# explicitly: `make verify NO_RUST=1` (no cargo) or `make verify NO_PWSH=1`
# (no pwsh). Say so when reporting the result.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: verify smoke py-tests rust-tests pwsh-smoke

verify: smoke py-tests pwsh-smoke rust-tests
	@echo "verify: OK$(if $(NO_RUST), (Rust tests skipped: NO_RUST),)$(if $(NO_PWSH), (smoke.ps1 skipped: NO_PWSH),)"

smoke:
	bash tests/bash/smoke.sh

py-tests:
	python3 tests/bash/blender_install.py
	python3 tests/bash/download_progress.py

pwsh-smoke:
ifdef NO_PWSH
	@echo "pwsh-smoke: skipped (NO_PWSH)"
else
	@command -v pwsh >/dev/null || { echo "pwsh not found: install PowerShell, or run 'make verify NO_PWSH=1'" >&2; exit 1; }
	pwsh -NoProfile tests/windows/smoke.ps1
endif

# tauri-build checks that the bundled/ resource exists, so stage it first
# when a fresh checkout has none (app/scripts/bundle-repo.js, plain node).
rust-tests:
ifdef NO_RUST
	@echo "rust-tests: skipped (NO_RUST)"
else
	@command -v cargo >/dev/null || { echo "cargo not found: install Rust (rustup), or run 'make verify NO_RUST=1'" >&2; exit 1; }
	@test -d app/src-tauri/bundled || node app/scripts/bundle-repo.js
	cd app/src-tauri && cargo test
	cd wm && cargo test
endif
