#!/usr/bin/env python3
"""run_freesense_install.py

Drives a FreeSense scripted ZFS install end to end under QEMU, non-interactively, and
verifies the result inside the VM before powering it off. Used by the
build-freesense-golden-image workflow and runnable by hand.

Unlike the pfSense build (run_scripted_install.py), the vendor media is NOT remastered.
The FreeSense installer mounts a writable md(4) over /etc and drops to a root shell when
its welcome menu is cancelled, so this script:

  1. answers "Console type" (vt100) and accepts the copyright notice,
  2. sends ESC at the welcome menu -- the installer exits and /etc/rc.local drops to a
     root shell ("The FreeSense installer exited (status 1)"), confirmed live,
  3. types /etc/installerconfig in as base64 one line at a time, waiting for each line
     to echo back before sending the next (confirmed live: an unpaced paste over the
     emulated serial port silently drops input after roughly 400 bytes), and checks its
     md5 against the local copy,
  4. runs `bsdinstall script /etc/installerconfig`,
  5. imports the new pool, applies the one change that has to go into the cf dataset
     (FreeSense's serial-console flag), then checks the things a deployed box
     depends on (fstab by GPT label only, the bootfs property, the ESP's
     removable-media fallback loader, the serial-console flag, the build marker),
     exports it and powers off.

Every wait has a timeout and every failure marker observed during manual testing ends
the run with a non-zero exit code. The full console is written to --log-file.

Version history (append only, never delete entries):
  0.1.0  2026-11-05  First version, written from a manual run of every step against
                     FreeSense 1.1.12 amd64 under KVM (install ~1 minute), then run
                     unchanged for arm64 under TCG (~4.5 minutes in all).
"""
import argparse
import base64
import hashlib
import os
import pty
import re
import select
import sys
import time

FAILURE_MARKERS = [
  re.compile(rb"panic:"),
  re.compile(rb"Fatal trap"),
  re.compile(rb"mountroot>"),
  # zfsboot's interactive menu appearing means the preamble's variables were not
  # seen (confirmed live when they were not exported).
  re.compile(rb"ZFS Configuration"),
  re.compile(rb"Installation Error"),
]
# ANSI/VT100 control sequences, CRs, and NUL padding. The NULs are terminfo padding
# after attribute changes -- seen on the arm64 (TCG) console as
# "R\x1b[m\x00\x00escue Shell", never on amd64 (confirmed live on both).
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-B]|\r|\x00")


class Failure(Exception):
  pass


class Console:
  def __init__(self, cmd, log_path, deadline):
    self.pid, self.fd = pty.fork()
    if self.pid == 0:
      os.execvp(cmd[0], cmd)
      os._exit(127)
    self.buf = b""
    self.mark = 0
    self.log = open(log_path, "wb")
    self.deadline = deadline

  def _pump(self, timeout):
    r, _, _ = select.select([self.fd], [], [], timeout)
    if self.fd in r:
      try:
        chunk = os.read(self.fd, 65536)
      except OSError:
        chunk = b""
      if not chunk:
        raise Failure("QEMU console closed unexpectedly")
      self.buf += chunk
      self.log.write(chunk)
      self.log.flush()
    wpid, status = os.waitpid(self.pid, os.WNOHANG)
    if wpid != 0:
      self.pid = 0
      raise Failure(f"QEMU exited unexpectedly, status={status}")

  def expect(self, pattern, timeout, failures=True, strip=False):
    """Wait for pattern (bytes regex) in output since the last match. Returns the
    match. Raises Failure on timeout, QEMU exit, or any FAILURE_MARKER.

    strip=True matches against the text with ANSI sequences removed and then
    consumes everything received so far -- needed for bsddialog screens, which
    split words with attribute codes (the hotkey letter of "Rescue Shell" arrives
    as "R\\x1b[mescue", confirmed live). Shell markers are plain text and use
    strip=False so the byte offsets stay exact for run()."""
    pat = re.compile(pattern) if isinstance(pattern, bytes) else pattern
    end = min(time.time() + timeout, self.deadline)
    while True:
      window = self.buf[self.mark:]
      m = pat.search(ANSI.sub(b"", window) if strip else window)
      if m:
        self.mark = len(self.buf) if strip else self.mark + m.end()
        return m
      if failures:
        for f in FAILURE_MARKERS:
          if f.search(window):
            raise Failure(f"failure marker {f.pattern!r} seen while waiting "
                                      f"for {pat.pattern!r}")
      if time.time() > end:
        raise Failure(f"timed out after {timeout}s waiting for {pat.pattern!r}")
      self._pump(1.0)

  def send(self, data):
    os.write(self.fd, data)

  def send_line(self, line, timeout=60):
    """Send one shell line and wait for its own echo, so input never outruns the
    emulated UART. Echo is matched on the raw bytes (see below)."""
    self.send(line.encode() + b"\r")
    # sh's line editor wraps at the terminal width by inserting " \b" (and on some
    # terminals CR/LF, or NUL padding) mid-line -- confirmed live as
    # "echo @@INSTALL \b_RC=$?@@" -- so tolerate those between any two characters.
    sep = rb"(?: \x08|\r|\n|\x00)*"
    tail = sep.join(re.escape(bytes([c])) for c in line[-24:].encode())
    end = time.time() + timeout
    while True:
      # Advance only to the end of the echo itself: the command's own output can
      # arrive in the same read and must stay unconsumed (confirmed live).
      m = re.search(tail, self.buf[self.mark:])
      if m:
        self.mark += m.end()
        return
      if time.time() > end:
        raise Failure(f"no echo for line {line[:40]!r}")
      self._pump(0.5)

  def run(self, command, tag, timeout):
    """Run a shell command, return (rc, output) using unique begin/end markers."""
    self.send_line(f"echo @@{tag}_BEGIN@@; {command}; echo @@{tag}_RC=$?@@")
    self.expect(rf"@@{tag}_BEGIN@@\r*\n".encode(), 30)
    start = self.mark
    m = self.expect(rf"@@{tag}_RC=(\d+)@@".encode(), timeout)
    output = ANSI.sub(b"", self.buf[start:self.mark - len(m.group(0))])
    return int(m.group(1)), output.decode(errors="replace")

  def kill(self):
    if self.pid:
      try:
        os.kill(self.pid, 9)
      except ProcessLookupError:
        pass
    self.log.close()


