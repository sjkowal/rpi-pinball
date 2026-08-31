# rpi-image-gen notes

Working notes on how [raspberrypi/rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen) actually behaves, gathered from its own docs/source and from [jonnymacs/rpi-tutorials](https://github.com/jonnymacs/rpi-tutorials)'s example repos. None of this is derivable just from reading this repo's customization tree — it comes from the upstream framework's internals. Written down so we don't have to re-derive it.

**Everything below this point describes the pre-v1.0 pinned commit this project used through `main`.** The `adopt_2.8.0` branch migrated to the current v2.8.0 release, which is a complete architectural rewrite (new Python-driven CLI, YAML-only config, no more `profile/` files, `.cfg`/`.options` fully removed) — see the "v2.8.0 migration" section at the end of this file for what changed and what's still true.

## The hook lifecycle — and the bug it caused us

rpi-image-gen builds in phases (`docs/execution/index.adoc` in the upstream repo):

| Phase | Context | Classification | When |
|---|---|---|---|
| setup | bdebstrap | bundle | after output dir creation, before packages installed |
| pre-build | bdebstrap | single | within setup |
| extract | bdebstrap | bundle | after `Essential:yes` packages extracted |
| essential | bdebstrap | bundle | after essential packages installed |
| **customize** | **bdebstrap** | bundle | **after all packages installed, before cleanup** |
| cleanup | bdebstrap | bundle | after customize |
| **post-build** | **main** | single | **after bdebstrap has already exited** |
| sbom / pre-image / post-image / finalize / deploy | main | single | later stages |

The critical column is **Context**. Everything through `cleanup` runs *inside* the `mmdebstrap`/`bdebstrap` process, which owns a private mount namespace with `/proc`, `sysfs`, `devpts` mounted into the rootfs. `post-build` explicitly runs in the `main` context, after that process has exited and torn its own mounts down.

**This means `device/<class>/post-build.sh` and `image/<layout>/post-build.sh` are structurally the wrong place for anything needing a working chroot** (`apt-get`, `pip install`, anything that touches `/dev/null`, DNS, etc.). We hit this directly: `chroot $rootfs apt-get update` inside `device/pi5/post-build.sh` failed with `apt-key: cannot create /dev/null: Permission denied` — there's no `/dev` in the rootfs at that point. Manually bind-mounting `/dev`/`/proc`/`/sys` ourselves in `post-build.sh` is fighting the framework (racing bdebstrap's own mount/unmount lifecycle) rather than using its supported extension point, and isn't reliable.

Every real-world example confirms `post-build.sh` is meant only for **plain file writes** into the rootfs — no chroot execution needed. E.g. `rpi-ble-server`'s `device/pi5/post-build.sh` just does:
```sh
cat <<EOF > $1/etc/modules
i2c-dev
i2c-bcm2835
EOF
```

## Where package/software installs actually belong

**`bdebstrap/customizeNN-*` scripts**, placed next to the image layout (or under a device asset dir), run during the `customize` phase — bundle-classified, discovered from `bdebstrap/` subdirectories in this order: device asset dir → image asset dir → `SRCROOT/bdebstrap` → built-in `IGROOT/scripts/bdebstrap`, executed in alphanumeric-basename order per phase. Because this runs *inside* the mmdebstrap-owned chroot, plain `chroot $1 apt install -y ...` and `chroot $1 <anything>` just work — no manual mounting needed.

This repo already had a working example of this pattern before we understood why it worked: `pinball/image/mbr/simple_dual/bdebstrap/customize05-pkgs` (installs `dosfstools`/`e2fsprogs`, vendored from rpi-image-gen-example). MPF installation now lives in `customize10-mpf` in the same directory, following the same pattern — **confirmed working**: `apt install` (411 packages, ~250MB) and `pip install "mpf~=0.57.0" "mpf-mc~=0.57.0"` both completed cleanly with no mount errors, resolving to `mpf==0.57.5` and `mpf-mc==0.57.1`. Total build time ~10 minutes on Docker Desktop for Mac (Apple Silicon, native arm64, no QEMU emulation).

