#!/usr/bin/env bash
#
# Checks for a new stable ZapZap release. If one is found that has not yet
# been mirrored here, downloads the upstream amd64 .deb, produces a renamed
# copy for each target Debian/Ubuntu distribution and publishes a GitHub
# release tagged "<version>+1".
#
# Requirements: gh (authenticated via GH_TOKEN), curl.

set -euo pipefail

UPSTREAM_REPO="rafatosta/zapzap"

# Target Debian/Ubuntu suites.
DISTROS=(bookworm trixie forky sid questing resolute noble jammy)

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- 1. Resolve the latest STABLE upstream version --------------------------
# `gh release view` with no tag returns the release marked "Latest", which
# excludes drafts and pre-releases.
VERSION="$(gh release view --repo "$UPSTREAM_REPO" --json tagName -q .tagName)"
VERSION="${VERSION#v}"   # strip a leading "v" if upstream ever uses one

if [[ -z "$VERSION" ]]; then
  echo "::error::Could not determine latest ZapZap version." >&2
  exit 1
fi

RELEASE_TAG="${VERSION}+1"
echo "Latest upstream stable version: $VERSION (target release tag: $RELEASE_TAG)"

# --- 2. Skip if we already published this version ---------------------------
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "Release $RELEASE_TAG already exists here. Nothing to do."
  exit 0
fi

# --- 3. Download the upstream amd64 .deb ------------------------------------
mkdir -p "$WORKDIR/src"
gh release download "$VERSION" \
  --repo "$UPSTREAM_REPO" \
  --pattern '*amd64.deb' \
  --dir "$WORKDIR/src"

SRC_DEB="$(find "$WORKDIR/src" -maxdepth 1 -name '*amd64.deb' | head -n1)"
if [[ -z "$SRC_DEB" ]]; then
  echo "::error::No amd64 .deb found in upstream release $VERSION." >&2
  exit 1
fi
echo "Downloaded upstream package: $(basename "$SRC_DEB")"

# --- 4. Repackage per distribution with a suite-suffixed Version -----------
# Unpack the upstream .deb, rewrite the control Version to
# "<ver>-1~<distro>" and repack. The "~<distro>" suffix makes apt order the
# packages correctly per suite (this is what apt actually reads).
#
# Note on the "~": GitHub sanitises the asset *name* to "." on upload, but it
# displays the asset *label* verbatim. We build each upload argument as
# "<path>#<label>" so the release page shows the real "~" file name.
mkdir -p "$WORKDIR/out"
assets=()
for distro in "${DISTROS[@]}"; do
  pkgver="${VERSION}-1~${distro}"
  extract="$WORKDIR/pkg-${distro}"
  rm -rf "$extract"
  dpkg-deb -R "$SRC_DEB" "$extract"
  sed -i "s/^Version:.*/Version: ${pkgver}/" "$extract/DEBIAN/control"

  fname="zapzap_${pkgver}_amd64.deb"   # zapzap_7.0.3-1~bookworm_amd64.deb
  out="$WORKDIR/out/$fname"
  dpkg-deb --build --root-owner-group "$extract" "$out"
  assets+=("${out}#${fname}")          # path#label -> label keeps the "~"
  echo "  -> ${fname}  (Version: ${pkgver})"
done

# --- 5. Publish the release -------------------------------------------------
gh release create "$RELEASE_TAG" "${assets[@]}" \
  --title "$RELEASE_TAG" \
  --notes "Repackaged ZapZap **$VERSION** for Debian/Ubuntu suites: ${DISTROS[*]}.

Based on upstream release [$VERSION](https://github.com/$UPSTREAM_REPO/releases/tag/$VERSION)."

echo "Published release $RELEASE_TAG."