# Run inside the installer after `bsdinstall script`, before VERIFY_SCRIPT. Changes
# that have to land in the cf dataset happen here rather than in installerconfig's
# chroot stage: FreeSense/ROOT/default/cf is canmount=noauto and is not mounted during
# the install (confirmed live), so a chroot-side write to /cf ends up hidden underneath
# it on the booted system.
FINALISE_SCRIPT = """\
zpool import -f -N -R /mnt FreeSense
zfs mount FreeSense/ROOT/default
zfs mount FreeSense/ROOT/default/cf
mkdir -p /mnt/cf/conf
# FreeSense's own appliance switch for a serial console (is_serial_enabled() in
# /etc/inc/freesense-utils.inc; preserved across factory reset by config.lib.inc).
touch /mnt/cf/conf/enableserial_force
zfs umount -a
zpool export FreeSense
"""

# Run inside the installer after FINALISE_SCRIPT, with `sh -ex`: any failing check
# aborts it non-zero. These are the properties a deployed box actually depends on.
VERIFY_SCRIPT = """\
zpool import -f -N -R /mnt FreeSense
zfs mount FreeSense/ROOT/default
zfs mount FreeSense/ROOT/default/cf
zfs mount -a
test "$(zpool get -H -o value bootfs FreeSense)" = FreeSense/ROOT/default
# fstab must reference partitions by GPT label only -- a raw device name (ada0p1,
# da0p3, vtbd0p1, nda0p1...) is exactly the v0.2.0 first-boot failure.
# (Not "! grep": sh -e exempts a negated command, so it could never abort the script.)
if grep -E '^/dev/(ada|da|vtbd|nda|nvd)[0-9]' /mnt/etc/fstab; then exit 1; fi
grep -q '^/dev/gpt/efiboot0' /mnt/etc/fstab
test -f /mnt/cf/conf/enableserial_force
test -f /mnt/etc/graensevagt-build-marker
mkdir -p /tmp/esp
mount -t msdosfs /dev/gpt/efiboot0 /tmp/esp
# The target's NVRAM has no boot entry for this disk, so the removable-media fallback
# path (efi/boot/bootx64.efi / bootaa64.efi) is what actually boots it.
ls /tmp/esp/efi/boot/boot*.efi
umount /tmp/esp
cat /mnt/etc/fstab /mnt/etc/graensevagt-build-marker
gpart show -l @DISK@
zfs list -o name,used,mountpoint
"""


def upload(con, path, data):
  """Type a file into the VM as base64, one echo-synchronised line at a time, then
  check its md5 against the local copy."""
  con.send_line(f"b64decode -r > {path} <<'GVEOF'")
  for line in base64.encodebytes(data).decode().split():
    con.send_line(line)
  con.send_line("GVEOF")
  want = hashlib.md5(data).hexdigest()
  _, out = con.run(f"md5 -q {path}", "MD5", 60)
  if want not in out:
    raise Failure(f"{path} md5 mismatch after upload: want {want}, got {out!r}")


