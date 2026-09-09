import sys

p = "/usr/lib/raspberrypi-sys-mods/firstboot"
lines = open(p).read().splitlines(keepends=True)

target_substr = "init=/usr/lib/raspberrypi-sys-mods/firstboot"
idx = None
for i, line in enumerate(lines):
    if target_substr in line and "sed" in line:
        idx = i
        break
if idx is None:
    sys.exit("anchor line not found -- upstream file may have changed, review this patch")

insert = (
    "sed -i -E 's/ ?systemd\\.run=[^ ]*//g; "
    "s/ ?systemd\\.run_success_action=[^ ]*//g; "
    "s/ ?systemd\\.unit=kernel-command-line\\.target//g' \"$FWLOC/cmdline.txt\"\n"
)
lines.insert(idx + 1, insert)
open(p, "w").writelines(lines)
