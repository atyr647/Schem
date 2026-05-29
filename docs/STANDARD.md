# The standard panel circuits

`lib/standard.tcl` is the library of named blocks every electrician keeps in
their head — time-delay relays, a one-shot, a contact debounce, a flasher
and a latching relay bank. They are not logic abstractions: each is an
ordinary circuit of coils, contacts, resistors and capacitors, and every
behaviour is computed by the engine from Ohm's and Kirchhoff's laws against
each relay's pick-up current.

```sh
tclsh examples/standard_circuits.tcl    # all six, drawn as timing strips
tclsh tests/test_standard.tcl           # the behaviours, asserted
```

## Timing is RC against a coil's pick-up

A relay coil picks up when its current reaches a threshold. Put an `R` and a
`C` in front of it and the *time* it takes to get there becomes the circuit's
function. So the time-based cells are observed with the transient analyser
(`run`), and their inputs are worked over time by a scheduled stimulus —
`run -events {t {close IN} ...}` — exactly like operating the panel by hand.

## Cell catalog

| builder | ports | function |
|---------|-------|----------|
| `on_delay_timer`  | `IN · OUT NC · VCC GND` | `OUT` energises a set time *after* `IN` (cap charges through `R` until the coil reaches pick-up) |
| `off_delay_timer` | `IN · OUT NC · VCC GND` | `OUT` energises at once, then *holds* a set time after `IN` drops (a diode charges the tank fast; the cap holds the coil up as it bleeds) |
| `one_shot`        | `IN · OUT NC · VCC GND` | a rising edge on `IN` makes one fixed-width pulse, however long `IN` stays up (capacitively coupled through a diode; the pulse ends as the cap charges) |
| `debounce`        | `IN · OUT NC · VCC GND` | a chattering contact yields one clean make — the cap integrates the bounce so the coil sees a single rise |
| `flasher`         | `OUT · VCC GND`         | a free-running pulse generator: the classic self-interrupting relay (coil fed through its own break contact), no external clock |
| `relay_bank`      | `Q1..Qn · VCC GND` (+ `SET1..SETn` buttons, `RST` switch) | a latching annunciator: `n` independent seal-in channels sharing one common reset |

Each timer takes optional `R`/`C` arguments after its name to set the time
constant, e.g. `on_delay_timer ton 100 5e-5`.

## How each one works (all contacts, no abstraction)

- **on-delay** — `IN → R → node → coil`, with a tank capacitor across the
  coil. The cap slows the node's rise, so the coil current crosses pick-up
  only after `R·C`; `OUT` is the relay's make contact.
- **off-delay** — `IN → diode → node → coil ∥ cap`. The diode lets the tank
  charge instantly when `IN` is high; when `IN` falls the diode blocks and
  the only discharge path is through the coil, holding it up until it bleeds
  below drop-out.
- **one-shot** — `IN → cap → diode → coil`, with a bleed resistor. The
  rising edge couples a current surge through the cap into the coil; as the
  cap charges the surge decays and the coil drops out — one pulse. The bleed
  re-arms the cap when `IN` falls.
- **debounce** — the on-delay RC, tuned so its time constant is longer than
  the bounce: brief openings can't discharge the tank enough to drop the
  coil, so the output makes a single solid transition.
- **flasher** — energising the coil opens the break contact that feeds it,
  which drops the coil, which closes the contact again, forever. The
  oscillation is emergent feedback plus the contact's switching lag.
- **relay bank** — each channel is a seal-in latch (a `SET` button picks the
  coil up; the coil's own make contact then holds it). All coils return to
  ground through one common `RST` contact, so opening it drops the whole
  bank at once.

## The bench stimulus (`run -events`)

`run` takes an optional `-events {time {op ...} ...}` schedule. Each `op` is
a method call on the schematic applied when the run reaches that instant —
`{close IN}`, `{open IN}`, `{press B}`, `{release B}`. It models the
operator (or a motor-driven cam timer) working the contacts over time, and
is what lets a single transient run show a debounce bouncing, a one-shot
firing on an edge, or an off-delay lingering after release. Events change
only contact state, never the wiring, so the circuit stays the same circuit.
