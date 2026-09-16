#!/bin/bash

set -eu

BUILD_ID=${RANDOM}
RPI_BUILD_SVC="rpi_imagegen"
RPI_BUILD_USER="imagegen"
RPI_CUSTOMIZATIONS_DIR="pinball"
RPI_CONFIG="pinball"
RPI_IMAGE_NAME="pinball"

# Output location. Both are overridable from the environment so CI
# (.github/workflows/build-image.yml) can write a deterministic
# pinball-<tag>.img into the runner's temp dir, while a plain local
# `./build.sh` keeps the original pinball/deploy/pinball-<timestamp>.img.
RPI_IMAGE_OUT_DIR="${RPI_IMAGE_OUT_DIR:-./${RPI_CUSTOMIZATIONS_DIR}/deploy}"
RPI_IMAGE_OUT_NAME="${RPI_IMAGE_OUT_NAME:-${RPI_IMAGE_NAME}-$(date +%m-%d-%Y-%H%M).img}"
OUT="${RPI_IMAGE_OUT_DIR}/${RPI_IMAGE_OUT_NAME}"

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

echo "🔨 Building Docker image with rpi-image-gen to create ${RPI_BUILD_SVC}..."
docker compose build ${RPI_BUILD_SVC}

echo "🚀 Running image generation in container..."
docker compose run --name ${RPI_BUILD_SVC}-${BUILD_ID} -d ${RPI_BUILD_SVC}

# v2.8.0 CLI: `rpi-image-gen build -S <srcroot> -c <config>.yaml`, invoked
# from inside the cloned rpi-image-gen checkout — replaces the old
# `build.sh -D <dir> -c <config> -o <options>.options`. There is no separate
# .options file anymore; everything lives in pinball.yaml.
docker compose exec ${EXEC_FLAGS} ${RPI_BUILD_SVC} bash -c "cd /home/${RPI_BUILD_USER}/rpi-image-gen && ./rpi-image-gen build -S /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR}/ -c /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR}/${RPI_CONFIG}.yaml"

CID=$(docker ps -a --filter "name=${RPI_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)

# v2.8.0's output path convention differs from the old work/<name>/deploy/
# layout (no more artefacts/ subdir, name includes arch/variant, e.g.
# work/image-deb13-arm64-min/deb13-arm64-min.img per upstream's own
# quickstart) — locate the built .img dynamically rather than guess the
# exact path. The work dir is fresh every run (not a persisted volume), so
# there's never more than one candidate. Always -T here: the path is
# captured into a variable and must not carry a trailing \r.
BUILT_IMG=$(docker compose exec -T ${RPI_BUILD_SVC} bash -c "find /home/${RPI_BUILD_USER}/rpi-image-gen/work -name '*.img' | head -n 1")

if [ -z "$BUILT_IMG" ]; then
  echo "🛑 Could not locate a built .img under rpi-image-gen/work/ — build likely failed, or the output path convention changed again."
  exit 1
fi

mkdir -p "${RPI_IMAGE_OUT_DIR}"
docker cp "${CID}:${BUILT_IMG}" "${OUT}"

echo "🚀 Completed -> ${OUT}"
