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
          complete single-image repository document (imager.devices block +
          os_list with one entry). CI stores one of these per model as a
          ``pinbos-mpf<NN>-rpi<N>-<tag>.manifest.json`` asset, so any single
          image is usable with ``rpi-imager --repo <asset url>`` on its own.
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

# Supported Pi models: build.sh model token -> (Imager device tag, human name).
# ADDING A MODEL (e.g. pi3) IS TWO EDITS: this table, and MODELS in
# scripts/image-name.sh.
MODELS = {
    "pi4": ("pi4", "Raspberry Pi 4"),
    "pi5": ("pi5", "Raspberry Pi 5"),
}
# Newest hardware first. Doubles as the display order of os_list entries that
# share a release date, so one release's two images stay adjacent instead of
# interleaving with an older release's.
MODEL_ORDER = ["pi5", "pi4"]

INIT_FORMAT = "rpi-preseed"
# Correct for every model here: Pi 4 is Cortex-A72 and Pi 5 Cortex-A76, both
# ARMv8-A/aarch64 (a future pi3 would be Cortex-A53, also armv8).
ARCHITECTURE = "armv8"
DEFAULT_NAME = "PinbOS"
DEFAULT_WEBSITE = "https://github.com/sjkowal/rpi-pinball"

# Imager builds its hardware filter solely from this block. Without it, every
# os_list entry that declares "devices" is dropped and the list comes up empty.
# Always every supported model, not just the ones an os_list happens to carry:
# a tag missing from here silently hides its entries, while a tag with no
# entries is harmless (Imager's "Choose Device" step draws from its own bundled
# catalog, a separate code path from this filter).
IMAGER_DEVICES = [
    {
        "name": MODELS[model][1],
        "description": MODELS[model][1],
        "tags": [MODELS[model][0]],
        "matching_type": "exclusive",
    }
    for model in MODEL_ORDER
]


def default_description(model):
    return (
        f"Custom MPF-based {MODELS[model][1]} pinball image (rpi-pinball project)"
    )


def default_name(model, version=None):
    human = MODELS[model][1]
    return f"{DEFAULT_NAME} {version} ({human})" if version else f"{DEFAULT_NAME} ({human})"


def _model_rank(entry):
    """Position of an entry's model in MODEL_ORDER; unknown tags sort last."""
    tags = entry.get("devices") or []
    for index, model in enumerate(MODEL_ORDER):
        if MODELS[model][0] in tags:
            return index
    return len(MODEL_ORDER)


def sha256_and_size(path):
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def build_entry(img, url, model, xz=None, name=None, description=None,
                release_date=None, website=None, version=None):
    extract_sha, extract_size = sha256_and_size(img)
    if xz:
        dl_sha, dl_size = sha256_and_size(xz)
    else:
        dl_sha, dl_size = extract_sha, extract_size
    return {
        "name": name or default_name(model, version),
        "description": description or default_description(model),
        "icon": "",
        "url": url,
        "extract_size": extract_size,
        "extract_sha256": extract_sha,
        "image_download_size": dl_size,
        "image_download_sha256": dl_sha,
        "release_date": release_date or _dt.date.today().isoformat(),
        # This model only: Imager's "exclusive" matching then offers a Pi 4
        # user the pi4 image and nothing else.
        "devices": [MODELS[model][0]],
        "init_format": INIT_FORMAT,
        "architecture": ARCHITECTURE,
        "website": website or DEFAULT_WEBSITE,
    }


def build_repo(entries, icon=None):
    # Newest release first, and within one release date the models in
    # MODEL_ORDER (negated so reverse=True still puts pi5 ahead of pi4). Sorting
    # on name instead would interleave releases once a release carries more than
    # one model. Imager displays entries in document order.
    entries = sorted(
        entries,
        key=lambda e: (e.get("release_date", ""), -_model_rank(e)),
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
    entry = build_entry(a.img, a.url, a.model, a.xz, a.name, a.description,
                        a.release_date, a.website, a.version)
    # Always a full document, never a bare entry: without the imager.devices
    # block Imager's hardware filter drops the entry and the list is empty.
    write_json(build_repo([entry]), a.output)


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
        img, "file://" + img, a.model,
        name=a.name or f"{DEFAULT_NAME} (dev build, {MODELS[a.model][1]})",
        description=f"{default_description(a.model)} -- {os.path.basename(img)}",
    )
    write_json(build_repo([entry]), a.output)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("entry", help="emit a one-image repository JSON for a built image")
    e.add_argument("--img", required=True, help="raw (uncompressed) .img")
    e.add_argument("--xz", help="compressed .img.xz actually served at --url")
    e.add_argument("--url", required=True, help="download URL for the image")
    e.add_argument("--model", required=True, choices=sorted(MODELS),
                   help="Pi model this image was built for")
    e.add_argument("--version", help="version shown in the entry name, e.g. v0.3.0")
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
    l.add_argument("--model", required=True, choices=sorted(MODELS),
                   help="Pi model this image was built for")
    l.add_argument("--name")
    l.add_argument("-o", "--output")
    l.set_defaults(func=cmd_local)

    a = p.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
