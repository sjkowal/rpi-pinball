#!/bin/bash

set -eu

BUILD_ID=${RANDOM}
RPI_BUILD_SVC="rpi_imagegen"
RPI_BUILD_USER="imagegen"
RPI_CUSTOMIZATIONS_DIR="pinball"
RPI_CONFIG="pinball"
RPI_IMAGE_NAME="pinball"

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
docker compose exec ${RPI_BUILD_SVC} bash -c "cd /home/${RPI_BUILD_USER}/rpi-image-gen && ./rpi-image-gen build -S /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR}/ -c /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR}/${RPI_CONFIG}.yaml"

CID=$(docker ps -a --filter "name=${RPI_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)

# v2.8.0's output path convention differs from the old work/<name>/deploy/
# layout (no more artefacts/ subdir, name includes arch/variant, e.g.
# work/image-deb13-arm64-min/deb13-arm64-min.img per upstream's own
# quickstart) — locate the built .img dynamically rather than guess the
# exact path. The work dir is fresh every run (not a persisted volume), so
# there's never more than one candidate.
BUILT_IMG=$(docker compose exec ${RPI_BUILD_SVC} bash -c "find /home/${RPI_BUILD_USER}/rpi-image-gen/work -name '*.img' | head -n 1")

if [ -z "$BUILT_IMG" ]; then
  echo "🛑 Could not locate a built .img under rpi-image-gen/work/ — build likely failed, or the output path convention changed again."
  exit 1
fi

docker cp "${CID}:${BUILT_IMG}" "./${RPI_CUSTOMIZATIONS_DIR}/deploy/${RPI_IMAGE_NAME}-$(date +%m-%d-%Y-%H%M).img"

echo "🚀 Completed -> ${RPI_CUSTOMIZATIONS_DIR}/deploy/${RPI_IMAGE_NAME}-$(date +%m-%d-%Y-%H%M).img"
