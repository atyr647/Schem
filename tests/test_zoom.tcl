#!/usr/bin/env tclsh
# test_zoom.tcl -- semantic zoom: the level-of-detail axis along the language's
# own Component -> Circuit -> Panel -> Grid ladder.  Asserts the key/group
# logic, that coarser levels collapse to fewer boxes, that the renderer honours
# the level, and that the editor's +/- drives the zoom.
#
#   tclsh tests/test_zoom.tcl
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

# ====================================================================
section "zoom::key -- resolve a hierarchical name to a level"
# ====================================================================
ok "component keeps the full name"  {[::schem::zoom::key SC/IN#7 4] eq "SC/IN#7"}
ok "bundle drops the lane index"     {[::schem::zoom::key SC/IN#7 3] eq "SC/IN"}
ok "circuit keeps instance+bundle"   {[::schem::zoom::key SC/IN#7 2] eq "SC/IN"}
ok "panel collapses to the instance" {[::schem::zoom::key SC/IN#7 1] eq "SC"}
ok "grid keeps the top segment"      {[::schem::zoom::key SC/IN#7 0] eq "SC"}
ok "a bare bundle keeps its base"    {[::schem::zoom::key CAB_A#13 1] eq "CAB_A"}
ok "a flat name is itself anywhere"  {[::schem::zoom::key R1 0] eq "R1" && [::schem::zoom::key R1 4] eq "R1"}
ok "clamp holds the range"           {[::schem::zoom::clamp 9] == 4 && [::schem::zoom::clamp -3] == 0}
ok "level names"                     {[::schem::zoom::levelName 0] eq "grid" && [::schem::zoom::levelName 4] eq "component"}

# ====================================================================
section "zoom::groups -- collapse a board, coarse to fine"
# ====================================================================
# A board with a circuit instance prefix and a bus inside it.
set inner [::schem::circuit scr]
$inner bus IN 4
for {set i 0} {$i < 4} {incr i} { $inner expose IN$i [$inner lane IN $i] }
set s [::schem::new top]
$s add battery KEY
$s add ground GND
set sp [$s instantiate $inner SC]
$s wire KEY.pos [dict get $sp IN0]
$s wire KEY.neg GND.t

# component level: KEY, GND, SC/IN#0..3  = 6
lassign [::schem::zoom::groups $s 4] o4 m4 t4
ok "component level: every part"     {[llength $o4] == 6}
# bundle level: KEY, GND, SC/IN  = 3
lassign [::schem::zoom::groups $s 3] o3 m3 t3
ok "bundle level collapses the bus"  {[llength $o3] == 3}
# grid level: KEY, GND, SC  = 3 (SC collapses the instance)
lassign [::schem::zoom::groups $s 0] o0 m0 t0
ok "grid level collapses instance"   {"SC" in $o0}
ok "coarser <= finer box count"      {[llength $o0] <= [llength $o4]}

# ====================================================================
section "renderer honours the zoom level"
# ====================================================================
set big [file join $here .. artifacts enigma_scrambler.schem]
if {[file exists $big]} {
    set bs [schem::load $big]
    lassign [::schem::zoom::groups $bs 0] g0 _ _
    lassign [::schem::zoom::groups $bs 4] g4 _ _
    ok "scrambler: grid coarser than component" {[llength $g0] < [llength $g4]}
    set svg0 [schem::svgGrouped $bs -level 0]
    set svg4 [schem::svg $bs]
    ok "grid SVG is smaller than flat SVG"      {[string length $svg0] < [string length $svg4]}
    ok "grid SVG shows a width tag"             {[regexp {\[\d+\]} $svg0]}
} else {
    ok "(skipped: no scrambler artifact)" 1
    ok "(skipped)" 1
    ok "(skipped)" 1
}

# ====================================================================
section "editor -- +/- drives the zoom"
# ====================================================================
set s [schem::new e]
$s add battery B
$s add resistor R -r 1000
$s add ground GND
$s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
set ed [::schem::EditorSession new $s]
ok "editor starts at component zoom" {[$ed zoom] == 4}
$ed key "-"
ok "'-' zooms out one level"         {[$ed zoom] == 3}
$ed key "-" ; $ed key "-" ; $ed key "-" ; $ed key "-"
ok "zoom clamps at grid (0)"         {[$ed zoom] == 0}
$ed key "+"
ok "'+' zooms back in"               {[$ed zoom] == 1}
ok "render mentions the level"       {[string match "*grid*" [$ed render]] || [string match "*panel*" [$ed render]]}
$ed setZoom 4
ok "component zoom draws the board"  {[string match "*B:battery*" [$ed render]] || [string match "*B*battery*" [$ed render]]}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
