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
- Working DNS resolution (`customize95-dns`) — without this, hostnames don't resolve at all (`ping github.com` → "Temporary failure in name resolution") even though the network itself works fine, since the image otherwise ships with a leftover Docker-build-time `/etc/resolv.conf` and no `systemd-resolved` to fix it via DHCP.
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

**Confirmed working on real Pi 5 hardware**: SSH, WiFi, and `mpf` (after the `ruamel.yaml.clib` fix in `customize10-mpf`) all verified directly on device.

**Root filesystem auto-expand — fixed after a real bug found on hardware.** The first version's partition-table resize worked (grew correctly to 14.5G), but its filesystem-grow follow-up step (`raspi-config`'s self-registered `resize2fs_once` init.d script) silently came out empty and never ran — unblocked manually (`sudo reboot` then `sudo resize2fs /dev/mmcblk0p2`), then fixed properly in `customize06-resize-root` by calling `resize2fs` ourselves instead of depending on that mechanism. See `docs/rpi-image-gen-notes.md` for the full root-cause writeup. **Not yet rebuilt/reverified with this fix** — the earlier manual workaround got the *current* device unblocked, but the next fresh image needs to be tested end-to-end again.

**Not yet rebuilt/verified**:
- `/etc/profile.d/mpf-path.sh`, so `mpf both` works without the full `/opt/mpf/venv/bin/` prefix.
- `customize95-dns` — fixes `ping github.com`/any hostname failing with "Temporary failure in name resolution" (found on real hardware; see `docs/rpi-image-gen-notes.md`).

## Notes

- Targets the Pi 5 device class (`pinball/config/pinball.cfg`) — confirmed valid.
- MPF's exact install steps come from [missionpinball/discussions#115](https://github.com/orgs/missionpinball/discussions/115) and PyPI, not a verbatim copy of the official docs (which render client-side and couldn't be scraped) — this worked on the first try, but if a future `pip install` fails after bumping the version pins, cross-check against https://missionpinball.org/latest/install/linux/raspberry/.
- See [`docs/rpi-image-gen-notes.md`](docs/rpi-image-gen-notes.md) for how rpi-image-gen's hook/build-phase system actually works — important before touching any `post-build.sh` or `bdebstrap/customizeNN-*` file in this repo.
