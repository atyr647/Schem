# Semantic zoom

Zoom in Schem is not pixel scaling — it is **level of detail** along the
language's own scale ladder:

```
Grid  ->  Panel  ->  Circuit  ->  Bundle  ->  Component
coarsest                                       finest
```

It is the one control that keeps the language *accessible* (a whole machine
as a handful of boxes) and *powerful* (down to the last conductor), with no
two different tools — coarse control and surgical control are the same
control, dialled. The editor shows it live (`+` / `-`, anchored to the part
under the cursor); the image renderer exports any level
(`schem image ... -level N`).

## Why it is free

A schematic already encodes the ladder in its component **names**. Instancing
a circuit under a prefix names parts `PREFIX/inner` (see `hierarchy.tcl`); a
`bus` or `bank` names its members `NAME#i` (see `bus.tcl`); panels prefix
their bundles with `PANEL/` too. So a part named

```
MENU/CAB_A#7
```

is a sequence of **tiers** — `[MENU, CAB_A, 7]` (panel → cable → conductor).
Zoom level *d* keeps the first *d+1* tiers as the collapse key; everything
sharing that key draws as one box (`src/view/zoom.tcl`):

| level | `MENU/CAB_A#7` resolves to | what you see |
|------:|---------------------------|--------------|
| 2 | `MENU/CAB_A#7` | every conductor — the editable board |
| 1 | `MENU/CAB_A`   | each cable drawn as one ribbon |
| 0 | `MENU`         | the whole menu as one box |

## The zoom limits are the *language* limits

There is no fixed 0–4 scale. A board's levels run from **0** (the whole board
in a few boxes) up to its **own depth** — the deepest tier any component
actually has:

- a flat voltage divider has depth **0**: every part is already top-level, so
  there is nothing to collapse and zoom is a no-op;
- the Enigma scrambler has depth **2** (`SC/IN#0` → instance, bundle, lane);
- the refactored bombe has depth **2** (`MENU/CAB_A#7` → panel, cable, lane).

`maxLevel` reports a board's finest level and every request is `clamp`ed into
`[0, maxLevel]`. You can never zoom out past the whole board, nor in past an
individual component — the limits fall out of the schematic's own structure.

## In the image renderer

```sh
schem image FILE.schem out.svg -level 0   # the whole thing in a few boxes
schem image FILE.schem out.svg -level 1   # buses/cables as ribbons
schem image FILE.schem out.svg            # finest: every part (default)
schem image FILE.schem out.svg -grouped   # one level coarser than finest
```

Out-of-range levels are clamped, and the wrote-line reports the effective
`level/max`, e.g. `zoom 0/2=grid`. The refactored bombe, for instance:

- **level 0** — `GND · POWER[2] · MENU[468] · REG[26] · LAMPS[26]`, five boxes;
- **level 1** — `MENU` opens into its 18 letter-cables (`CAB_A[26]` …),
  meshed by the scramblers and the diagonal board;
- **finest** — all 523 parts.

A collapsed group prints as `NAME[n]:type` — the `[n]` is how many real
components it stands for — and gets a doubled border so a ribbon reads as a
cable, not a single part.

## In the editor — anchored zoom

The editor starts fully zoomed in (the finest level), where placing, wiring
and editing happen as normal. `-` steps out toward the whole-board view; `+`
steps back in. Both are **anchored to the part under the cursor**: zooming in
descends into the group you are pointing at, and zooming out rises to its
enclosing block — the scroll-toward-the-pointer behaviour, so the thing you
point at is what you dive into or pull back from. The status line shows
`zoom level/max (name) @ focus`.

At any coarse level the canvas becomes a **navigable overview**: one row per
group, labelled `NAME[n]:type` with a count of how many other groups it wires
to — a minimap over the same board. The cursor selects a group; `+` drills
into it.

```
level 1/2 (panel)   (5 groups, 523 components)
  ▶ MENU[468]:bus                    links:3
    POWER[2]:battery                 links:2
    REG[26]:resistor                 links:2
    LAMPS[26]:lamp                   links:1
    ...
```

This is the same level-of-detail axis the renderer uses, so what you see in
the editor and what you export as an image are the same view at the same
depth.

## Hygiene — organise for richer zoom

Zoom is only as deep as the hierarchy a board actually has. Building with
`bus`/`bank` directly on the top board collapses cleanly at the bundle level
but cannot go coarser, because there is no enclosing block to fold into.
Giving repeated structure a panel prefix (`MENU/CAB_A`, `LAMPS/L_T`) or
wrapping it in an instantiated sub-circuit gives the coarser levels something
to collapse — which is why the bombe groups its cables under `MENU/`, its
register under `REG/`, its bulbs under `LAMPS/` and its supply under
`POWER/`. Good schematic hygiene and good zoom are the same thing.
