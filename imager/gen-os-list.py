#!/usr/bin/env python3
"""Generate Raspberry Pi Imager repository JSON (Repository JSON V4) entries.

Single source of truth for the shape of our Imager OS-list entry and the
top-level ``imager.devices`` block. Both of these broke on real hardware
before (see docs/rpi-image-gen-notes.md: without ``imager.devices`` Imager's
hardware filter silently hides every entry; ``init_format`` must be
"rpi-preseed", not "systemd"), so they live here exactly once and are shared
by the local workflow (``imager-repo.sh``) and the hosted one
(``.github/workflows/publish-imager-repo.yml``).

Subcommands
  entry   Hash one built image (raw .img, optionally its .img.xz) and emit a
          single os_list entry. CI stores this as a per-release
          ``pinball-<tag>.manifest.json`` sidecar asset.
  repo    Combine any number of entry files into a complete os_list.json
          (newest release first), setting the icon URL.
  local   ``entry`` + ``repo`` in one shot with a ``file://`` URL, for
          pointing a local Imager at a freshly built .img.

Stdlib only; runs on the macOS system python3 and on GitHub runners.
"""
import argparse
import datetime as _dt
import hashlib
import json
import os
import sys

DEVICES = ["pi5"]
INIT_FORMAT = "rpi-preseed"
ARCHITECTURE = "armv8"
DEFAULT_NAME = "Pinball Machine"
DEFAULT_DESCRIPTION = (
    "Custom MPF-based Raspberry Pi 5 pinball image (rpi-pinball project)"
)
DEFAULT_WEBSITE = "https://github.com/sjkowal/rpi-pinball"

# Imager builds its hardware filter solely from this block. Without it, every
# os_list entry that declares "devices" is dropped and the list comes up empty.
IMAGER_DEVICES = [
    {
        "name": "Raspberry Pi 5",
        "description": "Raspberry Pi 5",
        "tags": ["pi5"],
        "matching_type": "exclusive",
    }
]


def sha256_and_size(path):
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def build_entry(img, url, xz=None, name=None, description=None,
                release_date=None, website=None):
    extract_sha, extract_size = sha256_and_size(img)
    if xz:
        dl_sha, dl_size = sha256_and_size(xz)
    else:
        dl_sha, dl_size = extract_sha, extract_size
    return {
        "name": name or DEFAULT_NAME,
        "description": description or DEFAULT_DESCRIPTION,
        "icon": "",
        "url": url,
        "extract_size": extract_size,
        "extract_sha256": extract_sha,
        "image_download_size": dl_size,
        "image_download_sha256": dl_sha,
        "release_date": release_date or _dt.date.today().isoformat(),
        "devices": list(DEVICES),
        "init_format": INIT_FORMAT,
        "architecture": ARCHITECTURE,
        "website": website or DEFAULT_WEBSITE,
    }


def build_repo(entries, icon=None):
    entries = sorted(
        entries,
        key=lambda e: (e.get("release_date", ""), e.get("name", "")),
        reverse=True,
    )
    if icon is not None:
        for e in entries:
            e["icon"] = icon
    return {"imager": {"devices": IMAGER_DEVICES}, "os_list": entries}


def write_json(obj, out):
    text = json.dumps(obj, indent=2) + "\n"
    if out in (None, "-"):
        sys.stdout.write(text)
    else:
        with open(out, "w") as f:
            f.write(text)
        print(f"Wrote {out}", file=sys.stderr)


def cmd_entry(a):
    write_json(build_entry(a.img, a.url, a.xz, a.name, a.description,
                           a.release_date, a.website), a.output)


def cmd_repo(a):
    entries = []
    for path in a.manifests:
        with open(path) as f:
            data = json.load(f)
        # Accept either a bare entry or a full repo document.
        entries.extend(data["os_list"] if "os_list" in data else [data])
    write_json(build_repo(entries, a.icon), a.output)


def cmd_local(a):
    img = os.path.abspath(a.img)
    entry = build_entry(
        img, "file://" + img,
        name=a.name or f"{DEFAULT_NAME} (dev build)",
        description=f"{DEFAULT_DESCRIPTION} -- {os.path.basename(img)}",
    )
    write_json(build_repo([entry]), a.output)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("entry", help="emit one os_list entry for a built image")
    e.add_argument("--img", required=True, help="raw (uncompressed) .img")
    e.add_argument("--xz", help="compressed .img.xz actually served at --url")
    e.add_argument("--url", required=True, help="download URL for the image")
    e.add_argument("--name")
    e.add_argument("--description")
    e.add_argument("--release-date", help="YYYY-MM-DD (default: today)")
    e.add_argument("--website")
    e.add_argument("-o", "--output", help="file, or - for stdout (default)")
    e.set_defaults(func=cmd_entry)

    r = sub.add_parser("repo", help="combine entries into os_list.json")
    r.add_argument("manifests", nargs="*", help="entry JSON files")
    r.add_argument("--icon", help="icon URL applied to every entry")
    r.add_argument("-o", "--output")
    r.set_defaults(func=cmd_repo)

    l = sub.add_parser("local", help="os_list.json with a file:// URL")
    l.add_argument("--img", required=True)
    l.add_argument("--name")
    l.add_argument("-o", "--output")
    l.set_defaults(func=cmd_local)

    a = p.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
