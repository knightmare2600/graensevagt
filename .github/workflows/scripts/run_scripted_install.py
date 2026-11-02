#!/usr/bin/env python3
"""run_scripted_install.py

Drives the pfSense scripted install end to end, non-interactively, for the
build-golden-image CI workflow. Boots QEMU (kernel/initramfs-less -- this boots the
*installer* ISO directly, not graensevagt's own deploy-time initramfs, a separate
concern), answers the one interactive prompt the live environment shows (console type),
and waits for either a confirmed success or failure marker in the console output.

This replaces what was done by hand, one command at a time, while building this
workflow for the first time: watch the console, send Enter once "Console type" appears,
then watch for "Installation of pfSense complete" (success, confirmed live 2026-11-02)
or an "Extract Error"/"mountroot>"/kernel panic marker (failure). All of those markers
were observed for real during manual testing, not guessed.

Version history (append only, never delete entries):
    0.1.0  2026-11-02  First draft, written for the CI workflow. Mirrors the manual
                        testing session's own pty_daemon.py relay + separate send_cmd.txt
                        polling, but as one self-contained script with real timeouts and
                        exit codes instead of a human watching and deciding when to send
                        input. Untested in CI itself at this point -- the exact timing
                        and markers are known from manual testing, but running inside an
                        actual GitHub Actions runner (unknown KVM availability, unknown
                        CPU/disk speed) is not yet confirmed.
"""
import argparse
import os
import pty
import re
import select
import subprocess
import sys
import time

SUCCESS_MARKERS = [
    re.compile(rb"Installation of pfSense"),
]
FAILURE_MARKERS = [
    re.compile(rb"Extract Error"),
    re.compile(rb"mountroot>"),
    re.compile(rb"panic:"),
    re.compile(rb"Fatal trap"),
]
CONSOLE_PROMPT = re.compile(rb"Console type")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu-args", required=True, nargs=argparse.REMAINDER)
    parser.add_argument("--timeout", type=int, default=1800,
                         help="Overall wall-clock budget in seconds (default 30 minutes "
                              "-- generous on purpose since CI runner speed, "
                              "particularly whether KVM acceleration is actually "
                              "available, is not confirmed).")
    parser.add_argument("--log-file", required=True)
    args = parser.parse_args()

    qemu_cmd = args.qemu_args
    if qemu_cmd and qemu_cmd[0] == "--":
        qemu_cmd = qemu_cmd[1:]

    pid, master_fd = pty.fork()
    if pid == 0:
        os.execvp(qemu_cmd[0], qemu_cmd)
        os._exit(127)

    deadline = time.time() + args.timeout
    sent_console_prompt = False
    buf = b""
    log = open(args.log_file, "wb")

    try:
        while time.time() < deadline:
            r, _, _ = select.select([master_fd], [], [], 1.0)
            if master_fd in r:
                try:
                    chunk = os.read(master_fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                log.write(chunk)
                log.flush()

                if not sent_console_prompt and CONSOLE_PROMPT.search(buf):
                    os.write(master_fd, b"\n")
                    sent_console_prompt = True
                    buf = b""  # don't re-match the same prompt text repeatedly

                for pat in SUCCESS_MARKERS:
                    if pat.search(buf):
                        print(f"SUCCESS marker matched: {pat.pattern!r}")
                        return 0
                for pat in FAILURE_MARKERS:
                    if pat.search(buf):
                        print(f"FAILURE marker matched: {pat.pattern!r}", file=sys.stderr)
                        return 1

            wpid, status = os.waitpid(pid, os.WNOHANG)
            if wpid != 0:
                print(f"QEMU exited unexpectedly, status={status}", file=sys.stderr)
                return 1
    finally:
        log.close()
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass

    print("Timed out waiting for a success or failure marker", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
