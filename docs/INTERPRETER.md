# The Schem Interpreter

The reference interpreter is a small but real circuit engine written in
Tcl. It reads a schematic — components, terminals, and the wires that join
them — and computes the electrical state by obeying the fundamental rules
of electricity. This document covers how it works and the full API.

## How a schematic becomes a solution

The interpreter never executes text. Given a schematic it performs the
runtime cycle from the language definition (*find sources → trace
continuity → apply component behavior → propagate current → update state →
generate effects*) using **Modified Nodal Analysis (MNA)**:

1. **Continuity (nodes).** Ideal conductors — ungauged wires, bus and
   junction terminals — merge the terminals they touch into shared
   *nodes* using union-find. Every ground terminal collapses into **node
   0**, the `0 V` reference. This is continuity made concrete: terminals
   on the same node are electrically one point.

2. **Stamping.** Each remaining part contributes to a linear system
   `A x = z` whose unknowns are the node voltages and the branch currents
   of sources and ideal conductors:
   - **Resistors / relay coils** stamp a conductance `g = 1/R` (Ohm's law).
   - **Batteries** stamp a voltage-source branch (`V(pos) − V(neg) = EMF`).
   - **Closed switches/buttons, intact fuses, closed breakers, ammeters**
     are ideal conductors modelled as `0 V` branches, so their current is
     an explicit unknown that can be measured.
   - **Capacitors / inductors** stamp companion models (see Transient).
   - **Diodes** stamp a linearised companion, refreshed by Newton
     iteration.
   The matrix rows *are* Kirchhoff's current law at each node; the
   source-branch rows *are* Kirchhoff's voltage law.

3. **Solve.** The dense system is solved by Gaussian elimination with
   partial pivoting (`src/solver.tcl`). A singular system means a
   degenerate circuit — e.g. an ideal short across a source — and is
   reported as a **short-circuit fault** rather than a crash.

4. **Newton loop (nonlinear).** Diodes are nonlinear, so the solve is
   repeated, relinearising each diode about its latest junction voltage
   (with step limiting) until it converges.

5. **Fixed-point loop (stateful devices).** After a converged solve the
   engine re-evaluates devices whose *state* depends on the solution: a
   relay coil that now carries enough current energizes and flips its
   contacts; a fuse over its rating blows (permanently); a breaker over
   its rating trips (resettably). Any change triggers another solve, until
   the schematic settles. This is how conditional routing and latching
   *emerge* — there is no `if`.

The matrices are temporary scaffolding. The schematic stays the source of
truth.

## Workbench API

`source src/schem.tcl` then create a schematic:

```tcl
set s [schem::new myboard]     ;# returns a Schematic command
```

### Building

| Call | Effect |
|------|--------|
| `$s add TYPE NAME ?-param value ...?` | place a component |
| `$s wire A.pin B.pin ?-awg N?` | join two terminals (continuity); `-awg` makes it a measurable, ampacity-checked conductor |
| `$s set NAME key value` | change a parameter / state |
| `$s get NAME ?key?` | read parameters |
| `$s press/release NAME` | momentary button control |
| `$s open/close NAME` | switch control |
| `$s reset NAME` | reset a tripped breaker (a blown fuse cannot reset) |

### Solving & measuring (the test tools)

| Call | Returns |
|------|---------|
| `$s solve` | compute the DC operating point; returns a result dict |
| `$s probe A.pin` | node voltage at a terminal (V, vs. ground) — the **Probe** |
| `$s voltage A.pin B.pin` | potential difference (V) — the **Meter** (voltmeter) |
| `$s current NAME` | current through a part (A) — the **Meter** (ammeter) |
| `$s continuity A.pin B.pin` | `1/0`: is there a conductive path right now — the **Continuity Tester** |
| `$s faults` | list of fault dicts (blown fuse, tripped breaker, short, overload) |
| `$s energized NAME` | `1/0`: is a relay coil picked up |
| `$s report` | a formatted text summary of the whole solve |

### Transient analysis

```tcl
set data [$s run -duration 5.0 -dt 0.001 -record {C.a L Node.pin ...}]
```

Steps the schematic forward in time (backward-Euler companion models for
capacitors and inductors; relays switch with a one-step `dt` lag, which is
what lets oscillators oscillate). Returns a dict mapping `t` and each
recorded signal (a terminal → voltage, or a component → current) to a list
of samples.

A `-events` schedule works the panel's contacts over time — the bench
operator (or a cam-timer drum) closing and opening switches as the run
proceeds:

```tcl
set data [$s run -duration 0.02 -dt 5e-4 -record {OUT.t} \
    -events {0.001 {close IN}  0.008 {open IN}}]
```

Each entry is `time {operation ...}`, where the operation is any method on
the schematic (`close`/`open` a switch, `press`/`release` a button). Events
only change contact state, never topology, so the node map stays valid for
the whole run. This is how the time-based standard circuits (on/off-delay,
one-shot, debounce) are exercised — see `lib/standard.tcl`.

## Component catalog

`add TYPE NAME -param value`. Terminals are addressed as `NAME.pin`.

| Type | Terminals | Parameters (defaults) | Behavior |
|------|-----------|------------------------|----------|
| `battery` | `pos neg` | `emf 9.0`, `esr 0.0` | EMF source with internal resistance `esr`; terminal voltage sags as `emf − I·esr`, and `esr` bounds the short-circuit current at `emf/esr` |
| `ground` | `t` | — | the `0 V` reference (all grounds = node 0) |
| `resistor` | `a b` | `r 1000.0` | Ohm's law `V = I·R` |
| `capacitor` | `a b` | `c 1e-6`, `v0 0.0` | stores charge; open at DC, dynamic in transient |
| `inductor` | `a b` | `l 1e-3`, `i0 0.0` | opposes current change; short at DC |
| `switch` | `a b` | `state open` | ideal conductor when `closed` |
| `button` | `a b` | `state released` | ideal conductor when `pressed` |
| `relay` | `c1 c2 com no nc` | `coil 100.0`, `pickup 0.01`, `dropout 0.005`, `delay 0.0` | coil current ≥ `pickup` connects `com–no`, else `com–nc`; **hysteresis**: once picked up it holds in until the current falls below `dropout`; **propagation delay**: in transient the contacts move only after the coil condition persists for `delay` seconds (operate/release time), so a glitch shorter than `delay` is ignored |
| `breaker` | `a b` | `rating 10.0`, `state closed` | opens (trips) above `rating`; resettable |
| `fuse` | `a b` | `rating 1.0`, `state intact` | opens (blows) above `rating`; permanent |
| `diode` | `a k` | `is 1e-14`, `n 1.0` | one-way (Shockley); ~0.6–0.7 V forward drop |
| `bus` | `t` | — | shared node many parts attach to |
| `junction` | `t` | — | a connection point |
| `ammeter` | `a b` | — | a `0 V` series branch for current readout |

Relay coil current is read with `$s current K`; its contact current with
`$s current K.contact`.

## Scale hierarchy: Circuit → Panel → Grid

A reusable block is a schematic that **exposes ports**:

```tcl
proc make_divider {} {
    set c [schem::circuit divider]
    $c add resistor R1 -r 1000
    $c add resistor R2 -r 1000
    $c wire R1.b R2.a
    $c expose IN R1.a ; $c expose OUT R1.b ; $c expose GND R2.b
    return $c
}
```

`instantiate` flattens a child into a parent under an instance prefix and
returns its port → terminal map. Panels embed circuits; grids embed
panels — all by the same mechanism (`schem::circuit`, `schem::panel`,
`schem::grid` are aliases for a schematic):

```tcl
set panel [schem::panel P1]
$panel add battery B -emf 12
$panel add ground  GND
set u1 [$panel instantiate [make_divider] U1]    ;# -> {IN .. OUT .. GND ..}
$panel wire B.pos [dict get $u1 IN]
$panel wire [dict get $u1 GND] GND.t
$panel wire B.neg GND.t

set grid [schem::grid G]
$grid instantiate $panel BANK                    ;# whole panel embedded
$grid solve
$grid probe BANK/U1/R1.b                          ;# -> 6.0
```

Grounds are shared automatically across the whole assembly because all
ground terminals collapse to node 0. Panels and grids add organisation,
never new electrical behavior — exactly as the language definition
requires.

## Faults

`$s faults` returns a list of dicts, each with a `kind` and a
human-readable `detail`:

| `kind` | Meaning |
|--------|---------|
| `short` | ideal conductors form a loop with a source (infinite current) |
| `fuse-blown` | a fuse exceeded its rating and opened permanently |
| `breaker-tripped` | a breaker exceeded its rating and opened (resettable) |
| `wire-overload` | a gauged wire is carrying more than its AWG ampacity |
| `SCHEM NOGROUND` (error) | the schematic has no ground reference |
