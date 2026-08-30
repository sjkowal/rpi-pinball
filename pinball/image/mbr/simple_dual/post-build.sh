#!/bin/bash

set -eu

ROOTFS=$1

# configure autologin inside chroot
# NOTE: username is hardcoded here (matches device_user1 in pinball.options) —
# same pattern as the macmind original; chroot's piped bash has no access to
# the build host's IGconf_* env vars, so it can't be parameterized cleanly.
chroot "$ROOTFS" /bin/bash <<'EOF'
set -eu
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOC > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear --autologin pinball %I $TERM
Type=idle
EOC
EOF