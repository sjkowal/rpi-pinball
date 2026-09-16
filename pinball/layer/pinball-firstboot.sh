#!/bin/bash
# One-time setup on the first boot of a freshly written image, run by
# pinball-firstboot.service. / and /boot/firmware are mounted read-only from
# fstab; this script remounts both read-write for its duration and leaves
# them read-only again. The marker file lives on the DATA partition (via the
# /var bind mount) so the service never runs a second time.
#
# Deliberately no `set -e`: every step is best-effort and logged; a failure
# in one (e.g. growpart on an unusual disk) must not stop the rest, and must
# never leave the machine unbootable.

MARKER=/var/lib/pinball/firstboot-done
LOWER=/run/pinball/lower
PRESEED=/boot/firmware/rpi-preseed.toml

log()  { echo "pinball-firstboot: $*"; }
warn() { echo "pinball-firstboot: WARNING: $*" >&2; }

remount() { # $1 = rw|ro, $2 = mountpoint
   if mount -o "remount,$1" "$2"; then
      log "$2 remounted $1"
   else
      warn "could not remount $2 $1"
      return 1
   fi
}

log "starting first-boot setup"
remount rw / || exit 1
remount rw /boot/firmware

# 1. Grow the DATA partition (the last one) to fill the card/drive, online.
#    growpart: 0 = resized, 1 = already as large as possible, 2 = failure.
DATA_DEV=$(findmnt -no SOURCE /data)
if [ -n "$DATA_DEV" ]; then
   DATA_NAME=$(basename "$DATA_DEV")
   DISK="/dev/$(lsblk -no PKNAME "$DATA_DEV")"
   PARTNUM=$(cat "/sys/class/block/$DATA_NAME/partition")
   log "growing $DATA_DEV (partition $PARTNUM of $DISK)"
   growpart "$DISK" "$PARTNUM"
   rc=$?
   case $rc in
      0) log "partition table updated" ;;
      1) log "partition already fills the device" ;;
      *) warn "growpart exited $rc; /data stays at its image size" ;;
   esac
   if [ "$rc" -le 1 ]; then
      resize2fs "$DATA_DEV" || warn "resize2fs $DATA_DEV failed"
   fi
   log "/data is now $(findmnt -no SIZE /data)"
else
   warn "/data is not mounted; skipping partition growth"
fi

# 2. Migrate /home from the root partition into /data/home. The image keeps
#    the user's home skeleton on the root partition because Raspberry Pi
#    Imager renames /home/pinball to the chosen username directly on that
#    partition at flash time (and may drop authorized_keys there). A plain
#    bind mount of / exposes what is underneath the /home bind mount.
mkdir -p "$LOWER"
if mount --bind / "$LOWER"; then
   if [ -d "$LOWER/home" ] && [ -n "$(ls -A "$LOWER/home")" ]; then
      log "migrating from root partition /home: $(ls -m "$LOWER/home")"
      if cp -a "$LOWER/home/." /home/; then
         find "$LOWER/home" -mindepth 1 -delete || warn "could not clean root partition /home"
      else
         warn "copy of /home failed; root partition copy left in place"
      fi
   else
      log "root partition /home is empty; nothing to migrate"
   fi
   umount "$LOWER"
else
   warn "could not bind-mount the lower root; /home migration skipped"
fi

# 3. Raspberry Pi Imager rpi-preseed customisation, if Imager deferred any
#    of it to boot time (it usually applies everything at flash time).
if [ -f "$PRESEED" ]; then
   log "applying $PRESEED"
   /usr/local/sbin/pinball-apply-preseed.py || warn "pinball-apply-preseed.py failed"
fi

# 4. SSH host keys. ssh-hostkeys-generate.service (rpi-image-gen's
#    openssh-server layer) has ConditionPathIsReadWrite=/etc/ssh and so is
#    silently skipped on the read-only root; generate them here instead so
#    they are unique per device and live on the root partition.
if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
   log "ssh host keys already present"
else
   log "generating ssh host keys"
   ssh-keygen -A || warn "ssh-keygen -A failed"
fi

# 5. machine-id: the image ships an empty /etc/machine-id, so systemd
#    generated a transient one and bind-mounted it over the (read-only) file.
#    Commit it now that / is writable, so the id is stable across reboots
#    (DHCP DUIDs, journal directories, etc.).
#    systemd 252 (Bookworm) only has `systemd-machine-id-setup --commit`;
#    the standalone systemd-machine-id-commit binary is gone (confirmed on
#    hardware: "command not found").
if mountpoint -q /etc/machine-id; then
   log "committing transient machine-id"
   systemd-machine-id-setup --commit || warn "systemd-machine-id-setup --commit failed"
   mountpoint -q /etc/machine-id && warn "/etc/machine-id is still a transient mount"
fi

# 6. Done: mark, flush, and go read-only again.
mkdir -p "$(dirname "$MARKER")" && date -u +%FT%TZ > "$MARKER"
sync
remount ro /boot/firmware
remount ro / || warn "/ stays read-write until the next boot"
log "first-boot setup complete"
exit 0
