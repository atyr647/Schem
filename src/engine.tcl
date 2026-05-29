# engine.tcl --
#
# The Schem circuit engine.  This is the interpreter for the Schem visual
# electrical language: it reads a *schematic* (components, terminals, and
# the wires that join them) and computes the electrical state by obeying
# the fundamental rules of electricity:
#
#   * Continuity      current flows only around closed conductive loops
#   * Ohm's law       V = I * R across every resistance
#   * Kirchhoff KCL   currents into a node sum to zero
#   * Kirchhoff KVL   voltages around a loop sum to zero
#   * Reference       ground defines 0 V
#
# The solving technique is Modified Nodal Analysis (MNA): the schematic is
# flattened into a linear system  A x = z  whose unknowns are the node
# voltages and the branch currents of ideal conductors / sources.  Ideal
# wires merge terminals into shared nodes (continuity); resistances stamp
# conductances; sources and ideal conductors add current-branch unknowns.
#
# Stateful and nonlinear devices (relays, fuses, breakers, diodes) make the
# system nonlinear, so the engine wraps the linear solve in two loops:
#   * an inner Newton loop that linearises diodes, and
#   * an outer fixed-point loop that re-evaluates device state (a relay
#     that just energised closes its contacts, a fuse that just saw too
#     much current blows, ...) and re-solves until the schematic settles.
#
# The schematic is the source of truth.  The matrices built here are
# transient internal scaffolding, exactly as the language manifesto
# requires.

package require TclOO
source [file join [file dirname [info script]] solver.tcl]

namespace eval ::schem {
    variable VERSION 1.0

    # RSMALL  resistance (ohms) of an ideal closed conductor -- a closed
    #         switch / button / relay contact.  Modelling these as a tiny
    #         resistance (rather than an ideal 0 V branch) lets several
    #         closed contacts share a node without making the nodal matrix
    #         singular -- essential for relay logic (OR, NAND, latches).
    # SHORT_R  effective external resistance (ohms) at or below which a
    #          source is judged to be shorted -- i.e. the source's current
    #          returns through a near-ideal-conductor path (a few * RSMALL)
    #          rather than through a real load.  This distinguishes a genuine
    #          short from a legitimate high-current load (a starter, a welder).
    variable RSMALL 1e-3
    variable SHORT_R 1e-2

    # ----------------------------------------------------------------
    # Component metadata: terminals each part type exposes, and the
    # default parameters for its electrical behaviour.
    # ----------------------------------------------------------------
    variable META
    array set META {
        battery   {terminals {pos neg}     params {emf 9.0 esr 0.0}}
        ground    {terminals {t}           params {}}
        resistor  {terminals {a b}         params {r 1000.0}}
        capacitor {terminals {a b}         params {c 1e-6 v0 0.0 esr 0.0 rleak 0.0}}
        inductor  {terminals {a b}         params {l 1e-3 i0 0.0 r 0.0}}
        switch    {terminals {a b}         params {state open}}
        button    {terminals {a b}         params {state released}}
        relay     {terminals {c1 c2 com no nc} params {coil 100.0 coilL 0.0 pickup 0.01 dropout 0.005 delay 0.0}}
        breaker   {terminals {a b}         params {rating 10.0 state closed i2t 0.0}}
        fuse      {terminals {a b}         params {rating 1.0 state intact i2t 0.0}}
        diode     {terminals {a k}         params {is 1e-14 n 1.0 rs 0.0 bv 0.0}}
        transformer {terminals {p1 n1 p2 n2} params {l1 1.0 l2 1.0 k 0.99}}
        bus       {terminals {t}           params {}}
        junction  {terminals {t}           params {}}
        ammeter   {terminals {a b}         params {}}
    }

    # AWG -> continuous ampacity (amps), a representative subset.
    variable AMPACITY
    array set AMPACITY {
        22 7.0  20 11.0  18 16.0  16 22.0  14 32.0
        12 41.0  10 55.0  8 73.0  6 101.0  4 135.0
    }

    # AWG -> resistance of solid copper (ohms per metre at 20 C).  A gauged
    # wire given a length (-len) drops voltage and dissipates power according
    # to this; without a length it is treated as an ideal conductor.
    variable RESPERM
    array set RESPERM {
        22 0.05292  20 0.03326  18 0.02093  16 0.01318  14 0.008286
        12 0.005211 10 0.003277 8 0.002061  6 0.001296  4 0.0008152
    }
}

