# stored_program.tcl --
#
# The capstone: a stored-program machine -- a tiny "CPU" -- assembled from
# nothing but electrical parts, where the PROGRAM LIVES IN MEMORY and a relay
# program counter steps through it.  It ties together the three sequential
# parts of the language: a memory chip (the program store), a relay counter
# (the program counter), and tri-state buffers (a shared address bus and a
# shared output bus).  No CPU is described in software -- the schematic IS the
# machine, and current flow IS the execution.
#
#   program counter (2-bit relay counter)
#        |  RUN-gated tri-state buffers
#        v
#   address bus  ---->  RAM (4 words x 2 bits)  ---->  output bus
#        ^                                     RUN-gated tri-state buffers
#        |  LOAD-gated tri-state buffers
#   address switches (used only while loading the program)
#
# Two clock domains, never shared, so every edge is unambiguous:
#   * WCLK writes the program into memory (LOAD phase, PC parked)
#   * PCLK advances the program counter (RUN phase, memory read-only)
#
# The shared address bus is the point of the tri-state buffers: during LOAD the
# manual address switches own it; during RUN the program counter owns it; the
# idle bank goes high-impedance (Hi-Z) and lets go, so two sources share two
# wires with no shorts -- exactly how a real bus works.
#
# And because the machine is purely digital sequential logic, the *fast*
# clocked-digital backend (`digseq`, the spec the emitted Zig transcribes)
# runs it cycle-for-cycle -- and this program checks that the fast path agrees
# with the electrical engine on the output bus at every step.  The schematic is
# the source; the engine is the truth; the compiled path must match it.
#
#   run with:  tclsh examples/stored_program.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic logic.tcl]
source [file join $here .. lib logic catalog.tcl]

# build -- assemble the machine; returns the schematic.
proc build {} {
    set s [schem::new stored_program]
    $s add battery V -emf 12 ; $s add ground G ; $s wire V.neg G.t
    proc Vsw {s nm} { $s add switch $nm ; $s wire V.pos $nm.a }   ;# a switch off VCC

    # the program counter: a 2-bit relay counter, clocked by PCLK
    set cnt [$s instantiate [schem::lib::counter C 2] PC]
    $s wire [dict get $cnt VCC] V.pos ; $s wire [dict get $cnt GND] G.t
    Vsw $s PCLK ; $s wire PCLK.b [dict get $cnt CLK]

    # the program store: 4 words x 2 bits of RAM
    $s add memory M -abits 2 -dbits 2 ; $s wire M.GND G.t

    # RUN / LOAD mode select.  RUN high -> the counter owns the bus; an inverter
    # relay gives /RUN, high during LOAD, so the address switches own it instead.
    Vsw $s RUN
    $s add relay INV -coil 1000 ; $s wire RUN.b INV.c1 ; $s wire INV.c2 G.t
    $s wire V.pos INV.com ; set nrun INV.nc

    # the shared address bus: a line per bit, each with a weak pull-down keeper
    foreach i {0 1} {
        $s add junction AB$i ; $s wire AB$i.t M.A$i
        $s add resistor KA$i -r 100000 ; $s wire AB$i.t KA$i.a ; $s wire KA$i.b G.t
        # RUN bank: program counter bit i drives the bus when RUN is high
        $s add buffer RB$i
        $s wire [dict get $cnt Q$i] RB$i.in ; $s wire RUN.b RB$i.oe ; $s wire RB$i.out AB$i.t
        # LOAD bank: address switch i drives the bus when RUN is low (/RUN high)
        Vsw $s LA$i
        $s add buffer LB$i
        $s wire LA$i.b LB$i.in ; $s wire $nrun LB$i.oe ; $s wire LB$i.out AB$i.t
    }

    # the write path: data switches -> data-in; WE + WCLK clock a word in
    foreach i {0 1} { Vsw $s LD$i ; $s wire LD$i.b M.DI$i }
    Vsw $s WE   ; $s wire WE.b   M.WE
    Vsw $s WCLK ; $s wire WCLK.b M.CLK

    # the shared output bus: memory data-out -> bus, gated onto it during RUN
    foreach i {0 1} {
        $s add junction OB$i
        $s add resistor KO$i -r 100000 ; $s wire OB$i.t KO$i.a ; $s wire KO$i.b G.t
        $s add buffer OBF$i
        $s wire M.DO$i OBF$i.in ; $s wire RUN.b OBF$i.oe ; $s wire OBF$i.out OB$i.t
    }
    return $s
}

