# DIGITAL.md -- the FPGA-primitive digital kernel

Schem already has a *proven* clocked digital simulation kernel:
`::schem::backend::digseq` in `src/backend/digital.tcl`.  It carries relay and
memory state across clock cycles, settles a boolean fixed point each cycle
(reachability from supply rails + memory data-out), latches memory writes on
the rising clock edge, and is verified bit-for-bit against the analog MNA
engine.  The bombe (~500 components) is the existing proof it scales.

This document specifies how to **generalize** that kernel from relay / contact /
memory primitives to **FPGA primitives** (LUTs, flip-flops, gates, muxes, block
RAM) operating on a **digital netlist** of cells and 1-bit nets.  The point is
*not* to reinvent digseq, but to keep its exact shape -- *settle the
combinational cone, then latch the state elements on the clock edge, then
advance* -- and swap its primitive vocabulary.

> Status: this is a DESIGN + SKELETON.  `src/digital/cells.tcl` and
> `src/digital/simkernel.tcl` implement the anchored parts (LUT eval, basic-gate
> eval, `levelize`, `settle`); the sequential `tick` / `run` and most cell evals
> are documented stubs.  Nothing here is wired into the loader yet.

---

## 1. The shared digital-netlist IR contract (verbatim)

The importer (a separate agent / `yosys` front end) produces this; the kernel
consumes it.  Keep it EXACTLY this shape so importer and kernel stay compatible.

A design is a Tcl dict:

```
  name    <top module name>
  nbits   <number of distinct 1-bit nets; nets are integer ids 0..nbits-1;
           net 0 = const0, net 1 = const1 by convention>
  inputs  dict: signalName -> list of netIds (LSB first)
  outputs dict: signalName -> list of netIds (LSB first)
  clocks  list of netIds used as clocks
  cells   list of dicts, each:
          {name <inst> type <PRIM> params <dict> conn <dict port->listOfNetIds(LSB first)>}
          input ports READ nets, output ports DRIVE nets.
          LUT params: {k <int> init <2^k-bit truth table as wide int,
                       bit i = output for input combo i>}.
          DFF params: {clkpol 0|1 rstpol .. rstval .. async 0|1 ...}.
          MEM params: {abits dbits words rdsync 0|1 ...}.
```

**Net conventions.**  A net is a single bit.  Nets `0` and `1` are the constant
rails (`const0`, `const1`) -- the FPGA analogue of GND and VCC in digseq.  A
multi-bit *vector* is just an ordered list of net ids, LSB first, exactly as the
relay-logic `address` / `di` / `do` pin lists were in digseq.  There is no
separate multi-bit net object; a bus is a list of 1-bit nets, mirroring
`src/core/bus.tcl`'s rule that "a bus is N real conductors", not a wide type.

**Driver model.**  Each net is driven by exactly one cell output port (or is a
design input, or a constant rail).  This is the FPGA reality (one driver per
wire) and is *stronger* than digseq's reachability model -- so we do not need a
fixed-point reachability BFS; we can evaluate each cell once its inputs are
known.  See levelization (§4).

---

## 2. How this maps onto digseq (the kernel we are reusing)

digseq's per-cycle algorithm, abstracted:

| digseq step                                    | generalized step                              |
|------------------------------------------------|-----------------------------------------------|
| seed HIGH from VCC + memory data-out driving 1 | seed const0/const1 nets + DFF/MEM state outputs |
| BFS reachability through closed contacts       | evaluate combinational cells in topo order      |
| relays switch on a fixed point (iterate)       | combinational cone is acyclic -> one pass (§4)  |
| memory reads addressed cell every pass         | RAM async-read driven from state every settle   |
| memory latches write on rising clk edge        | DFF/MEM latch on the active clock edge (§3)      |
| carry `energized`/`cells`/`prevclk` between cycles | carry DFF Q-values / RAM contents / prevclk    |
| return `levels` (nid -> 0/1) + `state`         | return net values (nid -> 0/1) + `state`        |

The crucial structural reuse:

1. **State lives outside the cell, carried across cycles.**  digseq keeps
   `energized` (relay seal-in) and `cells` (memory) in a `state` dict threaded
   through every cycle.  We keep DFF Q-values and RAM contents the same way.
   A state element's *output* is read from the carried state at the **start** of
   settle (it is a source, like a memory data-out), and its *next* value is
   computed during settle and committed at the **end** of the cycle.

