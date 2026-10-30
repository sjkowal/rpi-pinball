#!/bin/bash
# Canonical artifact naming for this project -- the single place that knows
# which Raspberry Pi models and MPF release lines are supported, and how a
# released file is named. Both build.sh and .github/workflows/build-image.yml
# call this, so the naming rule, the model list and the MPF line list exist
# exactly once.
#
#   pinbos-mpf<MPF version>-rpi<N>-<VERSION>     e.g. pinbos-mpf0.81.0-rpi5-v0.8.0
#   pinbos-dev-mpf<MPF version>-rpi<N>-<VERSION> the PinbOS Dev desktop image
#
# <MPF version> is the exact release the image contains (major.minor.patch),
# read from the line's config; the line (major.minor, e.g. 0.81) selects that
# config.
#
# The basename only, with no extension: callers append .img, .img.xz,
# .img.xz.sha256 or .manifest.json as needed.
#
# Usage
#   scripts/image-name.sh --variants               -> game dev
#   scripts/image-name.sh --variant                -> game (validated $IMAGE_VARIANT)
#   scripts/image-name.sh --models                 -> pi4 pi5 (pi5 for dev)
#   scripts/image-name.sh --mpf-lines              -> 0.57 0.58 0.80 0.81
#   scripts/image-name.sh --mpf-line [0.81]         -> 0.81 (validated; default line if omitted)
#   scripts/image-name.sh --mpf-version [0.81]      -> 0.81.0 (exact version in the line's config)
#   scripts/image-name.sh --python-version [0.81]   -> 3.14.10 (empty: Debian's python3)
#   scripts/image-name.sh --device-layer pi4        -> rpi4
#   scripts/image-name.sh --config [0.81]           -> pinball-mpf81.yaml
#   scripts/image-name.sh --godot-version           -> 4.7.2
#   scripts/image-name.sh pi5                       -> pinbos-mpf0.57.6-rpi5-v0.8.0-3-gabc1234
#   scripts/image-name.sh pi5 v0.8.0                -> pinbos-mpf0.57.6-rpi5-v0.8.0
#   MPF_VERSION=0.81 scripts/image-name.sh pi4 v0.8.0 -> pinbos-mpf0.81.0-rpi4-v0.8.0
#   IMAGE_VARIANT=dev scripts/image-name.sh pi5 v0.9.0 -> pinbos-dev-mpf0.81.0-rpi5-v0.9.0
#
# Environment
#   IMAGE_VARIANT   which image: `game` (default; the pinball appliance,
#                   pinball/pinball-mpf<NN>.yaml) or `dev` (PinbOS Dev, the
#                   desktop development image, pinball/pinball-dev-mpf<NN>.yaml).
#                   Each variant has its own models and MPF lines
#   MPF_VERSION     which MPF release line, major.minor (default
#                   $DEFAULT_MPF). Selects the per-line config
#                   pinball/pinball-mpf<NN>.yaml, whose exact `mpf.version`
#                   must belong to that line -- checked, not assumed
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
MPF_LINES="0.57 0.58 0.80 0.81"
DEFAULT_MPF="0.57"

# Image variants. `dev` is the PinbOS Dev desktop image: its own models and
# lines (a subset of the game ones), its own configs
# (pinball/pinball-dev-mpf<NN>.yaml, which include pinball/pinball-dev.yaml)
# and its own product name. The game variant's names are unchanged.
VARIANTS="game dev"
DEV_MODELS="pi5"
DEV_MPF_LINES="0.81"
DEV_DEFAULT_MPF="0.81"

PRODUCT="pinbos"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/pinball"
GMC_LAYER="$ROOT/pinball/layer/pinball-gmc.yaml"

die() { echo "image-name.sh: $*" >&2 ; exit 1 ; }

# The requested variant, validated: $IMAGE_VARIANT, default game.
variant() {
  local v="${IMAGE_VARIANT:-game}" c
  for c in $VARIANTS; do
    [ "$c" = "$v" ] && { echo "$v"; return 0; }
  done
  die "unsupported IMAGE_VARIANT '$v' (supported: $VARIANTS)"
}
# Exits here (not just in a subshell) on a bad IMAGE_VARIANT.
VARIANT="$(variant)" || exit 1
if [ "$VARIANT" = dev ]; then
  MODELS="$DEV_MODELS"
  MPF_LINES="$DEV_MPF_LINES"
  DEFAULT_MPF="$DEV_DEFAULT_MPF"
  PRODUCT="pinbos-dev"
fi

usage() {
  echo "Usage: $0 <model> [version]" >&2
  echo "       $0 --variants" >&2
  echo "       $0 --variant" >&2
  echo "       $0 --models" >&2
  echo "       $0 --mpf-lines" >&2
  echo "       $0 --mpf-line [mpf line]" >&2
  echo "       $0 --mpf-version [mpf line]" >&2
  echo "       $0 --python-version [mpf line]" >&2
  echo "       $0 --device-layer <model>" >&2
  echo "       $0 --config [mpf line]" >&2
  echo "       $0 --godot-version" >&2
  echo "Variant: $VARIANT (of: $VARIANTS; IMAGE_VARIANT= selects)" >&2
  echo "Supported models: $MODELS" >&2
  echo "Supported MPF lines: $MPF_LINES (default $DEFAULT_MPF; MPF_VERSION= selects)" >&2
}