Real examples from `rpi-tutorials` confirm this is the standard way to install anything nontrivial:
- `rpi-lamp-stack`: `chroot $1 php composer-setup.php ...`, `chroot $1 runuser -u www-data -- bash -c "composer install ..."`
- `rpi-tradingstrategy-ai-part-2`: `chroot $1 runuser -u $IGconf_device_user1 -- bash -c "pipx install poetry"` (and similarly for `pip`/`npm` — run as the non-root device user via `runuser` when the installed tool expects a normal user's `$HOME`)
- `rpi-web-kiosk`: `chroot $1 runuser -u $IGconf_device_user1 -- bash -c "npm install --prefix ..."`

We install as root and `chown` the result to `$IGconf_device_user1` afterward instead of using `runuser` throughout, since a venv doesn't care who created it — just who can write to it later.

## The declarative alternative (not used here, but exists)

For plain apt package lists (no custom logic needed), rpi-image-gen supports a declarative path that skips hook scripts entirely:
- A `packages:` list in a config/options file becomes `IGconf_packages_N` variables, consumed automatically by the built-in `scripts/bdebstrap/customize20-packages` hook.
- A custom layer YAML can declare `mmdebstrap: packages: [...]` directly (e.g. upstream's `layer/rpi/misc-utils.yaml`).
- `rpi-tutorials`' `meta/*.yaml` files use this for third-party APT repos too — e.g. `meta/php.yaml` adds the sury.org PHP PPA via `mmdebstrap.setup-hooks` before listing PHP packages.

We didn't use this because MPF needs a venv + pip install + chown, not just apt packages — a `customizeNN-*` script is the right tool once you need actual shell logic, not just a package list.

## Layers, device/image/profile — how they relate

- **Layers** are the composable unit: YAML files with `X-Env-Layer-*` metadata, either `mmdebstrap:`-native (packages/customize-hooks consumed directly by mmdebstrap) or plain shell hooks. `device/pi5/device.yaml` upstream is itself a layer (category `device`), not a hooks container.
- **`<layer>.rootfs-overlay/`** — a directory named after a layer file, sitting next to it, gets copied into the rootfs automatically during `customize`, before that layer's own hooks run. Useful for shipping static files without writing a hook script at all.
- `examples/custom_layers/` in the upstream repo is the canonical worked example of authoring your own layer + config + traits from scratch (`rpi-image-gen build -S ./examples/custom_layers/ -c acme-integration.yaml`) — worth reading if this project ever needs a real custom layer instead of a `customizeNN-*` script bolted onto the `mbr/simple_dual` layout.

## Container/mount requirements

From upstream's `README.adoc`, quoted directly:

> The build invokes `mmdebstrap` to create a chroot and mount pseudo-filesystems (proc, sysfs, devpts) inside a private mount namespace, which requires `CAP_SYS_ADMIN` or equivalent (eg, `--privileged` or `--security-opt=unconfined` depending on rootless/container setup). The build will fail without that capability. [...] For a supported path, run on native Debian Bookworm/Trixie arm64.

Docker Desktop on Mac (what we build on) isn't an officially supported path — it works because `docker-compose.yml` sets `privileged: true`, but isn't guaranteed by upstream. In practice: `/dev` and `/proc` bind-mounts succeed in our container even when a *fresh* `mount -t proc`/`mount -t sysfs` doesn't (we saw bdebstrap itself fall back from a failed plain mount to a working bind-mount for `/proc` during the base build; `/sys` never got a working fallback, but nothing we've needed so far requires it).

## rpi-tutorials survey (for future reference)

`jonnymacs/rpi-tutorials` is just an index README pointing at separate repos — no content of its own. Repos and what they demonstrate:
- `rpi-boiler-plate` — minimal starter + `gpt/ab_userdata` (A/B failover) layout variant, as an alternative to `mbr/simple_dual`.
- `rpi-image-gen-example` — the macmind project this repo was forked from.
- `rpi-rails-mariadb-docker`, `rpi-lamp-stack` — web apps installed via chroot+customize hooks (Rails/Docker Compose+nginx+certbot+ddclient; Apache/PHP/MariaDB+Omeka via the sury.org PHP PPA meta layer).
- `rpi-web-kiosk`, `rpi-with-splash-screen` — Chromium kiosk / Plymouth splash screen tutorials, both ship dual `device/pi4` and `device/pi5` trees (useful precedent for our pi5-only setup).
- `rpi-auto-resize-root` — root partition auto-expand service only.
- `rpi-ble-server` — Rust BLE GATT server, `class=pi5` only, I2C RTC (`dtoverlay=i2c-rtc,ds3231` in `config.txt` + `i2c-dev`/`i2c-bcm2835` in `/etc/modules` via `post-build.sh`) — our closest hardware-integration precedent, though P-ROC is USB/FTDI-based so we don't need any of its I2C/dtoverlay config.
- `rpi-tradingstrategy-ai-part-2` — Jupyter/Poetry app via `pipx`, installed entirely inside a `customize-*` chroot hook as the non-root device user.

None of them use SPI or USB/FTDI peripherals, so there's no existing precedent in these repos for P-ROC-style hardware — our `libftdi1-2`/`libftdi1-dev` package choice is based on the missionpinball community discussion, not an rpi-tutorials example.

## Resolved: MPF install, confirmed working

The `customize10-mpf` hook succeeded on the first try after moving it out of `post-build.sh`. Notes for next time:
- **pip resolved `mpf-0.57.5` and `mpf-mc-0.57.1`** from the `~=0.57.0` range pins — both within the 0.57 line as intended.
- **piwheels (`https://www.piwheels.org/simple`) is used automatically** alongside PyPI inside the chroot's pip config (this comes from Raspberry Pi OS's default pip config, inherited into the rootfs) — this is why `Pillow` installed as a prebuilt arm64 wheel instantly instead of compiling from source. `psutil`, `mpf-mc`, and `ffpyplayer` still built from source (each took well under a minute), confirming the `-dev` headers we installed (GStreamer/SDL2/ffmpeg) were the right/sufficient set — no missing-header build failures.
- `mpf-mc` still depends on **Kivy 2.2.1** under the hood (despite mpf-mc having moved to GStreamer/SDL2 for actual media rendering) — Kivy itself has a prebuilt arm64 wheel on PyPI, so this added no build time.
- No `runuser`/non-root complications: installing as root inside the chroot and `chown`-ing `/opt/mpf` to `$IGconf_device_user1` afterward worked with zero issues.
- Full build time end-to-end (`./build.sh`, base rootfs + `customize10-mpf` + image packaging) was **~10 minutes** on Docker Desktop for Mac, Apple Silicon (native arm64 — no QEMU emulation tax, unlike the amd64 path mentioned in `CLAUDE.local.md`).