2. **Settle, then latch, then advance.**  digseq settles the boolean fixed
   point first, *then* (gated on `relays_stable`) performs the clocked write.
   We do the same: `settle` computes all combinational outputs and the D-inputs
   of every flip-flop from the *current* (start-of-cycle) state; only after
   settle do we sample those D-inputs and commit them as the new Q (§3).  This
   is the textbook "evaluate then update" that makes a shift register shift by
   one (not collapse), and it is exactly digseq's write gating.

3. **Edge detection by remembered clock level.**  digseq stores `prevclk` per
   memory and fires only on `clkH && !pc`.  DFFs use the identical mechanism,
   generalized for clock polarity (§3).

The key *simplification* over digseq: with one-driver-per-net, the combinational
part is a DAG, so `settle` is a single topological pass (§4) instead of a 1000-
iteration fixed point.  Sequential feedback (Q -> logic -> D) is broken by the
flip-flop, exactly as in hardware -- the DFF output is a *settled source*, the
DFF input is a *sink sampled after settle*.

---

## 3. The primitive cell set and exact eval semantics

All cells take their inputs as already-resolved 0/1 net values (LSB-first lists
for vectors) and produce 0/1 outputs.  Two-state now; §6 covers X / 4-state.

### Combinational cells (evaluated during `settle`, topo order)

