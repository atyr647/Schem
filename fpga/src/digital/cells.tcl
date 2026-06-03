# cells.tcl --
#
# The FPGA primitive cell set: the eval semantics of every digital netlist
# cell, one place.  This is the generalization of the relay/contact/memory
# vocabulary that `::schem::backend::digseq` (src/backend/digital.tcl) hard-
# codes -- where digseq knew only "relay coil" and "memory cell", this knows
# LUTs, flip-flops, gates, muxes and block RAM, the primitives a logic
# synthesizer emits for a software FPGA.
#
# WHY a separate cells layer: digseq baked each primitive's behaviour into its
# settle loop, so adding a primitive meant editing the loop.  An FPGA has a
# small fixed CELL SET but many instances; pulling each cell's truth into a
# registered `eval` proc keeps the cycle engine (simkernel.tcl) generic -- it
# only knows "evaluate this combinational cell" / "latch this state cell" -- and
# makes the future 2-state -> 4-state (X/Z) change a localized edit here
# (see docs/DIGITAL.md section 6).
#
# Convention: combinational eval procs take resolved input bits and return
# output bits; they are PURE (no state).  State cells expose two procs --
# `<T>_settle` (its current output, read from carried state, plus async
# overrides) and `<T>_next` (its committed value at a clock edge) -- mirroring
# digseq's "read every pass, latch on the edge" split.
#
# Bits are 0/1 (2-state for now).  A VECTOR is an LSB-first list of bits, the
# same shape digseq used for a memory's address/di/do pin lists.

namespace eval ::schem::digital {
    namespace export celltype cells eval_comb

    # CELLS -- the cell-type registry: PRIM -> descriptor dict.
    #   kind        comb | state          (does it hold value across cycles?)
    #   eval        proc name for a combinational cell (kind==comb)
    #   inports     port names that READ nets   (for levelization)
    #   outports    port names that DRIVE nets
    #   clocked     1 if it samples a clock edge (state cells)
    # The registry is what simkernel.tcl's levelize/settle dispatch on, exactly
    # as digseq's `switch [dict get $e class]` dispatched on electrical role.
    variable CELLS [dict create]
}

# celltype -- register a primitive.  Called at load time, once per cell kind.
proc ::schem::digital::celltype {prim desc} {
    variable CELLS
    dict set CELLS $prim $desc
}

# cells -- the registered primitive names (introspection / validation).
proc ::schem::digital::cells {} {
    variable CELLS
    return [dict keys $CELLS]
}

# ====================================================================
#  Combinational cells -- pure, evaluated during settle in topo order.
# ====================================================================

# LUT -- a k-input lookup table == a 2^k-bit truth-table ROM.  ANCHOR CELL.
#
# This is the single most important cell: every combinational function a
# synthesizer emits lowers to a LUT, so its bit numbering MUST match the
# importer's.  Contract (docs/DIGITAL.md section 3): inputs `in` is a k-element
# LSB-first list of bits; the index is
#     idx = in[0] + 2*in[1] + ... + 2^(k-1)*in[k-1]
# and the output is bit `idx` of the truth table `init`:
#     O = (init >> idx) & 1
# `params` carries {k init}.  Returns a 1-bit list (one output net).
#
# Fully implemented -- it anchors the eval contract the stubs below follow.
proc ::schem::digital::LUT_eval {params in} {
    set k [dict get $params k]
    set init [dict get $params init]
    if {[llength $in] != $k} {
        return -code error "LUT expects $k inputs, got [llength $in]"
    }
    set idx 0
    for {set i 0} {$i < $k} {incr i} {
        if {[lindex $in $i]} { set idx [expr {$idx | (1 << $i)}] }
    }
    return [list [expr {($init >> $idx) & 1}]]
}

