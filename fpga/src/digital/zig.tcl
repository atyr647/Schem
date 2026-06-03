#!/usr/bin/env tclsh
# zig.tcl -- compile a digital netlist to a native Zig cycle simulator.
#
# The compiled counterpart of simkernel.tcl: where `tick` interprets the IR each
# cycle, `emitZig` transcribes the SAME settle/latch/re-settle/advance steps into
# straight-line Zig once, so the design runs at native speed.  This is Verilator's
# trick (synthesizable RTL -> C++), done through Schem's IR -> Zig instead, and it
# is verified the Schem way: emit it, compile + run it, and diff its per-cycle
# output against both the interpreter and the Icarus reference (test_fpga_zig.tcl).
#
# Because every net has exactly one driver, the combinational part is a DAG: a
# single straight-line `settle()` in levelized order suffices (no fixed point).
# Flip-flops cut the sequential feedback exactly as in hardware -- their Q is a
# settled source, their D is sampled after settle and committed on the edge.
#
# Status: LUT / gates / MUX / the DFF family (clkpol, sync+async reset, enable).
# DLATCH and block RAM raise -- they are staged in cells.tcl/simkernel.tcl first.

namespace eval ::schem::digital {
    namespace export emitZig
}

# emitZig -- return a complete, self-contained Zig program for `design`.
#   order   levelized comb order (from `levelize`)
#   steps   the input schedule: a list of {assign {net val ...} record 0|1};
#           each step sets some input nets, advances one clock tick, and -- when
#           record is true -- prints the `outbus` value as one trace line.
#   outbus  net ids (LSB first) printed as `cycle <k> <label>=<decimal>`.
# The schedule mirrors the interpreted `run`, so the two are diff-comparable.
proc ::schem::digital::emitZig {design order steps outbus {label q}} {
    variable CELLS
    set N [dict get $design nbits]

    # Index the state cells (DFF only for now) and assign each clock net a slot.
    set dffs {} ; set clkidx [dict create] ; set nclk 0
    foreach c [dict get $design cells] {
        set type [dict get $c type]
        if {[dict get [dict get $CELLS $type] kind] ne "state"} continue
        if {$type ne "DFF"} {
            return -code error "emitZig: state cell $type not supported yet (DFF only)"
        }
        set p [dict merge {clkpol 1 rstpol 0 rstval 0 async 0 enable 0 enpol 1} \
                   [dict get $c params]]
        set clk [lindex [dict get $c conn CLK] 0]
        if {![dict exists $clkidx $clk]} { dict set clkidx $clk $nclk ; incr nclk }
        set d [dict create idx [llength $dffs] \
                   q [lindex [dict get $c conn Q] 0] d [lindex [dict get $c conn D] 0] \
                   clk $clk clkpol [dict get $p clkpol] async [dict get $p async] \
                   rstpol [dict get $p rstpol] rstval [dict get $p rstval] \
                   enable [dict get $p enable] enpol [dict get $p enpol]]
        if {[dict exists $c conn R]}  { dict set d r  [lindex [dict get $c conn R]  0] }
        if {[dict exists $c conn EN]} { dict set d en [lindex [dict get $c conn EN] 0] }
        lappend dffs $d
    }
    set Q [llength $dffs]

    set hasrec 0
    foreach step $steps { if {[dict get $step record]} { set hasrec 1 ; break } }

    set S {}
    lappend S "const std = @import(\"std\");"
    lappend S ""
    lappend S "var net: \[$N\]u8 = \[_\]u8{0} ** $N;"
    if {$Q}    { lappend S "var qreg: \[$Q\]u8 = \[_\]u8{0} ** $Q;" }
    if {$nclk} { lappend S "var prevclk: \[$nclk\]u8 = \[_\]u8{0} ** $nclk;" }
    lappend S ""

    # settle(): const rails, then each DFF's Q from carried state, then the
    # combinational DAG in levelized order.  Inputs are left untouched (set by main).
    lappend S "fn settle() void {"
    lappend S "    net\[0\] = 0;"
    lappend S "    net\[1\] = 1;"
    foreach d $dffs { lappend S "    net\[[dict get $d q]\] = qreg\[[dict get $d idx]\];" }
    foreach name $order {
        set c [::schem::digital::CellByName $design $name]
        foreach line [::schem::digital::ZEmitComb $c] { lappend S "    $line" }
    }
    lappend S "}"
    lappend S ""

    # tick(): settle -> latch every flip-flop (async reset level-sensitive; on the
    # active edge, priority sync-reset > enable-hold > data load) -> re-settle so
    # the new Q shows this cycle -> advance prevclk.  Mirrors simkernel.tcl tick.
    if {$Q} {
        lappend S "fn tick() void {"
        lappend S "    settle();"
        foreach d $dffs {
            set ci [dict get $clkidx [dict get $d clk]] ; set clk [dict get $d clk]
            if {[dict get $d clkpol]} {
                set edge "(net\[$clk\] == 1 and prevclk\[$ci\] == 0)"
            } else {
                set edge "(net\[$clk\] == 0 and prevclk\[$ci\] == 1)"
            }
            set idx [dict get $d idx]
            if {[dict get $d async] && [dict exists $d r]} {
                lappend S "    if (net\[[dict get $d r]\] == [dict get $d rstpol]) {"
                lappend S "        qreg\[$idx\] = [dict get $d rstval];"
                lappend S "    } else if ($edge) {"
                foreach line [::schem::digital::ZEmitEdge $d] { lappend S "        $line" }
                lappend S "    }"
            } else {
                lappend S "    if ($edge) {"
                foreach line [::schem::digital::ZEmitEdge $d] { lappend S "        $line" }
                lappend S "    }"
            }
        }
        lappend S "    settle();"
        dict for {clk ci} $clkidx { lappend S "    prevclk\[$ci\] = net\[$clk\];" }
        lappend S "}"
        lappend S ""
    }

    lappend S "pub fn main() !void {"
    lappend S "    const stdout = std.io.getStdOut().writer();"
    if {$hasrec} { lappend S "    var rec: usize = 0;" }
    foreach step $steps {
        foreach {net val} [dict get $step assign] { lappend S "    net\[$net\] = $val;" }
        if {$Q} { lappend S "    tick();" } else { lappend S "    settle();" }
        if {[dict get $step record]} {
            set terms {} ; set i 0
            foreach b $outbus { lappend terms "(@as(u64, net\[$b\]) << $i)" ; incr i }
            set expr [expr {[llength $terms] ? [join $terms " | "] : "0"}]
            lappend S "    try stdout.print(\"cycle {d} $label={d}\\n\", .{ rec, $expr });"
            lappend S "    rec += 1;"
        }
    }
    lappend S "}"
    return [join $S \n]
}

