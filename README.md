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
- SSH installed and enabled (`customize08-ssh`), autologin on the console as the `pinball` user.
- WiFi configured and connected automatically at boot (`customize09-wifi`) — see "Before flashing" below, you must supply your own credentials.
- P-ROC/P3-ROC build dependencies (`libftdi1-2`/`libftdi1-dev`, etc.) installed.
- Root filesystem auto-expands to fill your SD card/USB drive on first boot (`customize06-resize-root`) — **this triggers one automatic reboot right after first boot**, expected, not a crash. Without this the root partition is built at exactly its build-time size with zero free space, so nothing (not even `apt install git`) could be installed after flashing.
- Development conveniences — `git`, `htop`, `vim` (`customize90-dev-tools`) — **temporary**. Nothing else in this repo depends on these; delete that file and rebuild once they're no longer needed.

## What's *not* on the image (yet)

- No MPF "machine folder" (your actual game config/code) is baked in. Add yours after first boot, e.g.:
  ```bash
  ssh pinball@<device-ip>
  git clone <your-machine-folder-repo> ~/machine
  cd ~/machine && mpf both
  ```
  `mpf both` runs the core engine and media controller together — that's what you want for a full running machine. `mpf` alone only runs the core (no display), `mpf mc` alone only runs the media controller. `machine_path` is optional if you're already `cd`'d into a folder with a `config/` subfolder in it. (`mpf`/`mpf-mc` are on `$PATH` via `/etc/profile.d/mpf-path.sh` — no need for the full `/opt/mpf/venv/bin/` prefix.)
- No systemd service — MPF is started manually while developing, not on boot.

## Before flashing

- Set a real password: `pinball/pinball.options` ships with `device_user1pass=CHANGE_ME_BEFORE_FLASHING` — edit it before building.
- Create `pinball/wifi-credentials.env` (gitignored, not committed — you must create it fresh on any new checkout):
  ```sh
  WIFI_SSID="your-network-name"
  WIFI_PSK="your-network-password"
  ```

## Status

**Confirmed working on real Pi 5 hardware**: SSH, WiFi, and `mpf` (after the `ruamel.yaml.clib` fix in `customize10-mpf`) all verified by the user directly on device.

**Not yet rebuilt/verified**:
- `/etc/profile.d/mpf-path.sh`, so `mpf both` works without the full `/opt/mpf/venv/bin/` prefix.
- `customize06-resize-root` (root filesystem auto-expand) — fixes `apt install`/`git clone` failing with "No space left on device" (the root partition ships with zero free space by default). This one specifically needs two real reboots to prove out (partition grow, then filesystem grow), which can't be chroot-verified the way everything else in this repo has been — watch for `df -h /` growing to roughly your card/drive's full size after an automatic reboot on first boot.

## Notes

- Targets the Pi 5 device class (`pinball/config/pinball.cfg`) — confirmed valid.
- MPF's exact install steps come from [missionpinball/discussions#115](https://github.com/orgs/missionpinball/discussions/115) and PyPI, not a verbatim copy of the official docs (which render client-side and couldn't be scraped) — this worked on the first try, but if a future `pip install` fails after bumping the version pins, cross-check against https://missionpinball.org/latest/install/linux/raspberry/.
- See [`docs/rpi-image-gen-notes.md`](docs/rpi-image-gen-notes.md) for how rpi-image-gen's hook/build-phase system actually works — important before touching any `post-build.sh` or `bdebstrap/customizeNN-*` file in this repo.
