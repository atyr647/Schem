# sequencer.tcl --
#
# An instruction sequencer: the control unit of a machine, built from a
# counter and a decoder.  Each clock advances the phase; exactly one control
# line is energised per step, cycling forever.  This is what drives "step 1,
# then step 2, then step 3, ..." in a relay computer -- entirely electrical,
# no program counter in software, just a counter and a decoder of relays.
#
#   clock --> counter --> decoder --> one-hot control lines P0,P1,P2,P3,...
#
#   run with:  tclsh examples/sequencer.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic logic.tcl]
source [file join $here .. lib logic catalog.tcl]

set N 2   ;# 2 address bits -> 4 control phases
set s [schem::new sequencer]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
set g [$s instantiate [schem::lib::sequencer seq $N] U]
$s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
$s add switch SCLK ; $s wire VCC.pos SCLK.a ; $s wire SCLK.b [dict get $g CLK]
proc tick {s} { $s open SCLK ; $s solve ; $s close SCLK ; $s solve }

set phases [expr {1 << $N}]
set names {FETCH DECODE EXECUTE STORE}
set relays 0 ; foreach c [$s components] { if {[$s typeof $c] eq "relay"} { incr relays } }
puts "A $phases-phase instruction sequencer ($relays relays)\n"
$s open SCLK ; $s solve
proc show {s g phases names} {
    for {set k 0} {$k < $phases} {incr k} {
        if {[$s probe [dict get $g P$k]] > 6} {
            puts [format "    phase %d : %s" $k [lindex $names $k]]
        }
    }
}
puts "  reset:" ; show $s $g $phases $names
for {set t 1} {$t <= 6} {incr t} { tick $s ; puts "  tick $t:" ; show $s $g $phases $names }
$s destroy
puts ""