# ZEmitEdge -- the on-edge latch body for one DFF (sync-reset > enable > load).
# Zig braces are built with [format %c] so the Tcl proc body stays brace-balanced.
proc ::schem::digital::ZEmitEdge {d} {
    set OB [format %c 123] ; set CB [format %c 125]
    set idx [dict get $d idx] ; set out {}
    set hasR [expr {![dict get $d async] && [dict exists $d r]}]
    set hasE [expr {[dict get $d enable] && [dict exists $d en]}]
    if {$hasR} {
        lappend out "if (net\[[dict get $d r]\] == [dict get $d rstpol]) $OB"
        lappend out "    qreg\[$idx\] = [dict get $d rstval];"
        if {$hasE} {
            lappend out "$CB else if (net\[[dict get $d en]\] == [dict get $d enpol]) $OB"
            lappend out "    qreg\[$idx\] = net\[[dict get $d d]\];"
            lappend out "$CB"
        } else {
            lappend out "$CB else $OB"
            lappend out "    qreg\[$idx\] = net\[[dict get $d d]\];"
            lappend out "$CB"
        }
    } elseif {$hasE} {
        lappend out "if (net\[[dict get $d en]\] == [dict get $d enpol]) $OB"
        lappend out "    qreg\[$idx\] = net\[[dict get $d d]\];"
        lappend out "$CB"
    } else {
        lappend out "qreg\[$idx\] = net\[[dict get $d d]\];"
    }
    return $out
}

