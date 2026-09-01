#!/bin/bash
set -eu

# BusyBox blkid inside the initramfs cannot identify the ext4 root
# filesystem at all (not even TYPE), so the udev rule that image-rpios's
# own setup.sh relies on for root=/dev/disk/by-slot/system (matching
# ID_FS_LABEL=="ROOT" from a successful blkid probe) never fires on real
# Pi 5 hardware -- confirmed via blkid directly on real hardware showing
# only PARTUUID, nothing else, even with metadata_csum/64bit disabled.
# See docs/rpi-image-gen-notes.md for the full story.
#
# Bypass it: point both fstab's `/` line and cmdline.txt's root= at a
# PARTUUID derived from image.disksig instead -- the kernel resolves
# PARTUUID directly from the MBR partition table at boot, no blkid or udev
# involved at all. Partition 2 (root, in image-rpios's mbr/simple_dual
# layout) gets PARTUUID <disksig>-02 by standard MBR convention. BOOT's
# by-slot symlink is left alone since vfat blkid detection already works.
#
# This runs as the SRCROOT pre-image.sh hook -- the runner executes it
# after IGimage's own pre-image.sh (image/mbr/simple_dual/pre-image.sh),
# late enough to patch its setup.sh in place before genimage actually
# invokes the path genimage.cfg baked in via `readlink -ef setup.sh`.

DISKSIG_HEX="${IGconf_image_disksig#0x}"
DISKSIG_HEX="${DISKSIG_HEX,,}"
ROOT_PARTUUID="${DISKSIG_HEX}-02"

sed -i "s|/dev/disk/by-slot/system|PARTUUID=${ROOT_PARTUUID}|g" "${IGconf_image_assetdir}/setup.sh"
