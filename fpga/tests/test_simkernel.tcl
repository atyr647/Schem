# test_simkernel.tcl --
#
# The FPGA digital cycle engine (src/digital/cells.tcl + simkernel.tcl): proof
# that the generalized kernel evaluates LUTs and flip-flops correctly and
# advances clocked state exactly as digseq does for relays/memory.  Every design
# here is built inline as the shared digital-netlist IR (docs/DIGITAL.md s1) --
# no yosys, no schematic, no engine -- so the kernel is exercised in isolation.
#
# House style: `ok name {cond}` accumulates pass/fail, prints "N passed, M
# failed", and exits nonzero on any failure (so tests/run.tcl flags it).
#
#   tclsh tests/test_simkernel.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src digital cells.tcl]
source [file join $here .. src digital simkernel.tcl]

set ::passed 0 ; set ::failed 0
proc ok {name cond} {
    if {[catch {uplevel 1 [list expr $cond]} v]} { set v 0 ; set err " ($v)" } else { set err "" }
    if {$v} { incr ::passed } else { incr ::failed ; puts "FAIL: $name$err" }
}

# ============================================================================
#  1. LUT truth-table check -- the anchor combinational cell.
# ============================================================================
# A 2-input LUT loaded with the AND truth table (init bit i = output for input
# combo i): AND of {00,01,10,11} = {0,0,0,1} -> init = 0b1000 = 8.  Drive all
# four input combinations through a one-cell design and check the output net.

proc lut2 {init a b} {
    # design: in A=net2, B=net3 -> LUT -> out=net4.  (nets 0,1 are const rails.)
    set design [dict create name lut nbits 5 \
        inputs  [dict create A 2 B 3] \
        outputs [dict create Y 4] \
        clocks  {} \
        cells   [list [dict create name u0 type LUT \
                    params [dict create k 2 init $init] \
                    conn [dict create I [list 2 3] O 4]]]]
    dict set design stim 2 $a
    dict set design stim 3 $b
    set lv [::schem::digital::levelize $design]
    set nv [::schem::digital::settle $design [dict get $lv order] {}]
    return [dict get $nv 4]
}

# AND = init 0b1000 = 8
ok lut-and-00 {[lut2 8 0 0] == 0}
ok lut-and-01 {[lut2 8 0 1] == 0}
ok lut-and-10 {[lut2 8 1 0] == 0}
ok lut-and-11 {[lut2 8 1 1] == 1}
# XOR = {0,1,1,0} -> init 0b0110 = 6; full truth table in one shot
ok lut-xor {[list [lut2 6 0 0] [lut2 6 0 1] [lut2 6 1 0] [lut2 6 1 1]] eq {0 1 1 0}}

# LUT-vs-gate cross-check (the within-kernel verification of docs s7): a LUT
# loaded with AND's table must agree with the AND gate eval on all inputs.
ok lut-eq-gate {
    [string equal \
        [list [lut2 8 0 0] [lut2 8 0 1] [lut2 8 1 0] [lut2 8 1 1]] \
        [list [lindex [::schem::digital::Gate_eval AND 0 0] 0] \
              [lindex [::schem::digital::Gate_eval AND 0 1] 0] \
              [lindex [::schem::digital::Gate_eval AND 1 0] 0] \
              [lindex [::schem::digital::Gate_eval AND 1 1] 0]]]
}

# Basic-gate eval sanity (the other anchor): bitwise over a 4-bit vector.
ok gate-and-vec {[::schem::digital::Gate_eval AND {1 1 0 0} {1 0 1 0}] eq {1 0 0 0}}
ok gate-not-vec {[::schem::digital::Gate_eval NOT {1 0 1 0}] eq {0 1 0 1}}

# levelize must flag a combinational loop (two BUFs feeding each other's input).
# Nets 0/1/2 are the reserved const rails (0, 1, x); the loop uses 3<->4.
ok levelize-loop {
    [llength [dict get [::schem::digital::levelize [dict create \
        name loop nbits 5 inputs {} outputs {} clocks {} \
        cells [list \
            [dict create name g0 type BUF params {} conn {A 4 Y 3}] \
            [dict create name g1 type BUF params {} conn {A 3 Y 4}]]]] loops]] == 2
}

# ============================================================================
#  2. 1-bit DFF advancing on rising edges.
# ============================================================================
# D=net2, CLK=net3, Q=net4.  Drive a clock pattern and check Q samples D only
# on the 0->1 transition (digseq's rising-edge rule, polarity-aware).

proc dff_design {} {
    return [dict create name dff nbits 5 \
        inputs  [dict create D 2 CLK 3] \
        outputs [dict create Q 4] \
        clocks  {3} \
        cells   [list [dict create name ff type DFF \
                    params [dict create clkpol 1] \
                    conn [dict create D 2 CLK 3 Q 4]]]]
}

# Capture Q each cycle.  Stimulus pattern (D,CLK) per cycle:
#  cy0 D=1 clk=0 (no edge, Q stays 0)
#  cy1 D=1 clk=1 (rising edge -> Q=1)
#  cy2 D=0 clk=1 (no edge, Q holds 1)
#  cy3 D=0 clk=0 (falling, Q holds 1)
#  cy4 D=0 clk=1 (rising edge -> Q=0)
set ::dffQ {}
::schem::digital::run [dff_design] 5 \
    {0 {2 1 3 0}  1 {3 1}  2 {2 0}  3 {3 0}  4 {3 1}} \
    {apply {{cy nv} {lappend ::dffQ [dict get $nv 4]}}}
ok dff-edge-sampling {$::dffQ eq {0 1 1 1 0}}

# ============================================================================
#  3. 8-bit counter built by hand as IR, run for 16 cycles.
# ============================================================================
# A synchronous up-counter: 8 DFFs holding Q0..Q7, next-state computed with
# half-adder logic on the carry chain.  Built entirely from LUTs + DFFs so it
# exercises settle (the combinational next-state cone) AND tick (latching all 8
# bits on the same clock edge).  Expected value each cycle is hand-checkable:
# after N rising edges the count is N (mod 256).
#
# Net allocation (nbits = 2 rails + clk + 8 Q + 8 next = 19):
#   0,1 = const rails    2 = CLK
#   Q bits: 3..10        next bits (D of each DFF): 11..18
# next[i] = Q[i] XOR carry_in[i];  carry_out[i] = Q[i] AND carry_in[i]
# carry_in[0] = const1 (increment by 1) = net 1.
# We thread the carry through extra nets 19..25 (carry into bits 1..7).

proc counter8 {} {
    set CLK 2
    set Q [list 3 4 5 6 7 8 9 10]      ;# Q0..Q7
    set D [list 11 12 13 14 15 16 17 18] ;# next-state nets (DFF inputs)
    set carry [list 1 19 20 21 22 23 24 25] ;# carry into bit i; carry[0]=const1
    set nbits 26
    set cells {}
    for {set i 0} {$i < 8} {incr i} {
        set qi [lindex $Q $i] ; set di [lindex $D $i] ; set ci [lindex $carry $i]
        # next[i] = Q[i] XOR carry_in[i]  (XOR LUT init = 0b0110 = 6)
        lappend cells [dict create name sum$i type LUT params {k 2 init 6} \
            conn [dict create I [list $qi $ci] O $di]]
        # carry_out into bit i+1 = Q[i] AND carry_in[i]  (AND LUT init = 8)
        if {$i < 7} {
            set co [lindex $carry [expr {$i+1}]]
            lappend cells [dict create name cy$i type LUT params {k 2 init 8} \
                conn [dict create I [list $qi $ci] O $co]]
        }
        # the state bit: DFF clocked on CLK, D=next[i], Q=Q[i]
        lappend cells [dict create name ff$i type DFF params {clkpol 1} \
            conn [dict create D $di CLK $CLK Q $qi]]
    }
    set inputs [dict create CLK $CLK]
    set outputs [dict create COUNT $Q]
    return [dict create name counter8 nbits $nbits \
        inputs $inputs outputs $outputs clocks [list $CLK] cells $cells]
}

# Run 16 cycles, toggling the clock each cycle: even cycles clk=0, odd clk=1.
# A rising edge happens on every odd cycle -> 8 edges in 16 cycles -> count 0..8.
# Read the 8 Q nets as an integer after each cycle.
set ::counts {}
set stim [dict create]
for {set cy 0} {$cy < 16} {incr cy} {
    dict set stim $cy [dict create 2 [expr {$cy & 1}]]
}
::schem::digital::run [counter8] 16 $stim \
    {apply {{cy nv} {
        set v 0
        foreach net {3 4 5 6 7 8 9 10} i {0 1 2 3 4 5 6 7} {
            if {[dict get $nv $net]} { set v [expr {$v | (1 << $i)}] }
        }
        lappend ::counts $v
    }}}
# After cycle 0 (clk 0, no edge): 0.  After each rising edge (odd cycles) the
# count increments; it holds on the even cycles.  Sequence of the 16 reads:
ok counter8-sequence {$::counts eq {0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8}}
ok counter8-final {[lindex $::counts end] == 8}

# A longer run wraps at 256: drive 512 cycles = 256 edges -> back to 0.
set ::last 0
set stim2 [dict create]
for {set cy 0} {$cy < 512} {incr cy} { dict set stim2 $cy [dict create 2 [expr {$cy & 1}]] }
::schem::digital::run [counter8] 512 $stim2 \
    {apply {{cy nv} {
        set v 0
        foreach net {3 4 5 6 7 8 9 10} i {0 1 2 3 4 5 6 7} {
            if {[dict get $nv $net]} { set v [expr {$v | (1 << $i)}] }
        }
        set ::last $v
    }}}
ok counter8-wraps {$::last == 0}

# ============================================================================
#  Pending: cells that depend on stub evals (documented, not yet implemented).
# ============================================================================
# These exercise tick's staged-but-unimplemented state cells; they should raise
# a clear "not yet implemented" error.  We assert the error so the contract is
# pinned and the test stays green until the stubs are filled in.
proc raises {script} { expr {[catch {uplevel 1 $script}] ? 1 : 0} }
ok dffe-pending  {[raises {::schem::digital::DFFE_next {enpol 1} 0 1 1 1}]}
ok sdff-pending  {[raises {::schem::digital::SDFF_next {rstpol 1 rstval 0} 0 1 1 1}]}
ok mem-read-pending {[raises {::schem::digital::MEM_read {dbits 4} {} 0}]}

puts "$::passed passed, $::failed failed"
if {$::failed} { exit 1 }
