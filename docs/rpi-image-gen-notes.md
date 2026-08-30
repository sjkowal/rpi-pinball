# rpi-image-gen notes

Working notes on how [raspberrypi/rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen) actually behaves, gathered from its own docs/source and from [jonnymacs/rpi-tutorials](https://github.com/jonnymacs/rpi-tutorials)'s example repos. None of this is derivable just from reading this repo's customization tree — it comes from the upstream framework's internals. Written down so we don't have to re-derive it.

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
