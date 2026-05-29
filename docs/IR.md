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
schem::emit $schematic zig            ;# -> literal (electrical) Zig
schem::emit $schematic zig -digital   ;# -> digital (boolean) Zig
schem::backends                       ;# -> {dcref digref zig}
```

The backends ship today:

- **`zig`** — emits a self-contained Zig program. Same source/IR, choose the
  *solver* it emits — **literal** (the electrical truth) or **digital** (a
  verified, far faster boolean evaluator for digital circuits). Three modes:
  - **DC** (`schem emit zig FILE`) — the **full DC operating point** by
    Modified Nodal Analysis, with the engine's loops: an **outer fixed-point**
    over relay state (coil current → pick-up/drop-out → which contact is
    closed) **and protective state** (a fuse blows / breaker trips on
    over-rating current — an irreversible fault the rest of the circuit then
    sees), and an **inner Newton over diodes** (Shockley + Zener, series
    resistance). Covers every element at its DC behaviour — resistors,
    batteries with ESR, switches, relays, diodes, ammeters, gauged wires,
    fuses/breakers (which can blow), transformer windings (shorts at DC),
    inductors (a DC short), capacitors (open).
  - **Transient** (`schem emit zig FILE -transient -duration T -dt DT
    ?-events {t {op SW} …}?`) — a time-stepping solver with backward-Euler
    companion models (capacitors with ESR/leakage, inductors and inductive
    relay coils with winding R), Newton for diodes each step, relays switching
    with the one-step lag, propagation delay and hysteresis, **fuses/breakers
    that blow on their `i2t` time-current curve** (instantaneous when `i2t`=0),
    and timed **stimulus** (switches/buttons operated on a schedule) — the
    engine's transient analyser. It prints a table of node voltages over time.
    The one remaining niche is transformer mutual coupling in transient (the
    engine covers it); nothing else diverges silently within scope.
  - **Digital** (`schem emit zig FILE -digital`) — for a *provably-digital*
    relay-logic circuit, a boolean cycle evaluator: a net is HIGH iff a
    closed-contact path reaches a supply rail (reachability), relays switch on
    a fixed point. It prints each node's logic level. This is **not** an
    electrical solve — it is a verified, semantics-preserving compilation that
    gives the **identical** HIGH/LOW result at O(nets+contacts) per pass
    instead of an O(n^x) matrix factorisation (measured ~3× faster native on a
    266-node adder, the gap widening with size). It refuses non-digital parts
    (diodes/reactives/transformers) — use literal mode for those.
- **`dcref`** — a Tcl reference for the *literal* mode: solves the DC operating
  point straight from the IR (the same lowering the emitters use), the oracle
  the literal emitters are checked against.
- **`digref`** — a Tcl reference for the *digital* mode: the same boolean
  cycle evaluation `zig -digital` emits, verified node-for-node against the
  electrical engine.

> **The two-mode guarantee.** Literal mode is the trusted electrical truth and
> the default; digital mode is a verified optimization, never a shortcut. The
> check is total and automatic — *emit both, run both, diff*: on a digital
> circuit the compiled digital and literal programs (and the engine) must
> agree on every node's HIGH/LOW, which `tests/test_cir.tcl` asserts.
>
> Verified against Zig 0.13.0 (set `SCHEM_ZIG` or have `zig` on `PATH` and the
> compile-and-run tests execute; otherwise they skip cleanly).

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

- **DC**: the divider, a diode (Newton), a relay AND gate (fixed-point) and
  an over-rating fuse that **blows** (`dcref` and compiled Zig).
- **Transient**: an RC charge, an RL ramp, the relay oscillator, a
  switch-gated charge (`-events`) and a fuse blowing on its `i2t` curve —
  step-for-step against the engine's `run()`.

These were verified against Zig 0.13.0; every case matches to within `1e-3`.
When no toolchain is present the compile-and-run tests **skip** cleanly, and a
second layer of defence remains: `dcref`, a Tcl backend that runs the same
fixed-point/Newton algorithm over the same `LowerDC` mapping, is always
checked against the engine.

## Where this is heading

The IR is the foundation for running very large grids at full speed (compile
once, run native) and the natural home for a compiled, fill-reduced
elimination schedule. The one remaining transient edge (transformer mutual
coupling) is an extension, no IR or source change. After that: more targets
(C / WASM / HDL), each a sibling proc over the same IR.
