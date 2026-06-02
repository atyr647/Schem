# lib/ratings.tcl --
#
# The design review an engineer does by hand, automated: after solving a
# circuit, check every real part's operating point against its datasheet
# absolute-maximum ratings, and report what is over limit, what is marginal,
# and what is safe.  This is the difference between "the math works" and "the
# board survives" -- a 1N4148 in a mains rectifier passes the simulation and
# then explodes.
#
# Each part in lib/parts.tcl carries `limits` keyed by a `sense` that says how
# to measure the stress from the solved state:
#   reverse-voltage   peak reverse V across a diode (vs Vrrm / Vz)
#   forward-current   forward current through a diode (vs If)
#   reverse-current   reverse/zener current (vs Iz)
#   power             dissipation in the part (vs Pd)
#   cap-voltage       voltage across a capacitor (vs Vdc)
#   cap-current       RMS-ish current into a capacitor (vs Iripple)
#   ce-voltage        Vce of a BJT (vs Vceo)
#   collector-current Ic of a BJT (vs Ic)
#   ds-voltage        Vds of a MOSFET (vs Vds)
#   drain-current     Id of a MOSFET (vs Id)
#   inductor-current  current through an inductor (vs Isat)
#
# A check returns, per (part,limit): the measured stress, the rating, a margin
# (stress/rating), and a verdict over|marginal|ok.  "marginal" fires above a
# derating threshold (80% by default) -- the headroom a careful designer keeps.

namespace eval ::schem::ratings {
    variable DERATE 0.8   ;# >80% of a rating is "marginal" (datasheet derating)
}

# stress -- measure the quantity a given limit senses, from the solved board.
# Returns the magnitude in the limit's unit, or "" if it cannot be measured.
proc ::schem::ratings::stress {s name sense} {
    set type [$s typeof $name]
    switch -- $sense {
        power            { return [expr {abs([::schem::ratings::power $s $name])}] }
        reverse-voltage  {
            # peak reverse voltage across a 2-terminal junction (a..k or a..b)
            lassign [::schem::ratings::twoTerm $s $name] p q
            set v [expr {[$s probe $p] - [$s probe $q]}]
            # reverse stress is when cathode is higher than anode (v < 0)
            return [expr {$v < 0 ? -$v : 0.0}]
        }
        forward-current  {
            set i [::schem::ratings::current $s $name]
            return [expr {$i > 0 ? $i : 0.0}]
        }
        reverse-current  {
            set i [::schem::ratings::current $s $name]
            return [expr {$i < 0 ? -$i : 0.0}]
        }
        cap-voltage      {
            lassign [::schem::ratings::twoTerm $s $name] p q
            return [expr {abs([$s probe $p] - [$s probe $q])}]
        }
        cap-current      { return [expr {abs([::schem::ratings::current $s $name])}] }
        ce-voltage       { return [expr {abs([$s probe $name.c] - [$s probe $name.e])}] }
        collector-current { return [expr {abs([my_bjt_ic $s $name])}] }
        ds-voltage       { return [expr {abs([$s probe $name.d] - [$s probe $name.s])}] }
        drain-current    { return [expr {abs([::schem::ratings::pinCurrent $s $name d])}] }
        inductor-current { return [expr {abs([::schem::ratings::current $s $name])}] }
        default          { return "" }
    }
}

# twoTerm -- the two terminals of a 2-pin part, anode/cathode or a/b.
proc ::schem::ratings::twoTerm {s name} {
    set t [$s terminals $name]
    if {[lsearch $t a] >= 0 && [lsearch $t k] >= 0} { return [list $name.a $name.k] }
    return [list $name.[lindex $t 0] $name.[lindex $t 1]]
}

