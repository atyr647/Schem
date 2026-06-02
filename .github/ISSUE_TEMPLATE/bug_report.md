---
name: Bug report
about: Something behaves incorrectly (electrically or otherwise)
labels: bug
---

**What you built**
The smallest schematic that shows the problem — a few `add`/`wire` lines, or
the `.schem` file / steps in the GUI.

**What you expected (electrically)**
e.g. "the 1k across 9V should draw 9 mA", "the cap should charge to 63% at 1τ".

**What actually happened**
The number/behaviour you got.

**Environment**
- OS:
- Tcl/Tk version: `echo 'puts $tcl_patchLevel' | tclsh`
- CLI or GUI:
- Zig version (if using the compile backend):
