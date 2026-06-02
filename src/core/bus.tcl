# bus.tcl --
#
# Bundled conductors and schematic expansion -- the drafting layer that lets a
# board be described the way an electrical engineer reads a print, without ever
# leaving the electrical model.
#
# Two ideas, kept deliberately distinct:
#
#   * A BUS is electrical.  `bus DATA 8` is eight real conductors (lanes), each
#     an ordinary net that carries a voltage and obeys every rule a wire does
#     -- drive two sources onto one lane and it is contention, not a quiet
#     pick.  A lane is literally a `bus` component (a shared node many parts
#     attach to): a ribbon cable, a backplane, a row of an LED matrix.
#
#   * REPEAT / BANK are construction shorthand, NOT behaviour.  `bank LAMP 26
#     of lamp` places twenty-six real lamps; `repeat i 0 25 { ... }` stamps the
#     same sub-circuit twenty-six times at *build* time and then disappears.
#     The electricity is entirely in the components left behind -- exactly like
#     an engineer drawing 26 identical lamp circuits by hand.  Repetition over
#     *time* is never a primitive here; that is what clocks, counters and
#     stepping switches are for.
#
# Connections across bundles use slices and fan-out the way a print does:
#   connect ALPHA[*]   -> LAMP[*].a      ;# zip: lane i to unit i
#   connect CLK        -> REG[*].clk     ;# fan-out: one net to every unit
#   connect DATA[0..3] -> OUT[4..7]      ;# slice to slice

