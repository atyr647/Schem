# test_format.tcl --
#
# Tests for the Phase-1 artifact layer: the binary .schem object-model file,
# the derived netlist/IR cache, harnesses, and the viewer.  The contract is
# that a saved schematic round-trips losslessly and solves identically.
#
#   tclsh tests/test_format.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

proc approx {a b {tol 1e-6}} {
    if {abs($a-$b) <= $tol} { return ok }
    return "got $a, expected $b (tol $tol)"
}

set scratch [makeDirectory schemfmt]

# build a representative schematic with geometry, a gauged wire and ports
proc build_board {} {
    set s [schem::new board]
    $s add battery  B  -emf 9 -at 0,1
    $s add ground   GND -at 0,2
    $s add resistor R1 -r 1000 -at 1,0 -layer power
    $s add resistor R2 -r 2000 -at 1,1
    $s wire B.pos R1.a
    $s wire R1.b  R2.a
    $s wire R2.b  GND.t
    $s wire B.neg GND.t -awg 14
    $s expose OUT R1.b
    return $s
}

# ---- binary container ---------------------------------------------------

test fmt-magic {a .schem file starts with the SCHM binary magic} -setup {
    set s [build_board]
    set path [file join $scratch a.schem]
    schem::save $s $path
} -body {
    set fh [open $path rb] ; fconfigure $fh -translation binary
    set head [read $fh 4] ; close $fh
    set head
} -cleanup {$s destroy} -result "SCHM"

test fmt-not-text {the payload is binary, not a readable text/JSON source} -setup {
    set s [build_board]
    set path [file join $scratch b.schem]
    schem::save $s $path
} -body {
    set fh [open $path rb] ; fconfigure $fh -translation binary
    set raw [read $fh] ; close $fh
    # The component names exist in the model but must NOT appear as plain
    # text in the (compressed, binary) file -- it is not a text format.
    expr {[string first "battery" $raw] < 0 && [string first "resistor" $raw] < 0}
} -cleanup {$s destroy} -result 1

# ---- round-trip ---------------------------------------------------------

test fmt-roundtrip-solve {save+load preserves the electrical solution} -setup {
    set s [build_board] ; $s solve
    set v0 [$s probe R1.b]
    set path [file join $scratch c.schem]
    schem::save $s $path
    set s2 [schem::load $path]
    $s2 solve
} -body { approx [$s2 probe R1.b] $v0 } -cleanup {$s destroy ; $s2 destroy} -result ok

test fmt-roundtrip-model {save+load preserves params, geometry, layers, ports} -setup {
    set s [build_board]
    set path [file join $scratch d.schem]
    schem::save $s $path
    set s2 [schem::load $path]
} -body {
    list [lsort [$s2 components]] \
         [$s2 get R1 r] \
         [dict get [$s2 attrs R1] layer] \
         [dict get [$s2 attrs B] pos] \
         [$s2 port OUT]
} -cleanup {$s destroy ; $s2 destroy} \
  -result {{B GND R1 R2} 1000 power {0.0 1.0} R1.b}

# ---- harness ------------------------------------------------------------

test harness-continuity {a harness bundles ideal conductors (continuity)} -setup {
    set s [schem::new h]
    $s add battery B -emf 5
    $s add ground GND
    $s add resistor R1 -r 100
    $s add resistor R2 -r 100
    $s harness HBundle {B.pos R1.a  GND.t R1.b}
    $s wire R1.a R2.a
    $s wire R2.b GND.t
    $s wire B.neg GND.t
    $s solve
} -body {
    # R1 is fed entirely through the harness; it must carry current.
    expr {[$s current R1] > 0 && [$s continuity B.pos R1.a]}
} -cleanup {$s destroy} -result 1

test harness-roundtrip {harness bundles survive save/load} -setup {
    set s [schem::new h]
    $s add battery B -emf 5
    $s add ground GND
    $s add resistor R1 -r 100
    $s harness HB {B.pos R1.a}
    $s wire R1.b GND.t
    $s wire B.neg GND.t
    set path [file join $scratch h.schem]
    schem::save $s $path
    set s2 [schem::load $path]
} -body {
    list [dict keys [$s2 harnesses]] [$s2 continuity B.pos R1.a]
} -cleanup {$s destroy ; $s2 destroy} -result {HB 1}

# ---- derived netlist / IR ----------------------------------------------

test netlist-derive {the IR resolves continuity into shared nodes} -setup {
    set s [build_board]
    set ir [$s netlist]
} -body {
    # B.pos and R1.a are wired together -> same node.
    set nodes [dict get $ir nodes]
    set n1 "" ; set n2 ""
    dict for {nid terms} $nodes {
        if {"B.pos" in $terms} { set n1 $nid }
        if {"R1.a" in $terms} { set n2 $nid }
    }
    expr {$n1 ne "" && $n1 == $n2}
} -cleanup {$s destroy} -result 1

test netlist-ground-zero {ground terminals collapse to node 0 in the IR} -setup {
    set s [build_board]
    set ir [$s netlist]
} -body {
    expr {"GND.t" in [dict get $ir nodes 0]}
} -cleanup {$s destroy} -result 1

# ---- viewer -------------------------------------------------------------

test view-draws-boxes {the viewer renders boxes and a coupling arrow} -setup {
    set s [schem::new v]
    $s add switch SW
    $s add relay K
    $s wire SW.b K.c1
    set txt [$s view]
} -body {
    # contains box-drawing corners and a right arrow, and the labels
    set tl [format %c 0x250C] ; set ar [format %c 0x25B6]
    expr {[string first $tl $txt] >= 0 && [string first $ar $txt] >= 0 \
          && [string first "SW:switch" $txt] >= 0}
} -cleanup {$s destroy} -result 1

cleanupTests
