#!/usr/bin/env bash
#
# Checks for a new stable ZapZap release. If one is found that has not yet
# been mirrored here, it:
#   * downloads the upstream amd64 .deb and repackages it, per target suite,
#     with a suite-suffixed control Version ("<ver>-1~<distro>") and
#     Architecture: all, since the payload is pure Python;
#   * builds a Debian source package (.dsc + .orig.tar.gz + .debian.tar.xz)
#     per suite from the upstream sources, so we distribute the corresponding
#     source alongside the binaries (GPL-3 compliance);
#   * publishes everything in a GitHub release tagged "<version>+1".
#
# Requirements: gh (authenticated via GH_TOKEN), curl, file, dpkg-deb, dpkg-source.

set -euo pipefail

UPSTREAM_REPO="rafatosta/zapzap"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Target suites. Ubuntu binary .debs get a "_ubu" filename suffix (matching
# the convention used across the apt repo tooling) so Debian and Ubuntu
# builds never collide; the internal control Version is "<ver>-1~<distro>"
# for both.
DEBIAN_DISTROS=(bookworm trixie forky sid)
UBUNTU_DISTROS=(jammy noble questing resolute)
DISTROS=("${DEBIAN_DISTROS[@]}" "${UBUNTU_DISTROS[@]}")

# Echo "_ubu" for Ubuntu suites, empty otherwise. Always returns 0 so it is
# safe inside a command substitution under `set -e`.
ubu_suffix() {
  local d
  for d in "${UBUNTU_DISTROS[@]}"; do
    if [[ "$d" == "$1" ]]; then printf '_ubu'; return 0; fi
  done
  return 0
}

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

# --- 3. Download the upstream .deb ------------------------------------------
# Upstream builds only an amd64 .deb, but ZapZap is a pure-Python (PyQt6)
# application: the package contains no compiled code, and everything
# architecture-specific comes from the distribution's own python3-pyqt6
# packages. The repackaged .deb is therefore published as Architecture: all,
# which installs on arm64 and every other port as well.
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
  sed -i "s/^Architecture:.*/Architecture: all/" "$extract/DEBIAN/control"

  # Refuse to relabel a package that turns out to contain compiled code.
  if find "$extract" -type f -exec file -b {} + | grep -q '^ELF '; then
    echo "::error::Upstream .deb contains ELF binaries; it is not Architecture: all." >&2
    exit 1
  fi

  # Debian: zapzap_7.0.3-1~bookworm_all.deb
  # Ubuntu: zapzap_7.0.3-1~jammy_all_ubu.deb
  fname="zapzap_${pkgver}_all$(ubu_suffix "$distro").deb"
  out="$WORKDIR/out/$fname"
  dpkg-deb --build --root-owner-group "$extract" "$out"
  assets+=("${out}#${fname}")          # path#label -> label keeps the "~"
  echo "  -> ${fname}  (Version: ${pkgver})"
done

# --- 4b. Build source packages (GPL-3 source distribution) -----------------
# Download the upstream source tarball once as the shared .orig.tar.gz, then
# produce a source package (.dsc + .debian.tar.xz) per suite by dropping in
# our debian/ dir with a suite-specific changelog. This ships the
# corresponding source for the binaries above, as required by the GPL.
SRCDIR="$WORKDIR/src-pkg"
mkdir -p "$SRCDIR"
ORIG_TARBALL="$SRCDIR/zapzap_${VERSION}.orig.tar.gz"
curl -fsSL "https://github.com/$UPSTREAM_REPO/archive/refs/tags/${VERSION}.tar.gz" \
  -o "$ORIG_TARBALL"

for distro in "${DISTROS[@]}"; do
  pkgver="${VERSION}-1~${distro}"
  builddir="$SRCDIR/zapzap-${VERSION}"
  rm -rf "$builddir"
  tar -xzf "$ORIG_TARBALL" -C "$SRCDIR"   # extracts to zapzap-<version>/
  cp -r "$REPO_ROOT/debian" "$builddir/debian"

  cat > "$builddir/debian/changelog" <<EOF
zapzap (${pkgver}) ${distro}; urgency=medium

  * Repackage of upstream ZapZap ${VERSION} for ${distro}.

 -- Dario Griffo <dariogriffo@gmail.com>  $(date -R)
EOF

  ( cd "$SRCDIR" && dpkg-source --build "zapzap-${VERSION}" )
  echo "  -> zapzap_${pkgver}.dsc (+ .debian.tar.xz)"
done
rm -rf "$SRCDIR/zapzap-${VERSION}"

# Add the generated source artifacts (with "~"-preserving labels) to the
# upload set. The shared .orig.tar.gz is published once.
for f in "$SRCDIR"/*.dsc "$SRCDIR"/*.debian.tar.xz "$ORIG_TARBALL"; do
  assets+=("${f}#$(basename "$f")")
done

# --- 5. Publish the release -------------------------------------------------
gh release create "$RELEASE_TAG" "${assets[@]}" \
  --title "$RELEASE_TAG" \
  --notes "Repackaged ZapZap **$VERSION** for Debian/Ubuntu suites: ${DISTROS[*]}.

Includes the corresponding Debian source packages (.dsc / .orig.tar.gz / .debian.tar.xz) for GPL-3 compliance.

Based on upstream release [$VERSION](https://github.com/$UPSTREAM_REPO/releases/tag/$VERSION)."

echo "Published release $RELEASE_TAG."
