#!/bin/bash
# Generates a Raspberry Pi Imager "local repository" manifest for a built
# pinball .img, so Imager's OS Customisation step (WiFi/user/hostname/SSH)
# becomes available for it. Imager has no way to know a raw, unrecognized
# .img file supports customisation -- picking it via "Use custom" skips
# that step entirely, regardless of what the image itself actually
# supports. Pointing Imager at this generated manifest instead (as its own
# OS-list entry) gives it the metadata it needs. See
# docs/rpi-image-gen-notes.md for the full story and verification caveats.
#
# Thin wrapper: the manifest shape itself lives in imager/gen-os-list.py,
# shared with the hosted repo published by CI (see README "Releases").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$ROOT/pinball/deploy"
IMG="${1:-$(ls -t "$DEPLOY_DIR"/*.img 2>/dev/null | head -n1)}"

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
  echo "No .img file found in $DEPLOY_DIR (or the path given doesn't exist)." >&2
  echo "Usage: $0 [path/to/pinball-*.img]" >&2
  exit 1
fi

OUT="$DEPLOY_DIR/local_repo.json"
python3 "$ROOT/imager/gen-os-list.py" local --img "$IMG" -o "$OUT"

echo "Manifest covers $(basename "$IMG")"
echo
echo "In Raspberry Pi Imager: App Options -> Content Repository -> EDIT ->"
echo "Use custom file -> select $OUT -> APPLY & RESTART."
echo "Then pick \"Pinball Machine (dev build)\" from the OS list (NOT \"Use"
echo "custom\") -- that's what makes the Customisation step appear."
echo
echo "Re-run this script after every new build -- the manifest embeds a"
echo "sha256 of one specific .img file and Imager refuses to flash if it"
echo "doesn't match."
