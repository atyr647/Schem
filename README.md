# Schem ⌁

**A visual electrical programming language, with a working interpreter
that obeys the fundamental rules of electricity.**

In Schem the *schematic is the source code*. There are no functions,
variables, loops, or modules — only electrical parts (batteries, wires,
switches, relays, resistors, capacitors, inductors, diodes, fuses,
breakers) wired into circuits. Behavior emerges from continuity and
current flow, exactly as it does on a real workbench.

- **The language definition** lives in [`docs/LANGUAGE.md`](docs/LANGUAGE.md).
- **The architecture** (source = schematic object model; netlist = derived
  cache) is in [`docs/ROADMAP.md`](docs/ROADMAP.md), the binary `.schem`
  file in [`docs/FORMAT.md`](docs/FORMAT.md), the interactive editor +
  validator in [`docs/EDITOR.md`](docs/EDITOR.md), the relay logic
  library (the universality proof) in [`docs/LOGIC.md`](docs/LOGIC.md), and
  the standard panel circuits in [`docs/STANDARD.md`](docs/STANDARD.md),
  and the Circuit IR + backends in [`docs/IR.md`](docs/IR.md).
- **The interpreter** is a Tcl circuit engine in [`src/`](src/) that
  reads a schematic and solves it with real circuit theory:
  continuity (closed loops), Ohm's law, Kirchhoff's current & voltage
  laws, a ground reference, and correct device behavior.
- **How the engine works** is documented in
  [`docs/INTERPRETER.md`](docs/INTERPRETER.md).

## The source is the schematic

A Schem program is a **schematic object model**, saved as a binary
`.schem` project file — not text, not JSON, not an image. The interpreter,
viewer and (future) editor all consume that same object; a derived
netlist/IR is only a build-time cache.

```
.schem (binary object model = SOURCE)
   │  open in the viewer            │  derive
   ▼                                ▼
 wired box diagram (a view)      netlist / IR (a cache) ──▶ interpreter / backends
```

```sh
$ schem save examples/voltage_divider.schem.tcl divider.schem   # author -> object model
$ schem open divider.schem                                       # opens visually
Schematic: voltage_divider_schem

┌───────────┐       ┌───────────┐       ┌───────────┐       ┌───────────┐
│B:battery  │──────▶│R1:resistor│──────▶│R2:resistor│──────▶│GND:ground │
└───────────┘       └───────────┘       └───────────┘       └───────────┘

$ schem edit divider.schem        # author it interactively (place/wire/solve)
$ schem validate divider.schem    # anti-spaghetti + electrical checks
```

This is not a drawing that *looks* electrical — every result is computed
by **Modified Nodal Analysis** with Newton iteration for nonlinear devices
(diodes) and a fixed-point loop for stateful devices (relays, fuses,
breakers). Capacitors and inductors are time-stepped with companion
models.

---

## Requirements

A Tcl interpreter (Tcl 8.6+, which ships with TclOO):

```sh
sudo apt-get install tcl        # Debian/Ubuntu
```

No other dependencies.

## Quick start

Run an example schematic through the command-line interpreter:

```sh
$ tclsh bin/schem examples/voltage_divider.schem.tcl
Schematic: voltage_divider.schem
Nodes (voltages, ground = 0 V):
  node 0 (GND)      0.0000 V   {B.neg GND.t R2.b}
  node 1            9.0000 V   {B.pos R1.a}
  node 2            6.0000 V   {R1.b R2.a}
Currents:
  B            battery      0.00300 A
  R1           resistor     0.00300 A
  R2           resistor     0.00300 A
Faults: none
```

Or build one yourself. A schematic is created with the workbench API:

```tcl
package require Tcl
source src/schem.tcl

set s [schem::new divider]
$s add battery  B  -emf 9      ;# a 9 V source
$s add ground   GND            ;# the 0 V reference
$s add resistor R1 -r 1000
$s add resistor R2 -r 2000

$s wire B.pos R1.a             ;# connect terminals (continuity)
$s wire R1.b  R2.a
$s wire R2.b  GND.t
$s wire B.neg GND.t

$s solve
puts "Vout = [$s probe R1.b] V"     ;# -> 6.0
puts "I    = [$s current R1] A"     ;# -> 0.003
```

## What it gets right (the physics)

The regression suite in [`tests/test_schem.tcl`](tests/test_schem.tcl)
checks each fundamental rule against a hand-computed value:

