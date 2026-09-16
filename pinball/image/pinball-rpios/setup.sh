#!/bin/bash
# genimage exec-pre hook, run per image with $IMAGEMOUNTPATH = that image's
# staged file tree. Writes fstab into the ROOT tree and points cmdline.txt's
# root= at the ROOT partition in the BOOT tree.
#
# Root and data are addressed by PARTUUID derived from image.disksig (pinned
# in pinball.yaml): the kernel resolves PARTUUID straight from the MBR, with
# no blkid/udev involvement -- the by-slot udev symlink mechanism upstream
# uses for root does not work in this initramfs on real Pi 5 hardware (see
# docs/rpi-image-gen-notes.md). BOOT keeps its by-slot symlink since vfat
# detection works. MBR convention: partition N of a disk with signature S
# has PARTUUID S-0N.

set -eu

LABEL="$1"

DISKSIG_HEX="${IGconf_image_disksig#0x}"
DISKSIG_HEX=$(printf "%s" "$DISKSIG_HEX" | tr "A-F" "a-f")
ROOT_PARTUUID="${DISKSIG_HEX}-02"
DATA_PARTUUID="${DISKSIG_HEX}-03"

case $LABEL in
   ROOT)
      cat << EOF > $IMAGEMOUNTPATH/etc/fstab
# / and /boot/firmware are read-only; use \`sudo pinball-rw\` for maintenance.
# Everything writable at runtime lives on the DATA partition (/data) and is
# bind-mounted into place. See pinball/image/pinball-rpios/setup.sh.
PARTUUID=${ROOT_PARTUUID}  /               ext4   ro,noatime,errors=remount-ro                    0 1
/dev/disk/by-slot/boot  /boot/firmware  vfat   defaults,ro,noatime,errors=remount-ro           0 2
PARTUUID=${DATA_PARTUUID}  /data           ext4   rw,noatime,lazytime,commit=60,errors=remount-ro 0 2
/data/var               /var            none   bind,x-systemd.requires-mounts-for=/data        0 0
/data/home              /home           none   bind,x-systemd.requires-mounts-for=/data        0 0
tmpfs                   /tmp            tmpfs  nosuid,nodev,size=256M                          0 0
EOF
      ;;
   BOOT)
      sed -i "s|root=\([^ ]*\)|root=PARTUUID=${ROOT_PARTUUID}|" $IMAGEMOUNTPATH/cmdline.txt
      ;;
   *)
      ;;
esac