validate_model() {
  local candidate="$1" m
  for m in $MODELS; do
    [ "$m" = "$candidate" ] && return 0
  done
  die "unsupported model '$candidate' for the $VARIANT image (supported: $MODELS)"
}

# The upstream rpi-image-gen device layer for a model: pi4 -> rpi4.
device_layer() { echo "rpi${1#pi}"; }

validate_mpf() {
  local candidate="$1" l
  for l in $MPF_LINES; do
    [ "$l" = "$candidate" ] && return 0
  done
  die "unsupported MPF line '$candidate' for the $VARIANT image (supported: $MPF_LINES)"
}

# The requested MPF line: explicit argument, then $MPF_VERSION, then default.
requested_mpf() {
  local v="${1:-${MPF_VERSION:-$DEFAULT_MPF}}"
  validate_mpf "$v"
  echo "$v"
}

# Per-line config basename, relative to pinball/: 0.80 -> pinball-mpf80.yaml,
# or pinball-dev-mpf81.yaml for the dev variant.
config_for() {
  if [ "$VARIANT" = dev ]; then
    echo "pinball-dev-$(mpf_token "$1").yaml"
  else
    echo "pinball-$(mpf_token "$1").yaml"
  fi
}

# A value from the top-level `mpf:` section of a line's config, quotes and
# trailing comments stripped; empty if absent.
cfg_mpf_value() {
  awk -v key="$2" '
    /^[^[:space:]#]/ { in_mpf = ($0 ~ /^mpf:/) }
    in_mpf && $0 ~ "^[[:space:]]+" key ":" {
      sub("^[[:space:]]+" key ":[[:space:]]*", ""); gsub(/["\047]/, ""); sub(/[[:space:]]*(#.*)?$/, "")
      print; exit
    }' "$1"
}

# The line's config file, checked: it must exist and pin an exact MPF
# version within that line (0.81 -> 0.81.<patch>). The config's `mpf.version`
# is the single source of truth -- the pinball-mpf layer installs exactly it
# and fails the build if the venv disagrees -- so refuse to emit a name
# rather than ship a file whose name claims an MPF version the image does
# not have.
line_config() {
  local want cfg have
  # Explicit `|| exit`: this runs inside the caller's $(...), where bash
  # (no inherit_errexit before 4.4, and macOS ships 3.2) ignores set -e.
  want="$(requested_mpf "${1:-}")" || exit 1
  cfg="$CONFIG_DIR/$(config_for "$want")"
  [ -f "$cfg" ] || die "MPF line $want has no config file $cfg"
  have="$(cfg_mpf_value "$cfg" version)"
  [ -n "$have" ] || die "no 'version:' under 'mpf:' in $cfg"
  printf '%s\n' "$have" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "$cfg sets mpf.version '$have'; expected an exact major.minor.patch release"
  case "$have" in
    "$want".*) ;;
    *) die "$cfg sets mpf.version '$have', which isn't in MPF line '$want'" ;;
  esac
  echo "$cfg"
}

# The validated line (major.minor).
mpf_line() {
  local cfg
  cfg="$(line_config "${1:-}")" || exit 1
  requested_mpf "${1:-}"
}

# The exact MPF version the line's image contains.
mpf_full_version() {
  local cfg
  cfg="$(line_config "${1:-}")" || exit 1
  cfg_mpf_value "$cfg" version
}

# The line's Python (python-build-standalone) version; empty for Debian's
# python3.
python_version() {
  local cfg
  cfg="$(line_config "${1:-}")" || exit 1
  cfg_mpf_value "$cfg" python_version
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

# Config-file token for a line: 0.57 -> mpf57, 0.81 -> mpf81 (so
# pinball-mpf81.yaml). Strips a leading "0." then removes any remaining
# dots. Note an eventual MPF 1.0 would render as mpf10, colliding with a
# hypothetical 0.10 -- not a real concern, MPF's 0.x line is long past 0.10,
# but revisit this if MPF ever ships 1.x. Image filenames use the full
# version instead (mpf0.81.0).
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
  --variants)
    echo "$VARIANTS"
    exit 0
    ;;
  --variant)
    echo "$VARIANT"
    exit 0
    ;;
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
    # Plain assignments, not nested $(...): only an assignment propagates a
    # die().
    LINE="$(mpf_line "${2:-}")"
    echo "$LINE"
    exit 0
    ;;
  --mpf-version)
    [ $# -le 2 ] || { usage; exit 2; }
    FULL="$(mpf_full_version "${2:-}")"
    echo "$FULL"
    exit 0
    ;;
  --python-version)
    [ $# -le 2 ] || { usage; exit 2; }
    PY="$(python_version "${2:-}")"
    echo "$PY"
    exit 0
    ;;
  --config)
    [ $# -le 2 ] || { usage; exit 2; }
    # Validates the file agrees with the line before naming it.
    LINE="$(mpf_line "${2:-}")"
    config_for "$LINE"
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

FULL="$(mpf_full_version)"
echo "${PRODUCT}-mpf${FULL}-$(device_layer "$MODEL")-${VERSION}"
