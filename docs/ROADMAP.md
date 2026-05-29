# Schem Architecture & Roadmap

## The source is the schematic

A Schem program is a **schematic project file** (`.schem`).  It is not
text, not JSON, not SVG, not ASCII, and not "code behind the schematic."
It is a serialized **schematic object model** that opens only through Schem
tooling.  The interpreter, renderer, validator, editor and any LLM tooling
all consume that same object — there is no separate program text.

```
.schem project
   ↓
Schematic object model
   ├─ components      ├─ harnesses
   ├─ terminals       ├─ circuits
   ├─ wires           ├─ panels
   ├─ junctions       └─ grids
   └─ buses
   ↓
Schem viewer opens the visual schematic
   ↓
the same schematic is seen by:
   user · LLM · interpreter · renderer · validator
```

The object model is **not a user-editable programming language**.  It is
just the saved schematic.  The interpreter does not "read code" — it reads
schematic entities (a relay, its coil terminals, a wire from terminal A to
terminal B, a junction, a breaker's rating, a capacitor's stored state, a
circuit/panel/grid grouping).

There is **no raw view**.  Raw bytes exist, of course, but raw bytes are
not the language.  The source *is* the placed components, the connected
terminals, the wires, the couplings, the hierarchy and the continuity.

## Derived artifacts (never the source)

```
schematic source (.schem)
   ↓ derive
circuit graph / netlist / IR        ← cache / build artifact
   ↓
interpreter · (future) WASM · C · HDL · ...
```

- **Netlist / IR** is a *derived* cache: the flattened, continuity-resolved
  view the interpreter (and future backends) consume.  Editing it would
  mean nothing — the schematic is regenerated from, and is the source of,
  the netlist.
- An **exported schematic image** is an optional, derived view.

> Schematic = source.  Netlist/IR = derived.  Text = not part of the language.

## What exists today

| Layer | Status | Where |
|-------|--------|-------|
| Schematic object model (components, terminals, wires, junctions, buses, harnesses, layers, positions, ratings, state, hierarchy) | ✅ | `src/engine.tcl`, `src/hierarchy.tcl` |
| Binary `.schem` project file (save / load) | ✅ | `src/format.tcl` |
| Viewer — opens the schematic as a wired box diagram | ✅ | `src/render.tcl` |
| Derived netlist / IR cache | ✅ | `src/netlist.tcl` |
| Interpreter — Modified Nodal Analysis over the derived graph; obeys Ohm / Kirchhoff / continuity; relays, diodes, fuses, breakers, R/C/L; transient | ✅ | `src/simulate.tcl`, `src/transient.tcl`, `src/solver.tcl` |
| Component → Circuit → Panel → Grid scale | ✅ | `src/hierarchy.tcl` |
| Validator — anti-spaghetti rules (ground/source, isolated parts, floating terminals, terminal contracts, layers, board limits) + electrical faults | ✅ | `src/validate.tcl` |
| Editor — interactive workbench authoring the object model (place / wire / param / solve / validate) reading & writing `.schem` | ✅ | `src/editor.tcl`, `bin/schem edit` |

## Next

- **Standard-cell library** — relay logic (gates, latch, flip-flop) up to a
  counter / adder, proving the computational-universality claim, plus the
  manifesto's standard circuits (debounce, oscillator, timer, …).
- **Backends** — emit the derived netlist/IR to other targets (C / WASM /
  HDL), all from the same schematic source.
- **Engine** — AC/frequency analysis, more parts, convergence aids,
  bistable/sequential handling for the logic work.
