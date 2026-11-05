# Grænsevagt

*Danish: "border guard" — the firewall-fitting name for a deploy tool that writes a
prebuilt firewall disk image onto real hardware.*

Supported images:

| Image | Arch | Filesystem | Since | Default WebGUI login |
|---|---|---|---|---|
| pfSense CE 2.7.2 | amd64 | UFS | v0.1.0 | `admin` / `pfsense` |
| [FreeSense](https://freesense.org) 1.1.12 | amd64 | ZFS | v0.4.0 | `admin` / `freesense` |
| [FreeSense](https://freesense.org) 1.1.12 | arm64 | ZFS | v0.4.0 | `admin` / `freesense` |

FreeSense is a community rebuild of pfSense CE without the vendor lock-in; 1.1.12 is
based on FreeBSD 16.0-CURRENT and also ships an arm64 build, hence the arm64 deploy side
added in v0.4.0. The deploy mechanism itself is OS-agnostic (it writes bytes); only the
golden-image builds differ.

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
- `initramfs/root/` — the assembled amd64 initramfs tree: static busybox + applet
  symlinks, the init script, a `udhcpc` lease-apply script, and a small bundled
  kernel-module set (see below).
- `initramfs/modules-<arch>.txt` — the top-level kernel modules each architecture's
  initramfs bundles and loads (v0.4.0+). Dependencies are resolved automatically.
- `tools/build-initramfs.sh` — builds an initramfs for one architecture from a static
  busybox and a kernel module tree (v0.4.0+; the original amd64 tree was hand-built).
- `tools/fetch-debian-debs.sh` — fetches Debian .debs for a foreign architecture (the
  arm64 kernel and busybox) without root and without touching the host's apt/dpkg
  state, verified by apt itself against the Debian archive keyring.
- `kernel-amd64` / `initramfs-amd64.cpio.gz` — the built, ready-to-boot kernel and
  initramfs archive. `kernel-amd64` is this estate's own Debian trixie kernel
  (`6.12.113+deb13-amd64`), not built from scratch. `kernel-arm64` /
  `initramfs-arm64.cpio.gz` (v0.4.0+, release assets) are the same Debian trixie kernel
  line for arm64 (`6.12.113+deb13-arm64`, from `linux-image-6.12.113+deb13-arm64`
  6.12.113-1) with `busybox-static` 1:1.37.0-6+b9 for arm64 — the same versions as amd64.
- `.github/workflows/build-golden-image.yml` — automates building the actual
  *deployable pfSense image* this tool writes (a separate concern from the deploy
  mechanism above — see "Building the golden image" below).
- `.github/workflows/build-freesense-golden-image.yml`, `freesense/installerconfig.in`,
  `.github/workflows/scripts/run_freesense_install.py` — the same for the FreeSense
  images, amd64 and arm64 (v0.4.0+; see "Building the FreeSense golden images").
- `test/` — the QEMU+PTY test harness used to find and fix every bug below.
  `test/deploy_and_boot.sh` (v0.4.0+) runs one image end to end: deploy via this
  repo's kernel/initramfs, verify the checksum, then boot the deployed disk to the
  console menu on a *different* disk controller from the one it was built on.

### Why it bundles its own kernel modules

Confirmed live, the hard way: neither this estate's own kernel nor Debian's own
dedicated netboot kernel has NIC or disk-controller drivers built in — everything is
modular, and a from-scratch initramfs bundles none of that by default. `initramfs/root/
lib/modules/` carries a small, named subset covering common NICs (e1000, e1000e,
virtio_net) and common disk controllers (ahci, virtio_blk, nvme), with a real
`depmod -b`-generated `modules.dep` so `modprobe` resolves dependencies correctly rather
than needing them hand-ordered.

v0.4.0 moves the list into `initramfs/modules-<arch>.txt` and adds `virtio_scsi` to both
(a virtio-scsi disk — Proxmox's default controller — was invisible before, confirmed in
QEMU). arm64 drops `vmw_pvscsi` (x86-only) and adds `vmxnet3` (the paravirtual NIC of
VMware on Arm: Fusion on Apple Silicon, ESXi-Arm).

## Using it

Add a `menu.ipxe` entry (this estate's own copy already has one, `:graensevagt`,
v2.27) that boots this repo's kernel/initramfs with these kernel command-line
parameters:

```
graensevagt_image=<url>        Required. URL of a gzip-compressed raw disk image.
graensevagt_checksum=<url>     Optional. URL of a sha256sum file for that image --
                                the hash of the RAW (decompressed) image, since that
                                is what gets hashed as it is written, NOT of the .gz.
graensevagt_disk=<dev>|auto    Required. Target block device, or "auto" for the
                                single disk present (refuses if more than one exists).
graensevagt_iface=<name>       Optional. Network interface for DHCP. Auto-detects the
                                first non-loopback interface if unset.
```

Example `menu.ipxe` entry, serving `kernel-amd64`/`initramfs-amd64.cpio.gz`/the golden
image off `${boot-url}` (this estate's own site-mirrored bootstrap web server, set
earlier in `menu.ipxe` by gateway detection -- any plain HTTP URL works the same way):

```
:graensevagt
iseq ${arch} arm64 && goto noarch-msg ||
kernel ${boot-url}/graensevagt/kernel-amd64 console=ttyS0,115200 console=tty0 graensevagt_image=${boot-url}/graensevagt/pfsense-2.7.2-graensevagt-golden.img.gz graensevagt_checksum=${boot-url}/graensevagt/pfsense-2.7.2-graensevagt-golden.img.sha256 graensevagt_disk=auto
initrd ${boot-url}/graensevagt/initramfs-amd64.cpio.gz
boot
```

From v0.4.0, a FreeSense entry choosing the architecture with the same `${arch}`
convention the entry above already relies on (amd64 → FreeSense amd64, arm64 →
FreeSense arm64), and passing the raw-image checksum:

```
:graensevagt-freesense
iseq ${arch} arm64 && goto graensevagt-freesense-arm64 ||
kernel ${boot-url}/graensevagt/kernel-amd64 console=ttyS0,115200 console=tty0 graensevagt_image=${boot-url}/graensevagt/freesense-1.1.12-amd64-graensevagt-golden.img.gz graensevagt_checksum=${boot-url}/graensevagt/freesense-1.1.12-amd64-graensevagt-golden.img.sha256 graensevagt_disk=auto
initrd ${boot-url}/graensevagt/initramfs-amd64.cpio.gz
boot

:graensevagt-freesense-arm64
kernel ${boot-url}/graensevagt/kernel-arm64 console=ttyAMA0,115200 console=tty0 graensevagt_image=${boot-url}/graensevagt/freesense-1.1.12-arm64-graensevagt-golden.img.gz graensevagt_checksum=${boot-url}/graensevagt/freesense-1.1.12-arm64-graensevagt-golden.img.sha256 graensevagt_disk=auto
initrd ${boot-url}/graensevagt/initramfs-arm64.cpio.gz
boot
```

`console=ttyAMA0` is the PL011 UART (QEMU `virt`, many Arm servers); the serial device
name on a given arm64 board varies, so check that board's own console name.

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

Checksums (fixed 2026-11-05, workflow 0.2.0): the workflow originally published only
the `.gz`'s sha256, but `initramfs/init` compares against the hash of the
*decompressed* stream, so that file could never be used as `graensevagt_checksum=`. Both
workflows now publish `<name>.img.sha256` (raw image — give this one to init) and
`<name>.img.gz.sha256` (the download). v0.3.0 shipped no checksum at all; the raw-image
hash of its unchanged pfSense image is published with v0.4.0
(`pfsense-2.7.2-graensevagt-golden.img.sha256`), confirmed by a real deploy reporting
"Checksum verified". Each release from v0.4.0 also carries a `SHA256SUMS` covering
every asset as downloaded.

## Building the FreeSense golden images

`.github/workflows/build-freesense-golden-image.yml` builds both architectures (matrix:
amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`). Unlike the pfSense build it does
**not** remaster the vendor media:

1. Download the FreeSense installer media (the URLs, and optionally their sha256s, are
   workflow inputs — no stable direct download link was found to hardcode).
2. Boot it under QEMU (UEFI). `run_freesense_install.py` answers the console-type
   prompt, accepts the copyright notice and cancels the welcome menu, which drops to a
   root shell; the installer mounts a writable memory disk over `/etc`, so it types
   `/etc/installerconfig` (from `freesense/installerconfig.in`) straight in and runs
   `bsdinstall script`.
3. The scripted install reproduces FreeSense's own interactive ZFS layout (pool
   `FreeSense`, boot environment `ROOT/default`, same datasets, 1 GB swap). With ZFS on
   GPT, `/etc/fstab` references `/dev/gpt/efiboot0` and `/dev/gpt/swap0` and root comes
   from the pool's `bootfs`, so v0.3.0's by-label fix is built in rather than patched
   on. amd64 is BIOS+UEFI; arm64 is UEFI.
4. One change goes into the `cf` dataset from the installer shell:
   `/cf/conf/enableserial_force`, FreeSense's own appliance switch for a serial console
   (without it the stock config leaves the serial console with no getty at all). Video
   stays the primary console.
5. The result is checked inside the VM (fstab by label only, `bootfs`, the ESP's
   removable-media fallback loader, the serial flag), exported, compressed, and its
   raw-image sha256 recorded.

The same script runs locally; see the workflow for the exact QEMU arguments. Measured
on a 2-vCPU Debian trixie box: amd64 install ~90 s under KVM; arm64 ~4.5 min under TCG
emulation (no KVM for aarch64 on an amd64 host).

Two FreeSense-specific things to know:

- The images are 803 MB (amd64) and 733 MB (arm64) gzipped, against pfSense's 485 MB:
  ZFS `compression=on` has already compressed the blocks, so gzip has little left.
- The pool fills a 4 GB image and does **not** grow onto a larger target disk by
  itself (`autoexpand=off`); FreeBSD also warns at boot that "the secondary GPT header
  is not in the last LBA" (harmless; `gpart recover` fixes it). The pfSense image has
  the same not-growing limitation.

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
  convention elsewhere) is tracked separately, not yet built. The same applies to the
  FreeSense images (`admin`/`freesense`). FreeSense's installer has a hook worth
  looking at for this: `copy_configxml_from_usb` picks up a `config.xml` from a FAT USB
  stick at install time.

### v0.4.0 (FreeSense, arm64) — tested in QEMU only so far

- **Both FreeSense images built by `run_freesense_install.py`** (not by hand) and run
  end to end with `test/deploy_and_boot.sh`, 2026-11-05: deploy over HTTP via
  graensevagt's own kernel/initramfs, raw-image checksum verified, then first boot of
  the deployed disk on a different controller from the build one:
  - amd64: built on AHCI (`ada0`), deployed to and booted from virtio-scsi (`da0`),
    under both UEFI (OVMF) and legacy BIOS (SeaBIOS); reaches the console menu, WAN
    on DHCP. Default WebGUI login confirmed as `admin`/`freesense` with FreeSense's own
    `password_verify()` against the generated `config.xml`.
  - arm64: built on AHCI (`ada0`), deployed to and booted from NVMe (`nda0`) under
    UEFI (AAVMF), Debian arm64 kernel + this repo's arm64 initramfs (virtio-net DHCP,
    NVMe auto-detected). First boot stops at FreeSense's interface-assignment prompt
    because the stock config expects `em0`/`em1` and the VM has VirtIO NICs (`vtnet`);
    answering it reaches the console menu with WAN on DHCP. Any target whose NICs are
    not Intel `em` will see the same prompt — normal pfSense/FreeSense behaviour.
- **VMware virtual hardware, as emulated by QEMU** (amd64, 2026-11-05; QEMU's
  emulations, not a real VMware host):
  - **vmxnet3**: works on both sides — Linux `vmxnet3` gets the deploy's DHCP lease
    and fetches the image; FreeSense attaches `vmx0`/`vmx1`.
  - **PVSCSI**: works on both sides. The deploy finds the disk via Linux
    `vmw_pvscsi`, writes it and verifies the checksum; FreeSense boots from it
    (FreeBSD `pvscsi0`, `da0`) and, with vmxnet3 NICs, stops at the interface-
    assignment prompt (`vmx0`/`vmx1` vs the default config's `em0`/`em1`). Booted
    through SeaBIOS, because QEMU's OVMF has no PVSCSI boot driver (real VMware's EFI
    firmware does). Note: on a legacy-BIOS boot the FreeSense loader makes **video**
    the primary console, so that pre-login prompt appears on the screen only, not on
    serial; on UEFI, serial is primary and it appears there too.
  - **LSI Logic SAS** (QEMU `mptsas1068`): FreeSense boots from it cleanly
    (`da0 at mpt0`, console menu). The deploy side could not be tested: Linux `mptsas`
    initialises the controller but never discovers a disk on QEMU's emulation —
    and neither does Debian's own full initramfs on the same setup, so this is not a
    gap in graensevagt's initramfs. The same `mpt*` modules deployed fine on real
    VMware in v0.3.0.
  - **LSI Logic Parallel** (`mptspi`): QEMU has no emulation of it; untested.
- **Not yet confirmed on real hardware** for either architecture, and the arm64
  deploy side has only run under emulation. The `build-freesense-golden-image`
  workflow has not been run on a GitHub runner yet.
- The committed amd64 initramfs (`initramfs-amd64.cpio.gz`, `initramfs/root/`) is now
  rebuilt from source by `tools/build-initramfs.sh` with init 0.6.0 (pipeline-failure
  fix, per-arch module list, `virtio_scsi` + `vmxnet3`). Deploy-tested in QEMU against
  a 404 and an unfetchable checksum URL (each now fails loudly instead of claiming
  success) and against the real FreeSense image. The v0.3.0 initramfs that was proven
  on real VMware stays available as that release's asset.
