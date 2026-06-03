#!/usr/bin/env tclsh
# test_yosys_import.tcl --
#
# Exercises the Yosys JSON importer (src/digital/import_yosys.tcl) against a
# hand-authored, schema-faithful fixture (tests/fixtures/counter.yosys.json)
# so it runs with NO yosys toolchain installed.  Asserts the bit-blasting,
# the port/constant mapping and the cell count/shape of the emitted IR --
# the SHARED IR CONTRACT a separate kernel agent consumes.
#
#   tclsh tests/test_yosys_import.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src digital import_yosys.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

set fixture [file join $here fixtures counter.yosys.json]
set ir [::schem::digital::yosys::parse $fixture]

# ====================================================================
section "top module & shape"
# ====================================================================
ok "top module name"        {[dict get $ir name] eq "counter8"}
ok "ir has all IR keys"     {[lsort [dict keys $ir]] eq "cells clocks inputs name nbits outputs"}
ok "cell count = 8 DFF + 15 gates" {[llength [dict get $ir cells]] == 23}

# ====================================================================
section "ports map (LSB-first netId lists)"
# ====================================================================
# Bits are remapped first-seen during build: clk(bit2)->3, then q bits 3..10
# -> netIds 4..11.  Constants 0,1,2 are reserved (const0/const1/constX).
ok "single input clk"       {[dict keys [dict get $ir inputs]] eq "clk"}
ok "single output q"        {[dict keys [dict get $ir outputs]] eq "q"}
ok "clk is one net"         {[llength [dict get $ir inputs clk]] == 1}
ok "q is 8 nets"            {[llength [dict get $ir outputs q]] == 8}
ok "clk netId = 3"          {[dict get $ir inputs clk] eq {3}}
ok "q netIds LSB-first"     {[dict get $ir outputs q] eq {4 5 6 7 8 9 10 11}}
# never reuse the reserved constant ids for real nets
ok "no real net is 0/1/2"   {0 ni [concat {*}[dict values [dict get $ir inputs]] {*}[dict values [dict get $ir outputs]]]}

# ====================================================================
section "clocks"
# ====================================================================
ok "clk net is the clock"   {[dict get $ir clocks] eq [dict get $ir inputs clk]}

# ====================================================================
section "cell mapping & bit-blasting"
# ====================================================================
# find a cell by instance name
proc cellByName {ir name} {
    foreach c [dict get $ir cells] {
        if {[dict get $c name] eq $name} { return $c }
    }
    return ""
}

set ff0 [cellByName $ir ff0]
ok "ff0 is a DFF"           {[dict get $ff0 type] eq "DFF"}
ok "ff0 clkpol=1"           {[dict get $ff0 params clkpol] == 1}
ok "ff0 not async/enabled"  {[dict get $ff0 params async] == 0 && [dict get $ff0 params enable] == 0}
# ff0: C=clk(3) D=net11 Q=q[0]=net4.  D's net (yosys id 11) is first seen
# AFTER the 8 q outputs, so it allocates net 12.
ok "ff0 CLK connects to clk net" {[dict get $ff0 conn CLK] eq [dict get $ir inputs clk]}
ok "ff0 Q connects to q\[0\]"     {[dict get $ff0 conn Q] eq [list [lindex [dict get $ir outputs q] 0]]}

set sum0 [cellByName $ir sum0]
ok "sum0 is XOR"            {[dict get $sum0 type] eq "XOR"}
ok "sum0 A is q\[0\]"        {[dict get $sum0 conn A] eq [list [lindex [dict get $ir outputs q] 0]]}
# sum0 B is the constant "1" -> reserved const1 net id 1
ok "sum0 B is const1 (=1)"  {[dict get $sum0 conn B] eq {1}}
ok "sum0 Y feeds ff0 D"     {[dict get $sum0 conn Y] eq [dict get $ff0 conn D]}

set carry1 [cellByName $ir carry1]
ok "carry1 is AND"         {[dict get $carry1 type] eq "AND"}
ok "carry1 B is const1"    {[dict get $carry1 conn B] eq {1}}

# carry net threads sum1/carry2: carry1.Y is consumed by sum1.B and carry2.B
set sum1 [cellByName $ir sum1]
ok "carry1.Y -> sum1.B (shared net)" {[dict get $carry1 conn Y] eq [dict get $sum1 conn B]}

# ====================================================================
section "constants resolve to reserved ids"
# ====================================================================
# parse a tiny inline netlist using "0","1","x"
set tiny {
  {"modules":{"t":{
    "ports":{"a":{"direction":"input","bits":[5]},
             "o":{"direction":"output","bits":[6]}},
    "cells":{"g":{"type":"$_NOT_","connections":{"A":["0"],"Y":[6]}},
             "h":{"type":"$_AND_","connections":{"A":["1"],"B":["x"],"Y":[5]}}}
  }}}
}
set t [::schem::digital::yosys::parseString $tiny]
set g [cellByName $t g]
set h [cellByName $t h]
ok "\"0\" -> const0 net 0"  {[dict get $g conn A] eq {0}}
ok "\"1\" -> const1 net 1"  {[dict get $h conn A] eq {1}}
ok "\"x\" -> constX net 2"  {[dict get $h conn B] eq {2}}

# ====================================================================
section "unsupported cells error clearly"
# ====================================================================
set bad {
  {"modules":{"m":{"cells":{"u":{"type":"$lut","connections":{"A":[2],"Y":[3]}}}}}}
}
ok "unknown cell type raises" {[catch {::schem::digital::yosys::parseString $bad}]}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
