# simkernel.tcl --
#
# The interpreted cycle engine for the FPGA digital netlist -- the direct
# generalization of `::schem::backend::digseq` (src/backend/digital.tcl).
# digseq settled a relay/contact/memory fixed point each clock cycle and carried
# its state forward; this does the same for LUTs, flip-flops, gates, muxes and
# block RAM, consuming the shared digital-netlist IR (docs/DIGITAL.md section 1).
#
# WHY a topological settle instead of digseq's reachability BFS: in the FPGA IR
# every net has exactly ONE driver (a cell output, a design input, or a constant
# rail), so the combinational part -- once every state element is cut -- is a
# DAG.  We can therefore evaluate each cell once its inputs are known
# (levelize), in a single pass (settle), rather than relaxing a fixed point.
# Sequential feedback (Q -> logic -> D) is broken by the flip-flop exactly as in
# hardware: a state cell's OUTPUT is a settled source, its INPUT is sampled
# AFTER settle and committed on the clock edge (tick).  That settle/latch/advance
# split is digseq's settle / UpdateMemory / latch-prevclk, step for step.
#
# Status: `levelize` and `settle` are fully implemented; `tick`/`run` implement
# the single-clock loop for the anchor state cell (DFF).  Other state cells and
# multi-clock domains are documented stubs (see docs/DIGITAL.md sections 3, 5).

namespace eval ::schem::digital {
    namespace export levelize settle tick run
}

# ====================================================================
#  levelize -- topological order of combinational cells + loop detection.
# ====================================================================
#
# Kahn's algorithm over the comb cells.  A net is "ready" once its driver is a
# source (design input, const rail, or a STATE cell output -- known at the start
# of every cycle, like digseq's memory data-out) or an already-emitted comb
# cell.  Any comb cell still unready when no progress can be made sits on a
# COMBINATIONAL LOOP (a LUT/gate ring or a transparent-latch ring with no flip-
# flop to break it) -- a design error, returned in `loops` rather than spun on.
# Topology is static, so this is computed once and reused every cycle.
#
# Returns {order {cellName ...}  loops {cellName ...}}.
proc ::schem::digital::levelize {design} {
    variable CELLS
    set cells [dict get $design cells]

    # driver: net -> name of the comb cell that drives it (state outputs and
    # inputs/rails are NOT recorded here; they are sources, always ready).
    set driver [dict create]
    foreach c $cells {
        set type [dict get $c type]
        set desc [dict get $CELLS $type]
        if {[dict get $desc kind] ne "comb"} continue
        foreach port [dict get $desc outports] {
            if {![dict exists $c conn $port]} continue
            foreach net [dict get $c conn $port] { dict set driver $net [dict get $c name] }
        }
    }

    # ready nets: const rails (0,1) + design inputs + every STATE cell output.
    set ready [dict create 0 1 1 1]
    foreach {sig nets} [dict get $design inputs] {
        foreach net $nets { dict set ready $net 1 }
    }
    foreach c $cells {
        set desc [dict get $CELLS [dict get $c type]]
        if {[dict get $desc kind] ne "state"} continue
        foreach port [dict get $desc outports] {
            if {![dict exists $c conn $port]} continue
            foreach net [dict get $c conn $port] { dict set ready $net 1 }
        }
    }

    # comb cells to schedule, with their (combinational) input nets.
    set pending [dict create]   ;# name -> {input nets...}
    set byname  [dict create]   ;# name -> cell dict
    foreach c $cells {
        set type [dict get $c type]
        set desc [dict get $CELLS $type]
        if {[dict get $desc kind] ne "comb"} continue
        set ins {}
        foreach port [dict get $desc inports] {
            if {[dict exists $c conn $port]} { lappend ins {*}[dict get $c conn $port] }
        }
        dict set pending [dict get $c name] $ins
        dict set byname  [dict get $c name] $c
    }

    set order {}
    set progress 1
    while {$progress && [dict size $pending]} {
        set progress 0
        foreach name [dict keys $pending] {
            set allready 1
            foreach net [dict get $pending $name] {
                # ready if it is a source net or driven by an emitted comb cell
                if {[dict exists $ready $net]} continue
                if {[dict exists $driver $net] && [dict get $driver $net] in $order} continue
                set allready 0 ; break
            }
            if {$allready} {
                lappend order $name
                dict unset pending $name
                set progress 1
            }
        }
    }
    # whatever remains cannot be ordered -> sits on a combinational loop.
    return [dict create order $order loops [dict keys $pending]]
}

