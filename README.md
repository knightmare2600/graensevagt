# Grænsevagt

*Danish: "border guard" — the firewall-fitting name for a deploy tool that writes a
prebuilt pfSense disk image onto real hardware.*

## What this is

A minimal Linux environment, PXE-booted via iPXE, whose only job is: fetch a prebuilt
disk image over HTTP and write it straight onto the target machine's local disk, then
reboot into it.

It exists because repeatedly sanboot-ing pfSense's own FreeBSD installer over iPXE
turned out to be too fragile to maintain (BTX/El-Torito/GPT boot-structure issues, one
after another — see the parent `example_music_infra` repo's own
`project_pfsense_httpboot_sanboot_2026_11_01` memory for the full history if you need
it). The pivot: run the real installer **once**, offline, and capture the disk it
produces instead of re-running the installer on every deployment.

## How it works

1. A target machine PXE-boots `menu.ipxe`'s `:graensevagt` entry, which loads this
   repo's kernel + initramfs directly (no installer media involved at all).
2. `initramfs/init` (PID 1) brings up networking, loads the disk/NIC drivers it needs
   (none of this is built into the kernel — see below), detects the target disk, and
   streams a gzip-compressed disk image from a URL given on the kernel command line
   straight onto that disk — verified against a checksum, never buffered in full on
   local storage.
3. It reboots. The machine now boots pfSense from its own local disk, exactly as if
   the real installer had just finished running on it.

**This is completely destructive to whatever's already on the target disk.** There is a
10-second abort window built into the init script before it starts writing, and nothing
else stops it.

## What's in this repo

- `initramfs/init` — the actual deploy-time script (POSIX `sh`, runs under busybox
  `ash`). Read its own header and version-history comments for the full list of kernel
  command-line parameters it takes and every bug found fixing it against a real boot.
- `initramfs/root/` — the assembled initramfs tree: static busybox + applet symlinks,
  the init script, a `udhcpc` lease-apply script, and a small bundled kernel-module set
  (see below).
- `kernel-amd64` / `initramfs-amd64.cpio.gz` — the built, ready-to-boot kernel and
  initramfs archive. `kernel-amd64` is this estate's own Debian trixie kernel
  (`6.12.113+deb13-amd64`), not built from scratch.
- `.github/workflows/build-golden-image.yml` — automates building the actual
  *deployable pfSense image* this tool writes (a separate concern from the deploy
  mechanism above — see "Building the golden image" below).
- `test/` — the QEMU+PTY smoke-test harness used to find and fix every bug below. Not
  polished general-purpose tooling, just what was used to verify this live.

### Why it bundles its own kernel modules

Confirmed live, the hard way: neither this estate's own kernel nor Debian's own
dedicated netboot kernel has NIC or disk-controller drivers built in — everything is
modular, and a from-scratch initramfs bundles none of that by default. `initramfs/root/
lib/modules/` carries a small, named subset covering common NICs (e1000, e1000e,
virtio_net) and common disk controllers (ahci, virtio_blk, nvme), with a real
`depmod -b`-generated `modules.dep` so `modprobe` resolves dependencies correctly rather
than needing them hand-ordered.

## Using it

Add a `menu.ipxe` entry (this estate's own copy already has one, `:graensevagt`,
v2.26) that boots this repo's kernel/initramfs with these kernel command-line
parameters:

```
graensevagt_image=<url>        Required. URL of a gzip-compressed raw disk image.
graensevagt_checksum=<url>     Optional. URL of a sha256sum file for that image.
graensevagt_disk=<dev>|auto    Required. Target block device, or "auto" for the
                                single disk present (refuses if more than one exists).
graensevagt_iface=<name>       Optional. Network interface for DHCP. Auto-detects the
                                first non-loopback interface if unset.
```

## Building the golden image

The actual pfSense disk image this tool writes is a *separate* build — see
`.github/workflows/build-golden-image.yml`, which automates:

1. Fetching the real pfSense CE vendor ISO.
2. Swapping in a fixed `scriptedpart` binary (FreeBSD bug
   [273723](https://bugs.freebsd.org/273723) — the shipped one silently produces an
   empty `/etc/fstab` on a scripted install, confirmed live).
3. Running the real installer, fully unattended, under QEMU.
4. Compressing and publishing the resulting disk.

Trigger it manually via the Actions tab (`workflow_dispatch`) — it's a deliberate,
occasional build (a pfSense version bump, a `scriptedpart` re-check), not something
that runs on every push.

## Current status, honestly

- **Confirmed working end to end on real VMware hardware, 2026-11-03**: fetch the real
  ~485MB pfSense golden image over HTTP, auto-detect the target disk, stream-write with
  checksum verification, reboot, and boot cleanly into the real pfSense first-boot
  console wizard — no manual steps, no errors.
- **v0.3.0 fixes a real first-boot bug found during that real-hardware test**: the
  golden image's `/etc/fstab` referenced its root/boot partitions by raw device path
  (`/dev/ada0p2`, matching how FreeBSD enumerated the disk under the QEMU setup it was
  built on), which doesn't match every target — this specific VMware box's SCSI
  controller enumerates the same disk as `da0`, so the kernel couldn't find root and
  panicked. Fixed by GPT-labelling both partitions and rewriting `/etc/fstab` to
  reference them by label (`/dev/gpt/rootfs`, `/dev/gpt/efiboot`) instead of a raw
  device path — labels live in the partition table itself, independent of whatever name
  a given controller/bus happens to assign, so this is correct regardless of target
  hardware. Applied directly to the shipped image rather than a from-scratch rebuild;
  see `graensevagt`'s own GitHub release notes for this version and
  `example_music_infra`'s `project_pfsense_httpboot_sanboot_2026_11_01` memory for the
  full diagnostic trail.
- The `build-golden-image` workflow still has not been run for real on a GitHub Actions
  runner (the golden image shipped so far was built and fixed by hand, not through this
  workflow). Two real unknowns, documented in its own header: whether `ubuntu-latest`'s
  hosted runners have accessible KVM, and how long a software-emulated install takes if
  not.
- **No per-deployment customisation exists yet** — every machine written from the same
  golden image gets the same hostname and the same stock pfSense WebGUI admin
  credentials (`admin`/`pfsense`, pfSense's own out-of-the-box default, never
  customised during the scripted install). `/etc/rc.initial` (the console menu's own
  entry point) is a plain shell script, confirmed by Robert — the same script that
  resets the WebGUI password back to defaults is the likely pathway for a future
  one-shot first-boot customisation hook (and for a future in-place version upgrade).
  Fixing this (likely a small answer-file mechanism, matching this estate's own
  convention elsewhere) is tracked separately, not yet built.
