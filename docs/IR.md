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

- **`zig`** — emits a self-contained Zig program. Two modes:
  - **DC** (`schem emit zig FILE`) — the **full DC operating point** by
    Modified Nodal Analysis, with the engine's two loops: an **outer
    fixed-point over relay state** (coil current → pick-up/drop-out → which
    contact is closed) and an **inner Newton over diodes** (Shockley + Zener,
    series resistance). Covers every element at its DC behaviour — resistors,
    batteries with ESR, switches, relays, diodes, ammeters, gauged wires,
    fuses/breakers, transformer windings (shorts at DC), inductors (a DC
    short), capacitors (open).
  - **Transient** (`schem emit zig FILE -transient -duration T -dt DT
    ?-events {t {op SW} …}?`) — a time-stepping solver with backward-Euler
    companion models (capacitors with ESR/leakage, inductors and inductive
    relay coils with winding R), Newton for diodes each step, relays switching
    with the one-step lag, propagation delay and hysteresis, and timed
    **stimulus** (switches/buttons operated on a schedule) — the engine's
    transient analyser. It prints a table of node voltages over time. Two
    niches are not emitted in transient: transformer mutual coupling and
    mid-run protective tripping (a fuse/breaker conducts as intact); the
    engine covers both. Nothing diverges silently within scope.
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

Three committed samples of `schem emit zig`:

- `examples/voltage_divider.zig` — the divider, whose stamps
  (`stampG(a, 1, 2, 0.001)`, the 9 V source branch) solve to `N1 = 9 V`,
  `N2 = 6 V`, the same answer the engine computes.
- `examples/relay_and_gate.zig` — a relay AND gate (DC), emitting the relay
  metadata arrays and the fixed-point loop, so the generated program closes
  contacts and settles exactly as a relay machine does.
- `examples/relay_oscillator.zig` — the self-interrupting relay (transient),
  whose coil node prints `12, 0, 12, 0, …` over time — the same buzz the
  engine's `run()` produces.

## Verification

The emitted Zig is **compiled and run, and diffed against the electrical
engine**. With a Zig toolchain available (`SCHEM_ZIG=/path/to/zig`, or `zig`
on `PATH`), `tests/test_cir.tcl` emits the Zig, compiles + runs it, and
compares node-for-node:

- **DC**: the divider, a diode (Newton) and a relay AND gate (fixed-point).
- **Transient**: an RC charge, an RL ramp and the relay oscillator —
  step-for-step against the engine's `run()`.

These were verified against Zig 0.13.0; every case matches to within `1e-3`.
When no toolchain is present the compile-and-run tests **skip** cleanly, and a
second layer of defence remains: `dcref`, a Tcl backend that runs the same
fixed-point/Newton algorithm over the same `LowerDC` mapping, is always
checked against the engine.

## Where this is heading

The IR is the foundation for running very large grids at full speed (compile
once, run native) and the natural home for a compiled, fill-reduced
elimination schedule. The remaining transient edges (transformer mutual
coupling, mid-run protective tripping) are extensions, no IR or source
change. After that: more targets (C / WASM / HDL), each a sibling proc over
the same IR.
