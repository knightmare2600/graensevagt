#!/bin/bash
# build-initramfs.sh
#
# Assembles graensevagt's deploy-time initramfs for one architecture and packs it as a
# gzip-compressed newc cpio archive. Replaces the by-hand assembly used for the
# original amd64 initramfs (2026-11-02). Checked against that committed tree
# (initramfs/root/) on 2026-11-05 with the same inputs: identical busybox, every shared
# .ko byte-identical, and the same file list except (a) the new etc/graensevagt/modules
# and (b) two modules the hand-built tree carried that nothing needs -- nvme-fabrics
# and nvme-keyring (NVMe over Fabrics; per modules.dep, local PCIe nvme needs only
# nvme-core + nvme-auth, and init never loads either directly).
#
# Usage:
#   build-initramfs.sh <arch> <busybox-binary> <modules-dir> <stage-dir> <out.cpio.gz>
#
#   <arch>           amd64 | arm64 -- selects initramfs/modules-<arch>.txt
#   <busybox-binary> a STATIC busybox for <arch> (Debian busybox-static)
#   <modules-dir>    a kernel module tree, i.e. .../lib/modules/<kver>, for the kernel
#                    the initramfs will be booted with -- the host's own for amd64,
#                    or one unpacked from a Debian linux-image .deb for arm64. If it
#                    has no modules.dep yet (a freshly unpacked .deb has none), depmod
#                    generates one first; the host's depmod handles a foreign-arch
#                    tree (confirmed for arm64 on an amd64 host).
#   <stage-dir>      directory to assemble the tree in (emptied first)
#   <out.cpio.gz>    archive to write
#
# Only the top-level module names are listed in modules-<arch>.txt; their full
# dependency closure is taken from modules.dep rather than hand-maintained (the 0.4.x
# init history is a list of exactly the missing-dependency failures that hand
# maintenance produces). Modules are decompressed: Debian ships .ko.xz, and the
# original tree carried plain .ko for busybox modprobe.
#
# Version history (append only, never delete entries):
#   0.1.0  2026-11-05  First version, for v0.4.0's arm64 initramfs (and to make the
#                       amd64 one reproducible from source).
#
set -euo pipefail

ARCH="$1"
BUSYBOX="$2"
MODDIR="$(cd "$3" && pwd)"
STAGE="$4"
OUT="$5"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODLIST="$REPO/initramfs/modules-$ARCH.txt"
KVER="$(basename "$MODDIR")"
# Applets the init script and udhcpc hook use, as symlinks -- the same set as the
# original hand-built tree.
APPLETS="awk cat dd gunzip gzip ip ls mkdir mkfifo modprobe mount reboot sh sha256sum
sleep tee udhcpc wget"

[ -r "$MODLIST" ] || { echo "no module list $MODLIST" >&2; exit 1; }
file -L "$BUSYBOX" | grep -q 'statically linked' || {
  echo "$BUSYBOX is not a statically linked binary" >&2; exit 1; }

if [ ! -s "$MODDIR/modules.dep" ]; then
  echo "No modules.dep in $MODDIR -- generating it with depmod"
  BASE="$(cd "$MODDIR/../../.." && pwd)"  # depmod -b wants <base>/lib/modules/<kver>
  /sbin/depmod -b "$BASE" "$KVER"
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,dev,etc/udhcpc,etc/graensevagt,lib/modules/"$KVER",proc,sbin,sys,tmp}

install -m 0755 "$REPO/initramfs/init" "$STAGE/init"
install -m 0755 "$REPO/initramfs/root/etc/udhcpc/default.script" "$STAGE/etc/udhcpc/default.script"
install -m 0755 "$BUSYBOX" "$STAGE/bin/busybox"
for a in $APPLETS; do
  ln -s busybox "$STAGE/bin/$a"
done
grep -v '^\s*\(#\|$\)' "$MODLIST" > "$STAGE/etc/graensevagt/modules"

# Dependency closure from modules.dep ("path: dep dep ..."), keyed by module name.
declare -A WANT=()
resolve() {
  local name="$1" line path
  line="$(grep -E "(^|/)${name//-/[-_]}\.ko(\.xz|\.zst|\.gz)?:" "$MODDIR/modules.dep" || true)"
  if [ -z "$line" ]; then
    if grep -qE "(^|/)${name//-/[-_]}\.ko$" "$MODDIR/modules.builtin"; then
      echo "  $name: built in, nothing to bundle"
      return 0
    fi
    echo "module $name not found in $MODDIR" >&2
    exit 1
  fi
  for path in ${line/:/}; do
    WANT["$path"]=1
  done
}
while read -r m; do
  resolve "$m"
done < "$STAGE/etc/graensevagt/modules"

for path in "${!WANT[@]}"; do
  dest="$STAGE/lib/modules/$KVER/${path%.xz}"
  dest="${dest%.zst}"
  dest="${dest%.gz}"
  mkdir -p "$(dirname "$dest")"
  case "$path" in
    *.xz)  xz -dc "$MODDIR/$path" > "$dest" ;;
    *.zst) zstd -qdc "$MODDIR/$path" > "$dest" ;;
    *.gz)  gzip -dc "$MODDIR/$path" > "$dest" ;;
    *)     cp "$MODDIR/$path" "$dest" ;;
  esac
done
echo "Bundled ${#WANT[@]} modules for $ARCH ($KVER)"

# depmod needs modules.order/builtin(.modinfo) as inputs; the original tree kept only
# the generated indexes, so the inputs are removed again afterwards.
for f in modules.order modules.builtin modules.builtin.modinfo; do
  cp "$MODDIR/$f" "$STAGE/lib/modules/$KVER/"
done
/sbin/depmod -b "$STAGE" "$KVER"
rm -f "$STAGE/lib/modules/$KVER/"{modules.order,modules.builtin,modules.builtin.modinfo}

mkdir -p "$(dirname "$OUT")"
(cd "$STAGE" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) \
  | gzip -9 -n > "$OUT"
ls -la "$OUT"
