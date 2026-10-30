#!/bin/bash
# One-time setup on the first boot of the PinbOS Dev (desktop) image, run by
# pinball-dev-firstboot.service. The writable-root counterpart of
# pinball-firstboot.sh: no remounts and no /home migration, and SSH host keys
# and the machine-id are left to systemd's own first-boot units, which work
# on a writable root.
#
# Deliberately no `set -e`: every step is best-effort and logged; a failure
# in one must not stop the rest, and must never leave the machine unbootable.

MARKER=/var/lib/pinball/firstboot-done
PRESEED=/boot/firmware/rpi-preseed.toml
LIGHTDM_CONF=/etc/lightdm/lightdm.conf.d/50-pinball-dev.conf

log()  { echo "pinball-dev-firstboot: $*"; }
warn() { echo "pinball-dev-firstboot: WARNING: $*" >&2; }

log "starting first-boot setup"

# 1. Grow the ROOT partition (the last one) to fill the card/drive, online.
#    growpart: 0 = resized, 1 = already as large as possible, 2 = failure.
ROOT_DEV=$(findmnt -no SOURCE /)
if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
   ROOT_NAME=$(basename "$ROOT_DEV")
   DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV")"
   PARTNUM=$(cat "/sys/class/block/$ROOT_NAME/partition")
   log "growing $ROOT_DEV (partition $PARTNUM of $DISK)"
   growpart "$DISK" "$PARTNUM"
   rc=$?
   case $rc in
      0) log "partition table updated" ;;
      1) log "partition already fills the device" ;;
      *) warn "growpart exited $rc; / stays at its image size" ;;
   esac
   if [ "$rc" -le 1 ]; then
      resize2fs "$ROOT_DEV" || warn "resize2fs $ROOT_DEV failed"
   fi
   log "/ is now $(findmnt -no SIZE /)"
else
   warn "cannot find the root block device ('$ROOT_DEV'); skipping partition growth"
fi

# 2. Raspberry Pi Imager rpi-preseed customisation, if Imager deferred any
#    of it to boot time (it usually applies everything at flash time).
if [ -f "$PRESEED" ]; then
   log "applying $PRESEED"
   /usr/local/sbin/pinball-apply-preseed.py || warn "pinball-apply-preseed.py failed"
fi

# 3. Desktop autologin for the login user. Imager may have renamed the
#    UID-1000 placeholder account (at flash time or in step 2), so name it
#    now, before lightdm starts.
USER1=$(getent passwd 1000 | cut -d: -f1)
if [ -n "$USER1" ] && [ -f "$LIGHTDM_CONF" ]; then
   sed -i "s/^autologin-user=.*/autologin-user=$USER1/" "$LIGHTDM_CONF"
   log "desktop autologin user: $USER1"
else
   warn "no UID 1000 user or no $LIGHTDM_CONF; autologin left as built"
fi

mkdir -p "$(dirname "$MARKER")" && date -u +%FT%TZ > "$MARKER"
sync
log "first-boot setup complete"
exit 0
