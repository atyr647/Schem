# relay_oscillator.schem.tcl --
#
# The classic relay buzzer / oscillator.  The coil is fed through the
# relay's own normally-closed contact: energising the coil opens that
# contact, which de-energises the coil, which lets the contact close
# again -- forever.  Oscillation is an emergent property of feedback plus
# the contact's switching lag; there is no clock and no loop construct.
#
#   run with:  bin/schem examples/relay_oscillator.schem.tcl

$s add battery B -emf 12
$s add ground  GND
$s add relay   K -coil 100 -pickup 0.05

$s wire B.pos K.com      ;# supply into the common contact
$s wire K.nc  K.c1       ;# NC contact feeds the coil  (self-interrupting)
$s wire K.c2  GND.t
$s wire B.neg GND.t

set data [$s run -duration 0.012 -dt 0.001 -record K.c1]

puts "Relay oscillator coil-drive node over time:"
foreach t [dict get $data t] v [dict get $data K.c1] {
    set bar [expr {$v > 1 ? "ENERGISED ####" : "open      ...."}]
    puts [format "  t=%.3f s  V=%5.1f  %s" $t $v $bar]
}
puts ""
