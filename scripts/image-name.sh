#!/bin/bash
# Canonical artifact naming for this project -- the single place that knows
# which Raspberry Pi models are supported and how a released file is named.
# Both build.sh and .github/workflows/build-image.yml call this, so the naming
# rule and the model list exist exactly once.
#
#   pinbos-mpf<MPF>-rpi<N>-<VERSION>
#
# The basename only, with no extension: callers append .img, .img.xz,
# .img.xz.sha256 or .manifest.json as needed.
#
# Usage
#   scripts/image-name.sh --models                 -> pi4 pi5
#   scripts/image-name.sh --device-layer pi4        -> rpi4
#   scripts/image-name.sh pi5                       -> pinbos-mpf57-rpi5-v0.3.0-3-gabc1234
#   scripts/image-name.sh pi5 v0.3.0                -> pinbos-mpf57-rpi5-v0.3.0
#
# Environment
#   MPF_VERSION     override the MPF release line (build.sh then also passes
#                   IGconf_mpf_version to rpi-image-gen, so the name and the
#                   image stay in agreement)
#   IMAGE_VERSION   override the version component (CI passes it positionally
#                   instead, which wins over this)
#
# Kept to bash 3.2 features: /bin/bash on macOS is 3.2, so no mapfile, no
# associative arrays, no ${var^^}.

set -eu

# The canonical list of supported models. ADDING A MODEL (e.g. pi3) IS TWO
# EDITS: this line, and the MODELS table in imager/gen-os-list.py.
MODELS="pi4 pi5"

PRODUCT="pinbos"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MPF_LAYER="$ROOT/pinball/layer/pinball-mpf.yaml"

die() { echo "image-name.sh: $*" >&2 ; exit 1 ; }

usage() {
  echo "Usage: $0 <model> [version]" >&2
  echo "       $0 --models" >&2
  echo "       $0 --device-layer <model>" >&2
  echo "Supported models: $MODELS" >&2
}

validate_model() {
  local candidate="$1" m
  for m in $MODELS; do
    [ "$m" = "$candidate" ] && return 0
  done
  die "unsupported model '$candidate' (supported: $MODELS)"
}

# The upstream rpi-image-gen device layer for a model: pi4 -> rpi4.
device_layer() { echo "rpi${1#pi}"; }

# MPF release line. Single source of truth is the X-Env-Var-version line in
# the pinball-mpf layer's metadata, which is also what the layer's pip install
# hook uses -- so the filename cannot drift from what is in the image.
mpf_version() {
  if [ -n "${MPF_VERSION:-}" ]; then
    echo "$MPF_VERSION"
    return
  fi
  [ -f "$MPF_LAYER" ] || die "cannot find $MPF_LAYER"
  local v
  v=$(sed -n 's/^#[[:space:]]*X-Env-Var-version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$MPF_LAYER" | head -n1)
  # Hard-fail rather than emit a filename with a wrong or missing MPF version.
  [ -n "$v" ] || die "no 'X-Env-Var-version:' line in $MPF_LAYER -- has the layer metadata changed?"
  echo "$v"
}

# 0.57 -> mpf57, 0.60 -> mpf60. Strips a leading "0." then removes any
# remaining dots. Note an eventual MPF 1.0 would render as mpf10, colliding
# with a hypothetical 0.10 -- not a real concern, MPF's 0.x line is long past
# 0.10, but revisit this if MPF ever ships 1.x.
mpf_token() {
  local v="$1"
  printf 'mpf%s\n' "$(printf '%s' "${v#0.}" | tr -d '.')"
}

# Version component: explicit argument, then $IMAGE_VERSION, then git.
resolve_version() {
  if [ -n "${1:-}" ]; then
    echo "$1"
    return
  fi
  if [ -n "${IMAGE_VERSION:-}" ]; then
    echo "$IMAGE_VERSION"
    return
  fi
  if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "dev-$(date -u +%Y%m%d)"
    return
  fi
  if git -C "$ROOT" describe --tags --abbrev=0 >/dev/null 2>&1; then
    # v0.3.0 on a tag, else v0.3.0-3-gabc1234, plus -dirty when uncommitted.
    git -C "$ROOT" describe --tags --always --dirty
  else
    # No tags at all yet.
    echo "dev-$(git -C "$ROOT" describe --always --dirty)"
  fi
}

case "${1:-}" in
  --models)
    echo "$MODELS"
    exit 0
    ;;
  --device-layer)
    [ $# -eq 2 ] || { usage; exit 2; }
    validate_model "$2"
    device_layer "$2"
    exit 0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage
    exit 2
    ;;
esac

MODEL="$1"
validate_model "$MODEL"
VERSION="$(resolve_version "${2:-}")"
[ -n "$VERSION" ] || die "could not determine a version -- pass one explicitly"

echo "${PRODUCT}-$(mpf_token "$(mpf_version)")-$(device_layer "$MODEL")-${VERSION}"