proc setbits {s pfx val n} { for {set i 0} {$i<$n} {incr i} { if {($val>>$i)&1} {$s close $pfx$i} else {$s open $pfx$i} } }
proc outbus {s n}          { set v 0 ; for {set i 0} {$i<$n} {incr i} { if {[$s probe OB$i.t]>6} {set v [expr {$v|(1<<$i)}]} } ; return $v }

# step -- solve one cycle on the engine, run the same cycle on digseq (the fast
# clocked-digital backend), and assert they agree on the output bus.  Returns
# the engine's output-bus value; sets `mismatch` if the fast path diverged.
proc step {s stVar} {
    upvar 1 $stVar st
    $s solve
    set cir [$s compile]
    set r [schem::backend::digseq $cir $st] ; set st [dict get $r state]
    set lv [dict get $r levels]
    set nid(0) 0 ; set nid(1) 0
    dict for {n terms} [dict get $cir nodes map] {
        foreach i {0 1} { if {"OB$i.t" in $terms} { set nid($i) $n } }
    }
    set dv [expr {[dict get $lv $nid(0)] | ([dict get $lv $nid(1)]<<1)}]
    set ev [outbus $s 2]
    return [list $ev [expr {$ev==$dv}]]
}

# ---- run it -----------------------------------------------------------------
set s [build]
set program {1 2 3 0}     ;# the four words to store, addr 0..3

set relays 0 ; foreach c [$s components] { if {[$s typeof $c] eq "relay"} { incr relays } }
puts "Schem stored-program machine ([llength [$s components]] components, $relays relays)"
puts "  program in memory: addr0=1 addr1=2 addr2=3 addr3=0\n"

set st {} ; set allok 1

# LOAD PHASE -- /RUN owns the address bus; clock each word into its cell.
$s open RUN ; $s open WE ; $s open WCLK
foreach addr {0 1 2 3} {
    setbits $s LA $addr 2 ; setbits $s LD [lindex $program $addr] 2
    $s close WE
    $s open WCLK  ; lassign [step $s st] e ok ; set allok [expr {$allok && $ok}]
    $s close WCLK ; lassign [step $s st] e ok ; set allok [expr {$allok && $ok}]
    $s open WCLK  ; lassign [step $s st] e ok ; set allok [expr {$allok && $ok}]
}
$s open WE
puts "  loaded the program (4 clocked writes through the LOAD bank)\n"

# RUN PHASE -- RUN owns the address bus; the program counter sweeps the store.
$s open WCLK ; setbits $s LD 0 2 ; $s close RUN
$s open PCLK ; lassign [step $s st] e ok ; set allok [expr {$allok && $ok}]
puts "  executing (the program counter steps the address; memory drives OUT):"
puts [format "    PC=0  ->  OUT = %d" $e]
for {set k 1} {$k <= 5} {incr k} {
    $s close PCLK ; step $s st        ;# clock high: counter advances
    $s open  PCLK ; lassign [step $s st] e ok ; set allok [expr {$allok && $ok}]
    puts [format "    PC=%d  ->  OUT = %d" [expr {$k%4}] $e]
}

puts ""
if {$allok} {
    puts "  fast path verified: digseq (the clocked-digital backend) reproduced"
    puts "  the engine's output bus on every cycle -- the schematic ran its program,"
    puts "  and the compiled semantics matched the electrical truth exactly."
} else {
    puts "  !! the fast path diverged from the engine -- refusing to trust it"
}
$s destroy
