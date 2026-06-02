# relay_logic.tcl --
#
# A tour of the relay standard-cell library, showing that Schem is
# computationally universal: functionally-complete logic, composition,
# arithmetic and memory -- all built from relays, all solved by the
# electrical engine.
#
#   run with:  tclsh examples/relay_logic.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic logic.tcl]

proc hi {s t} { return [expr {[$s probe $t] > 6 ? 1 : 0}] }

# Build a supply + one instantiated cell, with input switches.
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
proc drive {s vals} {
    dict for {port v} $vals {
        set sw [dict get $::inmap $port]
        if {$v} {$s close $sw} else {$s open $sw}
    }
    $s solve
}

puts "Schem relay logic -- gates from contacts (no \"if\" anywhere)\n"

# 2-input gate truth tables
puts "  A B | AND OR NAND NOR XOR"
foreach {a b} {0 0  0 1  1 0  1 1} {
    set row ""
    foreach g {and_gate or_gate nand_gate nor_gate xor_gate} {
        lassign [rig $g {A B}] s gp
        drive $s [dict create A $a B $b]
        append row [format "  %d " [hi $s [dict get $gp OUT]]]
        $s destroy
    }
    puts "  $a $b |  $row"
}

# Full adder
puts "\n  A relay binary FULL ADDER  (SUM = A^B^Cin, COUT = carry):"
puts "  A B Cin | SUM COUT"
lassign [rig full_adder {A B CIN}] s g
foreach {a b c} {0 0 0  0 0 1  0 1 0  0 1 1  1 0 0  1 0 1  1 1 0  1 1 1} {
    drive $s [dict create A $a B $b CIN $c]
    puts [format "  %d %d  %d  |  %d   %d" $a $b $c \
        [hi $s [dict get $g SUM]] [hi $s [dict get $g COUT]]]
}
set nrelays 0
foreach c [$s components] { if {[$s typeof $c] eq "relay"} { incr nrelays } }
puts "  (one full adder = $nrelays relays, [llength [$s components]] components total)"
$s destroy

# Seal-in latch (memory)
puts "\n  A relay LATCH  (1 bit of memory via a self-holding contact):"
lassign [rig sr_latch {}] s g
proc bit {s} { return [expr {[$s energized U/K] ? 1 : 0}] }
$s solve                       ; puts "    power on            Q=[bit $s]"
$s press U/SET   ; $s solve     ; puts "    press SET           Q=[bit $s]"
$s release U/SET ; $s solve     ; puts "    release SET (hold)  Q=[bit $s]"
$s solve                       ; puts "    ... time passes     Q=[bit $s]"
$s open U/RST    ; $s solve     ; puts "    open RST (reset)    Q=[bit $s]"
$s close U/RST   ; $s solve     ; puts "    restore RST         Q=[bit $s]"
$s destroy
puts ""
