#!/usr/bin/env tclsh
# test_svg.tcl -- the SVG renderer: a schematic drawn as a box-and-arrow image
# (the same view the ASCII viewer gives, as a scalable vector).  We assert the
# structure of the emitted SVG rather than pixels: one box per component, the
# NAME:type label, an arrowed coupling per wire, and the grouped view that
# collapses NAME#i bundles into one ribbon.
#
#   tclsh tests/test_svg.tcl
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

# ====================================================================
section "flat view -- one box per component, one arrow per wire"
# ====================================================================
set s [schem::new yours]
$s add switch  SW -at 0,0
$s add relay   K  -at 2,0
$s add breaker CB -at 2,2
$s wire SW.b K.c1
$s wire K.no CB.a
set svg [schem::svg $s]
ok "is an svg document"        {[string match "*<svg*</svg>*" $svg]}
ok "a box per component (3)"   {[regexp -all {<rect[^>]*stroke=} $svg] >= 3}
ok "labels NAME:type"          {[string match "*SW*:*switch*" $svg]}
ok "draws K:relay"             {[string match "*K*:*relay*" $svg]}
ok "an arrowhead marker"       {[string match "*marker id='arrow'*" $svg]}
ok "an arrowed coupling"       {[regexp {marker-end='url\(#arrow\)'} $svg]}
ok "honours -title"            {[string match "*Code*" [schem::svg $s -title Code]]}

# ====================================================================
section "grouped view -- bundles collapse to ribbons"
# ====================================================================
set s [schem::new busboard]
$s add ground GND
$s bus ALPHA 26
$s bank LAMP 26 of lamp -r 2000
$s connect ALPHA\[*\] -> LAMP\[*\].a
$s connect LAMP\[*\].b -> GND.t
set g [schem::svgGrouped $s]
ok "grouped is an svg"             {[string match "*<svg*</svg>*" $g]}
# 26 ALPHA lanes + 26 LAMP units + GND collapse to ALPHA, LAMP, GND = 3 boxes
ok "ALPHA collapses to one ribbon" {[regexp {ALPHA\[26\]} $g]}
ok "LAMP collapses to one ribbon"  {[regexp {LAMP\[26\]} $g]}
ok "loose GND stays a plain box"   {[regexp {>GND<} $g] || [string match "*GND*:*ground*" $g]}
ok "far fewer boxes than parts"    {[regexp -all {<rect[^>]*stroke='#9a9a9a'} $g] < 10}

# groupOf maps members to their bundle
ok "groupOf strips the lane index" {[::schem::render::groupOf LAMP#7] eq "LAMP"}
ok "groupOf leaves loose parts"    {[::schem::render::groupOf GND] eq "GND"}

# ====================================================================
section "svgFile -- writes a file"
# ====================================================================
set tmp [file join [file dirname [info script]] svgtmp[pid].svg]
set n [schem::svgFile $s $tmp -grouped 1]
ok "svgFile returns a byte count"  {$n > 0}
ok "svgFile wrote the file"        {[file exists $tmp] && [file size $tmp] > 0}
file delete $tmp

# a real saved artifact round-trips into a render
set big [file join $here .. artifacts bombe_QER.schem]
if {[file exists $big]} {
    set bs [schem::load $big]
    ok "bombe artifact renders grouped" {[string match "*<svg*" [schem::svgGrouped $bs]]}
    ok "bombe shows a 26-lane cable"    {[regexp {CAB_[A-Z]\[26\]} [schem::svgGrouped $bs]]}
} else {
    ok "(skipped: no bombe artifact)" 1 ; ok "(skipped)" 1
}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