## `ssh_user1=y` does NOT work on the apt-min64 profile

`device/build.defaults` documents `ssh_user1` as: "If y, automatically include net-misc/openssh-server in the profile to enable SSH access." We set `ssh_user1=y` in `pinball.options` from the start, assumed it worked, and shipped a build claiming "SSH enabled" — it doesn't.

**Verified by mounting the built image directly** (no need to flash/boot a Pi to check this — much faster feedback loop):
```sh
fdisk -lu pinball-*.img   # find the ext4 (root) partition's start sector, multiply by 512 for byte offset
mount -o loop,ro,offset=<bytes> pinball-*.img /mnt/root
grep "^Package: openssh-server" /mnt/root/var/lib/dpkg/status   # nothing — not installed
ls /mnt/root/etc/ssh/                                            # doesn't exist
```
(Needs a Linux mount, so run it inside a throwaway `docker run --privileged -v <deploy-dir>:/data:ro debian:bookworm bash` — same privileged-container mechanism the build itself uses, not the host Mac directly.)

The `ssh_user1` flag is presumably consumed by some OTHER profile's layer (or a newer rpi-image-gen version) that conditionally adds `openssh-server` based on it — `apt-min64` doesn't wire it up. Fixed properly via `bdebstrap/customize08-ssh`, following the same working pattern as `customize05-pkgs`/`customize10-mpf`: `chroot $1 apt install -y openssh-server && chroot $1 systemctl enable ssh`. Left `ssh_user1=y` in `pinball.options` anyway (harmless, may matter on a different profile) but the comment there now points at the real mechanism.

