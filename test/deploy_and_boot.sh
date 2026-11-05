#!/bin/bash
# deploy_and_boot.sh
#
# End-to-end QEMU test of one golden image: (1) boots graensevagt's own kernel +
# initramfs, which fetches the image over HTTP, writes it to a blank target disk and
# verifies its checksum; (2) boots the target disk on its own, through UEFI, and waits
# for the FreeSense console menu.
#
# The target disk deliberately sits on a DIFFERENT controller from the one the golden
# image was built on (built on AHCI, i.e. ada0): amd64 boots it on virtio-scsi (da0,
# the same naming that broke v0.2.0's pfSense image on VMware), arm64 on NVMe (nda0).
# That is what proves fstab/root don't depend on a device name.
#
# CONTROLLER= and NIC= override the target disk controller and the NIC model, for both
# the deploy and the boot. CONTROLLER is one of virtio-scsi, pvscsi, mptsas1068, nvme,
# ahci; NIC is any QEMU NIC device (e1000, virtio-net-pci, vmxnet3, ...). pvscsi,
# mptsas1068 (LSI SAS1068, Linux mptsas) and vmxnet3 are QEMU's emulations of VMware's
# own virtual hardware -- close to, but not the same as, a real VMware host.
#
# FIRMWARE=bios (amd64 only) boots the deployed disk through SeaBIOS instead of OVMF.
# Needed for pvscsi and mptsas1068: OVMF has no boot driver for either (confirmed live:
# "map: No mapping found", UEFI shell), whereas SeaBIOS can boot from both. Real
# VMware's EFI firmware does have them; this is a QEMU limitation only.
#
# Usage: deploy_and_boot.sh <amd64|arm64> <image.gz URL> <raw sha256 URL> [workdir]
#   URLs are as seen from inside the guest (QEMU user networking: host = 10.0.2.2).
#   The kernel/initramfs come from this repo's root: kernel-<arch> and
#   initramfs-<arch>.cpio.gz (override with KERNEL= / INITRD=).
#
# Exit 0 only if the deploy reports "Checksum verified" AND the deployed disk reaches
# FreeSense's first-boot console (the menu, or the interface-assignment prompt when the
# NICs are not the em0/em1 the default config expects). Logs: <workdir>/{deploy,boot}.log.
#
# Version history (append only, never delete entries):
#   0.1.0  2026-11-05  First version, written up from the manual v0.4.0 FreeSense tests.
#   0.2.0  2026-11-05  CONTROLLER=/NIC= overrides, for the VMware-device runs.
#                       FIRMWARE=bios. QEMU is now reaped after being killed (a
#                       killed-but-unreaped deploy QEMU still held the image lock).
#
# shellcheck disable=SC2054  # QEMU option syntax uses commas inside one argument
set -euo pipefail

ARCH="$1"
IMAGE_URL="$2"
SUM_URL="$3"
GV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${4:-$(mktemp -d "${TMPDIR:-/tmp}/graensevagt-e2e.XXXXXX")}"
KERNEL="${KERNEL:-$GV/kernel-$ARCH}"
INITRD="${INITRD:-$GV/initramfs-$ARCH.cpio.gz}"
KERNEL="$(realpath "$KERNEL")"
INITRD="$(realpath "$INITRD")"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"  # absolute: QEMU's file= paths are used after the cd
cd "$WORK"
echo "Work dir: $WORK"

CMDLINE="graensevagt_image=$IMAGE_URL graensevagt_checksum=$SUM_URL graensevagt_disk=auto"
if [ "$ARCH" = amd64 ]; then
  CONTROLLER="${CONTROLLER:-virtio-scsi}"
  NIC="${NIC:-e1000}"
  AHCI=ahci
else
  CONTROLLER="${CONTROLLER:-nvme}"
  NIC="${NIC:-virtio-net-pci}"
  AHCI=ich9-ahci
fi
case "$CONTROLLER" in
  virtio-scsi) CTRL=(-device virtio-scsi-pci,id=scsi0 -device scsi-hd,bus=scsi0.0,drive=hd0) ;;
  pvscsi|mptsas1068) CTRL=(-device "$CONTROLLER",id=scsi0 -device scsi-hd,bus=scsi0.0,drive=hd0) ;;
  nvme) CTRL=(-device nvme,serial=gv0,drive=hd0) ;;
  ahci) CTRL=(-device "$AHCI",id=ahci0 -device ide-hd,bus=ahci0.0,drive=hd0) ;;
  *) echo "unknown CONTROLLER=$CONTROLLER" >&2; exit 2 ;;
esac
echo "Controller: $CONTROLLER, NIC: $NIC"
if [ "$ARCH" = amd64 ]; then
  ACCEL=tcg
  [ -w /dev/kvm ] && ACCEL=kvm
  DEPLOY=(qemu-system-x86_64 -accel "$ACCEL" -m 512 -kernel "$KERNEL" -initrd "$INITRD"
    -append "console=ttyS0,115200 $CMDLINE"
    "${CTRL[@]}" -netdev user,id=n0 -device "$NIC",netdev=n0)
  cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd
  if [ "${FIRMWARE:-uefi}" = bios ]; then
    FW=()
  else
    FW=(-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
      -drive if=pflash,format=raw,file=vars.fd)
  fi
  echo "Boot firmware: ${FIRMWARE:-uefi}"
  BOOT=(qemu-system-x86_64 -machine q35 -accel "$ACCEL" -m 1536 -smp 2
    "${FW[@]}"
    "${CTRL[@]}"
    -netdev user,id=wan -device "$NIC",netdev=wan
    -netdev user,id=lan,net=192.168.77.0/24 -device "$NIC",netdev=lan)
