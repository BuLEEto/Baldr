#!/usr/bin/env python3
"""Which platform.Backend procs each backend fills — read from the tree.

    tools/backend-coverage.py            # the table
    tools/backend-coverage.py cocoa      # …and what that one is missing

Re-run it rather than trusting a figure written down elsewhere: twice, a
number was copied from a status line that had been true weeks earlier, and
twice it was wrong.
"""
import re, glob, sys, os

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(root, "platform/platform.odin")).read()
body = re.search(r"\nBackend :: struct \{(.*?)\n\}", src, re.S).group(1)
fields = re.findall(r"^\t([a-z_][a-z0-9_]*)\s*:\s*proc", body, re.M)

# Fields that go the other way: the toolkit sets them and the backend calls
# them. Counting one as something a backend fills makes every backend look
# one short for ever.
INBOUND = {"redraw_callback"}
fields = [f for f in fields if f not in INBOUND]

# Fields outside the portable contract: a platform whose accessibility
# interface is answered *through a window* (NSAccessibility, UI Automation)
# has to hand the toolkit that window, and one whose interface is a bus of
# its own (AT-SPI2 on Wayland and X11) has nothing to hand over. Counting it
# against those two would report a gap where there is a design.
WINDOW_ANSWERED = {"surface_native"}
fields = [f for f in fields if f not in WINDOW_ANSWERED]

BACKENDS = ["wayland", "x11", "win32", "cocoa"]
filled = {}
for name in BACKENDS:
    text = ""
    for f in glob.glob(os.path.join(root, "platform", name, "*.odin")):
        if not f.endswith("_test.odin"):
            text += open(f).read()
    # a table entry (`field = proc,`) or a direct assignment (`b.field = proc`)
    filled[name] = {f for f in fields
                    if re.search(r"^\s*" + f + r"\s*=\s*\w", text, re.M)
                    or re.search(r"\bb\." + f + r"\s*=\s*\w", text)}

print(f"platform.Backend: {len(fields)} proc fields a backend fills "
      f"({len(INBOUND)} more the toolkit sets: {', '.join(sorted(INBOUND))}; "
      f"{len(WINDOW_ANSWERED)} only where accessibility is answered through a "
      f"window: {', '.join(sorted(WINDOW_ANSWERED))})\n")
for name in BACKENDS:
    print(f"  {name:8} {len(filled[name]):3}/{len(fields)}")

# The shell tier: what only the Wayland backend has, because only a Wayland
# compositor (the reference compositor) offers it. Absent elsewhere by design, not a gap.
shell = filled["wayland"] - filled["x11"] - filled["win32"] - filled["cocoa"]
print(f"\n  only wayland ({len(shell)}, the shell tier — by design elsewhere):")
print("    " + " ".join(sorted(shell)))

for name in sys.argv[1:]:
    if name not in filled:
        print(f"\nno backend {name!r}", file=sys.stderr)
        continue
    others = set().union(*(filled[o] for o in BACKENDS if o != name))
    gaps = sorted(others - filled[name])
    print(f"\n  {name} lacks {len(gaps)} that another backend has:")
    print("    " + " ".join(gaps))
