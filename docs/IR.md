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
| `memory` | RAM / ROM / tape | `abits`/`dbits`, `mode`, data-in / data-out / `WE` / `CLK` nodes; RAM carries address pins, a tape carries `LEFT`/`RIGHT` head-move pins (an unbounded store) |
| `buffer` | tri-state buffer | `in` / `oe` / `out` nodes, `vhigh`/`rout`; drives the bus when `oe` is high, else high-impedance (Hi-Z) so others can |

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
schem::emit $schematic zig                       ;# -> literal (electrical) Zig
schem::emit $schematic zig -digital              ;# -> digital (boolean) Zig
schem::emit $schematic zig -digital -cycles N …  ;# -> clocked digital (sequential)
schem::backends                                  ;# -> {dcref digref digseq zig}
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
    inductors (a DC short), capacitors (open), and memory chips (data-out
    drives the stored word through the output resistance, address/data/control
    pins are weak pull-downs — the power-on contents at a static operating
    point, since writes are clocked events, not part of a single DC solve).
  - **Transient** (`schem emit zig FILE -transient -duration T -dt DT
    ?-events {t {op SW} …}?`) — a time-stepping solver with backward-Euler
    companion models (capacitors with ESR/leakage, inductors and inductive
    relay coils with winding R), Newton for diodes each step, relays switching
    with the one-step lag, propagation delay and hysteresis, **fuses/breakers
    that blow on their `i2t` time-current curve** (instantaneous when `i2t`=0),
    and timed **stimulus** (switches/buttons operated on a schedule) — the
    engine's transient analyser. It prints a table of node voltages over time.
    The remaining niches are transformer mutual coupling and clocked memory in
    transient (the engine covers both — `run()` clocks a memory on its rising
    `CLK` edge and seals the word in); the emitter refuses them rather than
    diverge silently, so nothing diverges silently within scope.
  - **Digital** (`schem emit zig FILE -digital`) — for a *provably-digital*
    relay-logic circuit, a boolean cycle evaluator: a net is HIGH iff a
    closed-contact path reaches a supply rail (reachability), relays switch on
    a fixed point. It prints each node's logic level. This is **not** an
    electrical solve — it is a verified, semantics-preserving compilation that
    gives the **identical** HIGH/LOW result at O(nets+contacts) per pass
    instead of an O(n^x) matrix factorisation (measured ~3× faster native on a
    266-node adder, the gap widening with size). It also handles **tri-state
    buffers** sharing a bus — a buffer drives a 1 onto its output only when its
    output-enable is high (like a rail), otherwise releasing the line. It
    refuses non-digital parts (diodes/reactives/transformers) — use literal
    mode for those.
  - **Clocked digital** (`schem emit zig FILE -digital -cycles N ?-events
    {cycle {op SW} …}?`) — the *sequential* counterpart. Where plain digital
    settles one operating point, this **carries relay and memory state across
    clock cycles**: switches are runtime-mutable (the panel/clock, driven by a
    per-cycle `-events` schedule), and each cycle it settles the boolean fixed
    point — reachability from the rails *and* from any memory data-out driving a
    stored 1, relays switching, memory reading its addressed cell and latching a
    write on the rising `CLK` edge — then prints every node's level. This is how
    the fast boolean backend runs **latches, flip-flops, counters, RAM and an
    unbounded Turing tape**: a seal-in relay that was energised stays energised,
    a written cell keeps its word, the tape's head retraces over cells that
    persist, exactly as the engine's persistent state does. (The tape compiles
    to a window of `2·cycles+1` cells — the head moves at most one cell per
    cycle, so a finite run needs only finitely many, no gate explosion.)
    Verified cycle-for-cycle against the engine (and `digseq`).
- **`dcref`** — a Tcl reference for the *literal* mode: solves the DC operating
  point straight from the IR (the same lowering the emitters use), the oracle
  the literal emitters are checked against.
- **`digref`** — a Tcl reference for the *digital* mode: the same boolean
  cycle evaluation `zig -digital` emits, verified node-for-node against the
  electrical engine.
- **`digseq`** — a Tcl reference for the *clocked digital* mode: a **stateful**
  boolean evaluator that carries relay and memory state between cycles, the
  spec `zig -digital -cycles N` transcribes. Driven through a clock sequence it
  reproduces the engine's `solve`/`UpdateMemory`/`MemLatchClock` step for step,
  so a latch, counter or RAM gives the identical bit pattern every cycle.

> **The two-mode guarantee.** Literal mode is the trusted electrical truth and
> the default; digital mode is a verified optimization, never a shortcut. The
> check is total and automatic — *emit both, run both, diff*: on a digital
> circuit the compiled digital and literal programs (and the engine) must
> agree on every node's HIGH/LOW, which `tests/test_cir.tcl` asserts.
>
> Verified against Zig 0.13.0 (set `SCHEM_ZIG` or have `zig` on `PATH` and the
> compile-and-run tests execute; otherwise they skip cleanly).

## Examples

Committed samples of `schem emit zig`:

- `examples/voltage_divider.zig` — the divider, whose stamps
  (`stampG(a, 1, 2, 0.001)`, the 9 V source branch) solve to `N1 = 9 V`,
  `N2 = 6 V`, the same answer the engine computes.
- `examples/relay_and_gate.zig` — a relay AND gate (DC), emitting the relay
  metadata arrays and the fixed-point loop, so the generated program closes
  contacts and settles exactly as a relay machine does.
- `examples/relay_oscillator.zig` — the self-interrupting relay (transient),
  whose coil node prints `12, 0, 12, 0, …` over time — the same buzz the
  engine's `run()` produces.
- `examples/d_latch_seq.zig` — a D latch in **clocked digital** mode, carrying
  its held bit across six clock cycles (write 1, go transparent, hold, re-clock)
  — the same `Q` the engine settles each cycle.

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
- **Digital**: every logic gate, the half- and full-adder — the compiled
  digital and literal programs and the engine agreeing on every node.
- **Clocked digital**: a D latch held across clock cycles and a RAM
  write/read/reread sequence — the compiled clocked-digital program, `digseq`
  and the engine agreeing on every node, every cycle.

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
