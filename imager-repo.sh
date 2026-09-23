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
# With no arguments it covers the newest build of EVERY (model, MPF line)
# pair present in pinball/deploy/, so a local Imager filters by whichever
# board you picked and offers each MPF line for it -- same behaviour as the
# hosted repo. Pass a model and/or an MPF line to narrow it, or a path to use
# one specific image.
#
#   ./imager-repo.sh                 # newest build of each model x MPF line
#   ./imager-repo.sh pi4             # newest pi4 build of each MPF line
#   ./imager-repo.sh 0.80            # newest MPF 0.80 build of each model
#   ./imager-repo.sh pi4 0.80        # newest pi4 MPF 0.80 build only
#   ./imager-repo.sh pinball/deploy/pinbos-mpf57-rpi4-v0.3.0.img
#
# Thin wrapper: the manifest shape itself lives in imager/gen-os-list.py,
# shared with the hosted repo published by CI (see README "Releases").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$ROOT/pinball/deploy"
GEN="$ROOT/imager/gen-os-list.py"
MODELS="$("$ROOT/scripts/image-name.sh" --models)"
MPF_LINES="$("$ROOT/scripts/image-name.sh" --mpf-lines)"
GODOT_VERSION="$("$ROOT/scripts/image-name.sh" --godot-version)"
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

is_mpf_line() {
  local candidate="$1" l
  for l in $MPF_LINES; do
    if [ "$l" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

# Images are named pinbos-mpf<NN>-rpi<N>-<version>.img, so the model and the
# MPF line are both in the filename -- no guessing what an image holds.
model_of() {
  local base n
  base="$(basename "$1")"
  n="$(printf '%s\n' "$base" | sed -n 's/.*-rpi\([0-9][0-9]*\)-.*/\1/p')"
  [ -n "$n" ] || return 1
  is_model "pi$n" || return 1
  echo "pi$n"
}

# 0.80 -> 80, matching image-name.sh's mpf<NN> token.
mpf_digits() { printf '%s' "${1#0.}" | tr -d '.'; }

mpf_of() {
  local base n
  base="$(basename "$1")"
  n="$(printf '%s\n' "$base" | sed -n 's/.*-mpf\([0-9][0-9]*\)-.*/\1/p')"
  [ -n "$n" ] || return 1
  is_mpf_line "0.$n" || return 1
  echo "0.$n"
}

newest_for() {
  # shellcheck disable=SC2012  # -t ordering is the point; names have no newlines
  ls -t "$DEPLOY_DIR"/*-mpf"$(mpf_digits "$2")"-rpi"${1#pi}"-*.img 2>/dev/null | head -n1
}

# Resolve the list of images to cover: a path, or model/line filters.
IMAGES=""
WANT_MODELS="$MODELS"
WANT_LINES="$MPF_LINES"
if [ $# -eq 1 ] && [ -f "$1" ]; then
  IMAGES="$1"
else
  [ $# -le 2 ] || die "Usage: $0 [model] [mpf line] | <image.img>"
  for arg in "$@"; do
    if is_model "$arg"; then
      WANT_MODELS="$arg"
    elif is_mpf_line "$arg"; then
      WANT_LINES="$arg"
    else
      die "Not a file, a supported model ($MODELS) or a supported MPF line ($MPF_LINES): $arg"
    fi
  done
  for model in $WANT_MODELS; do
    for line in $WANT_LINES; do
      found="$(newest_for "$model" "$line" || true)"
      if [ -n "$found" ]; then
        IMAGES="${IMAGES}${found}
"
      fi
    done
  done
  [ -n "$IMAGES" ] || die "No matching images in $DEPLOY_DIR (expected pinbos-mpf<NN>-rpi<N>-*.img for models: $WANT_MODELS; MPF lines: $WANT_LINES). Build one with ./build.sh [model] [mpf line]"
fi

# One entry document per image, then merge them into a single local repo.
COUNT=0
MANIFESTS=""
while IFS= read -r img; do
  [ -n "$img" ] || continue
  model="$(model_of "$img")" || die "Cannot tell which Pi model $(basename "$img") is for -- expected a pinbos-mpf<NN>-rpi<N>-<version>.img name. Pass a supported model ($MODELS) to use the newest build for that board instead."
  line="$(mpf_of "$img")" || die "Cannot tell which MPF line $(basename "$img") holds -- expected a pinbos-mpf<NN>-rpi<N>-<version>.img name with NN one of: $(for l in $MPF_LINES; do mpf_digits "$l"; printf ' '; done)"
  manifest="$TMP/$model-$line.json"
  # gen-os-list.py only shows the Godot pin for lines that ship Godot.
  python3 "$GEN" local --img "$img" --model "$model" --mpf "$line" --godot-version "$GODOT_VERSION" -o "$manifest"
  MANIFESTS="$MANIFESTS $manifest"
  COUNT=$((COUNT + 1))
  echo "Covers $(basename "$img") ($model, MPF $line)"
done <<< "$IMAGES"

# shellcheck disable=SC2086  # deliberate word splitting of the manifest list
python3 "$GEN" repo $MANIFESTS -o "$OUT"

echo
echo "In Raspberry Pi Imager: App Options -> Content Repository -> EDIT ->"
echo "Use custom file -> select $OUT -> APPLY & RESTART."
echo "Then pick the \"PinbOS (dev build, ...)\" entry for your board from the OS"
echo "list (NOT \"Use custom\") -- that's what makes the Customisation step"
echo "appear. Entries are filtered by the device you chose, so only the images"
echo "built for that board are offered (one per MPF line)."
echo
echo "Re-run this script after every new build -- the manifest embeds a"
echo "sha256 of $([ "$COUNT" -eq 1 ] && echo "one specific .img file" || echo "each specific .img file") and Imager refuses to flash if it"
echo "doesn't match."
