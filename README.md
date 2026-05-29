# Schem ⌁

**A visual electrical programming language, with a working interpreter
that obeys the fundamental rules of electricity.**

In Schem the *schematic is the source code*. There are no functions,
variables, loops, or modules — only electrical parts (batteries, wires,
switches, relays, resistors, capacitors, inductors, diodes, fuses,
breakers) wired into circuits. Behavior emerges from continuity and
current flow, exactly as it does on a real workbench.

- **The language definition** lives in [`docs/LANGUAGE.md`](docs/LANGUAGE.md).
- **The interpreter** is a Tcl circuit engine in [`src/`](src/) that
  reads a schematic and solves it with real circuit theory:
  continuity (closed loops), Ohm's law, Kirchhoff's current & voltage
  laws, a ground reference, and correct device behavior.
- **How the engine works** is documented in
  [`docs/INTERPRETER.md`](docs/INTERPRETER.md).

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
| Capacitance (state/timing) | RC charging tracks `E(1−e^{−t/RC})`               |
| Inductance (inertia)       | RL current ramps as `I_max(1−e^{−tR/L})`          |
| Emergent oscillation       | a relay wired through its own NC contact buzzes   |
| Scale hierarchy            | a circuit → panel → grid flattens and solves      |
| Wire ampacity              | a gauged wire over its rating raises a fault      |

Run them:

```sh
$ tclsh tests/test_schem.tcl
test_schem.tcl:	Total	23	Passed	23	Skipped	0	Failed	0
```

## Examples

| File                                   | Shows                                        |
|----------------------------------------|----------------------------------------------|
| `examples/voltage_divider.schem.tcl`   | Ohm's law + KVL                              |
| `examples/safety_interlock.schem.tcl`  | series switches as a guard chain (AND)       |
| `examples/relay_and_gate.schem.tcl`    | relay logic: two coils → logical AND         |
| `examples/rc_timer.schem.tcl`          | a capacitor timer (transient)                |
| `examples/relay_oscillator.schem.tcl`  | an emergent relay oscillator (transient)     |

## Repository layout

```
docs/LANGUAGE.md     the language definition (the manifesto / spec)
docs/INTERPRETER.md  engine internals + full API reference
src/schem.tcl        package entry point
src/solver.tcl       dense linear solver (Gaussian elimination)
src/engine.tcl       schematic model + component metadata
src/simulate.tcl     nodal analysis, Newton + fixed-point solve, tools
src/transient.tcl    time-domain analysis (capacitors / inductors)
src/hierarchy.tcl    Component → Circuit → Panel → Grid
bin/schem            command-line runner
examples/            runnable schematics
tests/test_schem.tcl regression suite
```
