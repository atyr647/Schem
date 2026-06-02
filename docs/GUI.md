# The Schem workbench (GUI)

A drag-and-drop schematic editor in pure Tcl/Tk.  It is a *view* onto a live
schematic -- the same object model the engine solves and the `.schem` file
stores -- so what you draw is the program.

```sh
schem gui                 # start a blank board
schem gui board.schem     # open an existing board
# or directly:
wish bin/schem-gui board.schem
```

Requires Tk (`wish`).  On Linux: `apt-get install tk`.

## Layout

```
 menubar:  File   Edit   View   Simulate   Manufacture   Help
 toolbar:  [Select] [Wire] [Probe]  |  Solve  Design review  Rotate  Delete
 +------------+----------------------------------+------------+
 | PARTS BIN  |            SCHEMATIC             | INSPECTOR  |
 |  catalog   |          (grid canvas)          | props +    |
 |  by job    |                                 | ratings    |
 +------------+----------------------------------+------------+
 status:  tool - hint                              net = voltage
```

## The workflow

1. **Place** -- click a part in the bin, then click the canvas.  The bin holds
   the raw **basic elements** (battery, resistor, diode, MOSFET, ...) and the
   **real parts** grouped by the job they do (rectifier, smoothing, transistor,
   ...).  Each placed part gets a reference designator (R1, C1, D1, ...).
2. **Wire** -- with the Wire tool, click a pin, then click another pin.  A
   rubber-band follows the cursor; pins snap.
3. **Solve** (F5) -- computes the DC operating point.  Node voltages appear on
   the board; use the **Probe** tool to read any pin.  For time-varying
   circuits (AC sources, RC/RL timing, rectifier ripple) use **Simulate ->
   Transient analysis**, which runs a time-domain sweep and draws a live
   oscilloscope plot of any node.
4. **Check** -- **Simulate -> Design-rule check** runs the anti-spaghetti and
   electrical checks; **Manufacture -> Design review** checks every *real*
   part's operating point against its datasheet absolute-max ratings.
   Over-limit parts turn **red** on the schematic and **marginal** parts amber;
   the Inspector lists each part's stress vs rating (e.g. `If 117%`).
5. **Export / compile** --
   - `File -> Export image (SVG)` for a drawing,
   - `Manufacture -> Export PCB` for a KiCad netlist + BOM the board house
     turns into Gerbers,
   - `File -> Compile to Zig` to turn the board into a standalone Zig program
     that solves it (`zig run FILE.zig`),
   - `File -> Show netlist` for the derived nodes + elements.

## Tools & keys

| | |
|---|---|
| Select | click/drag parts; edit values in the Inspector |
| Wire   | click a pin, then another pin |
| Probe  | after Solve, click a pin to read its voltage |
| **F5** Solve · **R** Rotate · **Del** Delete · **T** ANSI/IEC | |
| **+ / −** zoom · **0** 100% · **F** fit · Ctrl+wheel zoom · middle-drag pan | |
| Ctrl+N / O / S | New / Open / Save |

## Symbols

Components are drawn as real schematic glyphs, switchable between **ANSI/IEEE
315** (zigzag resistor, the US convention) and **IEC 60617** (rectangular
resistor, the international convention) -- toggle with `T` or the View menu.
Battery cell-plates, ground bars, the diode triangle, the SPDT relay, etc. are
all the standard symbols an engineer reads without a legend.

## The Inspector

Selecting a part shows its name, type, the real part id + manufacturer (if it
is a catalog part), its **editable electrical parameters** (type a value, press
Enter), and -- after a design review -- its **ratings** coloured by verdict.
With nothing selected it shows a board summary and the next step.

## Real parts & ratings

The bin's real parts carry datasheet SPICE models *and* rated limits (see
`docs/PARTS.md`).  The design review is the bench check a tech does by hand,
automated: the same rectifier passes with a 1N4007 and is flagged
"OVER LIMIT" with a 1N4148.  Part identity survives save/load -- a loaded board
recovers each part by matching its model to the catalog.

## Notes

- Multiple boards can be open at once (each in its own window).
- The canvas positions are saved into the `.schem`, so a board reopens laid out
  as you left it.
- The GUI never edits text; it manipulates the schematic object model directly,
  exactly as the headless engine and the `.schem` file see it.
