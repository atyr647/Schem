# rc_timer.schem.tcl --
#
# A capacitor stores energy (state): charged through a resistor it follows
# the exponential V(t) = E (1 - e^{-t/RC}).  This is the basis of every
# Schem timer.  With R = 10 kOhm and C = 100 uF the time constant is 1 s.
#
#   run with:  bin/schem examples/rc_timer.schem.tcl

$s add battery   B -emf 10
$s add ground    GND
$s add resistor  R -r 10000
$s add capacitor C -c 100e-6 -v0 0

$s wire B.pos R.a
$s wire R.b   C.a
$s wire C.b   GND.t
$s wire B.neg GND.t

set data [$s run -duration 5.0 -dt 0.001 -record C.a]
set ts [dict get $data t]
set vs [dict get $data C.a]

puts "RC charge (R=10k, C=100uF, tau=1s):"
puts [format "  %-6s %-10s %-10s" "t(s)" "V_cap" "ideal"]
foreach mark {0.0 0.5 1.0 2.0 3.0 5.0} {
    set v 0.0
    foreach t $ts vv $vs { if {$t <= $mark + 1e-9} { set v $vv } }
    puts [format "  %-6.1f %-10.4f %-10.4f" $mark $v [expr {10*(1-exp(-$mark))}]]
}
puts ""
