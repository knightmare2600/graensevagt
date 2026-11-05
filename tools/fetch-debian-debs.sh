#!/bin/bash
# fetch-debian-debs.sh
#
# Downloads Debian .deb files for an architecture this host is NOT configured for
# (e.g. arm64 on an amd64 build box), without touching the system's own apt/dpkg
# state and without root: a private, throwaway apt root under $WORKDIR, pointed at the
# same Debian archive and verified by apt itself against the system's own
# debian-archive-keyring (InRelease signature -> Packages hash -> .deb hash). Nothing
# is installed; the .debs are only unpacked later with `dpkg-deb -x` into a build
# tree.
#
# Usage: fetch-debian-debs.sh <arch> <outdir> <package>...
#   e.g. fetch-debian-debs.sh arm64 build/debs-arm64 linux-image-6.12.113+deb13-arm64 busybox-static
#
# Version history (append only, never delete entries):
#   0.1.0  2026-11-05  First version, for graensevagt's arm64 deploy kernel/busybox.
#                       Suites mirror this build host's own /etc/apt/sources.list
#                       (trixie, trixie-updates, trixie-security -- the amd64 kernel in
#                       use came from trixie-security, confirmed via apt-cache policy).
#
set -euo pipefail

ARCH="$1"
OUTDIR="$2"
shift 2

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-debian-debs.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/state/lists/partial" "$WORKDIR/cache/archives/partial" "$WORKDIR/etc/preferences.d"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

cat > "$WORKDIR/etc/sources.list" <<SRC
deb [arch=$ARCH signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian trixie main
deb [arch=$ARCH signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian trixie-updates main
deb [arch=$ARCH signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://security.debian.org/debian-security trixie-security main
SRC

APT_OPTS=(
  -o "APT::Architecture=$ARCH"
  -o "APT::Architectures::=$ARCH"
  -o "Dir::State=$WORKDIR/state"
  -o "Dir::State::status=/dev/null"
  -o "Dir::Cache=$WORKDIR/cache"
  -o "Dir::Etc::sourcelist=$WORKDIR/etc/sources.list"
  -o "Dir::Etc::sourceparts=-"
  -o "Dir::Etc::preferencesparts=$WORKDIR/etc/preferences.d"
  -o "Debug::NoLocking=1"
)

apt-get "${APT_OPTS[@]}" update
cd "$OUTDIR"
apt-get "${APT_OPTS[@]}" download "$@"
ls -la "$OUTDIR"
