# rpi-pinball

Build a Raspberry Pi 5 image with [Mission Pinball Framework](https://missionpinball.org) 0.57 (`mpf` + `mpf-mc`) and P-ROC/P3-ROC hardware support installed, ready to run pinball game code.

Forked from [rpi-image-gen-example](https://github.com/jonnymacs/rpi-image-gen-example), which wraps Raspberry Pi Foundation's [rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen).

## Build

```bash
./build.sh
```

The output image lands in `pinball/deploy/pinball-<timestamp>.img`. Flash it with Raspberry Pi Imager.

## What's on the image

- MPF and mpf-mc installed into a dedicated venv at `/opt/mpf/venv` (see `pinball/image/mbr/simple_dual/bdebstrap/customize10-mpf`).
- SSH enabled, autologin on the console as the `pinball` user.
- P-ROC/P3-ROC build dependencies (`libftdi1-2`/`libftdi1-dev`, etc.) installed.

## What's *not* on the image (yet)

- No MPF "machine folder" (your actual game config/code) is baked in. Add yours after first boot, e.g.:
  ```bash
  ssh pinball@<device-ip>
  git clone <your-machine-folder-repo> ~/machine
  cd ~/machine && /opt/mpf/venv/bin/mpf
  ```
- No systemd service — MPF is started manually while developing, not on boot.

## Before flashing

Set a real password: `pinball/pinball.options` ships with `device_user1pass=CHANGE_ME_BEFORE_FLASHING` — edit it before building.

## Status

Builds successfully end-to-end (~10 minutes on Docker Desktop for Mac / Apple Silicon). Confirmed installed: `mpf==0.57.5`, `mpf-mc==0.57.1` (resolved from the `~=0.57.0` range pins in `customize10-mpf`).

## Notes

- Targets the Pi 5 device class (`pinball/config/pinball.cfg`) — confirmed valid.
- MPF's exact install steps come from [missionpinball/discussions#115](https://github.com/orgs/missionpinball/discussions/115) and PyPI, not a verbatim copy of the official docs (which render client-side and couldn't be scraped) — this worked on the first try, but if a future `pip install` fails after bumping the version pins, cross-check against https://missionpinball.org/latest/install/linux/raspberry/.
- See [`docs/rpi-image-gen-notes.md`](docs/rpi-image-gen-notes.md) for how rpi-image-gen's hook/build-phase system actually works — important before touching any `post-build.sh` or `bdebstrap/customizeNN-*` file in this repo.
