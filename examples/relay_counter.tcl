# relay_counter.tcl --
#
# Clocked sequential logic, built from nothing but relays: a gated D latch,
# a rising-edge D flip-flop, a toggle flip-flop and a 2-bit binary counter.
# Combinational gates (relay_logic.tcl) plus *state* make a machine; the
# state here is the engine's persistent relay memory, and the timing is the
# clock.  No "if", no loop -- just contacts, coils and a clock.
#
#   run with:  tclsh examples/relay_counter.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic.tcl]

proc hi {s t} { return [expr {[$s probe $t] > 6 ? 1 : 0}] }

# Build a supply + one instantiated cell, with named input switches.
proc rig {builder inports} {
    set s [schem::new demo]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::$builder] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    set i 0
    foreach p $inports {
        set sw SW[incr i]
        $s add switch $sw
        $s wire VCC.pos $sw.a ; $s wire $sw.b [dict get $g $p]
        dict set ::inmap $p $sw
    }
    return [list $s $g]
}
proc set1 {s port v} {
    set sw [dict get $::inmap $port]
    if {$v} {$s close $sw} else {$s open $sw}
}
# tick -- one clock cycle: CLK low (settle), then CLK high (the rising edge).
proc tick {s} { set1 $s CLK 0 ; $s solve ; set1 $s CLK 1 ; $s solve }

puts "Schem clocked logic -- flip-flops and a counter from relays\n"

# --- gated D latch: transparent while CLK high, holds while CLK low -------
puts "  Gated D latch (Q follows D while CLK=1, then holds):"
puts "    CLK D | Q   note"
lassign [rig d_latch {D CLK}] s g
foreach {clk d note} {1 1 {sample}  1 0 {transparent}  0 1 {hold prev}  0 0 {hold prev}} {
    set1 $s CLK $clk ; set1 $s D $d ; $s solve
    puts [format "     %d  %d  | %d   %s" $clk $d [hi $s [dict get $g Q]] $note]
}
$s destroy

# --- rising-edge D flip-flop ---------------------------------------------
puts "\n  Rising-edge D flip-flop (Q := D only at the clock edge):"
lassign [rig d_flipflop {D CLK}] s g
set1 $s CLK 0
set1 $s D 1 ; tick $s ; puts "    D=1, clock edge          -> Q=[hi $s [dict get $g Q]]"
set1 $s D 0 ; set1 $s CLK 1 ; $s solve
puts "    D=0 while CLK held high   -> Q=[hi $s [dict get $g Q]]   (edge already passed)"
tick $s ; puts "    D=0, clock edge          -> Q=[hi $s [dict get $g Q]]"
$s destroy

# --- toggle flip-flop -----------------------------------------------------
puts "\n  Toggle flip-flop (Q inverts on each edge):"
lassign [rig t_flipflop {CLK}] s g
set1 $s CLK 0 ; $s solve
puts -nonewline "    Q:"
puts -nonewline " [hi $s [dict get $g Q]]"
for {set i 0} {$i < 6} {incr i} { tick $s ; puts -nonewline " [hi $s [dict get $g Q]]" }
puts ""
$s destroy

# --- 2-bit binary counter -------------------------------------------------
puts "\n  2-bit binary counter (relay ripple counter):"
puts "    tick | Q1 Q0 = count"
lassign [rig counter2 {CLK}] s g
set1 $s CLK 0 ; $s solve
set b1 [hi $s [dict get $g Q1]] ; set b0 [hi $s [dict get $g Q0]]
puts [format "    %4s |  %d  %d  = %d" "rst" $b1 $b0 [expr {2*$b1+$b0}]]
for {set i 1} {$i <= 5} {incr i} {
    tick $s
    set b1 [hi $s [dict get $g Q1]] ; set b0 [hi $s [dict get $g Q0]]
    puts [format "    %4d |  %d  %d  = %d" $i $b1 $b0 [expr {2*$b1+$b0}]]
}
set nrelays 0
foreach c [$s components] { if {[$s typeof $c] eq "relay"} { incr nrelays } }
puts "    (the counter is $nrelays relays, [llength [$s components]] components -- all solved electrically)"
$s destroy

# --- the same counter, free-running on a relay-oscillator clock, in time --
# A self-interrupting relay is a clock; the transient analyser steps the
# whole machine forward in real time.  Each flip-flop adds a little relay
# propagation delay, so (exactly like a real relay counter) the count
# advances a few dt after each clock edge.
puts "\n  Same counter, clocked by a free-running relay oscillator (transient):"
set s [schem::new clocked]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
$s add relay OSC -coil 100 -pickup 0.05
$s wire VCC.pos OSC.com ; $s wire OSC.nc OSC.c1 ; $s wire OSC.c2 GND.t
set g [$s instantiate [schem::lib::counter2] U]
$s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
$s wire OSC.c1 [dict get $g CLK]
set data [$s run -duration 0.020 -dt 0.001 \
    -record [list OSC.c1 [dict get $g Q0] [dict get $g Q1]]]
puts "      t      CLK  Q1 Q0  count"
foreach t [dict get $data t] \
        clk [dict get $data OSC.c1] \
        q0 [dict get $data [dict get $g Q0]] \
        q1 [dict get $data [dict get $g Q1]] {
    set b0 [expr {$q0 > 6 ? 1 : 0}] ; set b1 [expr {$q1 > 6 ? 1 : 0}]
    puts [format "      %.3f   %d    %d  %d   = %d" \
        $t [expr {$clk > 6 ? 1 : 0}] $b1 $b0 [expr {2*$b1+$b0}]]
}
$s destroy
puts ""
