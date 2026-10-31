#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'imx install: %s\n' "$*" >&2
    exit 1
}

[[ $# -le 1 ]] || fail 'Usage: bash install.sh [vVERSION]'
[[ $(uname -s) == Linux ]] || fail 'Linux is required.'
case $(uname -m) in
    x86_64) architecture=x86_64 ;;
    aarch64 | arm64) architecture=aarch64 ;;
    *) fail 'Supported architectures: x86_64 and aarch64.' ;;
esac
for program in curl tar sha256sum mktemp install mkdir mv rm find; do
    command -v "$program" >/dev/null || fail "Required command: $program"
done
: "${HOME:?HOME must be set}"
if [[ -n ${IMX_PREFIX:-} ]]; then
    prefix=$IMX_PREFIX
else
    case :${PATH:?PATH must be set}: in
        *:/usr/local/bin:*) prefix=/usr/local ;;
        *:/usr/bin:*) prefix=/usr ;;
        *) fail 'PATH must contain /usr/local/bin or /usr/bin.' ;;
    esac
fi
cache=${XDG_CACHE_HOME:-"$HOME/.cache"}
[[ $prefix == /* && $cache == /* ]] || fail 'Installation and cache paths must be absolute.'
base=${IMX_RELEASE_BASE_URL:-https://github.com/inwf/imx/releases}
base=${base%/}
selector=${1:-latest}
if [[ $selector != latest ]]; then
    [[ $selector == v[0-9]* && $selector != *[!a-zA-Z0-9.+-]* ]] || fail 'Invalid release tag.'
fi

mkdir -p -- "$cache"
stage=$(mktemp -d "$cache/imx-install.XXXXXXXX")
staged_binary=
privileged=()
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n $staged_binary && -e $staged_binary ]]; then
        if [[ ${#privileged[@]} -gt 0 ]]; then
            sudo --non-interactive -- rm -- "$staged_binary"
        else
            rm -- "$staged_binary"
        fi
    fi
    rm -r -- "$stage"
    exit "$status"
}
trap cleanup EXIT

download() {
    curl --fail --silent --show-error --location --proto '=https,http' --proto-redir '=https' \
        --connect-timeout 15 --max-time 300 "$1" --output "$2"
}

if [[ $selector == latest ]]; then
    download "$base/latest/download/VERSION" "$stage/VERSION"
else
    download "$base/download/$selector/VERSION" "$stage/VERSION"
fi
IFS= read -r version < "$stage/VERSION"
[[ $version == [0-9]* && $version != *[!a-zA-Z0-9.+-]* ]] || fail 'Invalid release version.'
[[ $selector == latest || $selector == "v$version" ]] || fail 'Release tag and version do not match.'
release="$base/download/v$version"
archive="imx-linux-$architecture.tar.gz"
completions=(share/bash-completion/completions/imx share/zsh/site-functions/_imx share/zsh/vendor-completions/_imx share/fish/vendor_completions.d/imx.fish)
system_fish_completion=
case $prefix in
    /usr/local) system_fish_completion=/usr/share/fish/vendor_completions.d/imx.fish ;;
    /usr) system_fish_completion=/usr/local/share/fish/vendor_completions.d/imx.fish ;;
esac
mkdir -- "$stage/download" "$stage/tree"
download "$release/SHA256SUMS" "$stage/SHA256SUMS"
download "$release/$archive" "$stage/download/$archive"
# 校验目录仅包含当前架构的软件包，校验文件缺少该软件包时也会失败。
(
    cd -- "$stage/download"
    sha256sum --check --strict --ignore-missing "$stage/SHA256SUMS"
)
tar --extract --gzip --file "$stage/download/$archive" --directory "$stage/tree" \
    --no-same-owner --no-same-permissions bin/imx share/licenses/imx "${completions[@]}"
[[ $("$stage/tree/bin/imx" -v) == "imx $version" ]] || fail 'Downloaded executable has an unexpected version.'

writable_directory() {
    local directory=$1
    while [[ ! -e $directory ]]; do
        directory=${directory%/*}
        [[ -n $directory ]] || directory=/
    done
    [[ -d $directory && -w $directory && -x $directory ]]
}

needs_sudo=false
if (( EUID != 0 )); then
    for directory in "$prefix/bin" "$prefix/share/licenses/imx"; do
        writable_directory "$directory" || needs_sudo=true
    done
    for file in "${completions[@]}"; do
        writable_directory "$prefix/${file%/*}" || needs_sudo=true
    done
    if [[ -n $system_fish_completion ]]; then
        writable_directory "${system_fish_completion%/*}" || needs_sudo=true
    fi
fi
if [[ $needs_sudo == true ]]; then
    command -v sudo >/dev/null || fail 'sudo is required to install into the system directory.'
    printf 'Installing to %s; sudo may ask for your password.\n' "$prefix"
    sudo --validate
    privileged=(sudo --)
fi

"${privileged[@]}" install -d -m 755 -- "$prefix/bin" "$prefix/share/licenses/imx"
find "$stage/tree/share/licenses/imx" -type f -print0 > "$stage/licenses"
while IFS= read -r -d '' file; do
    relative=${file#"$stage/tree/share/licenses/imx/"}
    destination="$prefix/share/licenses/imx/$relative"
    "${privileged[@]}" install -d -m 755 -- "${destination%/*}"
    [[ ! -L $destination ]] || fail "License destination is a symbolic link: $destination"
    "${privileged[@]}" install -m 644 -- "$file" "$destination"
done < "$stage/licenses"
install_completion() {
    local source=$1 destination=$2
    "${privileged[@]}" install -d -m 755 -- "${destination%/*}"
    [[ ! -L $destination ]] || fail "Completion destination is a symbolic link: $destination"
    "${privileged[@]}" install -m 644 -- "$source" "$destination"
}
for file in "${completions[@]}"; do
    install_completion "$stage/tree/$file" "$prefix/$file"
done
if [[ -n $system_fish_completion ]]; then
    install_completion "$stage/tree/share/fish/vendor_completions.d/imx.fish" "$system_fish_completion"
fi

# 在目标目录准备文件，再通过 rename 替换可执行文件，运行中的会话继续执行。
staged_binary=$("${privileged[@]}" mktemp "$prefix/bin/.imx-install.XXXXXXXX")
"${privileged[@]}" install -m 755 -- "$stage/tree/bin/imx" "$staged_binary"
"${privileged[@]}" mv -T -- "$staged_binary" "$prefix/bin/imx"
staged_binary=
printf 'Installed imx %s: %s/bin/imx\n' "$version" "$prefix"
