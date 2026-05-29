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
| Relay standard-cell library — functionally-complete gates, XOR, half/full adder, seal-in latch; proves computational universality by truth table | ✅ | `lib/logic.tcl` |
| Engine: sequential/bistable support — persistent relay state (latch memory), parallel-contact handling, short-by-current and oscillation detection | ✅ | `src/simulate.tcl` |
| Clocked sequential logic — gated D latch, rising-edge (master/slave) D flip-flop, toggle flip-flop and a 2-bit ripple counter; clocked in DC via persistent state and free-running in the transient analyser | ✅ | `lib/logic.tcl` |
| Standard panel circuits — on/off-delay timers, one-shot, debounce, flasher, latching relay bank, safety interlock, plus a timed bench stimulus (`run -events`) | ✅ | `lib/standard.tcl`, `src/transient.tcl` |
| Engine: device realism — battery internal resistance; relay hysteresis, propagation delay and an inductive coil (current ramp + kickback); wire resistance from AWG×length; capacitor ESR/leakage; inductor winding resistance; diode series resistance and reverse breakdown (Zener); fuse/breaker inverse time-current (I²t); a coupled-winding transformer; power & energy measurement | ✅ | `src/simulate.tcl`, `src/transient.tcl` |

## Next

The language is electrically and computationally complete: every part and
named standard circuit in the definition exists, and the engine obeys the
fundamental laws with realistic devices.  What remains is *targets*, not
language:

- **Circuit IR** — a lowered, analysis-agnostic compile target (every
  element classified by electrical role with its derived quantities and
  control semantics) that backends consume.  The single foundation for:
- **Backends** — emit the Circuit IR to other targets (C / WASM / HDL), all
  from the same schematic source.
- **Engine (optional)** — AC/frequency analysis would turn Schem into a
  full electrical *simulator* as well as a computation language; convergence
  aids for very large nonlinear boards.  (All the DC/transient device
  physics is now in place — sources, reactives, semiconductors, protection,
  magnetics, with their real parasitics.)
