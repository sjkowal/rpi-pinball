import sys

p = "/usr/lib/raspberrypi-sys-mods/imager_custom"
lines = open(p).read().splitlines(keepends=True)

target = "raspi-config nonint do_hostname"
idx = None
for i, line in enumerate(lines):
    if target in line:
        idx = i
        break
if idx is None:
    sys.exit("target line not found -- upstream file may have changed, review this patch")

del lines[idx]
open(p, "w").writelines(lines)
