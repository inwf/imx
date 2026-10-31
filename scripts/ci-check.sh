#!/usr/bin/env bash
set -euo pipefail
zig fmt --check build.zig src
zig build -Dtarget="${ARCH:?}-linux-musl" -Dcpu=baseline
zig build test -Dcpu=baseline
shellcheck install.sh scripts/*.sh
shellcheck -s bash src/shell/bash.sh
shellcheck -s bash src/completions/bash.sh
bash -n src/shell/bash.sh
bash -n src/completions/bash.sh
zsh -n src/shell/zsh.sh
zsh -n src/completions/zsh.sh
fish -n src/shell/fish.fish
fish -n src/completions/fish.fish
actionlint .github/workflows/release.yml
uv run --frozen --project tests pytest -q
uv run --frozen --project tests python scripts/release.py package --arch "$ARCH" --tag "${RELEASE_TAG:-}"