# ====================================================================
#  settle -- evaluate combinational cells in topo order to settled values.
# ====================================================================
#
# Seeds net values from the const rails, the design-input stimulus, and every
# state cell's OUTPUT (read from carried `state` via its _settle proc -- the
# generalization of digseq seeding HIGH from memory data-out).  Then walks the
# precomputed `order`, evaluating each comb cell and driving its output nets.
# Returns a dict  netId -> 0/1  (every net that has a value this cycle).
#
# Fully implemented for LUT / gates / MUX; transparent DLATCH and async-reset
# state-output overrides are noted where they will hook in.
proc ::schem::digital::settle {design order state} {
    variable CELLS
    set netval [dict create 0 0 1 1]

    # design inputs (stimulus is applied by the caller into `design inputs`).
    foreach {sig nets} [dict get $design inputs] {
        foreach net $nets { dict set netval $net [expr {[dict exists $netval $net] ? [dict get $netval $net] : 0}] }
    }
    if {[dict exists $design stim]} {
        dict for {net v} [dict get $design stim] { dict set netval $net $v }
    }

    # state-cell outputs are sources this cycle: read carried Q / RAM word.
    foreach c [dict get $design cells] {
        set type [dict get $c type]
        set desc [dict get $CELLS $type]
        if {[dict get $desc kind] ne "state"} continue
        set name [dict get $c name]
        switch $type {
            DFF - DFFE - SDFF {
                set q [expr {[dict exists $state q $name] ? [dict get $state q $name] : 0}]
                dict set netval [lindex [dict get $c conn Q] 0] $q
            }
            ADFF {
                # TODO async reset override: q forced to rstval while R active.
                set q [expr {[dict exists $state q $name] ? [dict get $state q $name] : 0}]
                dict set netval [lindex [dict get $c conn Q] 0] $q
            }
            DLATCH {
                # TODO transparent: recompute Q from D when gate active (this
                # cell is in `order`, not here) -- handled once DLATCH_settle lands.
            }
            MEM {
                # TODO async read: drive RDATA from cells[RADDR] each settle.
            }
        }
    }

    # walk the combinational DAG.
    foreach name $order {
        set c [::schem::digital::CellByName $design $name]
        set type [dict get $c type]
        set desc [dict get $CELLS $type]
        set ev [dict get $desc eval]
        set out {}
        switch $ev {
            LUT_eval {
                set in {}
                foreach net [dict get $c conn I] { lappend in [dict get $netval $net] }
                set out [::schem::digital::LUT_eval [dict get $c params] $in]
                set onets [dict get $c conn O]
            }
            Gate_eval {
                set op [dict get $desc op]
                set a {} ; foreach net [dict get $c conn A] { lappend a [dict get $netval $net] }
                set b {}
                if {[dict exists $c conn B]} { foreach net [dict get $c conn B] { lappend b [dict get $netval $net] } }
                set out [::schem::digital::Gate_eval $op $a $b]
                set onets [dict get $c conn Y]
            }
            MUX_eval {
                set sel [dict get $netval [lindex [dict get $c conn S] 0]]
                set a {} ; foreach net [dict get $c conn A] { lappend a [dict get $netval $net] }
                set b {} ; foreach net [dict get $c conn B] { lappend b [dict get $netval $net] }
                set out [::schem::digital::MUX_eval $sel $a $b]
                set onets [dict get $c conn Y]
            }
            default { return -code error "settle: no eval for cell type $type" }
        }
        foreach net $onets bit $out { dict set netval $net $bit }
    }
    return $netval
}

# CellByName -- fetch a cell dict by instance name (internal helper).
proc ::schem::digital::CellByName {design name} {
    foreach c [dict get $design cells] {
        if {[dict get $c name] eq $name} { return $c }
    }
    return -code error "no cell named $name"
}

# ClockEdge -- did `clknet` see its active edge this cycle?  (digseq's prevclk.)
# clkpol 1 = rising (now=1, was=0); clkpol 0 = falling (now=0, was=1).
proc ::schem::digital::ClockEdge {netval prev clknet clkpol} {
    set now  [expr {[dict exists $netval $clknet] ? [dict get $netval $clknet] : 0}]
    set was  [expr {[dict exists $prev $clknet]   ? [dict get $prev $clknet]   : 0}]
    if {$clkpol} { return [expr {$now && !$was}] }
    return [expr {!$now && $was}]
}

