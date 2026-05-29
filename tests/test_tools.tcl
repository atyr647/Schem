# test_tools.tcl --
#
# Tests for the validator and the interactive editor (EditorSession).
#
#   tclsh tests/test_tools.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

proc approx {a b {tol 1e-6}} {
    if {abs($a-$b) <= $tol} { return ok }
    return "got $a, expected $b (tol $tol)"
}

# rules present in a validation result
proc rules {s} { return [lsort -unique [lmap f [$s validate] {dict get $f rule}]] }
proc hasRule {s r} { return [expr {$r in [rules $s]}] }

set scratch [makeDirectory schemtools]

# ===================== VALIDATOR =====================

test val-clean {a complete circuit validates with no findings} -setup {
    set s [schem::new ok]
    $s add battery B -emf 9 ; $s add ground GND ; $s add resistor R -r 1000
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
} -body { llength [$s validate] } -cleanup {$s destroy} -result 0

test val-no-ground {missing ground is an error} -setup {
    set s [schem::new ng]
    $s add battery B -emf 9 ; $s add resistor R -r 1000
    $s wire B.pos R.a ; $s wire R.b B.neg
} -body { hasRule $s no-ground } -cleanup {$s destroy} -result 1

test val-no-source {a board with no source is warned} -setup {
    set s [schem::new ns]
    $s add ground GND ; $s add resistor R -r 1000
    $s wire R.a GND.t ; $s wire R.b GND.t
} -body { hasRule $s no-source } -cleanup {$s destroy} -result 1

test val-isolated {an unconnected component is flagged} -setup {
    set s [schem::new iso]
    $s add battery B -emf 9 ; $s add ground GND ; $s add resistor R -r 100
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s add capacitor C       ;# placed, wired to nothing
} -body { hasRule $s isolated-component } -cleanup {$s destroy} -result 1

test val-floating {a half-wired two-terminal part is flagged} -setup {
    set s [schem::new fl]
    $s add battery B -emf 9 ; $s add ground GND ; $s add resistor R -r 100
    $s wire B.pos R.a ; $s wire B.neg GND.t     ;# R.b left floating
} -body { hasRule $s floating-terminal } -cleanup {$s destroy} -result 1

test val-contract {a circuit exposing a non-standard port is warned} -setup {
    set c [schem::circuit blk]
    $c add resistor R -r 100
    $c add ground GND
    $c wire R.b GND.t
    $c expose IN R.a
    $c expose ZAP R.b       ;# not IN/OUT/FAULT/GND
} -body { hasRule $c terminal-contract } -cleanup {$c destroy} -result 1

test val-layer {a non-standard layer is reported as info} -setup {
    set s [schem::new ly]
    $s add battery B -emf 9 ; $s add ground GND
    $s add resistor R -r 100 -layer plasma
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
} -body { hasRule $s layer-unknown } -cleanup {$s destroy} -result 1

test val-short {an ideal short across a source is an error} -setup {
    set s [schem::new sh]
    $s add battery B -emf 9 ; $s add ground GND ; $s add switch SW -state closed
    $s wire B.pos SW.a ; $s wire SW.b B.neg ; $s wire B.neg GND.t
} -body { expr {[hasRule $s short] || [hasRule $s short-circuit]} } -cleanup {$s destroy} -result 1

test val-no-side-effect {validation's trial solve must not blow a fuse} -setup {
    set s [schem::new fz]
    $s add battery B -emf 10 ; $s add ground GND
    $s add fuse F -rating 0.5 ; $s add resistor R -r 10
    $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s validate
} -body { $s get F state } -cleanup {$s destroy} -result intact

test val-board-limit {an oversized board suggests decomposition} -setup {
    set s [schem::new big]
    $s add battery B -emf 9 ; $s add ground GND
    for {set i 1} {$i <= 50} {incr i} {
        $s add resistor R$i -r 1000
        $s wire B.pos R$i.a ; $s wire R$i.b GND.t
    }
    $s wire B.neg GND.t
} -body { hasRule $s board-limit } -cleanup {$s destroy} -result 1