# Gate -- the basic Boolean gates, bitwise over equal-width vectors.  ANCHOR.
#
# One proc serves AND/OR/XOR/NAND/NOR/XNOR/NOT/BUF plus the two compound 2-input
# gates ANDNOT/ORNOT: `op` selects the function, `a`/`b` are LSB-first bit lists
# (NOT/BUF ignore `b`).  Output is the same width as the inputs.  These exist so
# trivial logic need not be LUT-wrapped, and so a LUT can be cross-checked
# against the gate whose truth table it holds (the within-kernel verification of
# docs/DIGITAL.md section 7).
#
# ANDNOT/ORNOT match the Yosys $_ANDNOT_/$_ORNOT_ cells (simcells.v):
#   ANDNOT: Y = A & ~B    ORNOT: Y = A | ~B
#
# Fully implemented.
proc ::schem::digital::Gate_eval {op a {b {}}} {
    set n [llength $a]
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        set x [lindex $a $i]
        set y [lindex $b $i]
        switch $op {
            AND    { lappend out [expr {($x & $y) & 1}] }
            OR     { lappend out [expr {($x | $y) & 1}] }
            XOR    { lappend out [expr {($x ^ $y) & 1}] }
            NAND   { lappend out [expr {!($x & $y) & 1}] }
            NOR    { lappend out [expr {!($x | $y) & 1}] }
            XNOR   { lappend out [expr {!($x ^ $y) & 1}] }
            NOT    { lappend out [expr {!$x & 1}] }
            BUF    { lappend out [expr {$x & 1}] }
            ANDNOT { lappend out [expr {($x & !$y) & 1}] }
            ORNOT  { lappend out [expr {($x | !$y) & 1}] }
            default { return -code error "unknown gate op: $op" }
        }
    }
    return $out
}

# AOI/OAI -- the compound and-or-invert / or-and-invert gates a standard-cell
# mapper (Yosys abc -g ...,AOI3,...) emits.  Single-bit (1-bit ports), matching
# Yosys $_AOI3_/$_OAI3_/$_AOI4_/$_OAI4_ exactly (simcells.v):
#   AOI3: Y = ~((A & B) | C)            OAI3: Y = ~((A | B) & C)
#   AOI4: Y = ~((A & B) | (C & D))      OAI4: Y = ~((A | B) & (C | D))
# NOTE: Yosys $_OAI4_ is ~((A|B)&(C|D)) -- an OR on the (C,D) leg, not an AND.
# Each proc takes resolved single bits and returns a 1-bit list (one output net).
proc ::schem::digital::AOI3_eval {a b c} {
    return [list [expr {!(($a & $b) | $c) & 1}]]
}
proc ::schem::digital::OAI3_eval {a b c} {
    return [list [expr {!(($a | $b) & $c) & 1}]]
}
proc ::schem::digital::AOI4_eval {a b c d} {
    return [list [expr {!(($a & $b) | ($c & $d)) & 1}]]
}
proc ::schem::digital::OAI4_eval {a b c d} {
    return [list [expr {!(($a | $b) & ($c | $d)) & 1}]]
}

# NMUX -- inverting 2:1 mux, matching Yosys $_NMUX_ (simcells.v): Y = ~(S?B:A)
# (= S ? !B : !A).  `sel` is a single bit; `a`,`b` are equal-width LSB-first bit
# lists.  Output is the same width as the inputs.
proc ::schem::digital::NMUX_eval {sel a b} {
    set src [expr {$sel ? $b : $a}]
    set out {}
    foreach x $src { lappend out [expr {!$x & 1}] }
    return $out
}

# MUX -- per-bit 2:1 multiplexer: Y[i] = sel ? b[i] : a[i].
#
# `sel` is a single bit; `a`,`b` are equal-width LSB-first bit lists.  Wide and
# n:1 muxes are built from 2:1 trees by the importer, so this one primitive
# suffices.  Implemented (trivial, and useful to anchor MUX wiring in tests).
proc ::schem::digital::MUX_eval {sel a b} {
    set src [expr {$sel ? $b : $a}]
    return $src
}

# ====================================================================
#  State cells -- value carried across cycles (the digseq `state` dict).
# ====================================================================
#
# Each state cell contributes a slot to the carried state.  Two phases per
# cycle, exactly as digseq read its memory every pass but latched only on the
# rising edge:
#   <T>_settle : the cell's OUTPUT this cycle, from carried state (+ async
#                overrides like an async reset / transparent latch).  Called
#                during settle; its result is a *source* for combinational eval.
#   <T>_next   : given the settled D / enables / resets and whether the active
#                clock edge occurred this cycle, the value to COMMIT into state.
# Clock-edge detection (active-edge given clkpol, using carried prevclk) is done
# by the kernel and passed in as `edge` (1 = active edge happened this cycle).

