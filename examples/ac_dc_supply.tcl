# ac_dc_supply.tcl --
#
# A real AC-DC power supply: a full-wave BRIDGE rectifier off a sinusoidal
# secondary, into a smoothing reservoir and a load -- the front end of nearly
# every mains supply.  This is the topology ET1 pointed at, and it exercises
# the whole chain: a time-varying source, four rectifier diodes, transient
# analysis, ripple measurement, and a real-parts design review.
#
#   tclsh examples/ac_dc_supply.tcl
#
#         AC ~       D1  +---+--->  Vout (+)
#        (sec)  o----|>|--+   |
#          |           D3 |   C  RL
#          o----|>|--+    |   |
#                D2  | D4 +---+--->  GND
#
# Bridge: on each half-cycle two diodes conduct, so the load always sees the
# same polarity -- full-wave.  The reservoir cap holds the peak between humps;
# the leftover sag is the ripple.
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib parts parts.tcl]
source [file join $here .. lib parts ratings.tcl]

# Build the bridge.  Secondary: 12 V RMS -> ~17 V peak.
set s [schem::new ac_dc]
$s add vsource SEC -vac 17 -freq 60 -voff 0      ;# 12 Vrms ~ 17 Vpk
$s add ground GND

# Four rectifier diodes as a bridge.  AC nodes are SEC.pos and SEC.neg.
::schem::parts::place $s D1 1N4007
::schem::parts::place $s D2 1N4007
::schem::parts::place $s D3 1N4007
::schem::parts::place $s D4 1N4007
::schem::parts::place $s C1 CAP_1000u_16V          ;# (we'll see this is marginal!)
$s add resistor RL -r 68                           ;# ~0.2 A load

# Bridge wiring: + rail = D1.k = D3.k ; - rail (GND) = D2.a = D4.a
#   SEC.pos -> D1.a , D2.k     SEC.neg -> D3.a , D4.k
$s wire SEC.pos D1.a ; $s wire SEC.pos D2.k
$s wire SEC.neg D3.a ; $s wire SEC.neg D4.k
$s wire D1.k C1.a ; $s wire D3.k C1.a              ;# + rail
$s wire D2.a GND.t ; $s wire D4.a GND.t            ;# - rail (return)
$s wire C1.a RL.a ; $s wire C1.b GND.t ; $s wire RL.b GND.t

puts "Topology: full-wave bridge, 12 Vrms (17 Vpk) secondary, 1000uF, 68 ohm load\n"

# --- transient: trace a few cycles and measure ripple + DC level ---
set res [$s run -duration 0.06 -dt 5e-5 -record {SEC.pos RL.a}]
set ts [dict get $res t] ; set vo [dict get $res RL.a]
set n [llength $ts]
# steady-state window: last third
set win {}
for {set i [expr {$n*2/3}]} {$i < $n} {incr i} { lappend win [lindex $vo $i] }
set sorted [lsort -real $win]
set vmax [lindex $sorted end] ; set vmin [lindex $sorted 0]
set vdc [expr {($vmax+$vmin)/2.0}]
puts [format "DC output  : %.2f V" $vdc]
puts [format "Ripple p-p : %.2f V  (%.1f%% of DC)" [expr {$vmax-$vmin}] [expr {($vmax-$vmin)/$vdc*100}]]
puts [format "Peak / min : %.2f V / %.2f V" $vmax $vmin]

# --- design review: are the parts up to the job? ---
puts ""
$s solve
puts [::schem::ratings::report $s]
