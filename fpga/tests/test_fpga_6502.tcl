#!/usr/bin/env tclsh
# test_fpga_6502.tcl -- run a REAL 6502 CPU on the engine, host-provided RAM.
#
# The milestone toward the NES (whose CPU is a 6502): import Arlet Ottens'
# verilog-6502, synthesized to 2344 gate-level cells (all within the engine's
# cell set), and run it cycle-accurately with the 2KB RAM modelled in the HOST
# harness -- exactly the emulator-backend pattern (CPU netlist = the chip, this
# harness = the board with memory).  The per-cycle bus trace is checked against
# the Icarus Verilog oracle (experiments/phase3_6502/cpu6502.ref.trace).
#
# Note on X: the oracle is 4-state and shows xx in cycles 0..9 (the 6502 leaves
# SP uninitialised through its reset/BRK sequence).  The engine is 2-state, so
# those cycles legitimately differ; the PROGRAM behaviour is deterministic, so
# we check every fully-concrete cycle (10..219) bit-identical plus the semantic
# landmarks.  Slow (thousands of cells x hundreds of cycles); gated on SCHEM_SLOW.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
foreach f {cells.tcl simkernel.tcl import_yosys.tcl} { source [file join $root src digital $f] }

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}

if {![info exists ::env(SCHEM_SLOW)]} {
    puts "ok   - (skipped: set SCHEM_SLOW=1 to run the 6502 -- thousands of cells)"
    puts "\n1 passed, 0 failed" ; exit 0
}

set ir [::schem::digital::yosys::parse [file join $root experiments phase3_6502 cpu6502.synth.json]]
set order [dict get [::schem::digital::levelize $ir] order]

# CPU bus nets (LSB first for vectors).
set clkn [lindex [dict get $ir inputs clk] 0]
set rstn [lindex [dict get $ir inputs reset] 0]
set DIn  [dict get $ir inputs DI]
set IRQn [lindex [dict get $ir inputs IRQ] 0]
set NMIn [lindex [dict get $ir inputs NMI] 0]
set RDYn [lindex [dict get $ir inputs RDY] 0]
set ABn  [dict get $ir outputs AB]
set DOn  [dict get $ir outputs DO]
set WEn  [lindex [dict get $ir outputs WE] 0]

proc busval {nv nets} {
    set v 0 ; set i 0
    foreach n $nets { if {[dict get $nv $n]} { set v [expr {$v | (1 << $i)}] } ; incr i }
    return $v
}

# 2KB RAM, zeroed, with the test program loaded at $0200 (see soc.v).
for {set i 0} {$i < 2048} {incr i} { set mem($i) 0 }
foreach {a b} {
    0x200 0xA2 0x201 0x00 0x202 0xA9 0x203 0x42 0x204 0x85 0x205 0x10
    0x206 0xE8 0x207 0x8A 0x208 0x95 0x209 0x20 0x20A 0xE0 0x20B 0x05
    0x20C 0xD0 0x20D 0xF8 0x20E 0x4C 0x20F 0x0E 0x210 0x02
} { set mem([expr {$a}]) [expr {$b}] }

set di 0
set design $ir
set state [dict create q [dict create] cells [dict create] prevclk [dict create]]
set lines {}

# soc_tb drives 2 reset edges (reset=1, not counted) then 220 counted edges.
for {set e 0} {$e < 222} {incr e} {
    set reset [expr {$e < 2 ? 1 : 0}]
    set n [expr {$e - 2}]

    # present DI + control inputs, stable for the whole clock period; the CPU
    # samples DI on the rising edge.  Two ticks per period (clk low then high)
    # so the kernel's edge detector (prevclk) advances correctly.
    for {set i 0} {$i < 8} {incr i} { dict set design stim [lindex $DIn $i] [expr {($di >> $i) & 1}] }
    dict set design stim $rstn $reset
    dict set design stim $IRQn 0 ; dict set design stim $NMIn 0 ; dict set design stim $RDYn 1

    # clk LOW tick: no edge -> CPU bus is the pre-edge state (AB/DO/WE this cycle).
    dict set design stim $clkn 0
    set r [::schem::digital::tick $design $order $state] ; set state [dict get $r state]
    set nv [dict get $r netval]
    set ABpre [busval $nv $ABn] ; set DOpre [busval $nv $DOn] ; set WEpre [dict get $nv $WEn]

    # synchronous RAM (soc.v posedge): read-old-data into di, write on WE, with
    # the $FFFC/$FFFD reset-vector overlay -> $0200.
    set addr [expr {$ABpre & 0x7FF}]
    if {$ABpre == 0xFFFC} { set dinew 0x00 } elseif {$ABpre == 0xFFFD} { set dinew 0x02 } else { set dinew $mem($addr) }
    if {$WEpre} { set mem($addr) $DOpre }

    # clk HIGH tick: rising edge latches the CPU (it samples the DI presented above).
    dict set design stim $clkn 1
    set r [::schem::digital::tick $design $order $state]
    set state [dict get $r state]
    set di $dinew

    # Resolve the post-edge bus with the NEW di: AB can be combinational from DI
    # (zero-page addressing drives AB from the just-fetched operand byte), so the
    # registered re-settle inside tick (done with the old DI) is not enough.
    for {set i 0} {$i < 8} {incr i} { dict set design stim [lindex $DIn $i] [expr {($di >> $i) & 1}] }
    set nv [::schem::digital::settle $design $order $state]

    if {$n >= 0} {
        lappend lines [format "cycle %d AB=%04x DB=%02x WE=%d DI=%02x R10=%02x R24=%02x" \
            $n [busval $nv $ABn] [busval $nv $DOn] [dict get $nv $WEn] $di $mem(16) $mem(36)]
    }
}

# --- compare against the Icarus oracle (the deterministic, concrete region) ---
set fh [open [file join $root experiments phase3_6502 cpu6502.ref.trace] r]
fconfigure $fh -encoding utf-8
set oracle [split [string trim [read $fh]] \n] ; close $fh

set firstConcrete 10
set ok1 1
for {set n $firstConcrete} {$n < 220} {incr n} {
    if {[lindex $lines $n] ne [lindex $oracle $n]} {
        set ok1 0
        puts "  mismatch cycle $n:"
        puts "    got:    [lindex $lines $n]"
        puts "    oracle: [lindex $oracle $n]"
        break
    }
}
ok "cycles 10..219 bit-identical to Icarus 6502 oracle" {$ok1}

# semantic landmarks (program-deterministic, independent of uninitialised SP).
ok "STA \$10 wrote \$42 (R10=42 from cycle 11)" {[string match "*R10=42*" [lindex $lines 11]]}
ok "indexed stores done (R24=04 from cycle 58)" {[string match "*R24=04*" [lindex $lines 58]]}
ok "ends in the JMP spin (AB in 020e/020f/0210)" {[regexp {AB=02(0e|0f|10)} [lindex $lines 219]]}

puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
