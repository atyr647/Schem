# Buses, banks & repetition

The drafting layer that lets a board be described the way an electrical
engineer reads a print — without ever leaving the electrical model. Two
ideas, kept deliberately apart:

- **A bus is electrical.** It is a bundle of real conductors. Each lane
  carries a voltage and obeys every rule a wire does — drive two sources
  onto one lane and it is *contention*, not a quiet pick.
- **`repeat` and `bank` are construction shorthand, not behaviour.** They
  stamp out real components at *build* time and then disappear. The
  electricity is entirely in the components left behind. Repetition over
  *time* is never a primitive here — that is what clocks, counters and
  stepping switches are for.

```sh
tclsh tests/test_bus.tcl
```

## `bus NAME WIDTH` — a bundle of conductors

```tcl
$s bus DATA 8        ;# eight conductors: DATA#0 .. DATA#7
$s bus ALPHA 26      ;# a 26-lane alphabet cable
```

Each lane is a real `bus` component (a shared node many parts attach to) —
a ribbon cable, a backplane, a row of an LED matrix. Query a lane's
terminal with `lane`:

```tcl
$s lane DATA 3       ;# -> DATA#3.t
$s width DATA        ;# -> 8
```

## `bank NAME COUNT of TYPE …` — repeated physical components

```tcl
$s bank LAMP 26 of lamp -r 2000 -ion 0.0005   ;# 26 real lamps
$s bank REG  8  of capacitor -c 1e-6           ;# 8 storage cells
$s unit LAMP 7       ;# -> LAMP#7   (append .pin yourself)
```

`of` is a literal keyword, so the line reads like hardware. Every element
is a real component built with the same parameters.

## `connect LHS -> RHS` — bundle-aware wiring

Endpoints may be a single lane, every lane, a slice, a unit's pin, or a
plain terminal:

```
BUS[i]            one lane                    (scalar)
BUS[*]            every lane                  (vector)
BUS[a..b]         a slice                     (vector)
BANK[i].pin       one unit's pin              (scalar)
BANK[*].pin       every unit's pin            (vector)
BANK[a..b].pin    a slice of pins             (vector)
COMP.pin          a plain terminal            (scalar)
```

The rule is what a print does:

- **vector → vector** zips lane-wise (widths must match),
- **scalar → vector** fans the scalar out to every element (one clock net
  feeding every latch is real fan-out, not magic),

```tcl
$s connect ALPHA[*]   -> LAMP[*].a      ;# lane i to lamp i
$s connect LAMP[*].b  -> GND.t          ;# every cathode to ground
$s connect CLK.t      -> REG[*].clk     ;# one clock to all cells
$s connect DATA[0..3] -> OUT[4..7]      ;# a nibble across
```

A width mismatch is an error, not a silent truncation.

## `repeat VAR LO HI { BODY }` — schematic expansion

Runs the body once for each `VAR` in `LO..HI`, stamping real components and
wires. This is netlist generation; nothing about it survives into the
solved circuit:

```tcl
$s bank LAMP 26 of lamp
$s repeat i 0 25 {
    $s connect SELECT[$i] -> LAMP[$i].a
    $s connect LAMP[$i].b -> GND.t
}
```

Think of it as drawing the same sub-circuit 26 times by hand — the result
is 26 independent lamp circuits, not a loop that "runs".

> **Behavioural repetition is not this.** "Repeat until solved" is a
> *circuit*: a clock into a counter into a sequencer. `repeat` only ever
> lays out copper and parts.

## Discipline — a shared line needs a default

A floating bus is undefined, so give shared lines a pull:

```tcl
$s pulldown IRQ[*] 4700 GND.t    ;# every lane to ground through 4.7k
$s pullup   DATA[*] 10000 VCC.t  ;# every lane to a rail through 10k
```

And drive a shared bus with discipline — tri-state buffers enabled one at a
time, or open-collector devices that only pull low. Two drivers fighting
over a lane is reported by `validate`:

```
BUS CONTENTION: buffers A and B both drive node N simultaneously
```

## Why this stays honest

`bus` groups physical wires. `bank` makes repeated physical components.
`repeat` is a layout tool. None of them add a value that isn't a voltage on
a real net — so the schematic still reads as a circuit, and the saved
`.schem` contains only components and wires, exactly as before.
