import os
import pty
import sys
import select

qemu_args = sys.argv[1:]
smoke_dir = os.environ.get("SMOKE_DIR", "/tmp/graensevagt-smoke-test")
log_path = os.path.join(smoke_dir, "console.log")
cmd_path = os.path.join(smoke_dir, "send_cmd.txt")

pid, master_fd = pty.fork()
if pid == 0:
    os.execvp(qemu_args[0], qemu_args)
else:
    logf = open(log_path, "wb")
    last_cmd_mtime = 0
    while True:
        r, _, _ = select.select([master_fd], [], [], 0.5)
        if master_fd in r:
            try:
                chunk = os.read(master_fd, 65536)
                if not chunk:
                    break
                logf.write(chunk)
                logf.flush()
            except OSError:
                break
        if os.path.exists(cmd_path):
            mtime = os.path.getmtime(cmd_path)
            if mtime > last_cmd_mtime:
                last_cmd_mtime = mtime
                with open(cmd_path, "rb") as f:
                    payload = f.read()
                os.write(master_fd, payload)
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            break
    logf.close()