oo::define ::schem::Schematic {
    variable Bus Bank

    # bus -- declare a bundle of `width` conductors named NAME#0 .. NAME#(w-1),
    # each a real shared-node `bus` component (a lane).  Returns the name.
    method bus {name width} {
        if {![info exists Bus]}  { set Bus  [dict create] }
        if {![info exists Bank]} { set Bank [dict create] }
        if {[dict exists $Bus $name] || [dict exists $Bank $name]} {
            return -code error "duplicate bundle name \"$name\""
        }
        if {![string is integer -strict $width] || $width < 1} {
            return -code error "bus width must be a positive integer (got \"$width\")"
        }
        for {set i 0} {$i < $width} {incr i} { my add bus ${name}#$i }
        dict set Bus $name $width
        return $name
    }

    # lane -- the terminal of bus NAME's conductor i.
    method lane {name i} {
        if {![info exists Bus] || ![dict exists $Bus $name]} {
            return -code error "no bus \"$name\""
        }
        return ${name}#$i.t
    }

    # bank -- place `count` repeated components named NAME#0 .. of `type`, each
    # built with the same parameters.  `of` is a literal keyword so the call
    # reads as hardware:  bank LAMP 26 of lamp -r 2000.
    method bank {name count of type args} {
        if {$of ne "of"} { return -code error "usage: bank NAME COUNT of TYPE ?-opt val ...?" }
        if {![info exists Bank]} { set Bank [dict create] }
        if {![info exists Bus]}  { set Bus  [dict create] }
        if {[dict exists $Bank $name] || [dict exists $Bus $name]} {
            return -code error "duplicate bundle name \"$name\""
        }
        if {![string is integer -strict $count] || $count < 1} {
            return -code error "bank count must be a positive integer (got \"$count\")"
        }
        for {set i 0} {$i < $count} {incr i} { my add $type ${name}#$i {*}$args }
        dict set Bank $name [list $count $type]
        return $name
    }

    # unit -- the component name of bank NAME's element i (append .pin yourself).
    method unit {name i} {
        if {![info exists Bank] || ![dict exists $Bank $name]} {
            return -code error "no bank \"$name\""
        }
        return ${name}#$i
    }

    # width -- the lane/element count of a declared bus or bank.
    method width {name} {
        if {[info exists Bus]  && [dict exists $Bus  $name]} { return [dict get $Bus $name] }
        if {[info exists Bank] && [dict exists $Bank $name]} { return [lindex [dict get $Bank $name] 0] }
        return -code error "unknown bus/bank \"$name\""
    }

    # repeat -- schematic expansion: run `body` once for each i in lo..hi with
    # the loop variable set in the *caller's* scope, stamping real components.
    # This is netlist generation, not a runtime loop -- nothing about it exists
    # after the board is built.
    method repeat {var lo hi body} {
        for {set i $lo} {$i <= $hi} {incr i} {
            uplevel 1 [list set $var $i]
            uplevel 1 $body
        }
        return
    }

    # connect -- wire two endpoints, bundle-aware.  Each endpoint is one of:
    #     BUS[i]            one lane            (scalar)
    #     BUS[*]            every lane          (vector)
    #     BUS[a..b]         a slice             (vector)
    #     BANK[i].pin       one unit's pin      (scalar)
    #     BANK[*].pin       every unit's pin    (vector)
    #     BANK[a..b].pin    a slice of pins     (vector)
    #     COMP.pin          a plain terminal    (scalar)
    #     NAME              a width-1 bus lane  (scalar)
    # Vector<->vector zips lane-wise (lengths must match); scalar<->vector fans
    # the scalar out to every element.
    method connect {lhs arrow rhs} {
        if {$arrow ne "->"} { return -code error "usage: connect LHS -> RHS" }
        lassign [my ResolveEndpoint $lhs] lk lt
        lassign [my ResolveEndpoint $rhs] rk rt
        set nl [llength $lt] ; set nr [llength $rt]
        if {$nl == $nr} {
            foreach a $lt b $rt { my wire $a $b }
        } elseif {$nl == 1} {
            foreach b $rt { my wire [lindex $lt 0] $b }
        } elseif {$nr == 1} {
            foreach a $lt { my wire $a [lindex $rt 0] }
        } else {
            return -code error "connect: width mismatch ($nl vs $nr) in \"$lhs -> $rhs\""
        }
        return
    }

    # tie -- fan one net out to every endpoint of a bundle (a convenience for
    # connect NET -> BUNDLE[*]).
    method tie {net ep} { my connect $net -> $ep }

    # pulldown / pullup -- give every endpoint a default level through a resistor
    # to GND / to a named rail terminal.  Models the real discipline a shared
    # line needs (a floating bus is undefined).
    method pulldown {ep r {gnd ""}} { my PullTo $ep $r $gnd 0 }
    method pullup   {ep r rail}     { my PullTo $ep $r $rail 1 }

    method PullTo {ep r ref up} {
        set terms [lindex [my ResolveEndpoint $ep] 1]
        set k 0
        foreach t $terms {
            set rn [string map {. _ # _} "P${up}_${t}"]
            my add resistor $rn -r $r
            my wire $t ${rn}.a
            if {$ref eq "" && !$up} {
                # auto-ground: reuse or make a ground
                if {![info exists ::_busGND]} { }
                my wire ${rn}.b [my AutoGround]
            } else {
                my wire ${rn}.b $ref
            }
            incr k
        }
        return
    }

    # AutoGround -- a shared ground terminal for pulldowns that didn't name one.
    method AutoGround {} {
        if {![dict exists [my ports] __busgnd__]} {
            if {"__BUSGND__" ni [my components]} { my add ground __BUSGND__ }
        }
        return __BUSGND__.t
    }

    # ResolveEndpoint -- {kind terms}; kind is scalar or vector.  A bundle/
    # component base may carry a hierarchy path with '/' (e.g. MENU/CAB_A), the
    # same separator instancing uses, so panels can nest bundles.
    method ResolveEndpoint {ep} {
        if {[regexp {^([A-Za-z_][A-Za-z0-9_/]*)\[([^\]]+)\](?:\.([A-Za-z0-9_]+))?$} $ep -> base idx pin]} {
            set indices [my ParseIndex $base $idx]
            set terms {}
            foreach i $indices {
                if {$pin eq ""} { lappend terms [my lane $base $i] } \
                else            { lappend terms [my unit $base $i].$pin }
            }
            set kind [expr {($idx eq "*" || [string match *..* $idx]) ? "vector" : "scalar"}]
            return [list $kind $terms]
        } elseif {[regexp {^([A-Za-z_][A-Za-z0-9_/#]*)\.([A-Za-z0-9_]+)$} $ep -> comp pin]} {
            my ResolveTerm $comp.$pin
            return [list scalar [list $comp.$pin]]
        } elseif {[regexp {^([A-Za-z_][A-Za-z0-9_/]*)$} $ep -> name]} {
            if {[info exists Bus] && [dict exists $Bus $name]} {
                return [list scalar [list [my lane $name 0]]]
            }
            return -code error "connect: cannot resolve endpoint \"$ep\" (not a width-1 bus; use COMP.pin or BUS\[i\])"
        }
        return -code error "connect: malformed endpoint \"$ep\""
    }

    method ParseIndex {base idx} {
        if {$idx eq "*"} {
            set n [my width $base]
            set out {} ; for {set i 0} {$i < $n} {incr i} { lappend out $i } ; return $out
        } elseif {[regexp {^(\d+)\.\.(\d+)$} $idx -> a b]} {
            set out {}
            if {$a <= $b} { for {set i $a} {$i <= $b} {incr i} { lappend out $i } } \
            else          { for {set i $a} {$i >= $b} {incr i -1} { lappend out $i } }
            return $out
        } elseif {[string is integer -strict $idx]} {
            return [list $idx]
        }
        return -code error "bad bundle index \"\[$idx\]\""
    }
}