def render_installerconfig(template_path, disk, boot_type, build_id):
  text = open(template_path).read()
  text = (text.replace("@DISK@", disk).replace("@BOOT_TYPE@", boot_type)
      .replace("@BUILD_ID@", build_id))
  # Drop the preamble's comment-only lines (everything is typed over a slow serial
  # line); keep everything from the first "#!" line on untouched.
  pre, sep, post = text.partition("\n#!")
  pre = "\n".join(l for l in pre.splitlines() if not l.lstrip().startswith("#"))
  return (pre.strip("\n") + "\n" + sep.lstrip("\n") + post).encode()


def main():
  p = argparse.ArgumentParser()
  p.add_argument("--installerconfig", required=True, help="path to installerconfig.in")
  p.add_argument("--disk", default="ada0")
  p.add_argument("--boot-type", required=True, choices=["BIOS+UEFI", "UEFI"])
  p.add_argument("--build-id", required=True)
  p.add_argument("--timeout", type=int, default=7200,
                   help="overall wall-clock budget, seconds (arm64 under TCG is slow)")
  p.add_argument("--log-file", required=True)
  p.add_argument("--qemu-args", required=True, nargs=argparse.REMAINDER)
  a = p.parse_args()
  qemu = a.qemu_args[1:] if a.qemu_args and a.qemu_args[0] == "--" else a.qemu_args

  cfg = render_installerconfig(a.installerconfig, a.disk, a.boot_type, a.build_id)

  t0 = time.time()
  con = Console(qemu, a.log_file, t0 + a.timeout)

  def step(msg):
    print(f"[{int(time.time() - t0):5d}s] {msg}", flush=True)

  try:
    step("waiting for the installer (boot)")
    con.expect(rb"Console type \[vt100\]:", 1800)
    con.send(b"vt100\r")
    con.expect(rb"Copyright and distribution notice", 300, strip=True)
    time.sleep(2)
    con.send(b"\r")
    con.expect(rb"Rescue Shell", 300, strip=True)
    time.sleep(2)
    con.send(b"\x1b")
    con.expect(rb"The FreeSense installer exited", 120, strip=True)
    time.sleep(2)
    rc, _ = con.run("true", "SHELL", 60)  # proves a live shell, prompt-agnostic
    step("at the rescue shell; typing /etc/installerconfig")

    upload(con, "/etc/installerconfig", cfg)
    step("installerconfig in place (md5 verified); running bsdinstall script")

    rc, _ = con.run("bsdinstall script /etc/installerconfig", "INSTALL", a.timeout)
    if rc != 0:
      _, log = con.run("tail -n 60 /tmp/bsdinstall_log", "LOG", 120)
      raise Failure(f"bsdinstall script failed rc={rc}\n{log}")
    step("bsdinstall script finished rc=0; verifying the installed system")

    upload(con, "/tmp/gv-finalise.sh", FINALISE_SCRIPT.encode())
    rc, out = con.run("sh -ex /tmp/gv-finalise.sh", "FINALISE", 300)
    print(out, flush=True)
    if rc != 0:
      raise Failure(f"post-install finalise step failed rc={rc}")
    upload(con, "/tmp/gv-verify.sh", VERIFY_SCRIPT.replace("@DISK@", a.disk).encode())
    rc, out = con.run("sh -ex /tmp/gv-verify.sh", "VERIFY", 300)
    print(out, flush=True)
    if rc != 0:
      raise Failure(f"post-install verification failed rc={rc}")
    rc, out = con.run("zfs umount -a; zpool export FreeSense", "EXPORT", 300)
    if rc != 0:
      raise Failure(f"zpool export failed rc={rc}: {out}")
    step("verified and exported; powering off")
    con.send_line("poweroff")
    # QEMU exiting closes the pty first, which _pump() reports as a Failure before
    # the process has necessarily been reaped -- so keep pumping/reaping until the
    # PID is actually gone (confirmed live: a clean "Uptime: ..." poweroff was
    # misreported as a hang when the closed pty alone ended this loop).
    end = time.time() + 300
    while con.pid and time.time() < end:
      try:
        con._pump(1.0)
      except Failure:
        wpid, _ = os.waitpid(con.pid, os.WNOHANG)
        if wpid != 0:
          con.pid = 0
        else:
          time.sleep(1)
    if con.pid:
      raise Failure("VM did not power off within 300s")
    step("done")
    return 0
  except Failure as e:
    print(f"FAILURE: {e}", file=sys.stderr, flush=True)
    return 1
  finally:
    con.kill()


if __name__ == "__main__":
  sys.exit(main())
