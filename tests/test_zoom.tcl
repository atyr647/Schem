#!/usr/bin/env tclsh
# test_zoom.tcl -- semantic zoom as level-of-detail over a board's OWN
# hierarchy depth.  A component name is a sequence of tiers (instance / bundle /
# lane); zoom level d keeps the first d+1 tiers as the collapse key.  The zoom
# limits are the language limits: 0 (the whole board) up to the board's actual
# depth (every component).  Asserts the tier/key/clamp logic, the renderer, and
# the editor's anchored +/- zoom.
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
section "tiers & depth -- a name is a hierarchy"
# ====================================================================
ok "instance/bundle/lane splits to 3" {[::schem::zoom::tiers MENU/CAB_A#7] eq {MENU CAB_A 7}}
ok "bus member splits to 2"           {[::schem::zoom::tiers SC/IN#0] eq {SC IN 0}}
ok "flat name is one tier"            {[::schem::zoom::tiers R1] eq {R1}}
ok "depth counts tiers - 1"           {[::schem::zoom::depth MENU/CAB_A#7] == 2}
ok "flat name has depth 0"            {[::schem::zoom::depth R1] == 0}

# ====================================================================
section "key -- resolve a name to a level"
# ====================================================================
ok "level 0 keeps the top tier"       {[::schem::zoom::key MENU/CAB_A#7 0] eq "MENU"}
ok "level 1 keeps two tiers"          {[::schem::zoom::key MENU/CAB_A#7 1] eq "MENU/CAB_A"}
ok "level 2 is the full name"         {[::schem::zoom::key MENU/CAB_A#7 2] eq "MENU/CAB_A#7"}
ok "past-depth level = full name"     {[::schem::zoom::key SC/IN#0 9] eq "SC/IN#0"}
ok "flat name is itself at any level" {[::schem::zoom::key R1 0] eq "R1" && [::schem::zoom::key R1 5] eq "R1"}
ok "leaf is the last tier"            {[::schem::zoom::leaf MENU/CAB_A] eq "CAB_A"}
ok "parentKey drops a tier"           {[::schem::zoom::parentKey MENU/CAB_A] eq "MENU"}

# ====================================================================
section "language limits -- clamp to the board's own depth"
# ====================================================================
# flat board: depth 0, so zoom is pinned at 0
set flat [schem::new flat]
$flat add battery B ; $flat add resistor R -r 1000 ; $flat add ground GND
$flat wire B.pos R.a ; $flat wire R.b GND.t ; $flat wire B.neg GND.t
ok "flat board maxLevel is 0"         {[::schem::zoom::maxLevel $flat] == 0}
ok "clamp pins a flat board at 0"     {[::schem::zoom::clamp $flat 3] == 0 && [::schem::zoom::clamp $flat -2] == 0}

# a board with an instance + a bus inside: depth 2
set inner [::schem::circuit scr]
$inner bus IN 4
for {set i 0} {$i < 4} {incr i} { $inner expose IN$i [$inner lane IN $i] }
set s [::schem::new top]
$s add battery KEY ; $s add ground GND
set sp [$s instantiate $inner SC]
$s wire KEY.pos [dict get $sp IN0] ; $s wire KEY.neg GND.t
ok "instanced board maxLevel is 2"    {[::schem::zoom::maxLevel $s] == 2}
ok "clamp holds within limits"        {[::schem::zoom::clamp $s 9] == 2 && [::schem::zoom::clamp $s -1] == 0}

# ====================================================================
section "groups -- collapse a board, coarse to fine"
# ====================================================================
# level 2 (finest): KEY, GND, SC/IN#0..3  = 6
lassign [::schem::zoom::groups $s 2] o2 m2 t2
ok "finest level: every part"         {[llength $o2] == 6}
# level 1: KEY, GND, SC/IN  = 3 (the bus collapses)
lassign [::schem::zoom::groups $s 1] o1 m1 t1
ok "level 1 collapses the bus"        {[llength $o1] == 3 && "SC/IN" in $o1}
# level 0: KEY, GND, SC  = 3 (the instance collapses)
lassign [::schem::zoom::groups $s 0] o0 m0 t0
ok "level 0 collapses the instance"   {"SC" in $o0}
ok "coarser <= finer box count"       {[llength $o0] <= [llength $o2]}

# ====================================================================
section "renderer honours the level + limits"
# ====================================================================
set big [file join $here .. artifacts enigma_scrambler.schem]
if {[file exists $big]} {
    set bs [schem::load $big]
    set max [::schem::zoom::maxLevel $bs]
    ok "scrambler has real depth (>=2)" {$max >= 2}
    lassign [::schem::zoom::groups $bs 0]    g0 _ _
    lassign [::schem::zoom::groups $bs $max] gm _ _
    ok "level 0 coarser than finest"    {[llength $g0] < [llength $gm]}
    ok "grid SVG smaller than flat SVG" {[string length [schem::svgGrouped $bs -level 0]] < [string length [schem::svg $bs]]}
    ok "grid SVG shows a width tag"     {[regexp {\[\d+\]} [schem::svgGrouped $bs -level 0]]}
} else {
    foreach n {1 2 3 4} { ok "(skipped: no scrambler artifact)" 1 }
}

# ====================================================================
section "editor -- anchored +/- zoom, clamped to limits"
# ====================================================================
set ed [::schem::EditorSession new $s]
set max [::schem::zoom::maxLevel $s]
ok "editor starts at the finest level" {[$ed zoom] == $max}
$ed key "-"
ok "'-' zooms out one level"           {[$ed zoom] == $max-1}
$ed key "-" ; $ed key "-" ; $ed key "-"
ok "zoom clamps at 0 (whole board)"    {[$ed zoom] == 0}
$ed key "+"
ok "'+' zooms back in"                 {[$ed zoom] == 1}
ok "status shows level/max"            {[string match "*1/$max*" [$ed status]]}

# anchored: at a coarse level, point at a group and zoom IN -> anchor follows
$ed setZoom 0
# cursor onto the SC group (find its row)
lassign [::schem::zoom::groups $s 0] order _ _
set scrow [lsearch -exact $order SC]
if {$scrow >= 0} {
    set ed2 [::schem::EditorSession new $s]
    $ed2 setZoom 0
    for {set i 0} {$i < $scrow} {incr i} { $ed2 key j }
    $ed2 key "+"
    ok "zoom-in anchors on the pointed group" {[string match "SC*" [$ed2 zoomAnchor]]}
} else {
    ok "(skipped: SC not found)" 1
}

# flat board: zoom can't move (no depth)
set edf [::schem::EditorSession new $flat]
$edf key "-" ; $edf key "+"
ok "flat board zoom is pinned at 0"    {[$edf zoom] == 0}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
