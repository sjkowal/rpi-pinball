# rpi-pinball

Build a Raspberry Pi image with [Mission Pinball Framework](https://missionpinball.org) and P-ROC/P3-ROC hardware support installed, ready to run pinball game code. Two MPF release lines are supported, each with its own media controller:

| MPF line | Media controller | What's installed for it |
|---|---|---|
| **0.57** | `mpf-mc` (Kivy/SDL2) | `mpf` + `mpf-mc` |
| **0.80** | [Godot Media Controller (GMC)](https://missionpinball.org/latest/gmc/) | `mpf`, Godot 4.7.2 as `godot`, and the `cage` Wayland kiosk compositor |

Supports the **Raspberry Pi 4** and **Raspberry Pi 5**. One build targets one board and one MPF line; each release carries all four combinations. (A Pi 3 would work the same way but is not supported yet — see *Adding a Pi model* below.)

Forked from [rpi-image-gen-example](https://github.com/jonnymacs/rpi-image-gen-example), which wraps Raspberry Pi Foundation's [rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen).

## Install a released image (Raspberry Pi Imager)

Released images are published as GitHub Releases and listed in an Imager repository served from GitHub Pages:

```bash
rpi-imager --repo https://sjkowal.github.io/rpi-pinball/os_list.json
```

Or in the app: **App Options → Content Repository → EDIT**, paste that URL, **APPLY & RESTART**. Then choose your board (**Raspberry Pi 4** or **Raspberry Pi 5**) and pick a **PinbOS vX.Y.Z · MPF 0.80 · Godot MC** or **PinbOS vX.Y.Z · MPF 0.57 · mpf-mc** entry (not "Use custom") — that is what makes the OS Customisation step (hostname, user/password, WiFi, SSH) appear. The list is filtered by the board you chose, so only images built for it are offered, one per MPF line. Imager forgets a custom repository on restart, so re-select it each session. Newest release is listed first, with the newer MPF line first within a release.

Assets are named `pinbos-mpf<NN>-rpi<N>-<tag>`, so a downloaded file says which MPF release line and which board it is for — e.g. `pinbos-mpf57-rpi5-v0.4.0.img.xz` is MPF 0.57 on a Pi 5, `pinbos-mpf80-rpi4-v0.4.0.img.xz` is MPF 0.80 on a Pi 4. Each release carries, **per board and MPF line**, the `.img.xz` (the image, xz-compressed), a `.sha256` for it, and a `.manifest.json`, which is a complete single-image Imager repository (the hosted `os_list.json` is merged from all of them). So any one image, prereleases included, can be used on its own without Pages:

```bash
rpi-imager --repo https://github.com/sjkowal/rpi-pinball/releases/download/v0.4.0/pinbos-mpf80-rpi5-v0.4.0.manifest.json
```

You can also download the `.img.xz` directly and use Imager's "Use custom", but then the Customisation step is skipped.

## Build locally

```bash
./build.sh              # Pi 5, MPF 0.57 (the defaults)
./build.sh pi4          # Pi 4, MPF 0.57
./build.sh pi5 0.80     # Pi 5, MPF 0.80 + Godot MC
```

One run builds one board with one MPF line. The output image lands in `pinball/deploy/` (uncompressed, gitignored), named the same way as a release asset but with the version from `git describe`:

```
pinball/deploy/pinbos-mpf80-rpi5-v0.4.0-3-gabc1234.img
```

To flash it with Imager *and* get the Customisation step, generate a local manifest and point Imager at it:

```bash
./imager-repo.sh            # newest build of every board × MPF line present in pinball/deploy/
./imager-repo.sh pi4        # newest Pi 4 build of each MPF line
./imager-repo.sh pi4 0.80   # just the newest Pi 4 MPF 0.80 build
```

Knobs:

- `PI_MODEL=pi4 MPF_VERSION=0.80 ./build.sh` — same as passing the model and MPF line as arguments.
- `RPI_IMAGE_OUT_DIR` / `RPI_IMAGE_OUT_NAME` — override the output location and filename outright (CI uses these).
- `scripts/image-name.sh <model> [version]` (with `MPF_VERSION=` for the line) prints the basename a build would use, without building anything. It refuses a line that isn't supported, or whose config's `mpf.version` disagrees with it.
- The Godot version for the 0.80 line is `X-Env-Var-godot_version` in `pinball/layer/pinball-gmc.yaml` (`scripts/image-name.sh --godot-version` prints it).

### How the MPF lines are configured

`pinball/pinball.yaml` is the **shared base**: the OS, partition layout, read-only root, networking, P-ROC and MPF core. It isn't built directly. Each MPF line has a small config that `include:`s it and adds only what differs: `pinball/pinball-mpf57.yaml` and `pinball/pinball-mpf80.yaml` each set `mpf.version` (**the single source of truth** for that line's MPF version) and the media-controller layer (`layer.mc`: `pinball-mpf-mc` or `pinball-gmc`). `build.sh` picks the config with `scripts/image-name.sh --config`, which also checks that the file's `mpf.version` matches the line in the filename.

### Adding an MPF line

Four edits: a new `pinball/pinball-mpf<NN>.yaml` (copy an existing one; set `mpf.version`, quoted, and `layer.mc`), `MPF_LINES` in `scripts/image-name.sh`, the `MPF_LINES` table in `imager/gen-os-list.py` (the media-controller name Imager shows, and whether the line ships Godot), and the `mpf` list in the CI matrix in `.github/workflows/build-image.yml`.

### Adding a Pi model

Two edits: `MODELS` in `scripts/image-name.sh`, and the `MODELS` table in `imager/gen-os-list.py` (which also needs the human name Imager shows). The model maps to upstream's device layer by name — `pi4` → `rpi4` — and `build.sh` passes it as `IGconf_device_layer`, so nothing in `pinball/pinball.yaml` changes. Add the model to the CI matrix in `.github/workflows/build-image.yml` to have releases include it (for every MPF line).

## Releases (CI)

`.github/workflows/build-image.yml` builds on GitHub-hosted `ubuntu-24.04-arm` runners using the same `Dockerfile` and `build.sh` as a local build, compresses with `xz -T0`, hashes, and publishes. It runs as four jobs: `prepare` (resolve the version, run the release guard once), `build` (a matrix leg per board × MPF line — four, in parallel, each on its own runner), `release` (collect every leg's assets and publish the GitHub Release exactly once — publishing from inside the matrix would have the legs racing on `generate_release_notes`), and `publish` (regenerate the Imager repo).

- **Release**: `git tag v1.0.0 && git push origin v1.0.0`. Creates a GitHub Release with the assets above, then regenerates and deploys the Imager repository.
- **Prerelease**: a tag containing `-` (e.g. `v1.0.0-rc1`) builds and publishes a release marked *prerelease*, but is **not** listed in the Imager repository.
- **Test build**: Actions tab → *Build image* → *Run workflow*. Produces a 1-day artifact per board, no release.
- `.github/workflows/publish-imager-repo.yml` regenerates `os_list.json` from every published non-prerelease release (via each release's `manifest.json`) and deploys to Pages. It also runs when a release is edited or deleted in the GitHub UI, and can be run manually.
- The entry shape, the per-board `devices` tag and the required top-level `imager.devices` block live in one place, `imager/gen-os-list.py`, shared by CI and `imager-repo.sh`. That block always lists every supported board, even ones a given `os_list` has no image for: a board missing from it makes Imager silently hide its entries, while a board with no entries is harmless.

**Release guard**: the `pinball-debug-shell` layer (`systemd.debug-shell=1`, an unauthenticated root shell on tty9, useful while debugging boot) is commented out in `pinball/pinball.yaml`. If it is ever re-enabled there or in a per-line `pinball/pinball-mpf*.yaml`, the workflow refuses to build a non-prerelease `v*` tag until it is commented out again; prerelease tags (`-rc1`) still build.

### One-time GitHub setup

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
2. **Settings → Environments → `github-pages` → Deployment branches and tags**: add a tag rule `v*`. The default policy only allows `main`, which blocks the tag-triggered deploy.
3. **Settings → Actions → General → Workflow permissions**: *Read and write* (the workflows also declare explicit `permissions:`).

Builds take roughly 30–60 minutes on the hosted arm64 runner; all four images build in parallel, so a release takes about as long as one image. Everything here is free on a public repository: standard hosted runner minutes are unmetered, release assets have no total storage or bandwidth cap (2 GiB per file), and Pages is free (soft limit 100 GB/month, only the JSON and icon are served from it).

## What's on the image

- MPF installed into a dedicated venv at `/opt/mpf/venv` (`pinball/layer/pinball-mpf.yaml`). The release line is pinned once per line, as `mpf.version` in `pinball/pinball-mpf<NN>.yaml` — the `pip install` hook and the `mpf<NN>` token in the image filename both come from it, so they cannot drift.
- **MPF 0.57 images**: `mpf-mc` in the same venv (`pinball/layer/pinball-mpf-mc.yaml`).
- **MPF 0.80 images**: the official Godot 4.7.2 `linux.arm64` build, checksum-verified at build time, at `/opt/godot/<version>/` and on `$PATH` as `godot` — exactly what `mpf both` looks for, so no `gmc.cfg` changes are needed. Plus `cage` (a single-app Wayland compositor), `seatd`, and Mesa's Vulkan/GLES drivers (`pinball/layer/pinball-gmc.yaml`). The GMC plugin itself is **not** on the image: it lives in your game project (`addons/mpf-gmc`), as the GMC docs describe.
- SSH enabled; WiFi via NetworkManager (`pinball-networkmanager`); hostname, user, password, WiFi credentials and SSH keys all come from Imager's OS Customisation (`init_format: rpi-preseed`; Imager applies most of it at flash time, anything deferred to boot is consumed by `pinball-readonly-root`'s first-boot script).
- Working DNS resolution.
- P-ROC/P3-ROC hardware support: `libpinproc` (built from the `dev` branch) installed system-wide, the `pinproc` Python extension (`pypinproc`) installed into the MPF venv, and udev rules so the boards are accessible without root.
- **Read-only OS.** `/` and `/boot/firmware` are mounted read-only so a power cut mid-game can't corrupt the OS. A third `DATA` partition (`/data`) holds everything that changes at runtime — `/home` (your MPF project folder, MPF data and logs) and `/var` (journal, NetworkManager state, apt/dpkg databases) are bind-mounted from it, `/tmp` is a tmpfs. On first boot `pinball-firstboot.service` grows `DATA` to fill your SD card/USB drive in place (no reboot), generates SSH host keys and commits the machine-id; `journalctl -u pinball-firstboot` shows what it did. Layout: `pinball/image/pinball-rpios/`, runtime: `pinball/layer/pinball-readonly-root.yaml`.
- **MPF at boot** (`mpf.service`, `pinball-mpf-service`): enabled, but it runs nothing until you switch it on for an MPF project folder. See *Starting MPF at boot* below.
- **Faster boot** (`pinball-boot-time`): no initramfs, no serial console, a quiet kernel, camera auto-detect off, and no apt timers. Plus `pinball-eeprom-tune` for this board's bootloader settings. See *Boot time* below.
- **Fallback IP on `eth0`** (`pinball-net-fallback`): if the cable has a link but DHCP doesn't answer within 20 s, `eth0` also gets `192.168.50.2/24`, so a laptop on a direct cable can reach the Pi. See *Direct-cable access* below.
- Boot splash (`rpi-splash-screen`, image from `pinball/assets/splash.tga`, currently a placeholder) and quiet boot (`pinball-quiet-boot`).
- Development conveniences — `git`, `htop`, `vim` (`packages:` in `pinball/pinball.yaml`) — **temporary**.

## What's *not* on the image (yet)

- No MPF project folder (your actual game config/code; MPF's own docs call it the "MPF project folder") is baked in. The image expects it at `~/mpf-project`. Add yours after first boot, e.g.:
  ```bash
  ssh <user>@<device-ip>
  git clone <your-mpf-project-repo> ~/mpf-project
  cd ~/mpf-project && mpf both
  ```
  `mpf both` runs the core engine and media controller together — that's what you want for a full running machine. `mpf` alone only runs the core (no display), `mpf mc` alone only runs the media controller. `machine_path` is optional if you're already `cd`'d into a folder with a `config/` subfolder in it. (`mpf`/`mpf-mc` are on `$PATH` via `/etc/profile.d/mpf-path.sh`.)

  **On an MPF 0.80 image**, use `gmc-run` instead:
  ```bash
  cd ~/mpf-project && git pull && gmc-run      # or: gmc-run ~/mpf-project
  ```
  It does two things:
  1. **Imports the Godot project's assets** with `godot --headless --import`. This step is **required**, not an optimisation. Running a project from source, which is what `mpf both` does, never imports assets; only the editor or `--import` does. Without it every image, sound and font fails to load (`No loader found for resource`), and new or changed assets fail again until the next import. It's skipped when nothing in the project changed since the last import, since it costs seconds at every boot. A timestamp file in `.godot/` tracks this, and MPF's own runtime files (`logs/`, `data/`, `*.bundle`, `.autostart`) don't count as changes. Files copied in with their old timestamps kept (`cp -p`, `rsync -t`) aren't noticed; run `GMC_FORCE_IMPORT=1 gmc-run` after those.
  2. **Starts `cage -- mpf both`.** Godot needs a display server, and cage provides a full-screen one. This works from the console and over SSH, because `seatd` gives cage the seat either way. **The mouse pointer is hidden.** cage itself only hides it when no pointing device is connected, so `gmc-run` points cage and Godot at an all-transparent cursor theme. To keep the pointer, run `GMC_SHOW_CURSOR=1 gmc-run`, or set `GMC_SHOW_CURSOR=1` in `/etc/default/pinball-mpf` for MPF at boot.

  `mpf both` starts `godot` against the `project.godot` in your MPF project folder, or wherever `gmc.cfg`'s `gmc_project_path` points; `gmc-run` imports that same folder. Arguments after the folder go to `mpf both` (`gmc-run ~/mpf-project -X`). `GMC_SKIP_IMPORT=1` skips the import, and `GMC_FORCE_IMPORT=1` forces it. To do it by hand: `godot --headless --import`, then `cage -- mpf both`.

  On a fresh checkout (no `.godot/` folder yet), the first import prints around 17 parse errors from GMC's own editor plugin, which tries to load its icons before they're imported; a second import is clean. `gmc-run` runs the first pass silently for that reason. `godot --import` exits 0 even when assets fail, so read its output rather than trusting the exit status. Don't copy `.godot/` from your desktop; let the Pi build its own.

  **You don't need to export your GMC project for the Pi.** It runs from source. See *Exported GMC builds (optional)* below for when exporting is worth it.

  **Use MSDF fonts.** Under the Vulkan renderer on a Pi 5, text in the default font setup comes out with chunks missing from each letter, even though images and the splash screens are fine and the same project looks right on a desktop. Switching fonts to Multichannel Signed Distance Field fixes it (confirmed on a Pi 5):
  - For Godot's default font: **Project Settings → GUI → Theme → Default Font Multichannel Signed Distance Field** (turn on *Advanced Settings* to see it).
  - For each `.ttf`/`.otf` in the project: select it, tick **Multichannel Signed Distance Field** in the **Import** dock, then **Reimport**.

  Then re-import on the Pi (`gmc-run` does it). MSDF text also stays sharp at any size, which suits a full-screen display.

  Edit your project with **Godot 4.7.x**, the version on the image. Prefer the *Mobile* or *Compatibility* renderer. Godot plays only OGG Theora video, decoded in software, which the Pi does poorly, so the GMC docs recommend a Pi for DMD-style games.

## Starting MPF at boot

Every image has `mpf.service` enabled, but it only starts MPF once you switch autostart on for the MPF project folder. A fresh flash, or a Pi you're developing on, is unaffected.

```bash
pinball-autostart on       # start MPF at every boot, and start it now
pinball-autostart off      # stop starting it at boot, and stop it now
pinball-autostart status
journalctl -u mpf -f       # follow MPF's output
```

- **The switch is a file:** `~/mpf-project/.autostart`. It's on the writable DATA partition, so neither maintenance mode nor a config edit is needed. `pinball-autostart` also starts or stops the service right away, using `sudo`. Creating or deleting the file by hand works too and takes effect at the next boot. If the MPF project folder is a git repo, add `.autostart` to its `.gitignore`, unless you *want* every Pi that clones the repo to autostart.
- **Coming from v0.5.0?** That release used `~/machine`. Move it with `mv ~/machine ~/mpf-project`, or set `MPF_PROJECT_DIR=/home/<user>/machine` in `/etc/default/pinball-mpf`. The autostart switch moves with the folder.
- **What it runs:** `mpf both` on MPF 0.57 images. On MPF 0.80 images it runs `gmc-run`, which imports the Godot assets and then starts `cage -- mpf both` full screen. It runs from `~/mpf-project`, as the login user (UID 1000, so an Imager-renamed user is fine), with `-t -P -A`:
  - `-t`: no text UI.
  - `-P`: production mode, which waits for hardware and exits if startup fails.
  - `-A`: no config cache files.
- **Production mode reads a config bundle, not your YAML.** With `-P`, MPF loads a prebuilt, pickled copy of your config: `mpf_config.bundle` in the MPF project folder, plus `mpf_mc_config.bundle` for mpf-mc on 0.57. The service builds it with `mpf build production_bundle` (`-b` on 0.80) when it's missing. **It isn't rebuilt when you change your config,** and a stale bundle silently runs the old config. After editing the MPF config, delete the bundles and restart:
  ```bash
  rm ~/mpf-project/*.bundle && sudo systemctl restart mpf
  ```
  Add `*.bundle` to the MPF project folder's `.gitignore`. If the build fails, for example from a config error, the service stops with the error in `journalctl -u mpf`; fix the config and run `pinball-autostart on`. Running MPF by hand without `-P` reads the YAML as usual.
- **Restarts:** if MPF exits or crashes, systemd restarts it after 5 s. If there's no MPF project folder or autostart is off, it stops without restarting.
- **Bench work:** `sudo systemctl stop mpf` before running MPF by hand, so two copies don't fight over the serial ports. It starts again at the next boot.
- **Settings:** `/etc/default/pinball-mpf` holds the MPF project folder path, the mode (`auto`, `both`, `game` or `gmc`), the MPF flags, devices to wait for, and the audio device for MPF-MC. It's on the read-only root, so edit it with `sudo pinball-rw` and then run `sudo systemctl restart mpf`.
- **MPF's data persists.** Its `logs/` and `data/` (audits, high scores, saved volume) are written in the MPF project folder, which is on DATA, so they survive reboots. MPF writes a new log file on every start, so a machine that keeps crashing and restarting will build up logs there.

## Exported GMC builds (optional)

*MPF 0.80 only.* An **exported build** is your Godot project packaged as a standalone app. In the Godot editor, choose **Project → Export → Linux**, architecture **arm64**. This uses Godot's arm64 export templates, a one-time download that must match the image's Godot version (4.7.2). The result is an executable plus a `.pck` file holding your scenes, scripts and assets, already imported.

### Why the image doesn't use exports

The image runs your project **from source**, and that's all you need:
- **There's no build step.** Godot runs scripts and scenes straight from the project folder. The only thing it needs first is the asset import, and `gmc-run` and the autostart service both do it on every start.
- **Updating is just `git pull`** on the Pi. With exports, every change means re-exporting on your desktop and copying the files over.
- **`mpf both` only launches projects from source.** It checks for a `project.godot` in the project folder, and an export doesn't have one. So `gmc-run`, and MPF at boot (`pinball-autostart`), work only with a project folder. They don't launch exported builds.
- **The image already ships the full Godot editor build**, which is what runs a project from source.

### Why you might export anyway

Exporting is worth it for a **finished machine**, once the project has stopped changing:
- **Faster startup.** There's no asset import at launch. The import takes a few seconds when nothing has changed, and longer after a fresh checkout or asset changes.
- **What you tested is exactly what runs.** The export is one fixed build, with no import step on the Pi that could differ from your desktop.
- **No project source on the machine.** Only the executable and `.pck` need to be there, so no `.godot/` cache or editor-only files.

### Running an exported build

`mpf both` can't launch it, so start the two halves yourself:
```bash
cage -- ~/game/yourgame.arm64      # SSH session 1: the exported GMC app, full screen
cd ~/mpf-project && mpf            # SSH session 2: MPF core only; it connects to GMC on port 5050
```
Start order doesn't matter: MPF keeps retrying until GMC is listening. The MSDF font advice above applies to exports too.

MPF at boot doesn't support exported builds yet. It would need the service to start the exported app plus `mpf game`, in place of `mpf both`. GMC can also start MPF itself (its `spawn_mpf` option), the reverse of `mpf both`.

## Direct-cable access (fallback IP)

`eth0` uses DHCP as normal. If the cable has a link but no DHCP lease arrives within 20 s, `pinball-net-fallback.service` adds `192.168.50.2/24` to `eth0`, and it removes it again as soon as a lease arrives. With no router, for example at a show:

1. Connect the laptop straight to the Pi's Ethernet port.
2. Give the laptop's Ethernet adapter the manual address `192.168.50.1`, mask `255.255.255.0`. On macOS that's System Settings → Network → (Ethernet adapter) → Details → TCP/IP.
3. Wait about 20 s after plugging in, then `ssh <user>@192.168.50.2`.

The address is added through a runtime systemd-networkd drop-in under `/run`, so it works on the read-only root and resets at every reboot. `journalctl -u pinball-net-fallback` shows when it switches. The address, interface and timeout are in `/etc/default/pinball-network`; edit with `sudo pinball-rw`, then `sudo systemctl restart pinball-net-fallback`. IPv4 link-local addressing (169.254.x.x) is also on for `eth0`. There's no mDNS/Avahi on the image, so `<hostname>.local` doesn't resolve.

## Boot time

The image is set up for a short power-on-to-game time. Most of this is in `pinball/layer/pinball-boot-time.yaml`:
- **No initramfs.** The kernel finds the root partition by PARTUUID itself, and has SD/eMMC, NVMe, USB storage and ext4 built in. `ro` on the kernel command line keeps the root read-only from the start. The exception is the boot splash: the `rpi-splash-screen` layer displays its image from the initramfs, so enabling it keeps the initramfs, automatically.
- **No serial console** (see below), and `quiet loglevel=3` on the kernel command line.
- **Smaller trims:** camera auto-detect is off, the firmware's rainbow splash is off, `multi-user.target` is the default, and the apt-daily timers are off (they can't work on the read-only root).
- **On MPF 0.80,** `gmc-run` skips the Godot asset import when nothing in the project changed.
- **Already minimal:** no swap, no Bluetooth, ModemManager, Avahi or cloud-init, and nothing at boot waits for the network.

Deliberately **not** done:
- **`fastboot`.** It skips the filesystem check on every partition, including DATA, which is what repairs DATA after a power cut.
- **`dtparam=audio=off` and `display_auto_detect=0`.** They would break the Pi 4's 3.5 mm audio and DSI screens. Set them in `/boot/firmware/config.txt` per machine if you don't need those. That file is on the read-only boot partition, so edit it with `sudo pinball-rw`.

**To measure boot time:**
```bash
systemd-analyze                                         # kernel + userspace (not the bootloader stage)
systemd-analyze blame | head -20
journalctl -b -u mpf -o short-monotonic | head -5       # when MPF started, in seconds since kernel start
```

### Bootloader (EEPROM) settings

These are stored on each board, not in the image, so they're never changed automatically. `pinball-eeprom-tune` shows this board's settings next to the recommended ones, and changes nothing. `pinball-eeprom-tune --apply` saves a backup to `~/eeprom-config.backup-*`, asks for confirmation, applies, and you then reboot. The recommendations:
- **`BOOT_ORDER`:** only the device this board booted from, then retry. That's `0xf1` for SD/eMMC, `0xf6` for NVMe, `0xf4` for USB. Each probe of an absent device costs time, but other boot devices are then no longer tried.
- **`NET_INSTALL_ENABLED=0`, `DISABLE_HDMI=1`, `BOOT_UART=0`,** and on Pi 5/CM5 **`WAIT_FOR_POWER_BUTTON=0`.**

`PSU_MAX_CURRENT=5000` is left alone. It skips the Pi 5's low-power warning, but only set it by hand, and only with a supply that really delivers 5 A, or USB devices can brown out. To undo: `sudo pinball-rw && sudo rpi-eeprom-config --apply ~/eeprom-config.backup-<date>`, then `sudo pinball-ro` and reboot.

### Serial console (removed)

The kernel no longer logs to the serial port, and the bootloader's second stage no longer logs over UART. To get them back for debugging:
```bash
sudo pinball-rw
sudo sed -i 's/console=tty1/console=serial0,115200 console=tty1/' /boot/firmware/cmdline.txt   # kernel console
sudo sed -i 's/^uart_2ndstage=0$/uart_2ndstage=1/' /boot/firmware/config.txt                     # bootloader logs (optional)
sudo pinball-ro
sudo reboot
```
`cmdline.txt` must stay a single line. On a Pi 4, `serial0` is the UART on GPIO 14/15, which the image already enables (`enable_uart=1`). On a Pi 5/CM5, `serial0` is the 3-pin debug UART connector; for GPIO 14/15, also add `enable_uart=1` to `config.txt`. Check Raspberry Pi's UART documentation for your board. A login prompt on the serial port needs `sudo systemctl enable serial-getty@serial0.service` as well. The bootloader's own UART logging is `BOOT_UART=1` in the EEPROM settings above.

## Maintenance mode (changing the OS)

Anything under `/home` or `/var` is always writable. To change the OS itself — `apt`, `pip install` into `/opt/mpf/venv`, adding a WiFi network with `nmcli`, editing `/boot/firmware/config.txt` or `cmdline.txt` — make the root and boot partitions writable first, then put them back:

```bash
sudo pinball-rw          # / and /boot/firmware read-write
sudo apt update && sudo apt upgrade
pip install <package>    # into /opt/mpf/venv
sudo pinball-ro          # back to read-only (or just reboot)
```

The root partition is a fixed 4 GB with ~2 GB free for this; it does not grow with the card.

## Before flashing

Nothing to edit. The image ships with a locked placeholder account and no baked-in WiFi (so a public image leaks nothing); set the username, password, WiFi and SSH keys in Imager's OS Customisation step, which only appears when the image is chosen from the Imager repository entry (hosted or local) rather than "Use custom".

## Status

**Confirmed working on real Pi 5 hardware**: SSH, WiFi, and `mpf` all verified directly on device. Imager OS Customisation via the `rpi-preseed` format is the current mechanism after several failed attempts with the `systemd` format — see `docs/rpi-image-gen-notes.md`.

**MPF 0.80 confirmed on real Pi 5 hardware**: the image works, and a GMC project exported from the Godot editor ran on the Pi with MPF connecting to it and driving it. Running a project from source needs its assets imported first (see `gmc-run` above). Not yet confirmed on hardware: `gmc-run` itself, audio, and the Pi 4.

**Pi 4 is not yet verified on hardware.** The rootfs is identical across boards apart from the kernel and boot firmware, and nothing in this repo hardcodes a block device — root discovery goes through a fixed MBR disk signature and PARTUUIDs, which is board-independent — so it is expected to work, but it has not been flashed and booted. Also untested: whether a Pi 4 has enough headroom for `mpf-mc`, or for Godot, at runtime.

Before shipping widely: replace the placeholder `pinball/assets/splash.tga` / `imager/icon.png` with real artwork. Keep `pinball-debug-shell` disabled in `pinball/pinball.yaml` (the release guard enforces this).

## Notes

- The Pi model is a build argument, not a config edit: `device.layer: rpi5` in `pinball/pinball.yaml` is only the default, and `./build.sh pi4` overrides it with `IGconf_device_layer=rpi4` on the rpi-image-gen command line. One config file therefore serves every board — the only genuinely board-specific setting, `fs.ext4_mkfs_args`' `-b 4096`, is a real fix on the Pi 5's 16K-page kernel and a harmless no-op on the Pi 4's 4K one.
- MPF 0.80 facts this relies on were read from MPF's own source (`0.80.x` branch), not just the docs: `mpf both` (`mpf/commands/both.py`) runs `shutil.which("godot")` (overridable with `-G` or `gmc.cfg`'s `godot_exec_path`), and MPF 0.80.0 pins GMC 1.0.0 (`__gmc_version__`), which requires Godot 4.5+.
- MPF's exact install steps come from [missionpinball/discussions#115](https://github.com/orgs/missionpinball/discussions/115) and PyPI, not a verbatim copy of the official docs — this worked on the first try, but if a future `pip install` fails after bumping the version pins, cross-check against https://missionpinball.org/latest/install/linux/raspberry/.
- See [`docs/rpi-image-gen-notes.md`](docs/rpi-image-gen-notes.md) for how rpi-image-gen's hook/build-phase system actually works and the full history of the Imager customisation work.
