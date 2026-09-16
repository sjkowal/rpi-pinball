#!/bin/bash
# pinball-image-rpios pre-image hook. Runs once the whole rootfs is built
# (after every layer's customize hooks) and immediately before genimage.
# $1 = rootfs directory, $2 = genimage input directory.
#
# Two jobs:
#  1. Fill in genimage.cfg.in.ext4 (as upstream image-rpios does), now with
#     a third DATA partition.
#  2. Relocate /var into /data so it lands in data.ext4 (genimage moves
#     everything under rootfs/data into the image whose mountpoint is /data),
#     and prepare the root tree for being mounted read-only. Mirrors what
#     rpi-image-gen's own immutable layout (image/gpt/ab_userdata) does.
#
# /home is deliberately NOT relocated here: Raspberry Pi Imager's OS
# Customisation renames /home/pinball to the chosen username directly on
# partition 2 at flash time (see docs/rpi-image-gen-notes.md), so the
# skeleton has to stay on the root partition for that to work.
# pinball-firstboot.sh migrates whatever is there into /data/home on the
# first boot, before the login user can touch it.

set -eu

fs=$1
genimg_in=$2

[[ -d "$fs" ]] || { echo "pre-image: rootfs '$fs' not found" >&2; exit 1; }


# Load pre-defined UUIDs
source "${IGconf_image_outputdir}/img_uuids"


MKE2FS_ARGS_STR="-U $ROOT_UUID ${IGconf_fs_ext4_mkfs_args:-}"
MKE2FS_DATA_ARGS_STR="-U $DATA_UUID ${IGconf_fs_ext4_mkfs_args:-}"
VFAT_ARGS_STR="-S $IGconf_device_sector_size -i $BOOT_LABEL ${IGconf_fs_vfat_mkfs_args:-}"


# Write genimage template
cat genimage.cfg.in.$IGconf_image_rootfs_type | sed \
   -e "s|<IMAGE_DIR>|$IGconf_image_outputdir|g" \
   -e "s|<IMAGE_NAME>|$IGconf_image_name|g" \
   -e "s|<IMAGE_SUFFIX>|$IGconf_image_suffix|g" \
   -e "s|<FW_SIZE>|$IGconf_image_boot_part_size|g" \
   -e "s|<ROOT_SIZE>|$IGconf_image_root_part_size|g" \
   -e "s|<DATA_SIZE>|$IGconf_image_data_part_size|g" \
   -e "s|<SETUP>|'$(readlink -ef setup.sh)'|g" \
   -e "s|<MKE2FS_CONF>|'$(readlink -ef mke2fs.conf)'|g" \
   -e "s|<MKE2FS_EXTRAARGS>|$MKE2FS_ARGS_STR|g" \
   -e "s|<MKE2FS_DATA_EXTRAARGS>|$MKE2FS_DATA_ARGS_STR|g" \
   -e "s|<VFAT_EXTRAARGS>|$VFAT_ARGS_STR|g" \
   -e "s|<BOOT_UUID>|$BOOT_UUID|g" \
   -e "s|<ROOT_UUID>|$ROOT_UUID|g" \
   -e "s|<DISK_SIGNATURE>|$IGconf_image_disksig|g" \
   > ${genimg_in}/genimage.cfg


# ---------------------------------------------------------------------------
# Relocate runtime-writable state into /data
# ---------------------------------------------------------------------------

echo "pre-image: relocating /var into /data ($(du -sh "${fs}/var" | cut -f1))"

install -d -m 0755 "${fs}/data"
install -d -m 0755 "${fs}/data/home"
rsync -aHAXS --numeric-ids --delete "${fs}/var/" "${fs}/data/var/"

# Reclaim /var on the root tree but keep a skeleton: on a read-only root,
# systemd cannot create these itself and per-service PrivateTmp namespace
# setup fails without var/tmp (status=226/NAMESPACE).
find "${fs}/var" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
install -d -m 1777 "${fs}/var/tmp"
install -d -m 0755 "${fs}/var/log" "${fs}/var/cache" "${fs}/var/spool" "${fs}/var/lib"

# Persistent journal on /data (via the /var bind mount), with a disk budget.
# (group looked up in the target's /etc/group, not the build host's)
journal_gid=$(awk -F: '$1=="systemd-journal"{print $3}' "${fs}/etc/group")
install -d -m 2755 -o 0 -g "${journal_gid:-0}" "${fs}/data/var/log/journal"
install -d -m 0755 "${fs}/etc/systemd/journald.conf.d"
cat > "${fs}/etc/systemd/journald.conf.d/persistent.conf" <<'EOJ'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=128M
SystemMaxFileSize=16M
RuntimeMaxUse=64M
SyncIntervalSec=2m
EOJ

# fake-hwclock saves the time at shutdown to /etc/fake-hwclock.data. Keep
# that working on a read-only /etc by pointing it at /var (persistent).
if [ -e "${fs}/etc/fake-hwclock.data" ] && [ ! -L "${fs}/etc/fake-hwclock.data" ]; then
   mv "${fs}/etc/fake-hwclock.data" "${fs}/data/var/lib/fake-hwclock.data"
   ln -s /var/lib/fake-hwclock.data "${fs}/etc/fake-hwclock.data"
fi

# Build-time leftovers: the chroot `pip install` hooks run with the build
# container user's HOME (/home/imagegen), leaving a pip cache there (and
# nothing else -- verified). Dead weight on the read-only root, and it would
# otherwise be migrated into /data/home on first boot.
rm -rf "${fs}/root/.cache/pip" "${fs}/home/imagegen"

# Older systemd (252/Bookworm) sets up per-service mount namespaces by bind
# mounting a read-only snapshot of / and mounting API filesystems inside it;
# on an immutable root this fails (status=226/NAMESPACE) for services that
# use PrivateDevices=. Newer systemd (257/Trixie) does not have the problem.
# Same workaround as rpi-image-gen's image/gpt/ab_userdata layout.
ver=$(systemd-major "$fs")
[[ "$ver" =~ ^[0-9]+$ ]] || { echo "pre-image: systemd-major failed for $fs" >&2; exit 1; }
if [[ "$ver" -lt 257 ]]; then
   for svc in systemd-resolved systemd-timesyncd; do
      d="${fs}/etc/systemd/system/${svc}.service.d"
      mkdir -p "$d"
      cat > "${d}/immutable-root.conf" <<'EOD'
[Service]
PrivateDevices=no
EOD
   done
fi

# Ship an empty machine-id so every device generates its own on first boot.
# On the read-only root systemd bind-mounts a transient id over the empty
# file; pinball-firstboot.sh commits it while / is temporarily writable.
: > "${fs}/etc/machine-id"
if [ -d "${fs}/data/var/lib/dbus" ]; then
   rm -f "${fs}/data/var/lib/dbus/machine-id"
   ln -s /etc/machine-id "${fs}/data/var/lib/dbus/machine-id"
fi

# Perms for the bind mount targets on the read-only root
chmod 755 "${fs}/home" "${fs}/var" "${fs}/data"

echo "pre-image: /data now holds $(du -sh "${fs}/data" | cut -f1) (data_part_size=${IGconf_image_data_part_size})"