# DFF -- rising/falling-edge D flip-flop.  STUB.
#   params: {clkpol 0|1}.  ports: D (in), CLK (in), Q (out).
#   _settle: Q is just the carried state value `q` (a pure source this cycle).
#   _next:   if `edge`, new Q = settled D; else Q holds (= q).
# This is digseq's seal-in latch generalized to an edge-triggered cell:
# "remembered value out, sampled value in, commit on the edge."
proc ::schem::digital::DFF_settle {params q} {
    # TODO: with 4-state, an uninitialized DFF outputs X until first edge/reset.
    return $q
}
proc ::schem::digital::DFF_next {params q d edge} {
    # TODO: return [expr {$edge ? $d : $q}]
    return -code error "DFF_next: not yet implemented (see docs/DIGITAL.md s3)"
}

# DFFE -- DFF with clock enable.  STUB.
#   params: {clkpol enpol}.  ports: D, EN, CLK, Q.
#   _next: commit D only if `edge` AND EN is at its active level (enpol); else
#          hold.  This is digseq's write-enable `we` gate on a flip-flop.
proc ::schem::digital::DFFE_settle {params q} { return $q }
proc ::schem::digital::DFFE_next {params q d en edge} {
    # TODO: set act [expr {$en == [dict get $params enpol]}]
    #       return [expr {($edge && $act) ? $d : $q}]
    return -code error "DFFE_next: not yet implemented"
}

# SDFF -- DFF with SYNCHRONOUS reset.  STUB.
#   params: {clkpol rstpol rstval}.  ports: D, R, CLK, Q.
#   _next: on `edge`, if R active (rstpol) commit rstval, else commit D.  Reset
#          is sampled like data -- it only acts AT the edge.
proc ::schem::digital::SDFF_settle {params q} { return $q }
proc ::schem::digital::SDFF_next {params q d r edge} {
    # TODO: if {!$edge} {return $q}
    #       return [expr {($r == [dict get $params rstpol]) ? [dict get $params rstval] : $d}]
    return -code error "SDFF_next: not yet implemented"
}

# ADFF -- DFF with ASYNCHRONOUS reset.  STUB.
#   params: {clkpol rstpol rstval}.  ports: D, R, CLK, Q.
#   The ONE cell whose output can change without a clock edge: while R is
#   active, Q is forced to rstval immediately (a level, checked every settle),
#   so _settle takes the live R value and overrides the carried q.
#   _next: if R active -> rstval; elif `edge` -> D; else hold.
proc ::schem::digital::ADFF_settle {params q r} {
    # TODO: return [expr {($r == [dict get $params rstpol]) ? [dict get $params rstval] : $q}]
    return -code error "ADFF_settle: not yet implemented"
}
proc ::schem::digital::ADFF_next {params q d r edge} {
    return -code error "ADFF_next: not yet implemented"
}

# DLATCH -- level-sensitive transparent D latch.  STUB.
#   params: {enpol}.  ports: D, G (gate/enable), Q.
#   Transparent while G active: Q follows D; opaque otherwise: Q holds.  Because
#   it is transparent it is recomputed during settle (NOT a pure start-of-cycle
#   source) -- so it participates in levelization and a D->Q ring is a flagged
#   combinational loop.  This is digseq's gated-D-latch, generalized.
proc ::schem::digital::DLATCH_settle {params q d g} {
    # TODO: return [expr {($g == [dict get $params enpol]) ? $d : $q}]
    return -code error "DLATCH_settle: not yet implemented"
}

