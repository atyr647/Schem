# test_standard.tcl --
#
# The standard panel circuits: time-delay relays (on/off delay), a one-shot
# (monostable), an RC contact debounce, a free-running flasher and a
# latching relay bank.  Each is an ordinary electrical circuit; the timing
# behaviour is observed with the transient analyser, driving inputs with a
# timed stimulus (run -events ...), as you would operate a panel.
#
#   tclsh tests/test_standard.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib standard.tcl]

# rig -- supply rails + one instantiated standard cell.
proc rig {builder args} {
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::$builder {*}$args] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    return [list $s $g]
}
# feed -- a switch from VCC into the cell's IN port.
proc feed {s g {name FS}} {
    $s add switch $name -state open
    $s wire VCC.pos $name.a ; $s wire $name.b [dict get $g IN]
    return $name
}
# bit -- HIGH (1) if a recorded sample is above the logic threshold.
proc bit {v} { return [expr {$v > 6 ? 1 : 0}] }
# at -- the recorded value of port `p` at time `t` (dt grid).
proc at {data g p t dt} {
    return [bit [lindex [dict get $data [dict get $g $p]] [expr {int(round($t/$dt))}]]]
}
# rises -- number of LOW->HIGH transitions in a recorded signal.
proc rises {data g p} {
    set n 0 ; set prev 0
    foreach v [dict get $data [dict get $g $p]] {
        set b [bit $v]
        if {$b && !$prev} { incr n }
        set prev $b
    }
    return $n
}

# ---- on-delay timer: OUT is delayed after IN closes --------------------

test on-delay {OUT picks up only after the RC delay, not immediately} -body {
    lassign [rig on_delay_timer ton 100 5e-5] s g
    feed $s $g
    set d [$s run -duration 0.008 -dt 5e-4 -record [dict get $g OUT] \
        -events {0.001 {close FS}}]
    set early [at $d $g OUT 0.002 5e-4]   ;# 1 ms after close: still charging
    set late  [at $d $g OUT 0.007 5e-4]   ;# well past the delay: picked up
    $s destroy
    list $early $late
} -result {0 1}

# ---- off-delay timer: OUT lingers after IN opens -----------------------

test off-delay {OUT picks up at once, then holds after IN drops} -body {
    lassign [rig off_delay_timer toff 1e-4] s g
    feed $s $g
    set d [$s run -duration 0.016 -dt 5e-4 -record [dict get $g OUT] \
        -events {0.0005 {close FS} 0.003 {open FS}}]
    set on    [at $d $g OUT 0.002 5e-4]   ;# energised while IN is on
    set hold  [at $d $g OUT 0.008 5e-4]   ;# still on after IN opened (.003)
    set off   [at $d $g OUT 0.015 5e-4]   ;# eventually drops out
    $s destroy
    list $on $hold $off
} -result {1 1 0}

# ---- one-shot: a single fixed pulse on the rising edge -----------------

test one-shot {one output pulse even though IN stays high} -body {
    lassign [rig one_shot os 200 5e-5] s g
    feed $s $g
    set d [$s run -duration 0.008 -dt 5e-4 -record [dict get $g OUT] \
        -events {0.001 {close FS}}]
    set pulses [rises $d $g OUT]
    set ended  [at $d $g OUT 0.0075 5e-4]  ;# pulse is over despite IN high
    $s destroy
    list $pulses $ended
} -result {1 0}

# ---- debounce: one clean edge despite a bouncing contact ---------------

test debounce {a bouncing input yields a single clean output transition} -body {
    lassign [rig debounce db 100 4e-5] s g
    feed $s $g BTN
    # BTN bounces three times before settling closed at t=0.003
    set d [$s run -duration 0.012 -dt 5e-4 -record [dict get $g OUT] -events {
        0.001 {close BTN} 0.0015 {open BTN} 0.002 {close BTN}
        0.0025 {open BTN} 0.003 {close BTN}}]
    set edges [rises $d $g OUT]
    set final [at $d $g OUT 0.0115 5e-4]
    $s destroy
    list $edges $final
} -result {1 1}

# ---- flasher: free-running oscillation, no external clock --------------

test flasher {the self-interrupting relay oscillates} -body {
    lassign [rig flasher] s g
    set d [$s run -duration 0.006 -dt 5e-4 -record [dict get $g OUT]]
    expr {[rises $d $g OUT] >= 2}
} -result 1

# ---- relay bank: independent latches, one common reset -----------------

test relay-bank {channels latch independently and clear together} -body {
    lassign [rig relay_bank bank 3] s g
    proc q {s g i} { return [expr {[$s probe [dict get $g Q$i]] > 6 ? 1 : 0}] }
    set seq {}
    $s solve ; lappend seq "[q $s $g 1][q $s $g 2][q $s $g 3]"          ;# 000
    $s press U/SET2 ; $s solve ; $s release U/SET2 ; $s solve
    lappend seq "[q $s $g 1][q $s $g 2][q $s $g 3]"                      ;# 010
    $s press U/SET1 ; $s solve ; $s release U/SET1 ; $s solve
    lappend seq "[q $s $g 1][q $s $g 2][q $s $g 3]"                      ;# 110
    $s open U/RST ; $s solve ; $s close U/RST ; $s solve
    lappend seq "[q $s $g 1][q $s $g 2][q $s $g 3]"                      ;# 000
    $s destroy
    set seq
} -result {000 010 110 000}

cleanupTests
