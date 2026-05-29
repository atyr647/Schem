# The Circuit IR and backends

A Schem program is a schematic. The **Circuit IR (CIR)** is how that schematic
is lowered for *backends* — the present Tcl solver today, and emitters to Zig
/ C / WASM / HDL. It is a derived artifact, never the source.

```
.schem (source)
   ↓ resolve continuity (BuildNodes)        netlist  — "what connects to what"
   ↓ classify each element by role          Circuit IR — "what each element does"
   ↓ backend
[ Tcl MNA solver | Zig | C | WASM | HDL | ... ]
```

```sh
schem ir   FILE.schem        # print the Circuit IR
schem emit zig FILE.schem    # emit a Zig DC solver
```

## Why a separate IR

The `netlist` (`src/netlist.tcl`) already resolves continuity into shared
nodes and lists the elements with their node mappings — the *structural* view.
The CIR (`src/compile.tcl`) goes one step further and **lowers** each element
to its electrical **role**, with the derived quantities and control semantics
a code generator needs, so a backend dispatches on role instead of
re-deriving device physics:

| `class` | elements | carries |
|---------|----------|---------|
| `conductance` | resistor, relay coil | `g = 1/R` between two nodes |
| `source` | battery | `emf`, series `rs` |
| `switch` | switch / button | `state`, closed resistance |
| `relay` | relay | coil (R, L), `pickup`/`dropout`/`delay`, contact nodes |
| `nonlinear` | diode | Shockley `is`/`n`, bulk `rs`, breakdown `bv` |
| `reactive` | capacitor / inductor | value, initial state, parasitics, DC behaviour |
| `coupled` | transformer | `L1`, `L2`, `k`, mutual `M` |
| `protective` | fuse / breaker | `rating`, `state`, `i2t` |
| `meter` | ammeter | a 0 V branch |
| `conductor` | gauged wire | resistance (AWG×len), ampacity |

Plus a node table (node 0 = ground), the ports, and `analysis` flags
(`reactive` / `nonlinear` / `stateful`) so a backend knows what machinery it
needs. Ground, buses and junctions are pure connectivity — folded into nodes,
never emitted as elements.

The CIR is **analysis-agnostic**: each element records how it behaves at DC
(e.g. an inductor `(dc:short)`, a capacitor `(dc:open)`) and carries the
parameters a transient or Newton backend would use, so one IR serves every
analysis.

## Backends are interchangeable

A backend is just a proc `::schem::backend::<name> {cir}` that returns the
emitted text; it registers by existing. The IR is the only contract, so a new
target is a sibling proc — no engine change.

```tcl
schem::emit $schematic zig      ;# -> Zig source
schem::backends                 ;# -> {dcref zig}
```

Two backends ship today:

- **`zig`** — emits a self-contained Zig program that solves the **full DC
  operating point** by Modified Nodal Analysis, with the same two loops the
  engine uses: an **outer fixed-point over relay state** (coil current →
  pick-up/drop-out → which contact is closed) and an **inner Newton over
  diodes** (Shockley + Zener, series resistance). It covers every element at
  its DC behaviour — resistors, batteries with ESR, switches, **relays**,
  **diodes**, ammeters, gauged wires, fuses/breakers, transformer windings
  (shorts at DC), inductors (a DC short), capacitors (open). The relay and
  diode metadata are emitted as Zig arrays and the contact/companion stamps
  are recomputed each iteration. (Transient — companion stepping over time —
  is the next layer; the IR already carries `v0`/`i0`/`L`/`C`/`coilL`/`delay`
  for it.)
- **`dcref`** — a reference backend, in Tcl, that solves the DC operating
  point *straight from the IR* (the same lowering the emitters use). It proves
  the IR carries enough to reproduce the solve, and is the oracle the code
  emitters are checked against: `tests/test_cir.tcl` asserts `dcref` matches
  the electrical engine node-for-node.

> Note: the emitted Zig is generated and structurally tested here, but not
> compiled (no Zig toolchain in this environment). Its correctness rests on
> the shared lowering — `dcref` exercises exactly the same `LowerDC` mapping
> and is verified numerically against the engine.

## Examples

Two committed samples of `schem emit zig`:

- `examples/voltage_divider.zig` — the divider, whose stamps
  (`stampG(a, 1, 2, 0.001)`, the 9 V source branch) solve to `N1 = 9 V`,
  `N2 = 6 V`, the same answer the engine computes.
- `examples/relay_and_gate.zig` — a relay AND gate, emitting the relay
  metadata arrays and the fixed-point loop, so the generated program closes
  contacts and settles exactly as a relay machine does.

## Verifying without a Zig compiler

There is no Zig toolchain in this environment, so the emitted `.zig` is
generated and structurally tested but not compiled. Its correctness rests on
the **shared lowering**: `tests/test_cir.tcl` asserts that `dcref` — which
runs the identical fixed-point/Newton algorithm over the same `LowerDC`
mapping — reproduces the engine node-for-node on linear, diode (Newton) and
relay (fixed-point) circuits, including a full AND-gate truth table. The Zig
emitter is a transcription of that verified algorithm.

## Where this is heading

The IR is the foundation for the native backend (the answer to running very
large grids at full speed) and the natural home for a compiled, fill-reduced
elimination schedule. The remaining code-gen layer is **transient** stepping
(companion models over time, the relay propagation delay) — it extends the
Zig backend without changing the IR or the source. After that: more targets
(C / WASM / HDL), each a sibling proc over the same IR.
