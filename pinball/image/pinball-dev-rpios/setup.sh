#!/bin/bash
# genimage exec-pre hook, run per image with $IMAGEMOUNTPATH = that image's
# staged file tree. Writes fstab into the ROOT tree and points cmdline.txt's
# root= at the ROOT partition in the BOOT tree.
#
# Same root discovery as the game layout (pinball/image/pinball-rpios/setup.sh):
# ROOT by PARTUUID derived from image.disksig, BOOT by its by-slot symlink.
# Unlike the game layout, both are read-write and there is no DATA
# partition: this is the desktop development image.

set -eu

LABEL="$1"

DISKSIG_HEX="${IGconf_image_disksig#0x}"
DISKSIG_HEX=$(printf "%s" "$DISKSIG_HEX" | tr "A-F" "a-f")
ROOT_PARTUUID="${DISKSIG_HEX}-02"

case $LABEL in
   ROOT)
      cat << EOF > $IMAGEMOUNTPATH/etc/fstab
PARTUUID=${ROOT_PARTUUID}  /               ext4   defaults,noatime  0 1
/dev/disk/by-slot/boot  /boot/firmware  vfat   defaults          0 2
EOF
      ;;
   BOOT)
      sed -i "s|root=\([^ ]*\)|root=PARTUUID=${ROOT_PARTUUID}|" $IMAGEMOUNTPATH/cmdline.txt
      ;;
   *)
      ;;
esac
