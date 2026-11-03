#!/bin/bash
# Launches a disposable QEMU smoke-test boot via test/pty_daemon.py -- the console
# log/command-injection files land under $SMOKE_DIR (default: a fresh mktemp -d),
# not anywhere inside this repo.
SMOKE_DIR="${SMOKE_DIR:-$(mktemp -d /tmp/graensevagt-smoke-test.XXXXXX)}"
GV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SMOKE_DIR"
echo "Smoke-test working dir: $SMOKE_DIR"
rm -f "$SMOKE_DIR/console.log"
export SMOKE_DIR
nohup python3 -I "$GV/test/pty_daemon.py" \
  qemu-system-x86_64 \
  -accel kvm \
  -m 512 \
  -kernel "$GV/kernel-amd64" \
  -initrd "$GV/initramfs-amd64.cpio.gz" \
  -append "console=ttyS0,115200 graensevagt_image=http://10.0.2.2:8123/test.img.gz graensevagt_checksum=http://10.0.2.2:8123/test.img.gz.sha256 graensevagt_disk=auto" \
  -device ahci,id=ahci0 \
  -drive if=none,id=disk0,file="$SMOKE_DIR/target-disk.raw",format=raw \
  -device ide-hd,bus=ahci0.0,drive=disk0 \
  -netdev user,id=net0 -device e1000,netdev=net0 \
  -nographic \
  -no-reboot \
  > "$SMOKE_DIR/daemon.log" 2>&1 &
disown