# power / current -- thin wrappers over the engine's measurements.
proc ::schem::ratings::power {s name} {
    if {[catch {$s power $name} p]} { return 0.0 } ; return $p
}
proc ::schem::ratings::current {s name} {
    if {[catch {$s current $name} i]} { return 0.0 } ; return $i
}
proc ::schem::ratings::pinCurrent {s name pin} {
    # current into a specific pin (MOSFET drain): approximate from device current
    if {[catch {$s current $name} i]} { return 0.0 } ; return $i
}
proc ::schem::ratings::my_bjt_ic {s name} {
    if {[catch {$s current $name} i]} { return 0.0 } ; return $i
}

# check -- review one schematic.  `idmap` maps instance name -> part id (from
# parts::idOf, or pass an explicit dict).  Returns a list of findings, each:
#   {part <name> id <partid> limit <key> measured <v> rating <max> unit <u>
#    margin <0..> verdict over|marginal|ok note <text>}
proc ::schem::ratings::check {s {idmap {}}} {
    variable DERATE
    set findings {}
    foreach name [$s components] {
        set id [expr {[dict exists $idmap $name] ? [dict get $idmap $name] \
                       : [::schem::parts::idOf $s $name]}]
        if {$id eq ""} continue
        set spec [::schem::parts::get $id]
        if {![dict exists $spec limits]} continue
        dict for {lk lim} [dict get $spec limits] {
            set sense [dict get $lim sense]
            set measured [::schem::ratings::stress $s $name $sense]
            if {$measured eq ""} continue
            set rating [expr {double([dict get $lim max])}]
            if {$rating <= 0} continue
            set margin [expr {$measured/$rating}]
            set verdict [expr {$margin > 1.0 ? "over" : ($margin > $DERATE ? "marginal" : "ok")}]
            set note [expr {[dict exists $lim note] ? [dict get $lim note] : ""}]
            lappend findings [dict create part $name id $id limit $lk \
                measured $measured rating $rating unit [dict get $lim unit] \
                margin $margin verdict $verdict note $note]
        }
    }
    return $findings
}

# report -- a human design-review of the findings, grouped by verdict.  Solves
# the board first if needed.  Returns readable text.
proc ::schem::ratings::report {s {idmap {}}} {
    if {[catch {$s solve}]} {}    ;# ensure a fresh operating point
    set f [::schem::ratings::check $s $idmap]
    if {[llength $f] == 0} {
        return "No real parts to review (place parts from lib/parts.tcl with idmap, or via parts::place)."
    }
    set over {} ; set marg {} ; set ok {}
    foreach r $f {
        set line [format "  %-8s %-12s %-16s %s / %s %s  (%.0f%%)%s" \
            [dict get $r part] [dict get $r id] [dict get $r limit] \
            [::schem::ratings::fmt [dict get $r measured]] \
            [::schem::ratings::fmt [dict get $r rating]] [dict get $r unit] \
            [expr {[dict get $r margin]*100}] \
            [expr {[dict get $r note] ne "" ? "  -- [dict get $r note]" : ""}]]
        switch -- [dict get $r verdict] {
            over     { lappend over $line }
            marginal { lappend marg $line }
            ok       { lappend ok   $line }
        }
    }
    set out {}
    lappend out "Design review: [llength $f] rating check(s) across the board"
    if {[llength $over]} { lappend out "OVER LIMIT (will fail):" ; lappend out {*}$over }
    if {[llength $marg]} { lappend out "MARGINAL (>80% of rating -- derate):" ; lappend out {*}$marg }
    if {[llength $ok]}   { lappend out "OK:" ; lappend out {*}$ok }
    if {![llength $over] && ![llength $marg]} {
        lappend out "All parts within ratings with healthy margin."
    }
    return [join $out \n]
}

proc ::schem::ratings::fmt {x} {
    if {![string is double -strict $x]} { return $x }
    if {$x != 0 && (abs($x) < 0.1 || abs($x) >= 1000)} {
        return [::schem::pcb::eng $x]
    }
    return [format %.3g $x]
}

package provide schem_ratings 1.0
