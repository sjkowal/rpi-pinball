#!/bin/bash
# pinball-dev-image-rpios pre-image hook. Runs once the whole rootfs is built
# (after every layer's customize hooks) and immediately before genimage.
# $1 = rootfs directory, $2 = genimage input directory.
#
# Fills in genimage.cfg.in.ext4 (as upstream image-rpios does) and removes
# build leftovers. Nothing is relocated: the root stays writable.

set -eu

fs=$1
genimg_in=$2

[[ -d "$fs" ]] || { echo "pre-image: rootfs '$fs' not found" >&2; exit 1; }


# Load pre-defined UUIDs
source "${IGconf_image_outputdir}/img_uuids"


MKE2FS_ARGS_STR="-U $ROOT_UUID ${IGconf_fs_ext4_mkfs_args:-}"
VFAT_ARGS_STR="-S $IGconf_device_sector_size -i $BOOT_LABEL ${IGconf_fs_vfat_mkfs_args:-}"


# Write genimage template
cat genimage.cfg.in.$IGconf_image_rootfs_type | sed \
   -e "s|<IMAGE_DIR>|$IGconf_image_outputdir|g" \
   -e "s|<IMAGE_NAME>|$IGconf_image_name|g" \
   -e "s|<IMAGE_SUFFIX>|$IGconf_image_suffix|g" \
   -e "s|<FW_SIZE>|$IGconf_image_boot_part_size|g" \
   -e "s|<ROOT_SIZE>|$IGconf_image_root_part_size|g" \
   -e "s|<SETUP>|'$(readlink -ef setup.sh)'|g" \
   -e "s|<MKE2FS_CONF>|'$(readlink -ef mke2fs.conf)'|g" \
   -e "s|<MKE2FS_EXTRAARGS>|$MKE2FS_ARGS_STR|g" \
   -e "s|<VFAT_EXTRAARGS>|$VFAT_ARGS_STR|g" \
   -e "s|<BOOT_UUID>|$BOOT_UUID|g" \
   -e "s|<ROOT_UUID>|$ROOT_UUID|g" \
   -e "s|<DISK_SIGNATURE>|$IGconf_image_disksig|g" \
   > ${genimg_in}/genimage.cfg

# Build-time leftovers: the chroot `pip install` hooks run with the build
# container user's HOME (/home/imagegen), leaving a pip cache there.
rm -rf "${fs}/root/.cache/pip" "${fs}/home/imagegen"

# Ship an empty machine-id so every device generates its own on first boot
# (the root is writable, so systemd commits it itself).
: > "${fs}/etc/machine-id"
if [ -d "${fs}/var/lib/dbus" ]; then
   rm -f "${fs}/var/lib/dbus/machine-id"
   ln -s /etc/machine-id "${fs}/var/lib/dbus/machine-id"
fi

echo "pre-image: rootfs is $(du -sh --exclude=boot/firmware "${fs}" | cut -f1) (root_part_size=${IGconf_image_root_part_size})"