# MEM -- block RAM: sync/async read port(s) + 1+ write port(s).  STUB.
#   params: {abits dbits words rdsync 0|1 wrports init}.
#   This is digseq's `memory` class generalized: async read reflects the
#   addressed word during settle (digseq's read); sync read captures into an
#   output register on the active clock edge (a registered read).  Each write
#   port {WADDR WDATA WE WCLK} latches WDATA into cells[WADDR] on its active
#   WCLK edge when WE active -- digseq's rising-edge addressed write verbatim.
#   State slot: the cell array (dict idx -> dbits-bit word) + any sync-read
#   output registers + per-write-clock prevclk.
proc ::schem::digital::MEM_read {params cells addr} {
    # Async/combinational read of the addressed word; all-0 if never written.
    # TODO: set w [expr {[dict exists $cells $addr] ? [dict get $cells $addr] : [lrepeat [dict get $params dbits] 0]}]
    #       return $w
    return -code error "MEM_read: not yet implemented (see docs/DIGITAL.md s3)"
}
proc ::schem::digital::MEM_write {params cells addr data edge we} {
    # Commit data on the active write-clock edge when WE active; return new cells.
    # TODO: if {$edge && $we} { dict set cells $addr $data } ; return $cells
    return -code error "MEM_write: not yet implemented"
}

# ---- register the cell set -------------------------------------------------
# inports/outports name the conn ports the kernel reads/drives; `clocked` marks
# the state cells whose clock the kernel must edge-detect.  See levelize().

namespace eval ::schem::digital {
    celltype LUT    {kind comb  eval LUT_eval  inports I       outports O}
    celltype AND    {kind comb  eval Gate_eval inports {A B}   outports Y  op AND}
    celltype OR     {kind comb  eval Gate_eval inports {A B}   outports Y  op OR}
    celltype XOR    {kind comb  eval Gate_eval inports {A B}   outports Y  op XOR}
    celltype NAND   {kind comb  eval Gate_eval inports {A B}   outports Y  op NAND}
    celltype NOR    {kind comb  eval Gate_eval inports {A B}   outports Y  op NOR}
    celltype XNOR   {kind comb  eval Gate_eval inports {A B}   outports Y  op XNOR}
    celltype NOT    {kind comb  eval Gate_eval inports A       outports Y  op NOT}
    celltype BUF    {kind comb  eval Gate_eval inports A       outports Y  op BUF}
    celltype ANDNOT {kind comb  eval Gate_eval inports {A B}   outports Y  op ANDNOT}
    celltype ORNOT  {kind comb  eval Gate_eval inports {A B}   outports Y  op ORNOT}
    celltype MUX    {kind comb  eval MUX_eval  inports {S A B} outports Y}

    # Compound and inverting cells.  These carry correct eval semantics + ports
    # so the importer can map the Yosys $_AOI3_/$_OAI3_/$_AOI4_/$_OAI4_/$_NMUX_
    # cells onto real primitives.  NOTE: the committed simkernel.tcl settle loop
    # dispatches only LUT_eval/Gate_eval/MUX_eval, so a netlist containing these
    # cells would need the kernel's settle switch extended to dispatch the new
    # eval procs below; the evals themselves are unit-tested in test_fpga2.tcl.
    celltype AOI3   {kind comb  eval AOI3_eval inports {A B C}   outports Y}
    celltype OAI3   {kind comb  eval OAI3_eval inports {A B C}   outports Y}
    celltype AOI4   {kind comb  eval AOI4_eval inports {A B C D} outports Y}
    celltype OAI4   {kind comb  eval OAI4_eval inports {A B C D} outports Y}
    celltype NMUX   {kind comb  eval NMUX_eval inports {S A B}   outports Y}

    celltype DFF    {kind state clocked 1 inports {D CLK}        outports Q  clkport CLK}
    celltype DFFE   {kind state clocked 1 inports {D EN CLK}     outports Q  clkport CLK}
    celltype SDFF   {kind state clocked 1 inports {D R CLK}      outports Q  clkport CLK}
    celltype ADFF   {kind state clocked 1 inports {D R CLK}      outports Q  clkport CLK}
    celltype DLATCH {kind state clocked 0 inports {D G}          outports Q  transparent 1}
    celltype MEM    {kind state clocked 1 inports {RADDR WADDR WDATA WE WCLK} outports RDATA clkport WCLK}
}
