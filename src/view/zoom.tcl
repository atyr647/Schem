# zoom.tcl --
#
# Semantic zoom: the level-of-detail axis that makes the language both simple
# at a glance and precise to the last conductor.  It is NOT pixel scaling -- it
# is how deep into the schematic's own hierarchy you resolve before collapsing
# everything that shares the remaining prefix into one box.
#
# That hierarchy is carried in the component names.  Instancing a circuit under
# a prefix names parts `PREFIX/inner` (hierarchy.tcl); a bus or bank names its
# members `NAME#i` (bus.tcl).  So a part
#
#     MENU/CAB_A#7
#
# is a sequence of TIERS: [MENU, CAB_A, 7].  Zoom level `d` keeps the first
# d+1 tiers as the collapse key; everything sharing that key draws as one box.
#
#     level 0  MENU            (the whole menu as one box)   -- coarsest
#     level 1  MENU/CAB_A      (one box per cable)
#     level 2  MENU/CAB_A#7    (every conductor)             -- finest
#
# The LANGUAGE LIMITS are the board's own depth: you cannot zoom out past the
# top tier (level 0, the grid) nor in past the individual component (the
# deepest tier any part has).  A flat board with no '/' or '#' has depth 0 --
# nothing to collapse, so zoom is a no-op there, exactly as it should be.

namespace eval ::schem::zoom {
    # Friendly names for levels, coarse -> fine, used only for display.  A board
    # rarely has all five; we map its actual depth onto this vocabulary.
    variable NAMES {grid panel circuit bundle component}
    variable SEP /
}

# tiers -- split a component name into its hierarchy tiers.  Only the leaf may
# carry a bundle index (base#i), which becomes its own final tier.
#   MENU/CAB_A#7  -> {MENU CAB_A 7}
#   SC/IN#0       -> {SC IN 0}
#   R1            -> {R1}
proc ::schem::zoom::tiers {name} {
    set segs [split $name /]
    set leaf [lindex $segs end]
    set path [lrange $segs 0 end-1]
    if {[regexp {^(.+)#(\d+)$} $leaf -> base idx]} {
        return [concat $path [list $base $idx]]
    }
    return [concat $path [list $leaf]]
}

# depth -- the finest zoom level a name can be resolved to (number of tiers
# minus one).  R1 -> 0; SC/IN#0 -> 2; MENU/CAB_A#7 -> 2.
proc ::schem::zoom::depth {name} {
    return [expr {[llength [::schem::zoom::tiers $name]] - 1}]
}

# maxLevel -- the board's finest level: the deepest any component goes.  This
# is the language's upper zoom limit for this board.
proc ::schem::zoom::maxLevel {s} {
    set m 0
    foreach c [$s components] {
        set d [::schem::zoom::depth $c]
        if {$d > $m} { set m $d }
    }
    return $m
}

# key -- the collapse key for `name` at zoom level `level`: the first level+1
# tiers, joined.  When the level is at or past the name's own depth the full
# name is returned (the component stands alone).
proc ::schem::zoom::key {name level} {
    set t [::schem::zoom::tiers $name]
    if {$level >= [llength $t]-1} { return $name }
    if {$level < 0} { set level 0 }
    return [join [lrange $t 0 $level] $::schem::zoom::SEP]
}

# leaf -- the display label of a key (its last tier).
proc ::schem::zoom::leaf {key} {
    return [lindex [split $key $::schem::zoom::SEP] end]
}

# clamp -- hold a requested level inside this board's language limits [0,max].
proc ::schem::zoom::clamp {s level} {
    set max [::schem::zoom::maxLevel $s]
    if {$level < 0}    { return 0 }
    if {$level > $max} { return $max }
    return $level
}

# levelName -- map a level onto the {grid..component} vocabulary, scaled to the
# board's depth so 0 reads "grid" and the deepest reads "component".
proc ::schem::zoom::levelName {level {max 4}} {
    variable NAMES
    if {$max <= 0} { return component }
    set idx [expr {int(round(double($level)/$max*4))}]
    if {$idx < 0} { set idx 0 } ; if {$idx > 4} { set idx 4 }
    return [lindex $NAMES $idx]
}

# groups -- collapse a board's components into {orderedKeys members types} at a
# level, keeping first-seen key order.
proc ::schem::zoom::groups {s level} {
    set order {} ; set members [dict create] ; set gtype [dict create]
    foreach c [$s components] {
        set k [::schem::zoom::key $c $level]
        if {![dict exists $members $k]} { lappend order $k }
        dict lappend members $k $c
        if {![dict exists $gtype $k]} { dict set gtype $k [$s typeof $c] }
    }
    return [list $order $members $gtype]
}

# edges -- the inter-group couplings at a level (deduped, self-loops dropped).
proc ::schem::zoom::edges {s level} {
    set seen [dict create] ; set out {}
    foreach co [$s conns] {
        lassign $co a b
        set ka [::schem::zoom::key [lindex [split $a .] 0] $level]
        set kb [::schem::zoom::key [lindex [split $b .] 0] $level]
        if {$ka eq $kb} continue
        if {[dict exists $seen [list $ka $kb]] || [dict exists $seen [list $kb $ka]]} continue
        dict set seen [list $ka $kb] 1 ; lappend out [list $ka $kb]
    }
    return $out
}

# childKey -- given a parent key and a finer level, the key of `name` if it is
# a descendant of parent at that level, else "".  Used by anchored zoom to
# follow the part under the cursor into more detail.
proc ::schem::zoom::childKey {name parent level} {
    set k [::schem::zoom::key $name $level]
    if {$k eq $parent || [string match "$parent$::schem::zoom::SEP*" $k]} { return $k }
    return ""
}

# parentKey -- the key one level coarser than `key` (drop its last tier).
proc ::schem::zoom::parentKey {key} {
    set segs [split $key $::schem::zoom::SEP]
    if {[llength $segs] <= 1} { return $key }
    return [join [lrange $segs 0 end-1] $::schem::zoom::SEP]
}