# ====================================================================
#  Schematic -- one electrical artifact (a board / circuit / panel).
# ====================================================================
oo::class create ::schem::Schematic {
    variable Comp     ;# name -> dict(type params attrs)
    variable Conns    ;# list of couplings {a b awg harness}; awg "" = ideal
    variable Harness  ;# name -> dict(layer {} members {pair ...})
    variable Node     ;# terminal -> resolved node id (after build)
    variable NNodes   ;# number of non-ground nodes
    variable Result   ;# last solve: dict(v branchI ...)
    variable Faults   ;# list of fault descriptions from last solve
    variable Diode    ;# diode name -> last junction voltage (Newton state)
    variable Energized ;# persistent relay-coil state (enables latch memory)
    variable NodeDirty ;# 1 when the wiring changed and nodes must be rebuilt
    variable Name

    constructor {{name schematic}} {
        set Name $name
        set Comp [dict create]
        set Conns {}
        set Harness [dict create]
        set Result [dict create]
        set Faults {}
        set Diode [dict create]
        set Energized [dict create]
        set Node [dict create]
        set NodeDirty 1
    }

    method name {} { return $Name }

    # powerReset -- clear persistent sequential state (relay latches return
    # to de-energised, the power-on condition).  Does not touch wiring.
    method powerReset {} { set Energized [dict create] ; return }

    # ---- construction (the "workbench") ----------------------------

    # add -- place a component on the board.
    #   add TYPE NAME ?-param value ...?
    method add {type name args} {
        variable ::schem::META
        if {![info exists META($type)]} {
            return -code error "unknown component type \"$type\""
        }
        if {[dict exists $Comp $name]} {
            return -code error "duplicate component name \"$name\""
        }
        set meta $META($type)
        set params [dict get $meta params]
        # attrs hold the spatial/organisational facts of the object model
        # (where the part sits, which layer it lives on) -- distinct from
        # its electrical parameters.
        set attrs [dict create pos {} layer default]
        foreach {k v} $args {
            set key [string trimleft $k -]
            switch -- $key {
                at    { dict set attrs pos [my ParsePos $v] ; continue }
                layer { dict set attrs layer $v ; continue }
            }
            if {![dict exists $params $key]} {
                return -code error "component $type has no parameter \"$key\""
            }
            dict set params $key $v
        }
        dict set Comp $name [dict create type $type params $params attrs $attrs]
        set NodeDirty 1
        return $name
    }

    method ParsePos {v} {
        set v [string map {, " "} $v]
        if {[llength $v] != 2} {
            return -code error "position must be \"x,y\" (got \"$v\")"
        }
        return [list [expr {double([lindex $v 0])}] [expr {double([lindex $v 1])}]]
    }

    # place / layer -- set a component's spatial attributes after the fact.
    method place {name x y} {
        if {![dict exists $Comp $name]} { return -code error "no such component \"$name\"" }
        dict set Comp $name attrs [dict replace [dict get $Comp $name attrs] pos [list [expr {double($x)}] [expr {double($y)}]]]
        return
    }
    method layer {name lyr} {
        if {![dict exists $Comp $name]} { return -code error "no such component \"$name\"" }
        dict set Comp $name attrs [dict replace [dict get $Comp $name attrs] layer $lyr]
        return
    }
    method attrs {name} { return [dict get $Comp $name attrs] }

    # wire -- join two terminals with a conductor (continuity).
    #   wire A.pin B.pin ?-awg N?
    # Without -awg the wire is ideal and simply merges the two terminals
    # into one node.  With -awg the wire is a measurable conductor whose
    # current is checked against the gauge's ampacity (overload -> fault).
    method wire {ta tb args} {
        my ResolveTerm $ta
        my ResolveTerm $tb
        set awg ""
        set len ""
        foreach {k v} $args {
            switch -- $k {
                -awg { set awg $v }
                -len { set len $v }
                default { return -code error "wire: unknown option $k" }
            }
        }
        # Coupling tuple: {a b awg harness len}.  Plain wires carry no harness
        # tag; len (metres) is optional and gives a gauged wire real resistance.
        lappend Conns [list $ta $tb $awg {} $len]
        set NodeDirty 1
        return
    }

    # harness -- bundle several conductors that route together between
    # assemblies.  Electrically it is just a set of ideal couplings; the
    # bundle name is kept for the object model, serialization and rendering.
    #   harness NAME {A.pin B.pin  C.pin D.pin ...}
    method harness {name pairs args} {
        if {[dict exists $Harness $name]} {
            return -code error "duplicate harness \"$name\""
        }
        set layer default
        foreach {k v} $args { if {$k eq "-layer"} { set layer $v } }
        if {[llength $pairs] % 2 != 0} {
            return -code error "harness members must be terminal pairs"
        }
        set members {}
        foreach {a b} $pairs {
            my ResolveTerm $a ; my ResolveTerm $b
            lappend Conns [list $a $b {} $name]
            lappend members [list $a $b]
        }
        dict set Harness $name [dict create layer $layer members $members]
        set NodeDirty 1
        return $name
    }

    # ---- object-model accessors (used by serializer / renderer / IR) ----
    method conns     {} { return $Conns }
    method harnesses {} { return $Harness }
    method comp      {name} { return [dict get $Comp $name] }

    # set -- change a parameter or state of a placed component.
    method set {name key value} {
        if {![dict exists $Comp $name]} {
            return -code error "no such component \"$name\""
        }
        dict set Comp $name params [dict replace \
            [dict get $Comp $name params] $key $value]
        return
    }

    method get {name {key ""}} {
        if {![dict exists $Comp $name]} {
            return -code error "no such component \"$name\""
        }
        set p [dict get $Comp $name params]
        if {$key eq ""} { return $p }
        return [dict get $p $key]
    }

    # press / release / open / close / reset -- convenience verbs.
    method press   {name} { my set $name state pressed }
    method release {name} { my set $name state released }
    method close   {name} { my set $name state closed }
    method open    {name} { my set $name state open }
    method reset   {name} {
        set t [dict get $Comp $name type]
        switch $t {
            breaker { my set $name state closed }
            fuse    { return -code error "a blown fuse cannot be reset (irreversible fault)" }
            default { return -code error "$t has nothing to reset" }
        }
    }

    method components {} { return [dict keys $Comp] }
    method typeof {name} { return [dict get $Comp $name type] }

    # terminals -- the pin names a placed component exposes.
    method terminals {name} {
        variable ::schem::META
        return [dict get $META([dict get $Comp $name type]) terminals]
    }

    # remove -- delete a component and every coupling/harness member that
    # touched it.  (The editor's delete verb.)
    method remove {name} {
        if {![dict exists $Comp $name]} { return -code error "no such component \"$name\"" }
        dict unset Comp $name
        set kept {}
        foreach co $Conns {
            lassign $co a b
            if {[lindex [split $a .] 0] eq $name || [lindex [split $b .] 0] eq $name} continue
            lappend kept $co
        }
        set Conns $kept
        dict for {hn h} $Harness {
            set mem {}
            foreach pr [dict get $h members] {
                lassign $pr a b
                if {[lindex [split $a .] 0] eq $name || [lindex [split $b .] 0] eq $name} continue
                lappend mem $pr
            }
            if {[llength $mem] == 0} { dict unset Harness $hn } \
            else { dict set Harness $hn [dict replace $h members $mem] }
        }
        set NodeDirty 1
        return
    }

    # ---- terminal helpers ------------------------------------------

    method ResolveTerm {term} {
        lassign [split $term .] name pin
        if {![dict exists $Comp $name]} {
            return -code error "no such component \"$name\" in terminal \"$term\""
        }
        variable ::schem::META
        set type [dict get $Comp $name type]
        set valid [dict get $META($type) terminals]
        if {$pin ni $valid} {
            return -code error "$type \"$name\" has no terminal \"$pin\" (has: $valid)"
        }
        return $term
    }

    method AllTerminals {} {
        variable ::schem::META
        set out {}
        dict for {name c} $Comp {
            set type [dict get $c type]
            foreach pin [dict get $META($type) terminals] {
                lappend out $name.$pin
            }
        }
        return $out
    }
}

# Load the simulation methods (kept in a separate file for clarity).
source [file join [file dirname [info script]] simulate.tcl]
