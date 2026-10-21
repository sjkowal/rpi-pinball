#!/usr/bin/env python3
"""Write an Xcursor theme whose every cursor is one transparent pixel.

    make-invisible-cursors.py <theme_dir>      # e.g. .../cursors-invisible/default

Used by the pinball-gmc layer to hide the mouse pointer in cage sessions
started by gmc-run. cage (wlroots) always loads the theme named "default",
and Godot loads $XCURSOR_THEME or "default"; both search $XCURSOR_PATH. So
gmc-run points XCURSOR_PATH at the parent of this theme directory, and the
pointer vanishes whichever of the two draws it, without touching the
system-wide /usr/share/icons/default.

Stdlib only: runs with the build host's python3, writing into the rootfs.
"""
import os
import struct
import sys

# Every name cage or Godot 4.7 looks up, plus the common freedesktop/CSS and
# legacy X11 aliases, so nothing falls through to a built-in arrow.
#   cage: DEFAULT_XCURSOR ("default"/"left_ptr").
#   Godot: platform/linuxbsd/wayland/wayland_thread.cpp cursor_names[] and
#          cursor_names_fallback[].
CURSOR_NAMES = """
default left_ptr arrow top_left_arrow
xterm text ibeam
hand2 hand1 hand pointer pointing_hand
cross crosshair tcross
watch wait left_ptr_watch progress half-busy
fleur move all-scroll size_all grabbing grab closedhand openhand dnd-move dnd-none
crossed_circle forbidden not-allowed no-drop circle
v_double_arrow sb_v_double_arrow ns-resize row-resize row_resize n-resize s-resize
h_double_arrow sb_h_double_arrow ew-resize col-resize col_resize e-resize w-resize
size_bdiag fd_double_arrow nesw-resize ne-resize sw-resize
size_fdiag bd_double_arrow nwse-resize nw-resize se-resize
size_ver size_hor
question_arrow help whats_this
context-menu cell copy alias vertical-text zoom-in zoom-out
""".split()

XCURSOR_IMAGE_TYPE = 0xFFFD0002
NOMINAL_SIZE = 24


def invisible_cursor():
    """A complete Xcursor file: one 1x1 image, fully transparent ARGB."""
    header = struct.pack("<4sIII", b"Xcur", 16, 0x00010000, 1)
    toc = struct.pack("<III", XCURSOR_IMAGE_TYPE, NOMINAL_SIZE, 16 + 12)
    image = struct.pack("<IIIIIIIII", 36, XCURSOR_IMAGE_TYPE, NOMINAL_SIZE,
                        1, 1, 1, 0, 0, 0)          # version, w, h, xhot, yhot, delay
    pixels = struct.pack("<I", 0x00000000)
    return header + toc + image + pixels


def main(theme_dir):
    cursors = os.path.join(theme_dir, "cursors")
    os.makedirs(cursors, exist_ok=True)
    with open(os.path.join(theme_dir, "index.theme"), "w") as f:
        f.write("[Icon Theme]\nName=Invisible\n"
                "Comment=Every cursor is transparent (pinball-gmc)\n")
    first, *aliases = CURSOR_NAMES
    with open(os.path.join(cursors, first), "wb") as f:
        f.write(invisible_cursor())
    for name in aliases:
        link = os.path.join(cursors, name)
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(first, link)
    print(f"wrote {len(CURSOR_NAMES)} invisible cursors to {cursors}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    main(sys.argv[1])
