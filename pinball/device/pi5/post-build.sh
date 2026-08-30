#!/bin/sh

set -eu

rootfs="$1"

# device/pi5/post-build.sh runs in the "main" context, AFTER bdebstrap has
# already exited and torn down its own /dev, /proc, /sys mounts — it's only
# suitable for plain file writes into the rootfs (e.g. /etc/modules), not
# apt/pip installs. MPF installation lives in
# pinball/image/mbr/simple_dual/bdebstrap/customize10-mpf instead, which runs
# during bdebstrap's "customize" phase while the chroot is still fully
# mounted. See docs/rpi-image-gen-notes.md for why.