else
  DEPLOY=(qemu-system-aarch64 -machine virt -cpu cortex-a72 -accel tcg,thread=multi -smp 2
    -m 1024 -kernel "$KERNEL" -initrd "$INITRD"
    -append "console=ttyAMA0,115200 $CMDLINE"
    "${CTRL[@]}" -netdev user,id=n0 -device "$NIC",netdev=n0)
  cp /usr/share/AAVMF/AAVMF_VARS.fd vars.fd
  BOOT=(qemu-system-aarch64 -machine virt -cpu cortex-a72 -accel tcg,thread=multi -smp 2
    -m 1536
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd
    -drive if=pflash,format=raw,file=vars.fd
    "${CTRL[@]}"
    -netdev user,id=wan -device "$NIC",netdev=wan
    -netdev user,id=lan,net=192.168.77.0/24 -device "$NIC",netdev=lan)
fi

rm -f target.qcow2
qemu-img create -f qcow2 target.qcow2 8G >/dev/null
DISK=(-drive if=none,id=hd0,file="$WORK/target.qcow2",format=qcow2,detect-zeroes=on)

# run_until <log> <timeout> <success-regex> <qemu args...>: run QEMU on a pty, log the
# console, answer any terminal-size query (resizewin's ESC[6n), stop at success or
# failure. Exit 0 on success. (The deploy stops at its "Write complete" line, so the
# init's "press Enter to reboot" prompt is never answered -- the write is already
# synced by then.)
run_until() {
  python3 -I - "$@" <<'PY'
import os, pty, re, select, sys, time
log, timeout, ok = sys.argv[1], int(sys.argv[2]), re.compile(sys.argv[3].encode())
bad = re.compile(rb"^\[x\] .*|panic:|mountroot>|Fatal trap|CHECKSUM MISMATCH", re.M)
pid, fd = pty.fork()
if pid == 0:
  os.execvp(sys.argv[4], sys.argv[4:])
buf, end, rc = b"", time.time() + timeout, 1
with open(log, "wb") as f:
  while time.time() < end:
    r, _, _ = select.select([fd], [], [], 1)
    if fd in r:
      try:
        c = os.read(fd, 65536)
      except OSError:
        c = b""
      if not c:
        print("FAILED: console closed; last output:\n"
                      + buf[-600:].decode(errors="replace"))
        break
      buf += c
      f.write(c)
      f.flush()
      clean = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\r|\x00", b"", buf)
      if b"\x1b[6n" in c:
        os.write(fd, b"\x1b[24;80R")
      if ok.search(clean):
        rc = 0
        break
      m = bad.search(clean)
      if m:
        print("FAILED:", m.group(0).decode(errors="replace"))
        break
    if os.waitpid(pid, os.WNOHANG)[0]:
      print(f"FAILED: QEMU exited before success; last output:\n"
                  + buf[-600:].decode(errors="replace"))
      break
  else:
    print(f"TIMED OUT after {timeout}s")
try:
  os.kill(pid, 9)
except ProcessLookupError:
  pass
# Reap it before returning: a killed-but-unreaped QEMU still holds the disk image's
# write lock, and the next QEMU then refuses to open it (confirmed live -- 'Failed to
# get "write" lock').
try:
  os.waitpid(pid, 0)
except ChildProcessError:
  pass
sys.exit(rc)
PY
}

echo "== deploy ($ARCH)"
run_until deploy.log 3600 'Checksum verified\.[^\n]*\n.*Write complete' \
  "${DEPLOY[@]}" "${DISK[@]}" -nographic -no-reboot
tr -d '\r' < deploy.log | grep -a -E '^\[[*+x]\] (Auto-resolved|Written|Checksum|Write)'

echo "== first boot of the deployed disk ($ARCH)"
# Either first-boot endpoint counts: the console menu, or FreeSense's interface-
# assignment prompt. The stock default config.xml expects em0/em1 (Intel e1000); any
# other NIC family -- virtio's vtnet here on arm64, igc/ix/mvneta on real hardware --
# stops first boot at "Should VLANs be set up now", standard pfSense/FreeSense
# behaviour, after the OS is fully up (confirmed live on arm64, and that answering it
# reaches the menu).
run_until boot.log 3600 'Enter an option:|Should VLANs be set up now' \
  "${BOOT[@]}" "${DISK[@]}" -nographic
tr -d '\r' < boot.log | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
  | grep -a -E 'Trying to mount root|^(n?da|ada|vtbd)[0-9]+:.*MB|Welcome to FreeSense|WAN \(wan\)'
echo "PASS: $ARCH image deployed, verified, and booted to the first-boot console"
