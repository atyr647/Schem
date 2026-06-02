# standard_circuits.tcl --
#
# The named panel circuits every electrician knows, built from coils,
# contacts, resistors and capacitors -- and solved by the engine from the
# fundamental rules of electricity.  The time-based circuits are observed
# with the transient analyser, with their inputs worked over time by a
# scheduled stimulus (run -events ...) -- the bench operator at the panel.
#
#   run with:  tclsh examples/standard_circuits.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic standard.tcl]

proc rig {builder args} {
    set s [schem::new demo]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::$builder {*}$args] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    return [list $s $g]
}
proc feed {s g {name FS}} {
    $s add switch $name -state open
    $s wire VCC.pos $name.a ; $s wire $name.b [dict get $g IN]
    return $name
}
# strip -- render a recorded signal (by its record key) as an on/off bar.
proc strip {label key data} {
    set bar ""
    foreach v [dict get $data $key] { append bar [expr {$v > 6 ? "#" : "_"}] }
    puts [format "    %-11s %s" $label $bar]
}

puts "Schem standard panel circuits  (time runs left -> right, # = energised)\n"

# --- on-delay timer: OUT comes on a set time AFTER the input -------------
puts "  ON-DELAY timer  (IN closes early; OUT waits out the RC delay):"
lassign [rig on_delay_timer ton 100 5e-5] s g
set fs [feed $s $g]
set d [$s run -duration 0.009 -dt 5e-4 -record [list $fs.b [dict get $g OUT]] \
    -events {0.001 {close FS}}]
strip "IN"  $fs.b $d
strip "OUT" [dict get $g OUT] $d
$s destroy

# --- off-delay timer: OUT stays on a set time AFTER the input drops ------
puts "\n  OFF-DELAY timer (OUT follows IN on, then holds after IN drops):"
lassign [rig off_delay_timer toff 1e-4] s g
set fs [feed $s $g]
set d [$s run -duration 0.016 -dt 5e-4 -record [list $fs.b [dict get $g OUT]] \
    -events {0.0005 {close FS} 0.003 {open FS}}]
strip "IN"  $fs.b $d
strip "OUT" [dict get $g OUT] $d
$s destroy

# --- one-shot: one fixed pulse per rising edge, however long IN stays ----
puts "\n  ONE-SHOT        (rising edge -> a single fixed-width pulse):"
lassign [rig one_shot os 200 5e-5] s g
set fs [feed $s $g]
set d [$s run -duration 0.008 -dt 5e-4 -record [list $fs.b [dict get $g OUT]] \
    -events {0.001 {close FS}}]
strip "IN"  $fs.b $d
strip "OUT" [dict get $g OUT] $d
$s destroy

# --- debounce: a bouncing contact, cleaned ------------------------------
puts "\n  DEBOUNCE        (a chattering contact -> one clean make):"
set s [schem::new dbcmp]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
$s add switch BTN -state open ; $s wire VCC.pos BTN.a
$s add relay RAW -coil 100 -pickup 0.05            ;# raw relay, no filter
$s wire BTN.b RAW.c1 ; $s wire RAW.c2 GND.t ; $s wire VCC.pos RAW.com
$s add resistor PR -r 10000 ; $s wire RAW.no PR.a ; $s wire PR.b GND.t
set g [$s instantiate [schem::lib::debounce db 100 4e-5] U]
$s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
$s wire BTN.b [dict get $g IN]
set d [$s run -duration 0.012 -dt 5e-4 -record [list BTN.b RAW.no [dict get $g OUT]] \
    -events {0.001 {close BTN} 0.0015 {open BTN} 0.002 {close BTN}
             0.0025 {open BTN} 0.003 {close BTN}}]
set bar ""; foreach v [dict get $d BTN.b]      { append bar [expr {$v>6?"#":"_"}] }
puts [format "    %-11s %s" "IN (bouncy)" $bar]
set bar ""; foreach v [dict get $d RAW.no]      { append bar [expr {$v>6?"#":"_"}] }
puts [format "    %-11s %s" "raw relay" $bar]
set bar ""; foreach v [dict get $d [dict get $g OUT]] { append bar [expr {$v>6?"#":"_"}] }
puts [format "    %-11s %s" "debounced" $bar]
$s destroy

# --- flasher: a free-running pulse generator ----------------------------
puts "\n  FLASHER         (self-interrupting relay; no external clock):"
lassign [rig flasher] s g
set d [$s run -duration 0.008 -dt 5e-4 -record [dict get $g OUT]]
strip "OUT" [dict get $g OUT] $d
$s destroy

# --- relay bank: a latching annunciator with a common reset -------------
puts "\n  RELAY BANK      (3 seal-in channels, one common RESET):"
lassign [rig relay_bank bank 3] s g
proc q {s g i} { return [expr {[$s probe [dict get $g Q$i]] > 6 ? 1 : 0}] }
proc show {s g msg} {
    puts [format "    %-22s Q1 Q2 Q3 = %d %d %d" $msg [q $s $g 1] [q $s $g 2] [q $s $g 3]]
}
$s solve                                        ; show $s $g "power on"
$s press U/SET2 ; $s solve ; $s release U/SET2 ; $s solve ; show $s $g "set channel 2"
$s press U/SET1 ; $s solve ; $s release U/SET1 ; $s solve ; show $s $g "set channel 1 (2 holds)"
$s open  U/RST  ; $s solve ; $s close   U/RST  ; $s solve ; show $s $g "tap common RESET"
$s destroy

# --- safety interlock: start/stop seal-in gated by a guard chain --------
puts "\n  SAFETY INTERLOCK (start/stop seal-in; any guard or E-STOP drops RUN):"
lassign [rig safety_interlock il 2] s g
proc run? {s g} { return [expr {[$s probe [dict get $g RUN]] > 6 ? 1 : 0}] }
proc line {s g msg} { puts [format "    %-26s RUN = %d" $msg [run? $s $g]] }
$s solve                                                         ; line $s $g "power on (idle)"
$s press U/START ; $s solve ; $s release U/START ; $s solve       ; line $s $g "tap START (seals in)"
$s solve                                                         ; line $s $g "...keeps running"
$s open U/GUARD2 ; $s solve                                       ; line $s $g "a guard opens"
$s close U/GUARD2 ; $s solve                                      ; line $s $g "guard closed (no auto-run)"
$s press U/START ; $s solve ; $s release U/START ; $s solve       ; line $s $g "restart"
$s open U/ESTOP ; $s solve                                        ; line $s $g "E-STOP!"
$s destroy
puts ""
