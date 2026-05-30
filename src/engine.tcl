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
        mosfet    {terminals {g d s}       params {vto 1.0 kp 2e-3 lambda 0.01 type n}}
        bjt       {terminals {b c e}       params {is 1e-14 beta 100.0 n 1.0 vaf 0.0 type n}}
        transformer {terminals {p1 n1 p2 n2} params {l1 1.0 l2 1.0 k 0.99}}
        memory    {terminals {}            params {abits 4 dbits 8 mode ram vhigh 12.0 rout 1e-3 rin 1e6}}
        buffer    {terminals {in oe out}   params {vhigh 12.0 rout 1e-3 rin 1e6}}
        bus       {terminals {t}           params {}}
        junction  {terminals {t}           params {}}
        ammeter   {terminals {a b}         params {}}
        lamp      {terminals {a b}         params {r 240.0 ion 0.01}}
        nixie     {terminals {a k0 k1 k2 k3 k4 k5 k6 k7 k8 k9} params {r 47000.0 ion 1.0e-4}}
        core      {terminals {xp xn yp yn s} params {iswitch 1.0 vhigh 12.0 rout 1.0e-3 rline 1.0e-3}}
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
    variable Mem       ;# persistent memory-chip state: name -> {cells prevclk}
    variable Core      ;# persistent magnetic-core remanence: name -> bit.
                       ;# NONVOLATILE: ferrite cores keep their magnetisation
                       ;# with the power off, so powerReset must NOT clear this
                       ;# (only an explicit degauss does).
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
        set Mem [dict create]
        set Core [dict create]
        set Node [dict create]
        set NodeDirty 1
    }

    method name {} { return $Name }

    # powerReset -- clear persistent sequential state (relay latches return
    # to de-energised, volatile memory clears) -- the power-on condition.  Does
    # not touch wiring, and deliberately does NOT clear magnetic cores: core
    # memory is non-volatile and survives a power cycle (that is its whole
    # point).  Use degauss to wipe the cores.
    method powerReset {} { set Energized [dict create] ; set Mem [dict create] ; return }

    # degauss -- wipe all magnetic cores back to 0.  This is the only thing
    # that clears core remanence (a power cycle does not), modelling a bulk
    # erase / demagnetisation of the ferrite plane.
    method degauss {} { set Core [dict create] ; return }

    # coreBit / coreSensed -- inspect a magnetic core after a solve.  coreBit
    # is the stored remanent bit; coreSensed is 1 when the most recent solve's
    # read pulse flipped this core 1->0 (a destructive read saw a stored one).
    method coreBit {name} { expr {[dict exists $Core $name] ? [dict get $Core $name] : 0} }
    method coreSensed {name} {
        expr {[dict exists $Result coresense $name] ? [dict get $Result coresense $name] : 0}
    }

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
        set comp [dict create type $type params $params attrs $attrs]
        # A memory chip's pins depend on its address/data width.
        if {$type eq "memory"} { dict set comp pins [my MemPins $params] }
        dict set Comp $name $comp
        set NodeDirty 1
        return $name
    }

    # MemPins -- the terminal list for a memory of the given width.
    #   ram  : address in (A0..), data in/out, write-enable, clock, ground.
    #   tape : an unbounded Turing tape -- no address pins; instead the head
    #          moves one cell LEFT/RIGHT each clock, over a sparse cell store
    #          that grows on demand (strict Turing completeness, no 2^N blow-up).
    method MemPins {params} {
        set pins {}
        set db [dict get $params dbits]
        if {[dict get $params mode] eq "tape"} {
            for {set i 0} {$i < $db} {incr i} { lappend pins DI$i }
            for {set i 0} {$i < $db} {incr i} { lappend pins DO$i }
            lappend pins WE CLK LEFT RIGHT GND
            return $pins
        }
        set ab [dict get $params abits]
        for {set i 0} {$i < $ab} {incr i} { lappend pins A$i }
        for {set i 0} {$i < $db} {incr i} { lappend pins DI$i }
        for {set i 0} {$i < $db} {incr i} { lappend pins DO$i }
        lappend pins WE CLK GND
        return $pins
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
        # changing a memory's width or mode regenerates its pins (+ node map)
        if {[dict get $Comp $name type] eq "memory" && $key in {abits dbits mode}} {
            dict set Comp $name pins [my MemPins [dict get $Comp $name params]]
            set NodeDirty 1
        }
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

    # terminals -- the pin names a placed component exposes.  A component may
    # carry instance-specific pins (a memory chip's address/data width); else
    # the pins come from the type's metadata.
    method terminals {name} {
        variable ::schem::META
        if {[dict exists $Comp $name pins]} { return [dict get $Comp $name pins] }
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
        set valid [my terminals $name]
        if {$pin ni $valid} {
            return -code error "[dict get $Comp $name type] \"$name\" has no terminal \"$pin\" (has: $valid)"
        }
        return $term
    }

    method AllTerminals {} {
        set out {}
        dict for {name c} $Comp {
            foreach pin [my terminals $name] { lappend out $name.$pin }
        }
        return $out
    }
}

# Load the simulation methods (kept in a separate file for clarity).
source [file join [file dirname [info script]] simulate.tcl]
source [file join [file dirname [info script]] ac.tcl]