# ====================================================================
#  tick -- one clock cycle: settle -> latch state cells -> advance.
# ====================================================================
#
# digseq's per-cycle body, generalized.  Implemented for the anchor state cell
# (DFF) over the single-clock loop; DFFE/SDFF/ADFF/DLATCH/MEM latching is staged
# in but raises until their cells.tcl evals land (see docs/DIGITAL.md section 3).
#
#   1. settle the combinational cone from carried state + this cycle's stimulus.
#   2. for each state cell, test its clock edge (now vs carried prevclk) and, if
#      it fired, sample the SETTLED D and compute the committed value.
#   3. advance: write committed Q-values into state; record each clock's level
#      as prevclk for next cycle's edge test.
#
# `state` carries {q {name->Q} cells {name->{idx->word}} prevclk {net->level}}.
# Returns {netval {net->0/1}  state {...}}.
proc ::schem::digital::tick {design order state} {
    variable CELLS
    set netval [settle $design $order $state]

    set prev [expr {[dict exists $state prevclk] ? [dict get $state prevclk] : [dict create]}]
    set q    [expr {[dict exists $state q]       ? [dict get $state q]       : [dict create]}]
    set mem  [expr {[dict exists $state cells]   ? [dict get $state cells]   : [dict create]}]

    foreach c [dict get $design cells] {
        set type [dict get $c type]
        set desc [dict get $CELLS $type]
        if {[dict get $desc kind] ne "state"} continue
        set name [dict get $c name]
        switch $type {
            DFF {
                set clknet [lindex [dict get $c conn CLK] 0]
                set edge [ClockEdge $netval $prev $clknet [dict get $c params clkpol]]
                if {$edge} {
                    set d [dict get $netval [lindex [dict get $c conn D] 0]]
                    dict set q $name $d
                }
            }
            DFFE - SDFF - ADFF - DLATCH - MEM {
                # TODO: latch via DFFE_next/SDFF_next/ADFF_next/DLATCH_settle/
                # MEM_write once those cell evals are implemented in cells.tcl.
                return -code error "tick: state cell $type not yet implemented (DFF only)"
            }
        }
    }

    # Re-settle with the freshly latched state so the new Q (and RAM words)
    # propagate to the outputs THIS cycle -- the visible-same-cycle behaviour of
    # digseq's fixed point, where a write became readable within the same solve.
    # Clocks are design inputs (never state-driven), so the edge already detected
    # above is unaffected by re-settling.
    set newstate [dict create q $q cells $mem prevclk $prev]
    set netval [settle $design $order $newstate]

    # advance prevclk for every clock net used this cycle.
    foreach clknet [dict get $design clocks] {
        dict set prev $clknet [expr {[dict exists $netval $clknet] ? [dict get $netval $clknet] : 0}]
    }
    return [dict create netval $netval \
        state [dict create q $q cells $mem prevclk $prev]]
}

# ====================================================================
#  run -- N clock cycles, with an optional per-cycle trace callback.
# ====================================================================
#
# Levelizes once (errors on a combinational loop), then drives the cycle loop.
# `stim` is the input schedule keyed by cycle number: {cycle {net val ...} ...}
# -- the interpreted analogue of ZigDigitalSeq's compiled-in -events.  Each
# cycle the matching net assignments are merged into `design stim` before
# settle.  `trace`, if given, is called as {apply $trace $cycle $netval} after
# each tick (waveform capture).  Returns the final state.
#
# Implemented for the single-clock DFF loop (rides on tick).
proc ::schem::digital::run {design cycles {stim {}} {trace {}}} {
    set lv [levelize $design]
    if {[llength [dict get $lv loops]]} {
        return -code error "combinational loop through: [dict get $lv loops]"
    }
    set order [dict get $lv order]
    set state [dict create q [dict create] cells [dict create] prevclk [dict create]]
    for {set cy 0} {$cy < $cycles} {incr cy} {
        if {[dict exists $stim $cy]} {
            dict for {net v} [dict get $stim $cy] { dict set design stim $net $v }
        }
        set r [tick $design $order $state]
        set state [dict get $r state]
        if {[llength $trace]} { uplevel #0 [list {*}$trace $cy [dict get $r netval]] }
    }
    return $state
}
