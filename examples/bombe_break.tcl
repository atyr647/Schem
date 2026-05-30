# bombe_break.tcl --
#
# A complete Enigma break, end to end, the way Hut 6 did it:
#
#   1. An operator encrypts a weather report on a Wehrmacht Enigma under a
#      secret key (wheel order, rings, ground setting).
#   2. We intercept only the ciphertext and guess a crib (the message almost
#      certainly begins WETTERVORHERSAGE -- "weather forecast").
#   3. Turing's bombe runs the crib against all 17,576 rotor start positions
#      and returns a short list of "stops".
#   4. We try each stop on the real machine; the one that yields German is the
#      key, and the message falls out.
#
# The bombe here is a real Schem schematic: at each candidate it is a board the
# engine solves, and a stop is an indicator lamp the engine lights from its own
# continuity.  The heavy sweep is the same logic compiled to Zig.
#
#   tclsh examples/bombe_break.tcl
set here [file dirname [file normalize [info script]]]
source [file join $here .. lib enigma.tcl]
source [file join $here .. lib bombe.tcl]
source [file join $here .. src schem.tcl]
source [file join $here .. lib bombe_schem.tcl]

set wheels {I II III} ; set rings AAA ; set refl B
set SECRET QER
set plain  "WETTERVORHERSAGEBERLINDIENSTAGSECHSUHR"

puts "== The intercept =="
set m [::enigma::new -wheels $wheels -rings $rings -pos $SECRET -reflector $refl]
set cipher [::enigma::encipher $m $plain]
puts "  wheel order : $wheels   rings : $rings   reflector : $refl"
puts "  secret key  : $SECRET   (this is what we must find)"
puts "  ciphertext  : $cipher"

puts "\n== The crib =="
set crib "WETTERVORHERSAGE"
set cribCt [string range $cipher 0 [expr {[string length $crib]-1}]]
puts "  guessed plain: $crib"
puts "  aligns cipher: $cribCt"
set edges [::bombe::menu $crib $cribCt]
set test  [::bombe::central $edges]
puts "  menu cables  : [::bombe::letters $edges]"
puts "  test register: $test  (the most-connected letter)"

puts "\n== Running the bombe (Schem schematic, lamp readout) =="
# Scan a band of positions and build the actual board at each, reading the stop
# from a lamp.  (The full 26^3 sweep is the Zig scanner; here we show the real
# circuit lighting up at the stops in the L=Q plane for brevity.)
set seed [::enigma::ord $test]
set stops {}
for {set M 0} {$M < 26} {incr M} {
  for {set R 0} {$R < 26} {incr R} {
    set ground [list 16 $M $R]
    set perms [::bombe::scramblerPerms $edges $wheels $rings $ground $refl]
    set s [::bombe::build $edges $perms $test $seed scan]
    ::bombe::addLamps $s $test
    $s solve
    set lit [::bombe::litLamps $s]
    if {[llength $lit] == 1} {
        set g "Q[::enigma::chr $M][::enigma::chr $R]"
        lappend stops $g
        puts "  STOP $g  --  one lamp lit: stecker $test-[::enigma::chr [lindex $lit 0]]"
    }
    $s destroy
  }
}

puts "\n== Trying each stop on the real machine =="
foreach g $stops {
    set md [::enigma::new -wheels $wheels -rings $rings -pos $g -reflector $refl]
    set dec [::enigma::encipher $md $cipher]
    set german [regexp {WETTER|BERLIN|UHR} $dec]
    puts [format "  %s -> %s   %s" $g $dec [expr {$german ? "<== GERMAN!" : "(noise)"}]]
}

puts "\n== Broken =="
set md [::enigma::new -wheels $wheels -rings $rings -pos [lindex $stops 0] -reflector $refl]
puts "  key  : [lindex $stops 0]"
puts "  plain: [::enigma::encipher $md $cipher]"