**LUT-k** -- `type LUT`, `params {k init}`.
A `k`-input lookup table = a `2^k`-bit truth-table ROM.  Inputs `I` is a
`k`-element LSB-first list of bits; form the index
`idx = I[0] + 2*I[1] + ... + 2^(k-1)*I[k-1]`; the output bit is bit `idx` of
`init`: `O = (init >> idx) & 1`.  This is the single most important cell: every
combinational function a synthesizer emits is a LUT, so getting this exactly
right (and matching the importer's bit numbering) anchors the whole contract.
Ports: `I` (k bits in), `O` (1 bit out).  *Implemented for real.*

**Basic gates** -- `type AND|OR|XOR|NAND|NOR|XNOR|NOT|BUF`.
Bitwise over equal-width vector inputs `A`,`B` (NOT/BUF take only `A`).  Output
`Y` is the same width.  Semantics are the obvious Boolean ops per bit.  These
exist so a netlist need not LUT-wrap trivial logic, and so we can cross-check
LUTs against gates.  *Implemented for real (see `Gate` in cells.tcl).*

**MUX** -- `type MUX`, `params {width}`.
2:1 multiplexer per bit: `Y[i] = S ? B[i] : A[i]`, where `S` is a single select
bit.  Wide muxes (4:1, ...) are built from 2:1 trees by the importer, so one
primitive suffices.

### State cells (sampled after `settle`, committed on the active edge in `tick`)

All flip-flops share: a clock net `CLK`, clock polarity `clkpol` (1 = rising
edge active, 0 = falling), a data input `D`, an output `Q` (width 1 unless the
importer vectorizes; we treat each Q-bit as its own state slot).

**DFF** -- `type DFF`, `params {clkpol}`.
On the active clock edge, `Q <- D`.  Edge = transition of `CLK` to its active
level since last cycle (the `prevclk` trick from digseq, but polarity-aware:
rising = `clk && !prev` for clkpol 1, falling = `!clk && prev` for clkpol 0).

**DFFE** -- `type DFFE`, `params {clkpol enpol}`.
DFF with a clock *enable* `EN`.  On the active edge, `Q <- D` **iff** `EN` is at
its active level (`enpol`); otherwise `Q` holds.  This is digseq's `we`
(write-enable) gate applied to a flip-flop.

**SDFF** -- `type SDFF`, `params {clkpol rstpol rstval}`.
DFF with *synchronous* reset `R`: on the active clock edge, if `R` is active
(`rstpol`) then `Q <- rstval`, else `Q <- D`.  Reset only takes effect *at* the
edge -- it is sampled like data.

**ADFF** -- `type ADFF`, `params {clkpol rstpol rstval}`.
DFF with *asynchronous* reset `R`: while `R` is at its active level, `Q` is
forced to `rstval` regardless of the clock (checked every settle, like a level,
not an edge); otherwise behaves as DFF on the edge.  Async reset is the one case
where a state output can change *within* a cycle without a clock edge, so it is
applied both as a settle-time override of the carried Q and as the committed
value.

**DLATCH** -- `type DLATCH`, `params {enpol}`.
Level-sensitive D latch (not edge): while enable `G` is active (`enpol`), `Q`
follows `D` transparently; while inactive, `Q` holds.  This is the direct
analogue of digseq's gated D-latch test.  Because it is transparent, its output
is recomputed during `settle` (it is *not* purely a start-of-cycle source); a
latch in a combinational loop is a known synthesis hazard and is reported by
loop detection (§4).

### Memory

**MEM** -- `type MEM`, `params {abits dbits words rdsync wrports ...}`.
Block RAM.  `words` cells of `dbits` each (default `2^abits`).  This is digseq's
`memory` class generalized:

- **Read port(s):** address `RADDR` (abits, LSB-first), data `RDATA` (dbits).
  `rdsync 0` = *asynchronous* read: `RDATA` reflects the addressed word during
  `settle` (combinational, exactly digseq's read).  `rdsync 1` = *synchronous*
  read: the addressed word is captured into an output register on the active
  clock edge and presented next cycle (a registered read = MEM + an internal
  DFF row; committed in `tick`).
- **Write port(s):** one or more `{WADDR WDATA WE WCLK}` groups.  On the active
  `WCLK` edge with `WE` active, `cells[WADDR] <- WDATA`.  This is digseq's
  rising-edge addressed write, verbatim, allowing `wrports > 1`.

Initial contents come from `params.init` (list of words) if present, else all-0.

---

## 4. Levelization and combinational-loop detection

Because every net has exactly one driver, the combinational cells form a DAG
once we **cut every state element**.  `levelize` (in `simkernel.tcl`):

1. Treat as a *source* (level 0, always-known): design inputs, constant rails,
   and **the output nets of every state cell** (DFF/SDFF/ADFF/DFFE Q, and the
   read-data nets of an *async* MEM read are driven from carried state, *sync*
   read outputs are also state).  These are known at the start of each cycle.
2. For each remaining **combinational** cell, it becomes evaluable once *all*
   its input nets are driven by already-evaluated cells or sources.  Repeatedly
   emit any cell whose inputs are all ready (Kahn's algorithm), producing an
   eval order.
3. If a pass makes no progress but cells remain, those cells form a
   **combinational loop** (e.g. a chain of LUTs feeding back with no flip-flop,
   or a transparent DLATCH ring).  `levelize` returns them in a `loops` list so
   the caller can report the offending instances rather than spin forever.  This
   is the principled replacement for digseq's 1000-iteration cap: a real
   combinational loop is a *design error*, not something to relax to a fixed
   point.

`levelize` returns `{order {cellName ...} loops {cellName ...}}`; it is computed
once per design (topology is static) and reused every cycle.

A note on DLATCH: a transparent latch is combinational *within* a cycle, so it
participates in levelization; a latch whose D depends on its own Q (a ring) is
correctly flagged as a loop.

---

## 5. The cycle loop

### Single clock (implemented first)

```
levelize once  -> order, loops      (error if loops non-empty)
state = {}      (DFF Q-values, RAM contents, prevclk per clock)
for each cycle:
    1. apply this cycle's input stimulus (the -events schedule, by cycle number)
    2. settle:  netval = inputs + const rails + state outputs;
                evaluate combinational cells in `order`, filling netval.
    3. latch:   for each state cell, determine if its clock saw the active edge
                this cycle (clk level now vs carried prevclk, polarity-aware);
                if so sample its (settled) D / addressed write and compute new Q
                / new RAM word.  Async resets/transparent latches already applied
                in settle are committed here.
    4. advance: commit new Q-values and RAM words into `state`; record each
                clock's level as prevclk for next cycle.
    5. trace:   optional callback(cycle, netval) for waveform capture.
```

Steps 2-4 are digseq's settle / UpdateMemory / latch-prevclk, one-to-one.
`tick` performs one such cycle; `run N` loops it.

### Multi-clock (the extension)

`clocks` may list several clock nets.  Each state cell names *its* clock.  The
generalization: track `prevclk` per clock net (digseq already keyed prevclk per
*memory*; we key per *clock net*), and in the latch step ask each state cell
whether *its* clock saw an active edge this cycle.  A single global cycle can
therefore advance some domains and not others.  Cross-domain paths (a net driven
in domain A, sampled by a DFF in domain B) are the classic CDC hazard; for now
we evaluate at the granularity of one global cycle = one event on every clock,
and leave finer event ordering (a true event queue keyed by clock edges) as
future work.  The single-clock loop is the special case where `clocks` has one
entry and every cycle is one edge of it.

---

## 6. State model: 2-state now, X / 4-state + power-on-reset later

We start **2-state** (every net is 0 or 1), exactly like digseq, because the
verification target (the MNA engine and the existing relay tests) is 2-state.

The planned extension to **4-state** (`0 1 X Z`):

- Nets initialize to `X` (unknown) at power-on rather than 0; a DFF with no
  reset holds `X` until first clocked or reset.  This catches designs that rely
  on uninitialized state.
- LUT/gate eval becomes X-pessimistic: any X input that the function depends on
  yields X (with the standard exceptions, e.g. `0 AND X = 0`).
- `Z` (high-impedance) appears only on tri-stated/bus nets; with one-driver-per-
  net it is rare, but a multi-driver bus (digseq's tri-state buffers) resolves
  by the usual `Z` rules.
- **Power-on reset**: ADFF/async-clear nets asserted for the first few cycles to
  drive known state, matching how real FPGAs come out of configuration.

The IR does not change for 4-state; only `netval` widens from `{0,1}` to
`{0,1,X,Z}` and the eval procs gain X-propagation.  Keeping eval semantics in
one place (`cells.tcl`) makes this a localized change.

---

## 7. The Zig emitter extension (verified == interpreted)

digital.tcl already shows the pattern: `ZigDigitalSeq` emits a `State`-style Zig
program -- persistent arrays for relay `energized`, per-memory `cells` /
`prevclk` / `wrote`, a `settle()` that reaches a fixed point, and a `main()` that
runs a compiled-in `-events` schedule and prints every net each cycle.  The
generalized emitter mirrors this kernel:

- **State struct.**  One `var` array per state kind: `dff_q: [NDFF]bool`,
  per-MEM `m<i>_cells: [words][dbits]bool`, and `prevclk: [NCLK]bool`.  These are
  the carried-across-cycles values, the direct analogue of `energized`/`cells`.
- **`settle()`.**  Instead of a reachability BFS, emit straight-line code in the
  levelized `order`: for each combinational cell, one statement computing its
  output net(s) from its input nets.  A LUT becomes an indexed load from a
  comptime-known `[2^k]bool` table; a gate becomes a Boolean expression; a MUX a
  `select`.  Because the order is topological, no iteration is needed -- this is
  *faster* than digseq's loop and provably terminates.
- **`tick()`.**  Call `settle()`, then for each state cell test its clock edge
  (`clk[c] and !prevclk[c]` for clkpol 1) and assign `dff_q[i] = d_net` /
  `m<i>_cells[addr] = wdata`.  Then `prevclk = clk` -- digseq's exact
  latch-prevclk step.
- **`main()`.**  The compiled `-events` schedule sets input nets per cycle, calls
  `tick()`, prints nets -- identical structure to `ZigDigitalSeq`'s main loop.

**Verification (Schem's house style).**  Emit the Zig program, run it, run the
*same* design + same stimulus through this interpreted kernel, and diff the
per-cycle net values.  They must match bit-for-bit every cycle, exactly as
`ZigDigital` is verified against the MNA solve ("emit both, run both, diff").
The interpreted kernel is the spec the Zig emitter transcribes; the LUT-vs-gate
cross-check (a LUT loaded with a gate's truth table must equal that gate) is the
within-kernel analogue of the engine-vs-digref check.

---

## 8. Open questions for integration

- **Vector representation.** `netval` is currently a per-net dict (nid -> bit),
  matching digseq's `levels`.  For wide arithmetic, caching vectors as Tcl wide
  ints may be faster; the eval procs accept LSB-first bit lists either way.
- **Multi-write-port arbitration.** Simultaneous writes to one MEM address on the
  same edge: pick a documented priority (lowest port index wins?) -- the IR
  permits `wrports > 1` but the importer must say the rule.
- **Sync-read MEM as a sub-DFF.** Whether to model a synchronous read port as an
  explicit internal DFF row (cleaner, reuses DFF latch path) or inline in MEM.
- **Clock as data.** A net used both as a clock and read as ordinary logic --
  digseq allowed it; confirm the importer keeps `clocks` and combinational use
  consistent.