# ===================== EDITOR =====================

test ed-place {placing a part adds it to the object model with a position} -setup {
    set ed [schem::EditorSession new]
    $ed key p                       ;# place battery (bin index 0) at (0,0)
    set s [$ed schematic]
} -body {
    list [$s components] [$s typeof B1] [dict get [$s attrs B1] pos]
} -cleanup {$ed destroy} -result {B1 battery {0.0 0.0}}

test ed-select-type {digit keys select the part type from the bin} -setup {
    set ed [schem::EditorSession new]
    $ed key 3 ; $ed key p           ;# part 3 = resistor
    set s [$ed schematic]
} -body { $s typeof R1 } -cleanup {$ed destroy} -result resistor

test ed-delete {deleting a component removes it and its couplings} -setup {
    set ed [schem::EditorSession new]
    $ed key p                       ;# B1 @ (0,0)
    $ed key l ; $ed key 3 ; $ed key p  ;# R1 @ (1,0)
    $ed key h ; $ed key w ; $ed key ENTER  ;# B1.pos
    $ed key l ; $ed key w ; $ed key ENTER  ;# -> R1.a
    set s [$ed schematic]
    set before [list [llength [$s components]] [llength [$s conns]]]
    $ed key d                       ;# cursor on R1 -> delete it
} -body {
    list $before [llength [$s components]] [llength [$s conns]]
} -cleanup {$ed destroy} -result {{2 1} 1 0}

test ed-wire-and-solve {a circuit built entirely in the editor solves correctly} -setup {
    set ed [schem::EditorSession new]
    $ed key p                          ;# B1 @ (0,0)
    $ed key l ; $ed key 3 ; $ed key p  ;# R1 @ (1,0)
    $ed key j ; $ed key 2 ; $ed key p  ;# GND1 @ (1,1)
    $ed key k ; $ed key h ; $ed key w ; $ed key ENTER  ;# B1.pos
    $ed key l ; $ed key w ; $ed key ENTER              ;# -> R1.a
    $ed key w ; $ed key j ; $ed key ENTER              ;# R1.b
    $ed key j ; $ed key w ; $ed key ENTER              ;# -> GND1.t
    $ed key k ; $ed key h ; $ed key w ; $ed key j ; $ed key ENTER  ;# B1.neg
    $ed key l ; $ed key j ; $ed key w ; $ed key ENTER              ;# -> GND1.t
    $ed key k ; $ed key e ; $ed type "emf 9" ; $ed key ENTER
    set s [$ed schematic]
    $s solve
} -body { approx [$s probe R1.a] 9.0 } -cleanup {$ed destroy} -result ok

test ed-save-load {the editor round-trips through a .schem file} -setup {
    set ed [schem::EditorSession new]
    $ed key p ; $ed key l ; $ed key 3 ; $ed key p
    set path [file join $scratch e.schem]
    $ed key S ; $ed type $path ; $ed key ENTER
    set s2 [schem::load $path]
} -body { lsort [$s2 components] } -cleanup {$ed destroy ; $s2 destroy} -result {B1 R1}

test ed-render-cursor {the frame shows the cursor box and the bin selection} -setup {
    set ed [schem::EditorSession new]
    $ed key p
    set frame [$ed render]
} -body {
    set dbl [format %c 0x2554]    ;# ╔ double-line corner = cursor highlight
    expr {[string first $dbl $frame] >= 0 && [string first "\[battery\]" $frame] >= 0}
} -cleanup {$ed destroy} -result 1

test ed-quit {the quit key sets the quit flag} -setup {
    set ed [schem::EditorSession new]
} -body { set q0 [$ed quit?] ; $ed key q ; list $q0 [$ed quit?] } \
  -cleanup {$ed destroy} -result {0 1}

cleanupTests
