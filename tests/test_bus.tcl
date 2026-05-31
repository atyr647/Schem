#!/usr/bin/env tclsh
# test_bus.tcl -- bundled conductors (bus), repeated components (bank), the
# schematic-expansion repeat, and bundle-aware connect.  These assert that a
# bus is electrical (lanes carry voltages and fight over contention), while
# repeat/bank are pure drafting that leave behind real components.
#
#   tclsh tests/test_bus.tcl
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

# ====================================================================
section "bus -- a bundle of real conductors"
# ====================================================================
set s [schem::new t]
$s bus ALPHA 26
ok "bus declares its width"        {[$s width ALPHA] == 26}
ok "each lane is a real component" {[llength [$s components]] == 26}
ok "lane resolves to a terminal"   {[$s lane ALPHA 7] eq "ALPHA#7.t"}
ok "duplicate bundle rejected"     {[catch {$s bus ALPHA 4}]}
ok "zero width rejected"           {[catch {$s bus BAD 0}]}

# ====================================================================
section "bank -- repeated physical components"
# ====================================================================
set s [schem::new t]
$s bank LAMP 26 of lamp -r 2000 -ion 0.0005
ok "bank places count components"  {[llength [$s components]] == 26}
ok "bank element type is honoured" {[$s typeof LAMP#0] eq "lamp"}
ok "bank params reach elements"    {[$s get LAMP#5 r] == 2000}
ok "unit names an element"         {[$s unit LAMP 9] eq "LAMP#9"}
ok "bank needs the 'of' keyword"   {[catch {$s bank X 4 froz lamp}]}

# ====================================================================
section "connect -- zip, fan-out, slice"
# ====================================================================
set s [schem::new t]
$s bus A 4 ; $s bus B 4
$s connect A\[*\] -> B\[*\]
ok "vector<->vector zips lane-wise" {[llength [$s conns]] == 4}

set s [schem::new t]
$s bus A 4 ; $s add junction J
$s connect J.t -> A\[*\]
ok "scalar fans out to a vector"    {[llength [$s conns]] == 4}

set s [schem::new t]
$s bus D 8 ; $s bus O 8
$s connect D\[0..3\] -> O\[4..7\]
ok "slice<->slice connects 4 lanes" {[llength [$s conns]] == 4}
ok "reversed slice is allowed"      {[catch {$s connect D\[3..0\] -> O\[0..3\]}] == 0}

set s [schem::new t]
$s bus A 4 ; $s bus B 3
ok "width mismatch is rejected"     {[catch {$s connect A\[*\] -> B\[*\]}]}

# ====================================================================
section "repeat -- schematic expansion, not a runtime loop"
# ====================================================================
set s [schem::new t]
$s add ground GND
$s bank R 5 of resistor -r 1000
$s repeat i 0 4 { $s wire R#$i.b GND.t }
ok "repeat stamps one wire per i"   {[llength [$s conns]] == 5}
# the loop variable is just an integer in the caller's scope; nothing persists
ok "repeat leaves only components"  {[llength [$s components]] == 6}

# ====================================================================
section "a bus is electrical -- lanes carry voltage independently"
# ====================================================================
set s [schem::new t]
$s bus ALPHA 26
$s bank LAMP 26 of lamp -r 2000 -ion 0.0005
$s add ground GND
$s add battery V -emf 12 ; $s wire V.neg GND.t
$s connect ALPHA\[*\]  -> LAMP\[*\].a
$s connect LAMP\[*\].b -> GND.t
$s connect V.pos -> ALPHA\[7\]
$s solve
ok "driving lane 7 lights lamp 7"   {[$s lit LAMP#7]}
ok "and only lamp 7 (lane 3 dark)"  {![$s lit LAMP#3]}

# ====================================================================
section "a bus has discipline -- contention is an error"
# ====================================================================
set s [schem::new t]
$s bus DATA 1
$s add ground GND
$s add battery V -emf 12 ; $s wire V.neg GND.t
$s add buffer A -vhigh 12 ; $s add buffer B -vhigh 12
$s connect V.pos -> A.in ; $s connect V.pos -> A.oe ; $s connect V.pos -> B.oe
$s wire B.in GND.t
$s connect A.out -> DATA\[0\] ; $s connect B.out -> DATA\[0\]
$s add resistor PD -r 100000 ; $s connect DATA\[0\] -> PD.a ; $s wire PD.b GND.t
set rules [lmap f [$s validate] { dict get $f rule }]
ok "two drivers on one lane -> contention" {"bus-contention" in $rules}

# one driver enabled at a time is fine
set s [schem::new t]
$s bus DATA 1
$s add ground GND
$s add battery V -emf 12 ; $s wire V.neg GND.t
$s add buffer A -vhigh 12 ; $s add buffer B -vhigh 12
$s connect V.pos -> A.in ; $s connect V.pos -> A.oe   ;# only A enabled
$s wire B.in GND.t ; $s wire B.oe GND.t
$s connect A.out -> DATA\[0\] ; $s connect B.out -> DATA\[0\]
$s add resistor PD -r 100000 ; $s connect DATA\[0\] -> PD.a ; $s wire PD.b GND.t
set rules [lmap f [$s validate] { dict get $f rule }]
ok "single active driver is clean"  {"bus-contention" ni $rules}

# ====================================================================
section "pulldown -- a default level for a shared line"
# ====================================================================
set s [schem::new t]
$s bus IRQ 4
$s add ground GND
$s pulldown IRQ\[*\] 4700 GND.t
$s solve
ok "an undriven bus sits at 0 V"    {abs([$s probe [$s lane IRQ 0]]) < 1e-6}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
