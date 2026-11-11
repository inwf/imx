#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package_dir=${ZIG_LOCAL_PKG_DIR:-"$project_dir/zig-pkg"}
mkdir -p "$project_dir/work"
temporary_dir=$(mktemp -d "$project_dir/work/dependency-sources.XXXXXX")
trap 'rm -rf -- "$temporary_dir"' EXIT

fetch_package() {
    local url=$1 source_root=$2 expected_hash=$3 actual_hash source_dir
    if [[ -d "$package_dir/$expected_hash" ]]; then
        return
    fi
    printf 'Fetching build dependency %s\n' "$expected_hash"
    source_dir="$temporary_dir/$expected_hash"
    mkdir -p "$source_dir"
    curl --fail --location --silent --show-error --max-time 60 "$url" --output "$source_dir/archive.tar.gz"
    tar -xzf "$source_dir/archive.tar.gz" --directory "$source_dir" --no-same-owner
    actual_hash=$(zig fetch "$source_dir/$source_root")
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        printf 'Dependency hash mismatch: expected %s, received %s\n' "$expected_hash" "$actual_hash" >&2
        exit 1
    fi
}

fetch_package \
    https://codeberg.org/ziglang/translate-c/archive/cfac21f3199b2b02ce3fd7db652aa456421fe4ab.tar.gz \
    translate-c \
    translate_c-2.0.2-Q_BUWvBNBwDnyehSiuAJmdFcMYHYGA-Jc3KiYdrV2Dqx
fetch_package \
    https://codeberg.org/ziglang/arocc/archive/630d99ed60fe61ccabe721f1af60881f8b2adde3.tar.gz \
    arocc \
    aro-0.0.0-JSD1QvCRNwC2O1Jkop9TO6sXb1U1vhrH8FnYK1VdEMKn
fetch_package \
    https://codeberg.org/ziglang/arocc/archive/d0c8c4d9c55daa7ef6e40cf0f630a5b5e900989b.tar.gz \
    arocc \
    aro-0.0.0-JSD1QtuBNwCASyBtNF3pqTl_W3oAJQGEVyFAtrBSE_Pa
