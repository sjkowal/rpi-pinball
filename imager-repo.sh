#!/bin/bash
# Generates a Raspberry Pi Imager "local repository" manifest for a built
# pinball .img, so Imager's OS Customisation step (WiFi/user/hostname/SSH)
# becomes available for it. Imager has no way to know a raw, unrecognized
# .img file supports customisation -- picking it via "Use custom" skips
# that step entirely, regardless of what the image itself actually
# supports. Pointing Imager at this generated manifest instead (as its own
# OS-list entry) gives it the metadata it needs. See
# docs/rpi-image-gen-notes.md for the full story and verification caveats.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/pinball/deploy" && pwd)"
IMG="${1:-$(ls -t "$DEPLOY_DIR"/*.img 2>/dev/null | head -n1)}"

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
  echo "No .img file found in $DEPLOY_DIR (or the path given doesn't exist)." >&2
  echo "Usage: $0 [path/to/pinball-*.img]" >&2
  exit 1
fi

SIZE=$(stat -f%z "$IMG" 2>/dev/null || stat -c%s "$IMG")
SHA256=$(shasum -a 256 "$IMG" | awk '{print $1}')
OUT="$DEPLOY_DIR/local_repo.json"

cat > "$OUT" <<JSON
{
  "imager": {
    "devices": [
      {
        "name": "Raspberry Pi 5",
        "description": "Raspberry Pi 5",
        "tags": ["pi5"],
        "matching_type": "exclusive"
      }
    ]
  },
  "os_list": [
    {
      "name": "Pinball Machine (dev build)",
      "description": "Custom MPF-based Raspberry Pi 5 pinball image (rpi-pinball project) -- $(basename "$IMG")",
      "icon": "",
      "url": "file://$IMG",
      "extract_size": $SIZE,
      "extract_sha256": "$SHA256",
      "image_download_size": $SIZE,
      "release_date": "$(date +%Y-%m-%d)",
      "devices": ["pi5"],
      "init_format": "rpi-preseed"
    }
  ]
}
JSON

echo "Wrote $OUT for $(basename "$IMG")"
echo
echo "In Raspberry Pi Imager: App Options -> Content Repository -> EDIT ->"
echo "Use custom file -> select $OUT -> APPLY & RESTART."
echo "Then pick \"Pinball Machine (dev build)\" from the OS list (NOT \"Use"
echo "custom\") -- that's what makes the Customisation step appear."
echo
echo "Re-run this script after every new build -- the manifest embeds a"
echo "sha256 of one specific .img file and Imager refuses to flash if it"
echo "doesn't match."
