# hierarchy.tcl --
#
# The Schem scale ladder:  Component -> Circuit -> Panel -> Grid.
#
# A Circuit is a bounded collection of components that exposes a few named
# terminals (its contract, e.g. IN / OUT / GND) and hides everything else.
# A Panel is a bounded collection of Circuits; a Grid a collection of
# Panels.  Panels and Grids add organisation, never new electrical
# behaviour.
#
# All four scales are represented by the *same* Schematic object -- a Grid
# is just a Schematic that has had Panels flattened into it, which in turn
# had Circuits flattened into them.  Embedding copies a child's components
# and wires into the parent under an instance prefix, exactly the
# "temporary internal structure" the interpreter is allowed to build while
# the hierarchical schematic stays the source of truth.

oo::define ::schem::Schematic {
    variable Ports

    # expose -- declare a named port that maps to an internal terminal,
    # turning this schematic into a reusable Circuit / Panel block.
    #   expose IN R1.a
    method expose {port term} {
        my ResolveTerm $term
        if {![info exists Ports]} { set Ports [dict create] }
        dict set Ports $port $term
        return
    }

    method ports {} {
        if {![info exists Ports]} { return {} }
        return $Ports
    }

    # port -- resolve a declared port to its internal terminal.
    method port {name} {
        if {![info exists Ports] || ![dict exists $Ports $name]} {
            return -code error "no exposed port \"$name\" (have: [my ports])"
        }
        return [dict get $Ports $name]
    }

    # Export -- accessor used by a parent's instantiate (cross-object, so
    # it must be exported; export must follow the method definition).
    method Export {} {
        set p [expr {[info exists Ports] ? $Ports : [dict create]}]
        return [list $Comp $Conns $p]
    }
    export Export

    # instantiate -- flatten a child schematic into this one under a
    # prefix.  Returns a dict mapping the child's port names to the
    # corresponding terminals in *this* schematic (prefixed), ready to be
    # wired up.  Ground components are shared automatically because all
    # grounds collapse to node 0 in the solver.
    method instantiate {child prefix} {
        lassign [$child Export] cComp cConns cPorts

        set rename {{term prefix} {
            lassign [split $term .] n pin
            return "$prefix/$n.$pin"
        }}

        dict for {name comp} $cComp {
            set newname "$prefix/$name"
            if {[dict exists $Comp $newname]} {
                return -code error "instance \"$prefix\" collides with existing component"
            }
            dict set Comp $newname $comp
        }
        foreach c $cConns {
            lassign $c a b awg
            lappend Conns [list [apply $rename $a $prefix] \
                                [apply $rename $b $prefix] $awg]
        }

        set portmap [dict create]
        dict for {pn term} $cPorts {
            dict set portmap $pn [apply $rename $term $prefix]
        }
        return $portmap
    }
}

# ----------------------------------------------------------------------
# Convenience constructors.  These are thin aliases over Schematic so that
# code reads at the intended scale; the behaviour is identical.
# ----------------------------------------------------------------------

# schem::circuit -- a reusable block.  Build it, expose ports, then embed
# it into panels with $panel instantiate $circuit U1.
proc ::schem::circuit {{name circuit}} { return [::schem::Schematic new $name] }
proc ::schem::panel   {{name panel}}   { return [::schem::Schematic new $name] }
proc ::schem::grid    {{name grid}}    { return [::schem::Schematic new $name] }