# ZEmitComb -- Zig statement(s) driving one combinational cell's output net(s).
# Transcribes the LUT_eval / Gate_eval / MUX_eval semantics of cells.tcl exactly.
proc ::schem::digital::ZEmitComb {c} {
    variable CELLS
    set type [dict get $c type]
    set desc [dict get $CELLS $type]
    set out {}
    switch [dict get $desc eval] {
        LUT_eval {
            set k [dict get $c params k] ; set init [dict get $c params init]
            if {$k > 6} { return -code error "emitZig: LUT k=$k > 6 unsupported" }
            set o [lindex [dict get $c conn O] 0] ; set in [dict get $c conn I]
            set terms {}
            for {set i 0} {$i < $k} {incr i} { lappend terms "(@as(u64, net\[[lindex $in $i]\]) << $i)" }
            set idx [expr {[llength $terms] ? [join $terms " | "] : "0"}]
            lappend out "net\[$o\] = @intCast((@as(u64, $init) >> @as(u6, @intCast($idx))) & 1);"
        }
        Gate_eval {
            set op [dict get $desc op]
            set ya [dict get $c conn Y] ; set aa [dict get $c conn A]
            set ba [expr {[dict exists $c conn B] ? [dict get $c conn B] : {}}]
            for {set i 0} {$i < [llength $ya]} {incr i} {
                lappend out "net\[[lindex $ya $i]\] = [::schem::digital::ZGate $op [lindex $aa $i] [lindex $ba $i]];"
            }
        }
        MUX_eval {
            set y [lindex [dict get $c conn Y] 0] ; set s [lindex [dict get $c conn S] 0]
            set a [lindex [dict get $c conn A] 0] ; set b [lindex [dict get $c conn B] 0]
            lappend out "net\[$y\] = if (net\[$s\] == 1) net\[$b\] else net\[$a\];"
        }
        NMUX_eval {
            set y [lindex [dict get $c conn Y] 0] ; set s [lindex [dict get $c conn S] 0]
            set a [lindex [dict get $c conn A] 0] ; set b [lindex [dict get $c conn B] 0]
            lappend out "net\[$y\] = (if (net\[$s\] == 1) net\[$b\] else net\[$a\]) ^ 1;"
        }
        AOI3_eval {
            lassign [list [lindex [dict get $c conn A] 0] [lindex [dict get $c conn B] 0] \
                          [lindex [dict get $c conn C] 0] [lindex [dict get $c conn Y] 0]] a b cc y
            lappend out "net\[$y\] = ((net\[$a\] & net\[$b\]) | net\[$cc\]) ^ 1;"
        }
        OAI3_eval {
            lassign [list [lindex [dict get $c conn A] 0] [lindex [dict get $c conn B] 0] \
                          [lindex [dict get $c conn C] 0] [lindex [dict get $c conn Y] 0]] a b cc y
            lappend out "net\[$y\] = ((net\[$a\] | net\[$b\]) & net\[$cc\]) ^ 1;"
        }
        AOI4_eval {
            lassign [list [lindex [dict get $c conn A] 0] [lindex [dict get $c conn B] 0] \
                          [lindex [dict get $c conn C] 0] [lindex [dict get $c conn D] 0] \
                          [lindex [dict get $c conn Y] 0]] a b cc d y
            lappend out "net\[$y\] = ((net\[$a\] & net\[$b\]) | (net\[$cc\] & net\[$d\])) ^ 1;"
        }
        OAI4_eval {
            lassign [list [lindex [dict get $c conn A] 0] [lindex [dict get $c conn B] 0] \
                          [lindex [dict get $c conn C] 0] [lindex [dict get $c conn D] 0] \
                          [lindex [dict get $c conn Y] 0]] a b cc d y
            lappend out "net\[$y\] = ((net\[$a\] | net\[$b\]) & (net\[$cc\] | net\[$d\])) ^ 1;"
        }
        default { return -code error "emitZig: no Zig for cell $type" }
    }
    return $out
}

# ZGate -- the Zig expression for a basic gate (u8 0/1 arithmetic).
proc ::schem::digital::ZGate {op a b} {
    switch $op {
        AND  { return "net\[$a\] & net\[$b\]" }
        OR   { return "net\[$a\] | net\[$b\]" }
        XOR  { return "net\[$a\] ^ net\[$b\]" }
        NAND { return "(net\[$a\] & net\[$b\]) ^ 1" }
        NOR  { return "(net\[$a\] | net\[$b\]) ^ 1" }
        XNOR { return "(net\[$a\] ^ net\[$b\]) ^ 1" }
        NOT  { return "net\[$a\] ^ 1" }
        BUF  { return "net\[$a\]" }
        default { return -code error "emitZig: gate op $op unsupported" }
    }
}
