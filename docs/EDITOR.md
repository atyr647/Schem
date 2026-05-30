# The editor & validator

These are the tools that *author* and *check* the schematic object model.
Both consume the schematic directly — neither edits text.

## Editor

```sh
schem edit                 # start a new, empty board
schem edit board.schem     # open an existing board
```

The editor is an interactive workbench on a grid.  A cursor selects a
cell; a part bin selects what to place; couplings are drawn by picking a
source terminal and a destination terminal.  It reads and writes the
binary `.schem` file — the file is the artifact, the editor is just how you
shape it.

```
⌁ Schem Editor -- board.schem*
────────────────────────────────────────────────────────────
╔═══════════╗       ┌───────────┐
║B1:battery ║──────▶│R1:resistor│             .
╚═══════════╝       └───────────┘
                          │
                          ▼
                    ┌───────────┐
      .             │GND1:ground│             .
                    └───────────┘
────────────────────────────────────────────────────────────
BIN: [battery] ground resistor capacitor inductor switch button relay ...
cursor: 0,0   mode: place
status: ready
keys: move=hjkl/arrows  place=p  wire=w  param=e  solve=s  validate=v  save=S  open=o  help=?  quit=q
```

The double-lined box (`╔═╗`) is the cursor; `.` marks empty placement
slots; `[+]` marks the cursor on an empty slot.

### Keys

| key | action |
|-----|--------|
| arrows / `h j k l` | move the cursor |
| `[` `]` (or `1`–`9`) | previous / next part in the bin |
| `p` / space | place the selected part at the cursor |
| `d` | delete the component at the cursor (and its couplings) |
| `w` | wire: pick a source terminal, move the cursor, press `w` again to pick the destination |
| `e` | edit a parameter (`emf 12`, `r 2200`, `state closed`, …) |
| `s` | solve (run the interpreter) |
| `v` | validate (see below) |
| `S` / `o` | save / open a `.schem` file |
| `?` | help · `q` quit |

### Headless core

The editor logic is `::schem::EditorSession`: it owns a schematic, a cursor
and a mode, accepts named key events (`$ed key p`, `$ed key ENTER`, …) and
renders a complete frame string.  The terminal front end (`schem edit`) is a
thin loop over it, so the workbench is fully scriptable and testable
without a TTY:

```tcl
set ed [schem::EditorSession new]
$ed key p                      ;# place a battery
$ed key l ; $ed key 3 ; $ed key p   ;# move right, pick resistor, place it
puts [$ed render]              ;# the current frame
set s [$ed schematic]          ;# the live object model
```

## Validator

```sh
schem validate board.schem
```

```tcl
set findings [$s validate]     ;# list of {severity rule message ?component?}
puts [$s validateText]         ;# readable report
```

Validation reads the object model (and runs one *side-effect-free* trial
solve for electrical faults).  Findings are graded **error** (won't run
correctly), **warning** (probably not what was intended) or **info**
(style / scale).

| rule | severity | meaning |
|------|----------|---------|
| `no-ground` | error | no `0 V` reference |
| `short` | error | ideal conductors loop a source (infinite current) |
| `no-source` | warning | nothing drives current (and no ports, so not a sub-circuit) |
| `isolated-component` | warning | a part wired to nothing |
| `floating-terminal` | warning | a two-terminal part with an unconnected pin |
| `terminal-contract` | warning/info | a circuit exposes a port outside `IN/OUT/FAULT/GND`, or has no `GND` |
| `fuse-blown` / `breaker-tripped` / `wire-overload` | warning | electrical faults found by the trial solve |
| `layer-unknown` | info | a part on a non-standard layer (use Power/Control/Signal/Fault/Ground) |
| `board-limit` | info | too many components/couplings — decompose into circuits/panels/grids |
