#!/bin/bash
# Build the Linux Mint Server ISO inside a privileged Docker container
# (debootstrap/chroot need mounts). Output lands in ./out/.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=mint-server-builder
docker build -q -t "$IMAGE" . >/dev/null
exec docker run --rm --privileged \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$PWD:/build" -w /build \
    "$IMAGE" /build/scripts/build-in-container.sh "$@"
