# zoom.tcl --
#
# Semantic zoom: the one idea that makes the language both simple at a glance
# and precise to the last conductor.  It is NOT pixel scaling -- it is *level
# of detail* along the language's own scale ladder:
#
#     Grid  ->  Panel  ->  Circuit  ->  Bundle  ->  Component
#
# A schematic already encodes that ladder in its names.  Instancing a circuit
# under a prefix names parts `PREFIX/inner` (see hierarchy.tcl); a bus or bank
# names its members `NAME#i` (see bus.tcl).  So a component like
#
#     SC/IN#7
#
# reads as: instance `SC`, bundle `IN`, lane `7`.  Zooming out is just
# resolving fewer of those segments before collapsing everything that shares
# the remaining key into one box.  Zoom in and the boxes split back apart,
# down to the individual component -- the lowest level there is.
#
# Both the image renderer and the interactive editor consume this, so the
# picture on screen and the picture you export are the same view at the same
# depth.  Coarse control and surgical control are the same control, dialled.

namespace eval ::schem::zoom {
    # The named levels, coarse (0) to finest.  COMPONENT is the floor: every
    # part stands alone.  Callers may clamp a request into this range.
    variable LEVELS {grid panel circuit bundle component}
    variable MAXLEVEL 4
}

# key -- the collapse key for component `name` at zoom `level`: the prefix of
# the name's hierarchy that survives at this depth.  Everything sharing a key
# draws as one box.  The name grammar is  seg/seg/.../leaf  where the leaf may
# carry a bundle index `base#i`.
#
#   level 4 component : SC/IN#7        (full name -- nothing collapsed)
#   level 3 bundle    : SC/IN          (#i dropped -- the bundle is one ribbon)
#   level 2 circuit   : SC/IN          (keep one path segment + the bundle)
#   level 1 panel     : SC             (the instance)
#   level 0 grid      : SC             (top segment only)
#
# A flat board with no '/' or '#' (a plain divider) has every part at its own
# key regardless of level, so zoom never hides what was never grouped.
proc ::schem::zoom::key {name level} {
    # Split the hierarchy path and the bundle leaf.
    set segs [split $name /]
    set leaf [lindex $segs end]
    set path [lrange $segs 0 end-1]          ;# instance prefixes, if any
    regexp {^(.+)#(\d+)$} $leaf -> base idx  ;# bundle base + lane, if any
    if {![info exists base]} { set base $leaf }

    # 4 component: the full name, nothing collapsed.
    # 3 bundle / 2 circuit: keep the instance path + bundle base, drop the
    #   lane index so a bus draws as one ribbon.
    # 1 panel: collapse to the instance prefix (or the bundle base if flat).
    # 0 grid: just the top path segment.
    switch -- $level {
        4 { return $name }
        3 { return [join [concat $path [list $base]] /] }
        2 { return [join [concat $path [list $base]] /] }
        1 {
            if {[llength $path] > 0} { return [join $path /] }
            return [join [concat $path [list $base]] /]
        }
        0 {
            if {[llength $path] > 0} { return [lindex $path 0] }
            return $base
        }
    }
    return $name
}

# label -- how a collapsed group prints at this level: the key, with a [n]
# width tag when it stands for more than one component, and the representative
# type appended as :type.  members is the list of component names in the group.
proc ::schem::zoom::label {keyName members type level} {
    set n [llength $members]
    set base [lindex [split $keyName /] end]
    if {$n > 1} { return "$base\[$n\]:$type" }
    return "$base:$type"
}

# groups -- collapse a schematic's components into {key -> {members type}} at a
# given level, preserving first-seen order of keys.  The type is the
# representative (first member's) type.
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

# edges -- the inter-group couplings at this level (deduped, self-loops
# dropped): a connection between two groups whenever any wire joins a member of
# one to a member of the other.  Returns a list of {ka kb}.
proc ::schem::zoom::edges {s level} {
    set seen [dict create] ; set out {}
    foreach co [$s conns] {
        lassign $co a b
        set ka [::schem::zoom::key [lindex [split $a .] 0] $level]
        set kb [::schem::zoom::key [lindex [split $b .] 0] $level]
        if {$ka eq $kb} continue
        set pair [list $ka $kb]
        if {[dict exists $seen $pair] || [dict exists $seen [list $kb $ka]]} continue
        dict set seen $pair 1 ; lappend out $pair
    }
    return $out
}

# levelName / clampLevel -- name<->index helpers with range clamping.
proc ::schem::zoom::levelName {level} {
    variable LEVELS ; return [lindex $LEVELS $level]
}
proc ::schem::zoom::clamp {level} {
    variable MAXLEVEL
    if {$level < 0} { return 0 }
    if {$level > $MAXLEVEL} { return $MAXLEVEL }
    return $level
}
