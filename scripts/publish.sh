#!/usr/bin/env bash
set -euo pipefail
: "${RELEASE_TAG:?RELEASE_TAG must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
uv run --frozen --project tests python scripts/release.py assemble --tag "$RELEASE_TAG"
assets=(work/release/imx-linux-x86_64.tar.gz work/release/imx-linux-aarch64.tar.gz \
    work/release/install.sh work/release/VERSION work/release/SHA256SUMS)
state=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases" | \
    uv run --frozen --project tests python scripts/release.py state --tag "$RELEASE_TAG")
case $state in
    missing)
        gh release create "$RELEASE_TAG" "${assets[@]}" --repo "$GITHUB_REPOSITORY" \
            --verify-tag --draft --generate-notes --title "imx ${RELEASE_TAG#v}"
        ;;
    draft)
        gh release upload "$RELEASE_TAG" "${assets[@]}" --repo "$GITHUB_REPOSITORY" --clobber
        ;;
    published)
        printf 'Release %s is already published.\n' "$RELEASE_TAG" >&2
        exit 1
        ;;
    *) exit 1 ;;
esac
gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest
