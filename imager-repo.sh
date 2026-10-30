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
# pair present in pinball/deploy/, for both the game images and PinbOS Dev
# (pinbos-dev-*), so a local Imager filters by whichever board you picked
# and offers each MPF line for it -- same behaviour as the hosted repo. Pass
# a model, an MPF line and/or a variant (game, dev) to narrow it, or a path
# to use one specific image.
#
#   ./imager-repo.sh                 # newest build of each model x MPF line x variant
#   ./imager-repo.sh pi4             # newest pi4 build of each MPF line
#   ./imager-repo.sh 0.81            # newest MPF 0.81 build of each model
#   ./imager-repo.sh pi4 0.81        # newest pi4 MPF 0.81 game build only
#   ./imager-repo.sh dev             # newest PinbOS Dev build(s) only
#   ./imager-repo.sh pinball/deploy/pinbos-mpf0.57.6-rpi4-v0.8.0.img
#
# Thin wrapper: the manifest shape itself lives in imager/gen-os-list.py,
# shared with the hosted repo published by CI (see README "Releases").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$ROOT/pinball/deploy"
GEN="$ROOT/imager/gen-os-list.py"
# The game variant's lists; PinbOS Dev's are a subset of them, checked per
# variant below.
MODELS="$(IMAGE_VARIANT=game "$ROOT/scripts/image-name.sh" --models)"
MPF_LINES="$(IMAGE_VARIANT=game "$ROOT/scripts/image-name.sh" --mpf-lines)"
VARIANTS="$(IMAGE_VARIANT=game "$ROOT/scripts/image-name.sh" --variants)"
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

is_variant() {
  case " $VARIANTS " in *" $1 "*) return 0 ;; esac
  return 1
}

# PinbOS Dev images are named pinbos-dev-mpf...; everything else is a game
# image.
variant_of() {
  case "$(basename "$1")" in
    pinbos-dev-*) echo dev ;;
    *) echo game ;;
  esac
}

# Whether a variant is built for a (model, line): `dev` has fewer of both.
variant_has() { # variant model line
  local v="$1"
  case " $(IMAGE_VARIANT="$v" "$ROOT/scripts/image-name.sh" --models) " in *" $2 "*) ;; *) return 1 ;; esac
  case " $(IMAGE_VARIANT="$v" "$ROOT/scripts/image-name.sh" --mpf-lines) " in *" $3 "*) ;; *) return 1 ;; esac
}

# Images are named pinbos-mpf<version>-rpi<N>-<release>.img (pinbos-mpf<NN>-... before v0.8.0), so the model and the
# MPF line are both in the filename -- no guessing what an image holds.
model_of() {
  local base n
  base="$(basename "$1")"
  n="$(printf '%s\n' "$base" | sed -n 's/.*-rpi\([0-9][0-9]*\)-.*/\1/p')"
  [ -n "$n" ] || return 1
  is_model "pi$n" || return 1
  echo "pi$n"
}

# 0.80 -> 80: the mpf<NN> token in image names before v0.8.0.
mpf_digits() { printf '%s' "${1#0.}" | tr -d '.'; }

# The exact MPF version in an image name (pinbos-mpf0.81.0-rpi5-...), or
# nothing for an older pinbos-mpf81- name.
mpf_full_of() {
  basename "$1" | sed -n 's/.*-mpf\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-.*/\1/p'
}

# The MPF line (major.minor), from either naming style.
mpf_of() {
  local base full n
  base="$(basename "$1")"
  full="$(mpf_full_of "$1")"
  if [ -n "$full" ]; then
    n="${full%.*}"
  else
    n="$(printf '%s\n' "$base" | sed -n 's/.*-mpf\([0-9][0-9]*\)-.*/\1/p')"
    [ -n "$n" ] || return 1
    n="0.$n"
  fi
  is_mpf_line "$n" || return 1
  echo "$n"
}

