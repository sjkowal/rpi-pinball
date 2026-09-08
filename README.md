# rpi-pinball

Build a Raspberry Pi 5 image with [Mission Pinball Framework](https://missionpinball.org) 0.57 (`mpf` + `mpf-mc`) and P-ROC/P3-ROC hardware support installed, ready to run pinball game code.

Forked from [rpi-image-gen-example](https://github.com/jonnymacs/rpi-image-gen-example), which wraps Raspberry Pi Foundation's [rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen).

## Install a released image (Raspberry Pi Imager)

Released images are published as GitHub Releases and listed in an Imager repository served from GitHub Pages:

```bash
rpi-imager --repo https://sjkowal.github.io/rpi-pinball/os_list.json
```

Or in the app: **App Options → Content Repository → EDIT**, paste that URL, **APPLY & RESTART**. Then choose **Raspberry Pi 5** and pick the **Pinball Machine vX.Y.Z** entry (not "Use custom") — that is what makes the OS Customisation step (hostname, user/password, WiFi, SSH) appear. Imager forgets a custom repository on restart, so re-select it each session. Newest release is listed first.

Each release carries `pinball-<tag>.img.xz` (the image, xz-compressed), a `.sha256` for it, and `pinball-<tag>.manifest.json` (the Imager metadata the repository is generated from). You can also download the `.img.xz` directly and use Imager's "Use custom", but then the Customisation step is skipped.

## Build locally

```bash
./build.sh
```

The output image lands in `pinball/deploy/pinball-<timestamp>.img` (uncompressed, gitignored). To flash it with Imager *and* get the Customisation step, generate a local manifest and point Imager at it:

```bash
./imager-repo.sh            # writes pinball/deploy/local_repo.json for the newest .img
```

`RPI_IMAGE_OUT_DIR` / `RPI_IMAGE_OUT_NAME` override the output location (CI uses these).

## Releases (CI)

`.github/workflows/build-image.yml` builds on a GitHub-hosted `ubuntu-24.04-arm` runner using the same `Dockerfile` and `build.sh` as a local build, compresses with `xz -T0`, hashes, and publishes.

- **Release**: `git tag v1.0.0 && git push origin v1.0.0`. Creates a GitHub Release with the assets above, then regenerates and deploys the Imager repository.
- **Prerelease**: a tag containing `-` (e.g. `v1.0.0-rc1`) builds and publishes a release marked *prerelease*, but is **not** listed in the Imager repository.
- **Test build**: Actions tab → *Build image* → *Run workflow*. Produces a 1-day artifact, no release.
- `.github/workflows/publish-imager-repo.yml` regenerates `os_list.json` from every published non-prerelease release (via each release's `manifest.json`) and deploys to Pages. It also runs when a release is edited or deleted in the GitHub UI, and can be run manually.
- The entry shape and the required `imager.devices` block live in one place, `imager/gen-os-list.py`, shared by CI and `imager-repo.sh`.

**Release guard**: the `pinball-debug-shell` layer (`systemd.debug-shell=1`, an unauthenticated root shell on tty9, useful while debugging boot) is commented out in `pinball/pinball.yaml`. If it is ever re-enabled, the workflow refuses to build a non-prerelease `v*` tag until it is commented out again; prerelease tags (`-rc1`) still build.

### One-time GitHub setup

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
2. **Settings → Environments → `github-pages` → Deployment branches and tags**: add a tag rule `v*`. The default policy only allows `main`, which blocks the tag-triggered deploy.
3. **Settings → Actions → General → Workflow permissions**: *Read and write* (the workflows also declare explicit `permissions:`).

Builds take roughly 30–60 minutes on the hosted arm64 runner. Everything here is free on a public repository: standard hosted runner minutes are unmetered, release assets have no total storage or bandwidth cap (2 GiB per file), and Pages is free (soft limit 100 GB/month, only the JSON and icon are served from it).

## What's on the image

- MPF and mpf-mc installed into a dedicated venv at `/opt/mpf/venv` (`pinball/layer/pinball-mpf.yaml`).
- SSH enabled; WiFi via NetworkManager (`pinball-networkmanager`); hostname, user, password, WiFi credentials and SSH keys all come from Imager's OS Customisation, consumed by `pinball-preseed` (`init_format: rpi-preseed`).
- Working DNS resolution.
- P-ROC/P3-ROC build dependencies (`libftdi1-2`/`libftdi1-dev`, etc.) installed.
- Root filesystem auto-expands to fill your SD card/USB drive on first boot (`pinball-resize-root`) — **this triggers one automatic reboot right after first boot**, expected, not a crash.
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
- No systemd service — MPF is started manually while developing, not on boot.

## Before flashing

Nothing to edit. The image ships with a locked placeholder account and no baked-in WiFi (so a public image leaks nothing); set the username, password, WiFi and SSH keys in Imager's OS Customisation step, which only appears when the image is chosen from the Imager repository entry (hosted or local) rather than "Use custom".

## Status

**Confirmed working on real Pi 5 hardware**: SSH, WiFi, and `mpf` all verified directly on device. Imager OS Customisation via the `rpi-preseed` format is the current mechanism after several failed attempts with the `systemd` format — see `docs/rpi-image-gen-notes.md`.

Before shipping widely: replace the placeholder `pinball/assets/splash.tga` / `imager/icon.png` with real artwork. Keep `pinball-debug-shell` disabled in `pinball/pinball.yaml` (the release guard enforces this).

## Notes

- Targets the Pi 5 device class (`device.layer: rpi5` in `pinball/pinball.yaml`).
- MPF's exact install steps come from [missionpinball/discussions#115](https://github.com/orgs/missionpinball/discussions/115) and PyPI, not a verbatim copy of the official docs — this worked on the first try, but if a future `pip install` fails after bumping the version pins, cross-check against https://missionpinball.org/latest/install/linux/raspberry/.
- See [`docs/rpi-image-gen-notes.md`](docs/rpi-image-gen-notes.md) for how rpi-image-gen's hook/build-phase system actually works and the full history of the Imager customisation work.
