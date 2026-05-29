# The circuit catalog

`lib/catalog.tcl` is the library of standard **electrical assemblies** an
engineer reuses when building larger machines — the parts you don't rebuild
from scratch every time. Each is an ordinary Schem *circuit*: a bounded group
of components exposing a terminal contract, built only from the relay logic
and sequential cells in `lib/logic.tcl` (which are themselves only relays,
contacts and pull-downs). Nothing here is a software abstraction; they
compose as **Component → Circuit → Panel → Grid**, and every output is
computed by the engine from Ohm's and Kirchhoff's laws.

```sh
source lib/logic.tcl ; source lib/catalog.tcl
tclsh tests/test_catalog.tcl
```

Each assembly takes a width `n`. The signal convention is the logic
library's: active-high levels (HIGH ≈ VCC, LOW ≈ 0 V), inputs drive coils,
outputs are levels — so assemblies chain directly, no glue.

| assembly | ports | what it is |
|----------|-------|-----------|
| `register n` | `D0..Dn-1 · CLK · Q0..Qn-1 NQ0..` | `n` edge-triggered D flip-flops on a common clock: captures `D` on the rising edge and holds it |
| `adder n` | `A0..An-1 B0..Bn-1 CIN · S0..Sn-1 COUT` | an `n`-bit ripple-carry adder (`SUM = A + B + CIN`) |
| `counter n` | `CLK · Q0..Qn-1` | an `n`-bit binary ripple counter (Q0 = LSB) |
| `decoder n` | `A0..An-1 · Y0..Y(2ⁿ-1)` | drives exactly one output HIGH, selected by the binary address (A0 most significant); a tree of SPDT contacts |
| `selector n` | `I0..I(2ⁿ-1) A0..An-1 · OUT` | a multiplexer: `OUT` follows the addressed input |
| `accumulator n` | `IN0..INn-1 CLK · Q0..Qn-1` | a register fed back through an adder: `Q := Q + IN` each clock (stateful arithmetic) |
| `sequencer n` | `CLK · P0..P(2ⁿ-1)` | a counter + decoder: one control line active per step, advancing each clock (a control unit) |

The `decoder` and `selector` share one builder, `Tree`, which wires a binary
tree of single-pole double-throw relay contacts — each relay's NC throw is
the "address bit = 0" branch and its NO throw the "= 1" branch — so `n`
address bits route VCC (decoder) or a data line (selector) to exactly one of
`2ⁿ` leaves. This is how real relay decoders are built.

## Composing upward

These assemblies build the proven machines, all still pure circuits:

- **Accumulator** (`accumulator`, `examples/accumulator.tcl`) = `register` +
  `adder` + a clock — adds an input into a running total each tick.
- **Instruction sequencer** (`sequencer`, `examples/sequencer.tcl`) =
  `counter` + `decoder` — steps through control phases, one line per step.
- **Computing panel** (`examples/computer.tcl`) = accumulator (datapath) +
  step counter and a seal-in HALT latch (control) + an operand (program): a
  controlled multiplier that computes `operand × n` by repeated addition and
  then halts. ~414 components, 132 relays — a real relay machine.
- **Computing grid** (`examples/grid.tcl`) = panels composed into a grid, the
  top of **Component → Circuit → Panel → Grid**: each component is addressed
  by its full path (`grid / panel / circuit / … / component`).

A register made of D flip-flops made of latches made of relays; an adder made
of full adders made of gates made of relays — the hierarchy doing its job.
