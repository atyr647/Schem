# computer.tcl --
#
# A complete (tiny) computing PANEL: a machine that multiplies by repeated
# addition and halts, assembled entirely from catalog circuits -- which are
# assembled from logic cells, which are assembled from relays.  This is the
# Component -> Circuit -> Panel hierarchy carrying all the way up to a
# programmable machine, with nothing but electrical parts.
#
#   datapath : a 4-bit accumulator        (Q := Q + operand each tick)
#   control  : a 2-bit step counter + a seal-in HALT latch
#   program  : the operand (switches) and the halt count (wiring)
#
# When the step counter reaches its limit, the halt latch seals in and gates
# the operand to zero, so the accumulator freezes at  operand x (steps)  --
# a product, computed by a controlled sequence of additions, then stopped.
#
#   run with:  tclsh examples/computer.tcl   (takes a few seconds: it is a
#                                              real ~400-part relay machine)

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic.tcl]
source [file join $here .. lib catalog.tcl]

# build -- assemble the computing panel; returns {panel acc halt-node}.
proc build {} {
    set p [schem::panel computer]
    $p add battery VCC -emf 12 ; $p add ground GND ; $p wire VCC.neg GND.t
    set acc  [$p instantiate [schem::lib::accumulator AC 4] ACC]
    set cnt  [$p instantiate [schem::lib::counter CT 2] CNT]
    set hd   [$p instantiate [schem::lib::and_gate] HD]
    foreach m [list $acc $cnt $hd] { $p wire [dict get $m VCC] VCC.pos ; $p wire [dict get $m GND] GND.t }

    # one clock drives the datapath and the control counter together
    $p add switch SCLK ; $p wire VCC.pos SCLK.a
    $p wire SCLK.b [dict get $acc CLK] ; $p wire SCLK.b [dict get $cnt CLK]

    # halt-detect: the step counter has reached 3 (both bits high)
    $p wire [dict get $cnt Q0] [dict get $hd A]
    $p wire [dict get $cnt Q1] [dict get $hd B]

    # seal-in HALT latch: set by halt-detect, then holds; HL.nc = "running"
    $p add relay KS -coil 100 -pickup 0.01
    $p wire [dict get $hd OUT] KS.c1 ; $p wire KS.c2 GND.t
    $p add relay HL -coil 100 -pickup 0.01
    $p wire VCC.pos KS.com ; $p wire VCC.pos HL.com
    $p wire KS.no HL.c1 ; $p wire HL.no HL.c1      ;# set OR seal -> coil
    $p wire HL.c2 GND.t
    $p add resistor RPD -r 10000 ; $p wire HL.nc RPD.a ; $p wire RPD.b GND.t

    # the operand (switches) gated by "running": IN_i = operand_i AND running
    for {set i 0} {$i < 4} {incr i} {
        set ag [$p instantiate [schem::lib::and_gate] G$i]
        $p wire [dict get $ag VCC] VCC.pos ; $p wire [dict get $ag GND] GND.t
        $p add switch OP$i ; $p wire VCC.pos OP$i.a ; $p wire OP$i.b [dict get $ag A]
        $p wire HL.nc [dict get $ag B]
        $p wire [dict get $ag OUT] [dict get $acc IN$i]
    }
    return [list $p $acc]
}
proc setop {p val} { for {set i 0} {$i<4} {incr i} { if {[expr {($val>>$i)&1}]} {$p close OP$i} else {$p open OP$i} } }
proc total {p acc} { set v 0 ; for {set i 0} {$i<4} {incr i} { if {[$p probe [dict get $acc Q$i]] > 6} {set v [expr {$v|(1<<$i)}]} } ; return $v }
proc running {p} { return [expr {[$p probe HL.nc] > 6 ? 1 : 0}] }
proc tick {p} { $p open SCLK ; $p solve ; $p close SCLK ; $p solve }

lassign [build] p acc
set relays 0 ; foreach c [$p components] { if {[$p typeof $c] eq "relay"} { incr relays } }
puts "Schem computing panel: multiply by repeated addition, then HALT"
puts "([llength [$p components]] components, $relays relays -- a real relay machine)\n"

foreach operand {2 3} {
    setop $p $operand ; $p powerReset ; $p open SCLK ; $p solve
    puts "  program: operand = $operand"
    puts [format "    start  : total = %2d   running=%d" [total $p $acc] [running $p]]
    for {set k 1} {$k <= 5} {incr k} {
        tick $p
        puts [format "    tick %d : total = %2d   running=%d" $k [total $p $acc] [running $p]]
    }
    puts [format "    => computed %d x 3 = %d\n" $operand [total $p $acc]]
}
$p destroy