| Rule / behavior            | Demonstrated by                                   |
|----------------------------|---------------------------------------------------|
| Ohm's law                  | 9 V / 1 kΩ → 9 mA                                  |
| Kirchhoff voltage law      | series resistors share one loop current; dividers |
| Kirchhoff current law      | parallel branch currents sum at the node          |
| Continuity                 | an open switch carries no current                 |
| Conditional routing        | a relay coil closes an isolated contact (no `if`) |
| One-way flow               | a diode conducts forward (~0.7 V), blocks reverse |
| Irreversible faults        | a fuse blows on over-current and cannot reset     |
| Resettable limits          | a breaker trips on over-current and resets        |
| Short-circuit detection    | an ideal short across a source is reported        |
| Source realism             | a battery sags under load and bounds its own short-circuit current (`esr`) |
| Wire resistance / ampacity | a gauged run drops voltage (AWG ×length) and faults over its rating |
| Capacitance (state/timing) | RC charging tracks `E(1−e^{−t/RC})`; ESR and leakage too |
| Inductance (inertia)       | RL current ramps as `I_max(1−e^{−tR/L})`; winding resistance too |
| Relay hysteresis           | a coil holds in between its drop-out and pick-up currents |
| Propagation delay          | contacts lag the coil by the operate time; brief glitches are ignored |
| Inductive coil / kickback  | coil current ramps (L/R); interrupting it spikes — a flyback diode clamps it |
| Diode realism              | series resistance, and reverse breakdown (a Zener clamps) |
| Inverse-time protection    | a fuse/breaker with an `i2t` curve blows faster the bigger the overload |
| Transformer                | coupled windings step voltage by the turns ratio `√(L2/L1)` |
| Power & energy             | `P = VI` (dissipated/delivered); `½CV²`, `½LI²` stored |
| Emergent oscillation       | a relay wired through its own NC contact buzzes   |
| Scale hierarchy            | a circuit → panel → grid flattens and solves      |
| **Computational universality** | relay gates → XOR → an 18-relay **full adder**; a seal-in **latch** holds a bit |
| **Sequential logic** | edge-triggered flip-flops → a 16-relay **2-bit counter** counting 00,01,10,11 |
| **Standard panel circuits** | on/off-delay timers, one-shot, debounce, flasher, relay bank, safety interlock |

Run them (116 tests total):

```sh
$ tclsh tests/test_schem.tcl     # 44: the electrical laws + device realism
$ tclsh tests/test_format.tcl    #  9: binary round-trip, harness, IR, viewer
$ tclsh tests/test_tools.tcl     # 17: validator + interactive editor
$ tclsh tests/test_logic.tcl     # 10: relay gates, adder, latch (universality)
$ tclsh tests/test_seq.tcl       #  8: D latch, flip-flops, binary counter
$ tclsh tests/test_standard.tcl  #  7: timers, one-shot, debounce, flasher, bank, interlock
$ tclsh tests/test_catalog.tcl   #  9: register, adder, counter, decoder, selector, accumulator, sequencer, computer
$ tclsh tests/test_cir.tcl       # 12: circuit IR + Zig/dcref backends (DC: linear, diode, relay)
```

## Examples

| File                                   | Shows                                        |
|----------------------------------------|----------------------------------------------|
| `examples/voltage_divider.schem.tcl`   | Ohm's law + KVL                              |
| `examples/safety_interlock.schem.tcl`  | series switches as a guard chain (AND)       |
| `examples/relay_and_gate.schem.tcl`    | relay logic: two coils → logical AND         |
| `examples/rc_timer.schem.tcl`          | a capacitor timer (transient)                |
| `examples/relay_oscillator.schem.tcl`  | an emergent relay oscillator (transient)     |
| `examples/relay_logic.tcl`             | relay gates, a full adder, and a latch       |
| `examples/relay_counter.tcl`           | flip-flops and a 2-bit binary counter        |
| `examples/standard_circuits.tcl`       | timers, one-shot, debounce, flasher, bank    |
| `examples/device_realism.tcl`          | ESR, wire drop, coil kickback, Zener, I²t, transformer |
| `examples/accumulator.tcl`             | a register+adder running total (stateful arithmetic) |
| `examples/sequencer.tcl`               | counter+decoder control phases (FETCH/EXEC/...) |
| `examples/computer.tcl`                | a controlled multiplier panel that halts |
| `examples/grid.tcl`                    | panels composed into a grid (the full hierarchy) |
| `examples/voltage_divider.zig`         | a sample `schem emit zig` DC solver (generated) |
| `examples/relay_and_gate.zig`          | emitted Zig for a relay gate (fixed-point loop) |

## Repository layout

```
docs/LANGUAGE.md      the language definition (the manifesto / spec)
docs/ROADMAP.md       architecture: source object model, derived netlist
docs/FORMAT.md        the binary .schem project file
docs/INTERPRETER.md   engine internals + full API reference
src/schem.tcl         package entry point
src/solver.tcl        dense linear solver (Gaussian elimination)
src/engine.tcl        schematic object model + component metadata
src/simulate.tcl      nodal analysis, Newton + fixed-point solve, tools
src/transient.tcl     time-domain analysis (capacitors / inductors)
src/hierarchy.tcl     Component → Circuit → Panel → Grid
src/format.tcl        binary .schem save / load
src/netlist.tcl       derived netlist / IR (build cache)
src/compile.tcl       the Circuit IR (lowered, backend-agnostic compile target)
src/backend.tcl       interchangeable backends over the IR (zig, dcref)
src/render.tcl        the viewer (draws the schematic as a wired diagram)
src/validate.tcl      anti-spaghetti + electrical validation
src/editor.tcl        the interactive workbench (EditorSession)
lib/logic.tcl         relay standard-cell library (gates, adder, latch)
lib/standard.tcl      standard panel circuits (timers, one-shot, debounce, ...)
lib/catalog.tcl       circuit catalog (register, adder, counter, decoder, selector)
bin/schem             CLI front end (run/save/open/edit/validate/netlist)
examples/             runnable schematics
tests/                regression suites (engine, artifact, tools, logic, sequential)
```
