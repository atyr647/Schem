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

- **`zig`** — emits a self-contained Zig program that solves the **DC
  operating point** by Modified Nodal Analysis (straight-line conductance and
  source stamps + a Gaussian-elimination solver), then prints the node
  voltages. It covers the linear DC elements at their stated device state
  (resistors, batteries with ESR, closed switches, ammeters, gauged wires,
  fuses/breakers, inductors as a DC short, capacitors open). Elements that
  need the nonlinear / stateful / transient code-gen layer (diodes, relays,
  transformers) are reported as unsupported — the IR already carries their
  parameters for when that layer is built.
- **`dcref`** — a reference backend, in Tcl, that solves the DC operating
  point *straight from the IR* (the same lowering the emitters use). It proves
  the IR carries enough to reproduce the solve, and is the oracle the code
  emitters are checked against: `tests/test_cir.tcl` asserts `dcref` matches
  the electrical engine node-for-node.

> Note: the emitted Zig is generated and structurally tested here, but not
> compiled (no Zig toolchain in this environment). Its correctness rests on
> the shared lowering — `dcref` exercises exactly the same `LowerDC` mapping
> and is verified numerically against the engine.

## Example

`examples/voltage_divider.zig` is a committed sample of `schem emit zig` for
the divider. The relevant generated MNA stamps:

```zig
// R1 (resistor)
a[0 * SZ + 0] += 0.001;   a[1 * SZ + 1] += 0.001;
a[0 * SZ + 1] -= 0.001;   a[1 * SZ + 0] -= 0.001;
// R2 (resistor)
a[1 * SZ + 1] += 0.0005;
// branch B (the 9 V source)
a[0 * SZ + 2] += 1.0;     a[2 * SZ + 0] += 1.0;   z[2] = 9.0;
```

solving to `N1 = 9.0 V`, `N2 = 6.0 V` — the same divider the engine computes.

## Where this is heading

The IR is the foundation for the native backend (the answer to running very
large grids at full speed) and the natural home for a compiled, fill-reduced
elimination schedule. The next code-gen layers — Newton (diodes), the
fixed-point relay loop (with the hysteresis/delay the IR already carries), and
transient stepping (companion models) — extend the Zig backend without
changing the IR or the source.
