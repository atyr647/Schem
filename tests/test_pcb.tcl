#!/usr/bin/env tclsh
# test_pcb.tcl -- export to the files a board house needs.  A Schem schematic
# is an electrical netlist already, so these assert that the KiCad netlist and
# BOM are faithful: every placed part gets a reference designator and a real
# footprint, the nets match the engine's own continuity, values read in
# engineering notation, and connectivity slips are flagged.
#
#   tclsh tests/test_pcb.tcl
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

# a voltage divider: the canonical small board
proc divider {} {
    set s [schem::new divider]
    $s add battery B -emf 9
    $s add resistor R1 -r 1000
    $s add resistor R2 -r 2000
    $s add ground GND
    $s wire B.pos R1.a ; $s wire R1.b R2.a ; $s wire R2.b GND.t ; $s wire B.neg GND.t
    return $s
}

# ====================================================================
section "engineering value formatting"
# ====================================================================
ok "1000 -> 1k"            {[::schem::pcb::eng 1000] eq "1k"}
ok "2200 -> 2.2k"          {[::schem::pcb::eng 2200] eq "2.2k"}
ok "1e-6 F -> 1uF"         {[::schem::pcb::eng 1e-6 F] eq "1uF"}
ok "4.7e-9 -> 4.7n"        {[::schem::pcb::eng 4.7e-9] eq "4.7n"}
ok "9 V -> 9V"             {[::schem::pcb::eng 9 V] eq "9V"}
ok "0 stays 0"             {[::schem::pcb::eng 0 V] eq "0V"}
ok "1.5e6 -> 1.5M"         {[::schem::pcb::eng 1.5e6] eq "1.5M"}

# ====================================================================
section "reference designators (IEEE 315 prefixes)"
# ====================================================================
set s [divider]
set ref [::schem::pcb::refmap $s]
ok "battery -> BT1"        {[dict get $ref B] eq "BT1"}
ok "resistors -> R1, R2"   {[dict get $ref R1] eq "R1" && [dict get $ref R2] eq "R2"}
ok "ground is not placed"  {![dict exists $ref GND]}

# ====================================================================
section "nets follow the engine's continuity"
# ====================================================================
set nets [::schem::pcb::nets $s]
# the divider tap: R1.b and R2.a share exactly one net, with two pins
set tap ""
dict for {nid spec} $nets {
    lassign $spec nname pins
    set rds [lsort [lmap p $pins { lindex $p 0 }]]
    if {$rds eq {R1 R2}} { set tap [list $nname $pins] }
}
ok "R1.b and R2.a form one net" {$tap ne ""}
# GND ties battery neg and R2.b
set gndpins ""
dict for {nid spec} $nets {
    lassign $spec nname pins
    if {$nname eq "GND"} { set gndpins [lsort [lmap p $pins { lindex $p 0 }]] }
}
ok "GND net ties BT1 and R2"     {$gndpins eq {BT1 R2}}

# ====================================================================
section "KiCad netlist structure"
# ====================================================================
set net [::schem::pcb::kicadNetlist $s]
ok "is a KiCad export s-expr"    {[string match "(export*" $net]}
ok "declares components block"   {[string match "*(components*" $net]}
ok "declares nets block"         {[string match "*(nets*" $net]}
ok "carries the footprint"       {[string match "*Resistor_THT:*" $net]}
ok "carries engineering value"   {[string match "*\"1kΩ\"*" $net]}
ok "keeps the Schem name field"  {[string match "*Schem_Name*" $net]}
ok "pinfunction keeps pin names" {[string match "*pinfunction \"pos\"*" $net]}

# ====================================================================
section "BOM CSV"
# ====================================================================
set bom [::schem::pcb::bomCsv $s]
set lines [split $bom \n]
ok "has a header row"            {[lindex $lines 0] eq "Item,Qty,Value,Footprint,References,Description"}
ok "one row per distinct part"   {[llength $lines] == 4}    ;# header + BT + R1 + R2 (R1,R2 differ in value)
ok "lists the references"        {[string match "*R1*" $bom] && [string match "*R2*" $bom]}
ok "groups identical parts"      {[apply {{} {
    set s [schem::new g]
    $s add resistor RA -r 1000 ; $s add resistor RB -r 1000 ; $s add ground GND
    $s wire RA.a RB.a ; $s wire RA.b GND.t ; $s wire RB.b GND.t
    set bom [::schem::pcb::bomCsv $s]
    # two identical 1k resistors collapse to one BOM line of qty 2
    expr {[string match "*2,1k*" $bom]}
}}]}

# ====================================================================
section "manufacturability pre-flight"
# ====================================================================
ok "clean divider has no warnings" {[llength [::schem::pcb::manufacturability $s]] == 0}
ok "a floating pin is flagged"     {[apply {{} {
    set s [schem::new f]
    $s add resistor R -r 1000 ; $s add battery B -emf 9 ; $s add ground GND
    $s wire B.pos R.a ; $s wire B.neg GND.t   ;# R.b left floating
    set w [::schem::pcb::manufacturability $s]
    expr {[llength $w] > 0 && [string match "*floating*" $w]}
}}]}

# ====================================================================
section "export writes both files"
# ====================================================================
set base [file join [file dirname [info script]] pcbtmp[pid]]
set res [::schem::pcb::export $s $base]
ok "writes a .net file"          {[file exists [dict get $res netlist]] && [file size [dict get $res netlist]] > 0}
ok "writes a .csv file"          {[file exists [dict get $res bom]] && [file size [dict get $res bom]] > 0}
file delete [dict get $res netlist] [dict get $res bom]

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
