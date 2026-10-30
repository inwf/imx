#!/usr/bin/env bash
set -euo pipefail
zig fmt --check build.zig src
zig build -Dtarget="${ARCH:?}-linux-musl" -Dcpu=baseline
zig build test -Dcpu=baseline
shellcheck install.sh scripts/*.sh
actionlint .github/workflows/release.yml
uv run --frozen --project tests pytest -q
uv run --frozen --project tests python scripts/release.py package --arch "$ARCH" --tag "${RELEASE_TAG:-}"