newest_for() { # model line variant
  # Both naming styles: pinbos-mpf0.81.<patch>-rpi5-* and pinbos-mpf81-rpi5-*.
  # The globs also match pinbos-dev-*, so keep only the asked-for variant.
  # shellcheck disable=SC2012  # -t ordering is the point; names have no newlines
  ls -t "$DEPLOY_DIR"/*-mpf"$2".[0-9]*-rpi"${1#pi}"-*.img \
        "$DEPLOY_DIR"/*-mpf"$(mpf_digits "$2")"-rpi"${1#pi}"-*.img 2>/dev/null |
    while IFS= read -r f; do
      [ "$(variant_of "$f")" = "$3" ] && echo "$f"
    done | head -n1
}

# Resolve the list of images to cover: a path, or model/line filters.
IMAGES=""
WANT_MODELS="$MODELS"
WANT_LINES="$MPF_LINES"
WANT_VARIANTS="$VARIANTS"
if [ $# -eq 1 ] && [ -f "$1" ]; then
  IMAGES="$1"
else
  [ $# -le 3 ] || die "Usage: $0 [model] [mpf line] [variant] | <image.img>"
  for arg in "$@"; do
    if is_model "$arg"; then
      WANT_MODELS="$arg"
    elif is_mpf_line "$arg"; then
      WANT_LINES="$arg"
    elif is_variant "$arg"; then
      WANT_VARIANTS="$arg"
    else
      die "Not a file, a supported model ($MODELS), MPF line ($MPF_LINES) or variant ($VARIANTS): $arg"
    fi
  done
  for variant in $WANT_VARIANTS; do
    for model in $WANT_MODELS; do
      for line in $WANT_LINES; do
        variant_has "$variant" "$model" "$line" || continue
        found="$(newest_for "$model" "$line" "$variant" || true)"
        if [ -n "$found" ]; then
          IMAGES="${IMAGES}${found}
"
        fi
      done
    done
  done
  [ -n "$IMAGES" ] || die "No matching images in $DEPLOY_DIR (expected pinbos[-dev]-mpf<version>-rpi<N>-*.img for models: $WANT_MODELS; MPF lines: $WANT_LINES; variants: $WANT_VARIANTS). Build one with ./build.sh [model] [mpf line] [variant]"
fi

# One entry document per image, then merge them into a single local repo.
COUNT=0
MANIFESTS=""
while IFS= read -r img; do
  [ -n "$img" ] || continue
  model="$(model_of "$img")" || die "Cannot tell which Pi model $(basename "$img") is for -- expected a pinbos-mpf<version>-rpi<N>-<release>.img name. Pass a supported model ($MODELS) to use the newest build for that board instead."
  line="$(mpf_of "$img")" || die "Cannot tell which MPF line $(basename "$img") holds -- expected a pinbos-mpf<version>-rpi<N>-<release>.img name, with an MPF version in one of: $MPF_LINES"
  full="$(mpf_full_of "$img")"
  variant="$(variant_of "$img")"
  manifest="$TMP/$variant-$model-$line.json"
  # gen-os-list.py only shows the Godot pin for lines that ship Godot. No
  # --python-version: the filename doesn't record it, and an older image in
  # deploy/ may predate the current config.
  python3 "$GEN" local --img "$img" --model "$model" --mpf "$line" ${full:+--mpf-version "$full"} --godot-version "$GODOT_VERSION" --variant "$variant" -o "$manifest"
  MANIFESTS="$MANIFESTS $manifest"
  COUNT=$((COUNT + 1))
  echo "Covers $(basename "$img") ($variant, $model, MPF ${full:-$line})"
done <<< "$IMAGES"

# shellcheck disable=SC2086  # deliberate word splitting of the manifest list
python3 "$GEN" repo $MANIFESTS -o "$OUT"

echo
echo "In Raspberry Pi Imager: App Options -> Content Repository -> EDIT ->"
echo "Use custom file -> select $OUT -> APPLY & RESTART."
echo "Then pick the \"PinbOS (dev build, ...)\" or \"PinbOS Dev (local build, ...)\" entry for your board from the OS"
echo "list (NOT \"Use custom\") -- that's what makes the Customisation step"
echo "appear. Entries are filtered by the device you chose, so only the images"
echo "built for that board are offered (one per MPF line)."
echo
echo "Re-run this script after every new build -- the manifest embeds a"
echo "sha256 of $([ "$COUNT" -eq 1 ] && echo "one specific .img file" || echo "each specific .img file") and Imager refuses to flash if it"
echo "doesn't match."
