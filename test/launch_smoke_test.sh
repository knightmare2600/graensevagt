#!/bin/bash
TMPDIR="/tmp/claude-1000/-home-knightmare-example-music-infra/df994ae5-6d51-4b04-8ddb-242abd0f8f68/scratchpad"
GV="/home/knightmare/graensevagt"
rm -f "$TMPDIR/smoke-test/console.log"
nohup python3 -I "$GV/initramfs/pty_daemon.py" \
  qemu-system-x86_64 \
  -accel kvm \
  -m 512 \
  -kernel "$GV/kernel-amd64" \
  -initrd "$GV/initramfs-amd64.cpio.gz" \
  -append "console=ttyS0,115200 graensevagt_image=http://10.0.2.2:8123/test.img.gz graensevagt_checksum=http://10.0.2.2:8123/test.img.gz.sha256 graensevagt_disk=auto" \
  -device ahci,id=ahci0 \
  -drive if=none,id=disk0,file="$TMPDIR/smoke-test/target-disk.raw",format=raw \
  -device ide-hd,bus=ahci0.0,drive=disk0 \
  -netdev user,id=net0 -device e1000,netdev=net0 \
  -nographic \
  -no-reboot \
  > "$TMPDIR/smoke-test/daemon.log" 2>&1 &
disown
