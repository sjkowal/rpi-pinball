#!/bin/bash
# Generates a Raspberry Pi Imager "local repository" manifest for locally built
# images, so Imager's OS Customisation step (WiFi/user/hostname/SSH) becomes
# available for them. Imager has no way to know a raw, unrecognized .img file
# supports customisation -- picking it via "Use custom" skips that step
# entirely, regardless of what the image itself actually supports. Pointing
# Imager at this generated manifest instead (as its own OS-list entry) gives it
# the metadata it needs. See docs/rpi-image-gen-notes.md for the full story and
# verification caveats.
#
# With no arguments it covers the newest build of EVERY model present in
# pinball/deploy/, so a local Imager filters by whichever board you picked --
# same behaviour as the hosted repo. Pass a model to narrow it, or a path to
# use one specific image.
#
#   ./imager-repo.sh                 # newest build of each model
#   ./imager-repo.sh pi4             # newest pi4 build only
#   ./imager-repo.sh pinball/deploy/pinbos-mpf57-rpi4-v0.3.0.img
#
# Thin wrapper: the manifest shape itself lives in imager/gen-os-list.py,
# shared with the hosted repo published by CI (see README "Releases").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$ROOT/pinball/deploy"
GEN="$ROOT/imager/gen-os-list.py"
MODELS="$("$ROOT/scripts/image-name.sh" --models)"
OUT="$DEPLOY_DIR/local_repo.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "$*" >&2 ; exit 1 ; }

is_model() {
  local candidate="$1" m
  for m in $MODELS; do
    if [ "$m" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

# Images are named pinbos-mpf<NN>-rpi<N>-<version>.img, so the model is in the
# filename -- no guessing which board an image belongs to.
model_of() {
  local base n
  base="$(basename "$1")"
  n="$(printf '%s\n' "$base" | sed -n 's/.*-rpi\([0-9][0-9]*\)-.*/\1/p')"
  [ -n "$n" ] || return 1
  is_model "pi$n" || return 1
  echo "pi$n"
}

newest_for_model() {
  # shellcheck disable=SC2012  # -t ordering is the point; names have no newlines
  ls -t "$DEPLOY_DIR"/*-rpi"${1#pi}"-*.img 2>/dev/null | head -n1
}

# Resolve the list of images to cover.
IMAGES=""
if [ $# -gt 0 ]; then
  if is_model "$1"; then
    IMAGES="$(newest_for_model "$1" || true)"
    [ -n "$IMAGES" ] || die "No $1 image in $DEPLOY_DIR (looked for *-rpi${1#pi}-*.img). Build one with ./build.sh $1"
  else
    [ -f "$1" ] || die "Not a file, and not one of the supported models ($MODELS): $1"
    IMAGES="$1"
  fi
else
  for model in $MODELS; do
    found="$(newest_for_model "$model" || true)"
    if [ -n "$found" ]; then
      IMAGES="${IMAGES}${found}
"
    fi
  done
  [ -n "$IMAGES" ] || die "No model-tagged .img files in $DEPLOY_DIR (expected *-rpi<N>-*.img). Build one with ./build.sh"
fi

# One entry document per image, then merge them into a single local repo.
COUNT=0
MANIFESTS=""
while IFS= read -r img; do
  [ -n "$img" ] || continue
  model="$(model_of "$img")" || die "Cannot tell which Pi model $(basename "$img") is for -- expected a pinbos-mpf<NN>-rpi<N>-<version>.img name. Pass a supported model ($MODELS) to use the newest build for that board instead."
  manifest="$TMP/$model.json"
  python3 "$GEN" local --img "$img" --model "$model" -o "$manifest"
  MANIFESTS="$MANIFESTS $manifest"
  COUNT=$((COUNT + 1))
  echo "Covers $(basename "$img") ($model)"
done <<< "$IMAGES"

# shellcheck disable=SC2086  # deliberate word splitting of the manifest list
python3 "$GEN" repo $MANIFESTS -o "$OUT"

echo
echo "In Raspberry Pi Imager: App Options -> Content Repository -> EDIT ->"
echo "Use custom file -> select $OUT -> APPLY & RESTART."
echo "Then pick the \"PinbOS (dev build, ...)\" entry for your board from the OS"
echo "list (NOT \"Use custom\") -- that's what makes the Customisation step"
echo "appear. Entries are filtered by the device you chose, so only the image"
echo "built for that board is offered."
echo
echo "Re-run this script after every new build -- the manifest embeds a"
echo "sha256 of $([ "$COUNT" -eq 1 ] && echo "one specific .img file" || echo "each specific .img file") and Imager refuses to flash if it"
echo "doesn't match."