**Caveat for later**: baking `openssh-server` in at image-build time means its host keys are generated once, at build time, and are then identical across every device flashed from the same `.img` — fine for a single hobby machine, but if this image is ever flashed onto multiple pinball cabinets, add a first-boot service that deletes and regenerates `/etc/ssh/ssh_host_*` keys (the standard fix Raspberry Pi OS itself uses) rather than shipping shared keys.

## WiFi: baked in via `customize09-wifi`, no NetworkManager/raspi-config here

This image uses `systemd-networkd` (from the `sys-apps/systemd-net-min` layer), not NetworkManager — `raspi-config`'s usual wifi wizard doesn't apply. Also, `apt-min64` ships neither `wpasupplicant` nor `firmware-brcm80211` (the Pi 5's Broadcom wifi chip firmware), so wifi doesn't work out of the box at all, same story as SSH above.

`customize09-wifi` installs both packages, writes `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` (SSID/PSK) and a `systemd-networkd` `.network` unit for `wlan0` (`DHCP=yes`, mirroring the existing `01-eth0.network` pattern from the `netgen eth0` built-in hook), then enables `wpa_supplicant@wlan0.service`.

**Credentials never touch git**: real SSID/PSK live in `pinball/wifi-credentials.env` (gitignored), sourced by the hook via its known absolute path inside the build container (`/home/imagegen/pinball/wifi-credentials.env` — matches `docker-compose.yml`'s bind mount + `RPI_BUILD_USER`/`RPI_CUSTOMIZATIONS_DIR` in `build.sh`). Anyone rebuilding this repo fresh needs to create that file themselves (see README).

No `country=` set in the wpa_supplicant config — wifi still works without it (falls back to the world regulatory domain), just without your country's extended channel set. Add `country=<ISO 3166-1 alpha-2>` inside the hook if you hit connectivity issues.

## `mpf` crashed on every invocation — pkg_resources bug, not our packaging

Discovered by chrooting into the built image and running the venv's `mpf` binary directly (mounting `/dev`+`/proc` first, same as the customize hooks need) — this is a much faster way to sanity-check "does the installed software actually run" than flashing/booting real hardware:
```sh
mount -o loop,offset=<root-partition-bytes> pinball-*.img /mnt/root
mount --bind /dev /mnt/root/dev; mount --bind /proc /mnt/root/proc
chroot /mnt/root /opt/mpf/venv/bin/mpf --help
```
This crashed immediately with `pkg_resources.DistributionNotFound: The 'ruamel.yaml.clib>=0.2.7' distribution was not found`, thrown from `mpf`'s own CLI loader (`mpf/commands/__init__.py`'s `get_external_commands()`, which uses the legacy `pkg_resources` API to load `mpf.command` entry points contributed by `mpf-mc`).

**Root cause, reproduced independently** on a clean `python:3.11-bookworm` container (nothing to do with our chroot/piwheels/arm64 setup — this is a real upstream bug hit by `mpf~=0.57.0` + `setuptools~=72.2.0`, the exact setuptools version `mpf` itself pins):
```sh
pip install "setuptools~=72.2.0" "ruamel.yaml==0.18.6"
python3 -c "import pkg_resources; pkg_resources.require('ruamel.yaml.clib>=0.2.7')"
# -> pkg_resources.DistributionNotFound, even though pip installed it and `pip check` is clean
```
`ruamel.yaml.clib`'s wheel installs a dist-info directory named `ruamel_yaml_clib-0.2.15.dist-info` (dots normalized to underscores, standard modern packaging practice for a project name containing literal dots). The legacy `pkg_resources.working_set` scanner in `setuptools` 72.2.0 fails to match the requirement string `ruamel.yaml.clib>=0.2.7` against that underscore-normalized directory name — a known class of `pkg_resources`/dotted-project-name bug, unrelated to piwheels, arm64, or anything in this repo.

**Verified fix**: duplicate that dist-info directory under its dotted name (`ruamel.yaml.clib-0.2.15.dist-info`) right after installing MPF — purely additive, doesn't touch any actual installed files, and confirmed (via the same clean-container repro, then against a copy of this image's actual venv) to make `pkg_resources.require(...)` resolve correctly and `mpf --help` run without error. Implemented in `customize10-mpf`.

