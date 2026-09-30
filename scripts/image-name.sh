#!/bin/bash
# Canonical artifact naming for this project -- the single place that knows
# which Raspberry Pi models and MPF release lines are supported, and how a
# released file is named. Both build.sh and .github/workflows/build-image.yml
# call this, so the naming rule, the model list and the MPF line list exist
# exactly once.
#
#   pinbos-mpf<MPF>-rpi<N>-<VERSION>
#
# The basename only, with no extension: callers append .img, .img.xz,
# .img.xz.sha256 or .manifest.json as needed.
#
# Usage
#   scripts/image-name.sh --models                 -> pi4 pi5
#   scripts/image-name.sh --mpf-lines              -> 0.57 0.80
#   scripts/image-name.sh --mpf-line [0.80]         -> 0.80 (validated; default line if omitted)
#   scripts/image-name.sh --device-layer pi4        -> rpi4
#   scripts/image-name.sh --config [0.80]           -> pinball-mpf80.yaml
#   scripts/image-name.sh --godot-version           -> 4.7.2
#   scripts/image-name.sh pi5                       -> pinbos-mpf57-rpi5-v0.3.0-3-gabc1234
#   scripts/image-name.sh pi5 v0.3.0                -> pinbos-mpf57-rpi5-v0.3.0
#   MPF_VERSION=0.80 scripts/image-name.sh pi4 v0.4.0 -> pinbos-mpf80-rpi4-v0.4.0
#
# Environment
#   MPF_VERSION     which MPF release line (default $DEFAULT_MPF). Selects the
#                   per-line config pinball/pinball-mpf<NN>.yaml, whose
#                   `mpf.version` must agree -- checked, not assumed
#   IMAGE_VERSION   override the version component (CI passes it positionally
#                   instead, which wins over this)
#
# Kept to bash 3.2 features: /bin/bash on macOS is 3.2, so no mapfile, no
# associative arrays, no ${var^^}.

set -eu

# The canonical list of supported models. ADDING A MODEL (e.g. pi3) IS TWO
# EDITS: this line, and the MODELS table in imager/gen-os-list.py.
MODELS="pi4 pi5"

# The canonical list of supported MPF release lines. Each has its own config,
# pinball/pinball-mpf<NN>.yaml, that includes the shared pinball.yaml. ADDING
# A LINE: that config file, this line, the MPF_LINES table in
# imager/gen-os-list.py, and the CI matrix. The default is what a bare
# ./build.sh builds.
MPF_LINES="0.57 0.80"
DEFAULT_MPF="0.57"

PRODUCT="pinbos"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/pinball"
GMC_LAYER="$ROOT/pinball/layer/pinball-gmc.yaml"

die() { echo "image-name.sh: $*" >&2 ; exit 1 ; }

usage() {
  echo "Usage: $0 <model> [version]" >&2
  echo "       $0 --models" >&2
  echo "       $0 --mpf-lines" >&2
  echo "       $0 --mpf-line [mpf line]" >&2
  echo "       $0 --device-layer <model>" >&2
  echo "       $0 --config [mpf line]" >&2
  echo "       $0 --godot-version" >&2
  echo "Supported models: $MODELS" >&2
  echo "Supported MPF lines: $MPF_LINES (default $DEFAULT_MPF; MPF_VERSION= selects)" >&2
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

validate_mpf() {
  local candidate="$1" l
  for l in $MPF_LINES; do
    [ "$l" = "$candidate" ] && return 0
  done
  die "unsupported MPF line '$candidate' (supported: $MPF_LINES)"
}

# The requested MPF line: explicit argument, then $MPF_VERSION, then default.
requested_mpf() {
  local v="${1:-${MPF_VERSION:-$DEFAULT_MPF}}"
  validate_mpf "$v"
  echo "$v"
}

# Per-line config basename, relative to pinball/: 0.80 -> pinball-mpf80.yaml.
config_for() { echo "pinball-$(mpf_token "$1").yaml"; }

# MPF release line, checked against its config. The config's `mpf.version`
# is the single source of truth -- it is what the pinball-mpf layer's pip
# install hook uses -- so refuse to emit a name if the two disagree rather
# than ship a file whose name claims an MPF version the image does not have.
mpf_version() {
  local want cfg have
  # Explicit `|| exit`: this runs inside the caller's $(...), where bash
  # (no inherit_errexit before 4.4, and macOS ships 3.2) ignores set -e.
  want="$(requested_mpf "${1:-}")" || exit 1
  cfg="$CONFIG_DIR/$(config_for "$want")"
  [ -f "$cfg" ] || die "MPF line $want has no config file $cfg"
  # The quoted `version:` line inside the top-level `mpf:` section.
  have=$(awk '
    /^[^[:space:]#]/ { in_mpf = ($0 ~ /^mpf:/) }
    in_mpf && /^[[:space:]]+version:/ {
      sub(/^[[:space:]]+version:[[:space:]]*/, ""); gsub(/["\047]/, ""); sub(/[[:space:]]*(#.*)?$/, "")
      print; exit
    }' "$cfg")
  [ -n "$have" ] || die "no 'version:' under 'mpf:' in $cfg"
  [ "$have" = "$want" ] || die "$cfg sets mpf.version '$have', but MPF line '$want' was requested"
  echo "$have"
}

# Pinned Godot version for the GMC line, from the pinball-gmc layer metadata
# (the same value its install hook uses).
godot_version() {
  [ -f "$GMC_LAYER" ] || die "cannot find $GMC_LAYER"
  local v
  v=$(sed -n 's/^#[[:space:]]*X-Env-Var-godot_version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$GMC_LAYER" | head -n1)
  [ -n "$v" ] || die "no 'X-Env-Var-godot_version:' line in $GMC_LAYER"
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
  --mpf-lines)
    echo "$MPF_LINES"
    exit 0
    ;;
  --mpf-line)
    [ $# -le 2 ] || { usage; exit 2; }
    mpf_version "${2:-}"
    exit 0
    ;;
  --config)
    [ $# -le 2 ] || { usage; exit 2; }
    # Validates the file agrees with the line before naming it. Plain
    # assignment, not a nested $(...): only an assignment propagates a die().
    MPF="$(mpf_version "${2:-}")"
    config_for "$MPF"
    exit 0
    ;;
  --godot-version)
    godot_version
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

MPF="$(mpf_version)"
echo "${PRODUCT}-$(mpf_token "$MPF")-$(device_layer "$MODEL")-${VERSION}"
