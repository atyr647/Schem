# Semantic zoom

Zoom in Schem is not pixel scaling — it is **level of detail** along the
language's own scale ladder:

```
Grid  ->  Panel  ->  Circuit  ->  Bundle  ->  Component
 0         1          2           3           4
```

It is the one control that keeps the language *accessible* (a whole machine
as a handful of boxes) and *powerful* (down to the last conductor), with no
two different tools — coarse control and surgical control are the same
control, dialled. The editor shows it live (`+` / `-`); the image renderer
exports any level (`schem image ... -level N`).

## Why it is free

A schematic already encodes the ladder in its component names. Instancing a
circuit under a prefix names parts `PREFIX/inner` (see `hierarchy.tcl`); a
`bus` or `bank` names its members `NAME#i` (see `bus.tcl`). So a part named

```
SC/IN#7
```

reads as *instance `SC` → bundle `IN` → lane `7`*. Zooming out is just
resolving fewer of those segments before collapsing everything that shares
the remaining key into one box (`src/zoom.tcl`):

| level | name | `SC/IN#7` resolves to | what you see |
|------:|------|----------------------|--------------|
| 4 | component | `SC/IN#7` | every part — the editable board |
| 3 | bundle    | `SC/IN`   | each bus drawn as one ribbon |
| 2 | circuit   | `SC/IN`   | the circuit's buses |
| 1 | panel     | `SC`      | the instance as one box |
| 0 | grid      | `SC`      | whole sub-machines as single boxes |

A flat board with no `/` or `#` (a plain divider) has every part at its own
key at every level, so zoom never hides what was never grouped.

## In the image renderer

```sh
schem image FILE.schem out.svg -level 0   # grid: the whole thing in a few boxes
schem image FILE.schem out.svg -level 2   # circuit: buses as ribbons
schem image FILE.schem out.svg -level 4   # component: every part (default)
schem image FILE.schem out.svg -grouped   # == -level 3 (bundle)
```

The Enigma scrambler, for instance:

- **grid (0)** — `GND · KEY:battery · SC[52]:bus · LB[53]:ground`, four boxes;
- **circuit (2)** — the buses appear: `IN[26] → OUT[26]`, `IN[26] → LAMP[26]`;
- **component (4)** — all 107 parts, one row per alphabet lane.

A collapsed group prints as `NAME[n]:type` — the `[n]` is how many real
components it stands for — and gets a doubled border so a ribbon reads as a
cable, not a single part.

## In the editor

The editor starts fully zoomed in (component level), where placing, wiring
and editing happen as normal. `-` steps out toward the grid; `+` steps back
in. At any coarse level the canvas becomes a **navigable overview**: one row
per group, labelled `NAME[n]:type` with a count of how many other groups it
wires to — a minimap over the same board. The cursor selects a group; `+`
drills back into detail.

```
level 2 = circuit   (7 groups, 107 components)
  ▶ GND:ground                         links:1
    KEY:battery                        links:2
    IN[26]:bus                         links:2
    OUT[26]:bus                        links:2
    ...
```

This is the same level-of-detail axis the renderer uses, so what you see in
the editor and what you export as an image are the same view at the same
depth.

## Design note — instance for richer zoom

Zoom is only as deep as the hierarchy a board actually has. A machine built
with bus/bank directly on the top board (like the current bombe) collapses
cleanly at the bundle level, but levels 0–2 cannot go coarser because there
is no enclosing circuit *instance* to fold into. Wrapping repeated structure
in instantiated sub-circuits (a `cable` circuit, a `scrambler` circuit) gives
the coarser levels something to collapse — and is good schematic hygiene
regardless.