**Confirmed on real hardware** after rebuilding and flashing: SSH, WiFi, and `mpf` (with this fix) all work on an actual Pi 5.

## Confirmed CLI usage (from reading `mpf/commands/__init__.py` and `mpf/commands/both.py` directly)

- `mpf [machine_path]` — defaults to the `game` command (core engine only, no display). `machine_path` is optional if the current directory has a `config/` subfolder (auto-detected as the machine folder).
- `mpf mc [machine_path]` — media controller only (`mpfmc.commands.mc`, contributed via mpf-mc's `mpf.command` entry point).
- `mpf both [machine_path]` — **the one to actually use for a full running machine**: spawns the media controller as a subprocess and runs the core engine in the main process, both from one command (`mpf/commands/both.py`).
- No first-boot systemd service exists yet (deliberate — see earlier "Manual for now" decision) — start manually over SSH: `cd ~/machine && mpf both`, or `mpf both ~/machine` from anywhere.
- `/opt/mpf/venv/bin` is added to `$PATH` via `/etc/profile.d/mpf-path.sh` (written by `customize10-mpf`, same mechanism the base image already uses for its own `/etc/profile.d/01local.sh`) — works for both the autologin console session and interactive SSH logins, since both are login shells that source `/etc/profile.d/*.sh`. Not yet rebuilt/verified since adding this.

## Root filesystem has zero free space by default — `apt install`/`git clone` fail with "No space left on device"

`root_part_size=100%` (the layout's default, unchanged by us) means the root partition is built to *exactly* fit its contents at build time — no headroom at all, on every image, regardless of the SD card/USB drive's actual size. This isn't a permissions/read-only issue (the filesystem genuinely does mount `rw`) — it's a real disk-full condition, reproduced ourselves earlier while debugging (`cp: cannot create directory ...: No space left on device` when trying to write into the mounted image directly).

**Fix, adapted from `jonnymacs/rpi-auto-resize-root`** (a working `rpi-tutorials` example whose entire purpose is exactly this problem) — full first-boot auto-expand, implemented in a single hook, `customize06-resize-root`:
- Delegates the partition-table resize to **`raspi-config --expand-rootfs`** (installed via `apt install raspi-config fdisk`) rather than hand-rolling `parted`/`growpart` logic. `raspi-config`'s own implementation (`RPi-Distro/raspi-config`, `do_expand_rootfs()`) does device detection fully dynamically via `findmnt / -o source -n` + `lsblk -no pkname` — no hardcoded `/dev/mmcblk0p2`/`/dev/sda2` assumptions, so it works whether the image ends up on an SD card, USB drive, or NVMe.
- Two-stage because a mounted partition can't be resized live: `fdisk` deletes+recreates the root partition at its original start sector with no explicit end (fills the disk) on **boot 1**, then **immediately hard-reboots via `echo b > /proc/sysrq-trigger`** (not `systemctl reboot`) so the kernel re-reads the new partition table right away instead of waiting for a manual reboot. On **boot 2** onward, our own trigger script runs `resize2fs` directly on the root device — a safe no-op once the filesystem already fills the partition, so it's fine to leave the systemd service enabled forever rather than disabling it after success.
- **This means first boot after flashing reboots itself once automatically** — expected behavior, not a crash, if you're watching the console/SSH connection drop and come back.
- `dosfstools`/`e2fsprogs` (needed for `resize2fs`) were already installed via `customize05-pkgs`, inherited unchanged from macmind — only `raspi-config`/`fdisk` needed adding. `fdisk` isn't guaranteed present on a minimal profile (Debian split it out of `util-linux-core` into its own package), hence installing it explicitly rather than assuming it's already there.

**Confirmed on real hardware, with a real bug found and fixed along the way.** The partition-table resize worked correctly (`fdisk -l` after the fact showed the root partition correctly grown from 1.7G to 14.5G) — but the original design (mirroring `jonnymacs/rpi-auto-resize-root` exactly) relied on `raspi-config`'s own self-registered `/etc/init.d/resize2fs_once` script to grow the filesystem on the second boot, and that file came out **empty (0 bytes)** on the actual device — it never ran, the automatic reboot never fired (confirmed via `journalctl -u expand-rootfs` showing the service cleanly "Finished" with no gap for a reboot), and the filesystem stayed at its original size until manually run.

Root cause not fully pinned down: reproducing the *exact* heredoc-write from `do_expand_rootfs()` in isolation (same `/bin/sh` = dash, same no-TTY stdin-from-`/dev/null` context matching a systemd service) wrote the file correctly every time — so whatever actually broke it is specific to the real invocation context (live-mounted root, run via `raspi-config --expand-rootfs`'s full call graph, possibly the trailing `whiptail --msgbox` call inside `do_expand_rootfs()` failing since `INTERACTIVE=True` is hardcoded at the top of `raspi-config` with no TTY-detection override — this is also probably *why* the reboot never fired in the original design, since `raspi-config --expand-rootfs`'s own exit code is unreliable here and our very first version had no `set -e`, so that wasn't the direct cause of the missing reboot, but it's suggestive of the same underlying "no TTY" class of problem).

**Fix**: stopped depending on `raspi-config`'s internal resize2fs_once scheduling entirely. Our own trigger script now calls `resize2fs "$(findmnt / -o source -n)"` directly once a `/boot/firstboot_resized` sentinel shows the partition step already ran — a single well-tested, well-understood command, no dependency on `raspi-config`'s internal state machine. Manually verified as the correct fix on the affected device (`sudo resize2fs /dev/mmcblk0p2` after a manual reboot grew the filesystem to 14.5G immediately) before folding it into the hook.

**Also worth noting for future edits to `expand-rootfs.sh`**: it deliberately has no `set -e`. `raspi-config`'s own comment in `do_expand_rootfs()` says fdisk's exit code will likely be non-zero on a mounted root partition, and the trailing whiptail call has no TTY to render into — both look like failures but aren't fatal ones; the script needs `touch`/`sync`/reboot to run regardless of `raspi-config`'s own exit status.

## DNS resolution is broken by default — `ping github.com` fails, `ping 8.8.8.8` works

`/etc/resolv.conf` in the built rootfs is a **leftover from the Docker build container itself**: debootstrap copies the build host's `/etc/resolv.conf` into the target rootfs so `apt` can resolve `deb.debian.org`/`archive.raspberrypi.com` *during the build* — nobody ever swaps it out for something that makes sense on the actual device. Confirmed by inspecting the built image directly (`cat /mnt/root/etc/resolv.conf`): it's a Docker-generated file pointing at `nameserver 127.0.0.11` (Docker's internal per-container DNS proxy), which obviously doesn't exist once flashed onto a Pi. Symptom is exactly "Temporary failure in name resolution" — DNS-specific, not a general connectivity problem, since the network itself (IP/routing over eth0/wlan0) works fine.

Root cause has two parts, both present in the `apt-min64` profile:
1. The stale build-time `resolv.conf` never gets replaced.
2. **`systemd-resolved` isn't installed** — and it's specifically `systemd-resolved`'s job to take the DNS servers `systemd-networkd`'s DHCP client learns and turn them into a working `/etc/resolv.conf`. `systemd-networkd` alone has no mechanism to write `/etc/resolv.conf` itself; that hand-off is by design delegated to resolved. Both `01-eth0.network` (built-in) and our own `02-wlan0.network` already have `DHCP=yes` (which implies `UseDNS=yes` by default) — they were fine all along, just with nothing downstream to consume the DNS info they were already receiving.

**Fix, `customize95-dns`**: `apt install systemd-resolved`, enable it, then force-replace `/etc/resolv.conf` with the standard `/run/systemd/resolve/stub-resolv.conf` symlink ourselves (rather than trust `systemd-resolved`'s postinst to handle an already-present, foreign, Docker-injected file correctly).

**Critical ordering constraint — this hook MUST run last** (hence the `95` prefix, highest of all our `customizeNN-*` hooks). The symlink it creates only resolves to a real file once `systemd-resolved` is actually *running*, which it isn't during the build (a chroot has no init system). Any `apt install` inside the chroot *after* this hook runs would itself fail to resolve `deb.debian.org` and break the build — this would have been a nasty one to debug blind, since it only would have surfaced as a mysterious apt failure in whichever hook happened to run after it, with no obvious connection to DNS.

---

## v2.8.0 migration (`adopt_2.8.0` branch)

Migrated from the pre-v1.0 commit above to the current `v2.8.0` tag. This is a **complete rewrite**, not a version bump — confirmed by fetching every release's notes (v1.0.0 through v2.8.0) and diffing the actual repo tree between our old pinned commit and v2.8.0. The rewrite landed between `v1.0.0` and `v2.0.0-rc.1` (days apart); everything from v2.1 onward is incremental refinement on the new architecture.

### What changed structurally
- CLI: `./build.sh -D <dir> -c <config>.cfg -o <options>.options` → `./rpi-image-gen build -S <srcroot> -c <config>.yaml`.
- Config format: `.cfg`+`.options` (INI) → a single YAML file. INI support is fully gone as of v2.8.0 — this was a schema rewrite, not a find/replace.
- "Profiles" removed entirely. `apt-min64` no longer exists by that name — its functional equivalent is the `bookworm-minbase` layer (`layer/suite/debian/bookworm-minbase.yaml`), referenced directly by name in the config's `layer:` section.
- `image/mbr/simple_dual/` keeps its path and its `bdebstrap/customizeNN-*` hook convention (still discovered the same way), but `config.options` → `image.yaml`.
- Custom logic now belongs in **custom layer YAML files** (`pinball/layer/*.yaml`, discovered via `-S`), not a wholesale copy of the built-in image directory. `mmdebstrap: customize-hooks:` is an inline list of shell snippets right in the layer file — no separate hook script files needed. See `examples/custom_layers/` in the upstream repo for the reference pattern this project's `pinball-mpf`/`pinball-resize-root` layers are based on.
- **Layer labels become shell variable names** (`IGconf_layer_<label>`) — hyphens in a label (e.g. `wifi-reg:`) produce an invalid variable name and fail immediately. Use underscores (`wifi_reg:`).

### What got simpler (old custom hooks → new mechanism)
- `customize08-ssh` → **gone entirely**. `bookworm-minbase` requires `openssh-server` unconditionally — SSH is just always there. The `openssh-server` layer also now generates host SSH keys at boot (not build) time, fixing the "shared host keys across clones" risk we'd flagged as a known caveat under the old system.
- `customize09-wifi` (hand-rolled `wpa_supplicant`+`systemd-networkd` config) → the built-in `iwd` layer + an `iwd.network(5)` profile file (`pinball/wifi/<SSID>.psk`, gitignored, containing `[Security]\nPassphrase=...`), referenced via `iwd.profile` in the config. WiFi firmware (`firmware-brcm80211`) and `wlan0`'s DHCP config are *also* now automatic, provided by `rpi-device-base` — nothing to configure at all beyond the profile file.
- `customize95-dns` → **untested whether still needed** (kept anyway, low cost) — `bookworm-minbase` transitively requires `systemd-net-min` → `systemd-resolved`, so DNS resolution should now come for free. Confirmed via the build log that `systemd-resolved` gets enabled and its stub-resolv.conf seeded automatically.
- `customize90-dev-tools` (git/htop/vim) → the new top-level `packages:` config section. No layer file needed at all for a plain package list.
- `customize06-resize-root` → **ported essentially unchanged**, now as a custom layer (`pinball-resize-root.yaml`) instead of a bdebstrap hook file. No upstream replacement exists for the plain flash-and-boot workflow (`expand-to-fit` only applies through the full fastboot/IDP/`rpi-sb-provisioner` pipeline, which this project doesn't use).
- `customize10-mpf` → ported essentially unchanged as `pinball-mpf.yaml`, same install logic (venv, pip, the `ruamel.yaml.clib` pkg_resources fix, `/etc/profile.d/mpf-path.sh`).

### New required settings for parity
- **Password complexity is now enforced** (`device-user-credentials` layer): 8+ chars, upper+lower+digit+special-char, via regex. A weak password fails validation at the `parameter_assembly` stage, before any building starts.
- **Passwordless sudo is no longer the default** — set `device.user1sudo: nopasswd` explicitly to match the old image's behavior.
- **Timezone is a single IANA string now** (`locale.timezone: America/Chicago`), not split area/city debconf values — simpler than before. Requires explicitly including the `locale-base`+`locale-gen` layers (not pulled in by `bookworm-minbase`).

### Real bug hit during migration: 16K page size breaks ext4 image generation on Pi 5

`rpi5`'s device layer requires the `rpi-linux-2712` kernel, which has a 16K page size (`IGconf_linux_page_size=16384`). `image-rpios` has a trigger that sets the ext4 mkfs block size to match the kernel's page size — but the installed `e2fsprogs` (1.47.0) can't actually create an ext4 filesystem with 16384-byte blocks:
```
Warning: 16384-byte blocks too big for system (max 4096), forced to continue
mke2fs: Could not allocate block in ext2 filesystem while populating file system
```
This happens at the very end of the build, in `generate_images` — after the entire rootfs (including all custom layers) has already built successfully, so it's an expensive failure to hit blind. Upstream's own v2.3.0 release notes actually flag this exact scenario in a migration note: *"On 16K page kernels, add `IGconf_fs_ext4_mkfs_args: -b 4096` for identical partition sizing."* Fixed in `pinball.yaml`:
```yaml
fs:
  ext4_mkfs_args: "-F -b 4096"
```

### Verification status

**Full build succeeded end-to-end** (rootfs + image assembly, ~20 minutes) after the `ext4_mkfs_args` fix. Chroot-inspected the result (same technique used throughout this project — mount the root partition read-only, bind-mount `/dev`+`/proc`, execute binaries directly) and confirmed full parity with the old pinned-commit image:

- SSH: `openssh-server` installed, `ssh.service` **and** `ssh-hostkeys-generate.service` enabled (host keys generate at boot, not build time — an improvement over the old system's shared-host-key risk).
- WiFi: `pinball/wifi/Space.psk` correctly installed to `/var/lib/iwd/Space.psk` with the right content, `iwd.service` enabled.
- **DNS confirmed fixed automatically** — `/etc/resolv.conf` is correctly symlinked to `../run/systemd/resolve/stub-resolv.conf`, with no custom hook of ours involved at all (we didn't port `customize95-dns` to this branch — `bookworm-minbase`'s transitive `systemd-resolved` dependency handles it entirely on its own). Note: `systemctl enable systemd-resolved` produces no discoverable symlink under `/etc/systemd/system/` (it's a static/preset-enabled unit on Debian) — don't go looking for one as a health check, check the `resolv.conf` symlink target instead.
- `expand-rootfs.service` present and enabled, script content correct.
- `git`/`htop`/`vim` all installed and on `$PATH`.
- Timezone: `America/Chicago`.
- `mpf --help` runs cleanly — the `ruamel.yaml.clib` fix carried over correctly into the new layer.
- `pinball` user's groups include `sudo`, `dialout`, `plugdev`, `spi`, `i2c`, `gpio` (P-ROC/hardware access) — via `device-user-credentials`'s sensible default `user1groups`, nothing we had to configure.

**Not yet done**: flashing/booting on real hardware. Everything above is chroot-verifiable; the two-reboot resize-root behavior specifically (like on the old system) can only be fully proven on real hardware.
