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
- **Read-only OS.** `/` and `/boot/firmware` are mounted read-only so a power cut mid-game can't corrupt the OS. A third `DATA` partition (`/data`) holds everything that changes at runtime — `/home` (your machine folder, MPF data and logs) and `/var` (journal, NetworkManager state, apt/dpkg databases) are bind-mounted from it, `/tmp` is a tmpfs. On first boot `pinball-firstboot.service` grows `DATA` to fill your SD card/USB drive in place (no reboot), generates SSH host keys and commits the machine-id; `journalctl -u pinball-firstboot` shows what it did. Layout: `pinball/image/pinball-rpios/`, runtime: `pinball/layer/pinball-readonly-root.yaml`.
- Boot splash (`rpi-splash-screen`, image from `pinball/assets/splash.tga`, currently a placeholder) and quiet boot (`pinball-quiet-boot`).
- Development conveniences — `git`, `htop`, `vim` (`packages:` in `pinball/pinball.yaml`) — **temporary**.

## What's *not* on the image (yet)

- No MPF "machine folder" (your actual game config/code) is baked in. Add yours after first boot, e.g.:
  ```bash
  ssh <user>@<device-ip>
  git clone <your-machine-folder-repo> ~/machine
  cd ~/machine && mpf both
  ```
  `mpf both` runs the core engine and media controller together — that's what you want for a full running machine. `mpf` alone only runs the core (no display), `mpf mc` alone only runs the media controller. `machine_path` is optional if you're already `cd`'d into a folder with a `config/` subfolder in it. (`mpf`/`mpf-mc` are on `$PATH` via `/etc/profile.d/mpf-path.sh`.)

  **On an MPF 0.80 image**, use `gmc-run` instead:
  ```bash
  cd ~/machine && git pull && gmc-run      # or: gmc-run ~/machine
  ```
  It does two things:
  1. **Imports the Godot project's assets** with `godot --headless --import`. This step is **required**, not an optimisation. Running a project from source, which is what `mpf both` does, never imports assets; only the editor or `--import` does. Without it every image, sound and font fails to load (`No loader found for resource`), and new or changed assets fail again until the next import. When nothing changed, the import takes a few seconds.
  2. **Starts `cage -- mpf both`.** Godot needs a display server, and cage provides a full-screen one. This works from the console and over SSH, because `seatd` gives cage the seat either way.

  `mpf both` starts `godot` against the `project.godot` in your machine folder, or wherever `gmc.cfg`'s `gmc_project_path` points; `gmc-run` imports that same folder. Arguments after the folder go to `mpf both` (`gmc-run ~/machine -X`). `GMC_SKIP_IMPORT=1` skips the import. To do it by hand: `godot --headless --import`, then `cage -- mpf both`.

  On a fresh checkout (no `.godot/` folder yet), the first import prints around 17 parse errors from GMC's own editor plugin, which tries to load its icons before they're imported; a second import is clean. `gmc-run` runs the first pass silently for that reason. `godot --import` exits 0 even when assets fail, so read its output rather than trusting the exit status. Don't copy `.godot/` from your desktop; let the Pi build its own.

  **You don't need to export for the Pi while developing.** The image ships the full Godot editor build, which runs the project from source. An export (made with Godot's Linux arm64 export templates) starts faster and has its assets already packed, so it's worth it for a finished machine. An export has no `project.godot`, though, so `mpf both`/`gmc-run` can't launch it: start the exported app under `cage` yourself and run plain `mpf` alongside it.

  Edit your project with **Godot 4.7.x**, the version on the image. Prefer the *Mobile* or *Compatibility* renderer. Godot plays only OGG Theora video, decoded in software, which the Pi does poorly, so the GMC docs recommend a Pi for DMD-style games.
- No systemd service — MPF is started manually while developing, not on boot.

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
