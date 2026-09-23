#!/bin/bash

set -eu

BUILD_ID=${RANDOM}
RPI_BUILD_SVC="rpi_imagegen"
RPI_BUILD_USER="imagegen"
RPI_CUSTOMIZATIONS_DIR="pinball"
RPI_CONFIG="pinball"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMER="${ROOT}/scripts/image-name.sh"

# Which Raspberry Pi to build for. One run builds one model. The supported
# list and the artifact naming rule both live in scripts/image-name.sh.
PI_MODEL="${1:-${PI_MODEL:-pi5}}"

if ! echo " $("$NAMER" --models) " | grep -q " ${PI_MODEL} "; then
  echo "🛑 Unknown Pi model '${PI_MODEL}'."
  echo "   Usage: $0 [$("$NAMER" --models | tr ' ' '|')]   (default: pi5; PI_MODEL= also works)"
  exit 2
fi

# The upstream rpi-image-gen device layer for this model (pi5 -> rpi5). Passed
# as a variable override rather than edited into pinball.yaml, so one config
# serves every model -- see the note next to `device.layer` in pinball.yaml.
RPI_DEVICE_LAYER="$("$NAMER" --device-layer "${PI_MODEL}")"

# Output location. Both are overridable from the environment so CI
# (.github/workflows/build-image.yml) can pin an exact release filename, while
# a plain local `./build.sh` gets the same self-describing name derived from
# the model, the MPF release line and `git describe`:
#   pinball/deploy/pinbos-mpf57-rpi5-v0.3.0.img
RPI_IMAGE_OUT_DIR="${RPI_IMAGE_OUT_DIR:-./${RPI_CUSTOMIZATIONS_DIR}/deploy}"
RPI_IMAGE_OUT_NAME="${RPI_IMAGE_OUT_NAME:-$("$NAMER" "${PI_MODEL}").img}"
OUT="${RPI_IMAGE_OUT_DIR}/${RPI_IMAGE_OUT_NAME}"

# Forwarded only when set, so the image's MPF version and the mpf<NN> token in
# the filename above can never disagree.
MPF_OVERRIDE=""
if [ -n "${MPF_VERSION:-}" ]; then
  MPF_OVERRIDE=" IGconf_mpf_version=${MPF_VERSION}"
fi

# `docker compose exec` allocates a TTY by default. CI has none ("the input
# device is not a TTY"), and a TTY would also inject \r into captured output.
EXEC_FLAGS=""
[ -t 1 ] || EXEC_FLAGS="-T"

ensure_cleanup() {
  echo "Cleanup containers..."

  RPI_BUILD_SVC_CONTAINER_ID=$(docker ps -a --filter "name=${RPI_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1) \
    && docker kill ${RPI_BUILD_SVC_CONTAINER_ID} \
    && docker rm ${RPI_BUILD_SVC_CONTAINER_ID}

  echo "Cleanup complete."
}

# Set the trap to execute the ensure_cleanup function on EXIT
trap ensure_cleanup EXIT

echo "🎯 Target: ${PI_MODEL} (device layer ${RPI_DEVICE_LAYER}) -> ${RPI_IMAGE_OUT_NAME}"
echo "🔨 Building Docker image with rpi-image-gen to create ${RPI_BUILD_SVC}..."
docker compose build ${RPI_BUILD_SVC}

echo "🚀 Running image generation in container..."
docker compose run --name ${RPI_BUILD_SVC}-${BUILD_ID} -d ${RPI_BUILD_SVC}

# v2.8.0 CLI: `rpi-image-gen build -S <srcroot> -c <config>.yaml`, invoked
# from inside the cloned rpi-image-gen checkout — replaces the old
# `build.sh -D <dir> -c <config> -o <options>.options`. There is no separate
# .options file anymore; everything lives in pinball.yaml.
# Variable overrides go after `--` as IGconf_<section>_<key>=value pairs; they
# beat the config file. `IGconf_device_layer` is specifically what the CLI's own
# collect_layers() reads to decide which device layer to apply, so this is all
# it takes to retarget the build at another Pi.
docker compose exec ${EXEC_FLAGS} ${RPI_BUILD_SVC} bash -c "cd /home/${RPI_BUILD_USER}/rpi-image-gen && ./rpi-image-gen build -S /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR}/ -c /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR}/${RPI_CONFIG}.yaml -- IGconf_device_layer=${RPI_DEVICE_LAYER}${MPF_OVERRIDE}"

CID=$(docker ps -a --filter "name=${RPI_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)

# v2.8.0's output path convention differs from the old work/<name>/deploy/
# layout (no more artefacts/ subdir, name includes arch/variant, e.g.
# work/image-deb13-arm64-min/deb13-arm64-min.img per upstream's own
# quickstart) — locate the built .img dynamically rather than guess the
# exact path. The work dir is fresh every run (not a persisted volume), so
# there should never be more than one candidate — asserted below rather than
# assumed, since picking the wrong one would now ship an image whose filename
# claims a Pi model it wasn't built for. Always -T here: the path is
# captured into a variable and must not carry a trailing \r.
#
# Confirmed on a real pi4 build: the one match is work/image-<name>/<name>.img
# (the .sparse and .zst siblings don't match '*.img').
# Prune the chroot rootfs: it is root-owned in places, so descending into it
# makes find exit non-zero ("Permission denied") even when the search itself
# succeeded — which, in a command substitution under `set -e`, killed the
# script right after a perfectly good build. Skipping it is also correct on
# the merits: an .img inside the rootfs would not be the image we just built.
# `|| true` covers anything else unreadable; the count check below is what
# actually decides whether the search worked.
BUILT_IMGS=$(docker compose exec -T ${RPI_BUILD_SVC} bash -c "find /home/${RPI_BUILD_USER}/rpi-image-gen/work -path '*/chroot-*/filesystem' -prune -o -name '*.img' -type f -print 2>/dev/null || true")
BUILT_COUNT=$(printf '%s\n' "$BUILT_IMGS" | grep -c . || true)

if [ "$BUILT_COUNT" -eq 0 ]; then
  echo "🛑 Could not locate a built .img under rpi-image-gen/work/ — build likely failed, or the output path convention changed again."
  exit 1
fi

if [ "$BUILT_COUNT" -ne 1 ]; then
  # The work dir belongs to a container created fresh for this run, so exactly
  # one image is expected. More than one means we would be copying out an
  # arbitrary pick — which, now that the filename asserts a specific Pi model,
  # could ship an image that contradicts its own name.
  echo "🛑 Expected exactly one .img under rpi-image-gen/work/, found ${BUILT_COUNT}:"
  printf '   %s\n' $BUILT_IMGS
  exit 1
fi

BUILT_IMG=$(printf '%s\n' "$BUILT_IMGS" | head -n 1)

mkdir -p "${RPI_IMAGE_OUT_DIR}"
docker cp "${CID}:${BUILT_IMG}" "${OUT}"

echo "🚀 Completed ${PI_MODEL} build -> ${OUT}"
