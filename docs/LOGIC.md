# The relay standard-cell library

`lib/logic.tcl` builds digital logic out of nothing but relays — the way
relay computers did — and proves, by truth table, the language
definition's claim that **Schem is computationally universal**. No logic
is hard-coded anywhere: every gate is a contact network, and every output
is computed by the electrical engine obeying Ohm's and Kirchhoff's laws.

```sh
tclsh examples/relay_logic.tcl     # gates, a full adder, and a latch
tclsh tests/test_logic.tcl         # the truth tables, asserted
```

## Signal convention

Active-high levels: a logic value is a node voltage — **HIGH ≈ VCC**,
**LOW ≈ 0 V**. An input drives a relay coil (HIGH energises it); an output
is tied to VCC through contacts when HIGH and to GND through a pull-down
resistor when LOW. Because outputs are levels and inputs are coils, a
cell's `OUT` drives the next cell's input with no glue — cells chain
directly.

## How gates are just contacts (no `if`)

| gate | construction |
|------|--------------|
| `NOT`  | one **NC** contact: `VCC → com`, `nc → OUT` (HIGH only when de-energised) |
| `AND`  | **NO** contacts in **series**: `VCC → KA.no → KB.no → OUT` |
| `OR`   | **NO** contacts in **parallel** onto `OUT` |
| `NAND` | **NC** contacts in **parallel** onto `OUT` (De Morgan) |
| `NOR`  | **NC** contacts in **series** |

`NAND` alone is functionally complete, so these cells can express any
boolean function. The library then *composes* them:

- `xor_gate` = `AND( OR(A,B), NAND(A,B) )`
- `half_adder` = `SUM = XOR(A,B)`, `CARRY = AND(A,B)`
- `full_adder` = two half-adders + an `OR` → `SUM = A⊕B⊕Cin`, `COUT = carry`

A single `full_adder`, fully flattened, is an **18-relay, 71-component**
circuit — real binary arithmetic, solved as one electrical network in a
few milliseconds. This is the Component → Circuit → Panel → Grid hierarchy
doing its job: a `full_adder` is a circuit made of half-adder circuits
made of gate circuits made of relays.

## Memory: the latch

Combinational logic plus **state** is what makes a machine universal.
`sr_latch` is a seal-in (self-holding) relay: pressing `SET` energises the
coil, whose own NO contact then keeps it energised after `SET` is released;
opening the normally-closed `RST` switch drops it. `Q` is HIGH while
latched.

A bistable latch has *two* self-consistent DC states, so the engine carries
relay state across solves (and `powerReset` returns it to the de-energised
power-on condition). That persistence is the model of memory — the same
mechanism that lets the transient analyser run relay oscillators and
timers.

## Clocked (sequential) logic

Combinational gates plus the latch's memory are enough for a state machine,
but a *level* latch is transparent — it tracks its data the whole time the
gate is open. A machine wants to sample on a **clock edge**. Edge-triggering
is built the way relay computers did it: two oppositely-gated latches in
series (**master / slave**). The master is transparent while the clock is
low and the slave while it is high, so on the rising edge the master freezes
the value it last saw and the slave copies it — `Q` takes `D`'s value *at the
edge* and ignores `D` afterward.

| cell | construction |
|------|--------------|
| `d_latch`     | a **gated** latch: a clock relay's contact (`KC`) admits the data only while open; set/seal/reset are the latch above, now clock-gated. Transparent while `CLK` HIGH (`gate no`) or LOW (`gate nc`). |
| `d_flipflop`  | master `d_latch` (transparent on `CLK` low) → slave `d_latch` (transparent on `CLK` high); rising-edge triggered |
| `t_flipflop`  | a `d_flipflop` with `D` wired back to its own `¬Q` → `Q` toggles every edge |
| `counter2`    | two `t_flipflop`s; stage 1 is clocked by stage 0's `¬Q` → a 2-bit ripple counter, `Q1Q0` = 00,01,10,11,00,… |

The timing model is the engine's **persistent relay state**: each `solve`
settles one clock event and the seal-in hold carries a bit between solves,
so clocking is just `CLK` low → `solve` → `CLK` high → `solve`. The same
cells also run in the **transient analyser**, where a self-interrupting
relay is a free-running clock and the count advances in real (stepped) time
— a few `dt` after each edge, exactly like a real relay counter with finite
contact-propagation delay.

`counter2` is a **16-relay** machine (two flip-flops of two latches of four
relays), and it counts correctly purely by Ohm's and Kirchhoff's laws.

## Cell catalog

| builder | ports | function |
|---------|-------|----------|
| `not_gate`   | `A · OUT · VCC · GND`        | `OUT = ¬A` |
| `and_gate`   | `A B · OUT · VCC · GND`      | `OUT = A·B` |
| `or_gate`    | `A B · OUT · VCC · GND`      | `OUT = A+B` |
| `nand_gate`  | `A B · OUT · VCC · GND`      | `OUT = ¬(A·B)` |
| `nor_gate`   | `A B · OUT · VCC · GND`      | `OUT = ¬(A+B)` |
| `xor_gate`   | `A B · OUT · VCC · GND`      | `OUT = A⊕B` |
| `half_adder` | `A B · SUM CARRY · VCC · GND`| 1-bit add |
| `full_adder` | `A B CIN · SUM COUT · VCC · GND` | 1-bit add with carry |
| `d_latch`    | `D CLK · Q OUT NQ · VCC · GND` | gated 1-bit latch |
| `d_flipflop` | `D CLK · Q NQ · VCC · GND`   | rising-edge D flip-flop |
| `t_flipflop` | `CLK · Q NQ · VCC · GND`     | toggle (÷2) flip-flop |
| `counter2`   | `CLK · Q0 Q1 · VCC · GND`    | 2-bit binary counter |
| `sr_latch`   | `Q · VCC · GND` (+ `SET` button, `RST` switch) | 1 bit of memory |

## Usage

```tcl
source src/schem.tcl
source lib/logic.tcl

set s [schem::new board]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
set g [$s instantiate [schem::lib::full_adder] U1]   ;# embed the cell
$s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
# drive [dict get $g A], [dict get $g B], [dict get $g CIN] high/low, then:
$s solve
# read [dict get $g SUM] / [dict get $g COUT] as levels (> 6 V == HIGH)
```
