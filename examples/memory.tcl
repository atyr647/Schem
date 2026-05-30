# memory.tcl --
#
# A RAM chip as a first-class electrical part.  A memory presents real pins --
# address (A0..), data-in (DI0..), data-out (DO0..), write-enable (WE) and a
# clock (CLK) -- and stores a word per address.  A write happens on the rising
# CLK edge when WE is high; the addressed cell latches DI, and from then on
# DO drives that word back out (through the chip's output resistance) until it
# is overwritten.  This is genuine sequential storage: the value is sealed in
# and survives after the clock falls, with no software state anywhere.
#
#   write phase:  put address + data on the pins, pulse CLK with WE high
#   read  phase:  put the address on the pins, DO drives the stored word
#
#   run with:  tclsh examples/memory.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

set AB 3 ; set DB 4                 ;# 8 words x 4 bits
set s [schem::new memory]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
$s add memory M -abits $AB -dbits $DB
$s wire M.GND GND.t

# A switch on every address / data-in / control pin -- the panel that drives
# the chip.  Closing a switch pulls that pin up to the rail (logic 1).
proc pin {s name} {
    $s add switch S_$name -state open
    $s wire VCC.pos S_$name.a ; $s wire S_$name.b M.$name
}
for {set i 0} {$i < $AB} {incr i} { pin $s A$i }
for {set i 0} {$i < $DB} {incr i} { pin $s DI$i }
pin $s WE
pin $s CLK

proc setbits {s prefix n val} {
    for {set i 0} {$i < $n} {incr i} {
        if {[expr {($val >> $i) & 1}]} { $s close S_$prefix$i } else { $s open S_$prefix$i }
    }
}
proc dataout {s n} {
    set v 0
    for {set i 0} {$i < $n} {incr i} { if {[$s probe M.DO$i] > 6} { set v [expr {$v | (1 << $i)}] } }
    return $v
}

# write VAL to ADDR: drive the pins, raise WE, pulse CLK (rising edge latches).
proc store {s ab db addr val} {
    setbits $s A $ab $addr
    setbits $s DI $db $val
    $s close S_WE
    $s open  S_CLK ; $s solve
    $s close S_CLK ; $s solve        ;# rising edge -> the cell latches DI
    $s open  S_CLK ; $s open S_WE ; $s solve
}
# read ADDR: drive the address, let DO settle, sample it.
proc fetch {s ab db addr} {
    setbits $s A $ab $addr
    $s solve
    return [dataout $s $db]
}

puts "RAM: $AB address bits ([expr {1<<$AB}] words) x $DB data bits"
store $s $AB $DB 2 13      ;# mem\[2] := 13
store $s $AB $DB 5 6       ;# mem\[5] := 6
store $s $AB $DB 0 9       ;# mem\[0] := 9

foreach a {0 1 2 5} {
    puts [format "  read mem\[%d] = %2d" $a [fetch $s $AB $DB $a]]
}
puts "(address 1 was never written, so it reads 0)"
