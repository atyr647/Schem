# simulate.tcl --
#
# Simulation methods for ::schem::Schematic, added with oo::define.  This
# is where continuity, Ohm's law and Kirchhoff's laws are actually
# enforced.  See engine.tcl for the overview.

oo::define ::schem::Schematic {

    # ================================================================
    #  Node resolution -- continuity via union-find.
    # ================================================================
    #
    # Ideal conductors (ungauged wires, and the single shared terminal of
    # a bus or junction) merge the terminals they touch into one node.
    # All ground terminals collapse into node 0 (the 0 V reference).
    # Everything that has impedance or is a source stays as a distinct
    # branch between nodes -- including *closed* switches, intact fuses and
    # closed breakers, which are ideal conductors but are modelled as
    # 0 V branches so their current can be measured (Ohm/Kirchhoff still
    # hold; an ideal conductor just has V = 0 across it).
    method BuildNodes {} {
        # Union-find over every terminal string.
        set parent [dict create]
        foreach t [my AllTerminals] { dict set parent $t $t }

        # find with path compression
        set find {t {
            upvar 1 parent parent
            set root $t
            while {[dict get $parent $root] ne $root} {
                set root [dict get $parent $root]
            }
            while {[dict get $parent $t] ne $root} {
                set next [dict get $parent $t]
                dict set parent $t $root
                set t $next
            }
            return $root
        }}
        set union {{a b} {
            upvar 1 parent parent find find
            set ra [apply $find $a]
            set rb [apply $find $b]
            if {$ra ne $rb} { dict set parent $ra $rb }
        }}

        # Merge ungauged wires.
        foreach c $Conns {
            lassign $c a b awg
            if {$awg eq ""} { apply $union $a $b }
        }

        # Collapse every ground terminal together.
        set grounds {}
        dict for {name comp} $Comp {
            if {[dict get $comp type] eq "ground"} { lappend grounds $name.t }
        }
        if {[llength $grounds] == 0} {
            return -code error -errorcode {SCHEM NOGROUND} \
                "schematic has no ground reference"
        }
        foreach g [lrange $grounds 1 end] { apply $union [lindex $grounds 0] $g }
        set groundRoot [apply $find [lindex $grounds 0]]

        # Assign node ids: ground -> 0, every other root -> 1..N.
        set Node [dict create]
        set idmap [dict create $groundRoot 0]
        set next 1
        foreach t [my AllTerminals] {
            set r [apply $find $t]
            if {![dict exists $idmap $r]} {
                dict set idmap $r $next
                incr next
            }
            dict set Node $t [dict get $idmap $r]
        }
        set NNodes [expr {$next - 1}]
        return
    }

    method NodeOf {term} { return [dict get $Node $term] }

    # ================================================================
    #  Branch enumeration.
    # ================================================================
    #
    # A "branch" is an MNA current-unknown: a voltage source, an ideal
    # conductor (closed switch, intact fuse, ...) modelled as a 0 V source,
    # a gauged wire, or an inductor treated as a DC short.  Returns a list
    # of dicts: {owner <name|wire#> kind <k> p <node> q <node> emf <V>}.
    # The list order fixes each branch's column in the matrix.
    method Branches {mode} {
        set br {}
        # Gauged wires are measurable conductors -> 0 V branches.
        set wi 0
        foreach c $Conns {
            lassign $c a b awg
            if {$awg ne ""} {
                lappend br [dict create owner wire$wi kind wire awg $awg \
                    p [my NodeOf $a] q [my NodeOf $b] emf 0.0]
            }
            incr wi
        }
        dict for {name comp} $Comp {
            set type [dict get $comp type]
            set pr [dict get $comp params]
            switch $type {
                battery {
                    lappend br [dict create owner $name kind battery \
                        p [my NodeOf $name.pos] q [my NodeOf $name.neg] \
                        emf [expr {double([dict get $pr emf])}]]
                }
                switch - button {
                    set on [expr {[dict get $pr state] in {closed pressed}}]
                    if {$on} {
                        lappend br [dict create owner $name kind $type \
                            p [my NodeOf $name.a] q [my NodeOf $name.b] emf 0.0]
                    }
                }
                breaker {
                    if {[dict get $pr state] eq "closed"} {
                        lappend br [dict create owner $name kind breaker \
                            rating [dict get $pr rating] \
                            p [my NodeOf $name.a] q [my NodeOf $name.b] emf 0.0]
                    }
                }
                fuse {
                    if {[dict get $pr state] eq "intact"} {
                        lappend br [dict create owner $name kind fuse \
                            rating [dict get $pr rating] \
                            p [my NodeOf $name.a] q [my NodeOf $name.b] emf 0.0]
                    }
                }
                ammeter {
                    lappend br [dict create owner $name kind ammeter \
                        p [my NodeOf $name.a] q [my NodeOf $name.b] emf 0.0]
                }
                relay {
                    set energ [my RelayEnergized $name]
                    if {$energ} {
                        lappend br [dict create owner $name.contact kind relay-no \
                            p [my NodeOf $name.com] q [my NodeOf $name.no] emf 0.0]
                    } else {
                        lappend br [dict create owner $name.contact kind relay-nc \
                            p [my NodeOf $name.com] q [my NodeOf $name.nc] emf 0.0]
                    }
                }
                inductor {
                    if {$mode eq "dc"} {
                        # An inductor is a short circuit at DC steady state.
                        lappend br [dict create owner $name kind inductor \
                            p [my NodeOf $name.a] q [my NodeOf $name.b] emf 0.0]
                    }
                }
            }
        }
        return $br
    }

    # RelayEnergized -- has the relay coil drawn enough current to pick up?
    # Reads the most recent solved currents; defaults to de-energised.
    method RelayEnergized {name} {
        return [dict exists $Result energized $name]
    }

    # ================================================================
    #  Matrix assembly + linear solve for one operating point.
    # ================================================================
    #
    # state: dict of dynamic data the stamps need:
    #   diodeV   -> name -> junction voltage guess (Newton)
    #   capState -> name -> {geq ieq} companion (transient)
    #   indState -> name -> {geq ieq} companion (transient)
    method AssembleSolve {branches state} {
        set N $NNodes
        set B [llength $branches]
        set sz [expr {$N + $B}]
        if {$sz == 0} { return [dict create v {} i {}] }

        set A [::schem::la::zeros $sz $sz]
        set z [::schem::la::zeros $sz]

        # gmin: a tiny conductance from every node to ground keeps floating
        # subnetworks solvable (standard SPICE practice).
        set gmin 1e-12
        for {set i 0} {$i < $N} {incr i} {
            lset A $i $i [expr {[lindex $A $i $i] + $gmin}]
        }

        # Conductance stamp helper (node ids; 0 == ground == skipped).
        set stampG {{nA nB g} {
            upvar 1 A A
            if {$nA != 0} { lset A [expr {$nA-1}] [expr {$nA-1}] \
                [expr {[lindex $A [expr {$nA-1}] [expr {$nA-1}]] + $g}] }
            if {$nB != 0} { lset A [expr {$nB-1}] [expr {$nB-1}] \
                [expr {[lindex $A [expr {$nB-1}] [expr {$nB-1}]] + $g}] }
            if {$nA != 0 && $nB != 0} {
                lset A [expr {$nA-1}] [expr {$nB-1}] \
                    [expr {[lindex $A [expr {$nA-1}] [expr {$nB-1}]] - $g}]
                lset A [expr {$nB-1}] [expr {$nA-1}] \
                    [expr {[lindex $A [expr {$nB-1}] [expr {$nA-1}]] - $g}]
            }
        }}
        # Current-source stamp: pushes current I from node a to node b.
        set stampI {{nA nB I} {
            upvar 1 z z
            if {$nA != 0} { lset z [expr {$nA-1}] [expr {[lindex $z [expr {$nA-1}]] - $I}] }
            if {$nB != 0} { lset z [expr {$nB-1}] [expr {[lindex $z [expr {$nB-1}]] + $I}] }
        }}

        # --- resistive + reactive (conductance) elements ---
        dict for {name comp} $Comp {
            set type [dict get $comp type]
            set pr [dict get $comp params]
            switch $type {
                resistor {
                    set r [expr {double([dict get $pr r])}]
                    if {$r <= 0} { set r 1e-9 }
                    apply $stampG [my NodeOf $name.a] [my NodeOf $name.b] [expr {1.0/$r}]
                }
                relay {
                    set rc [expr {double([dict get $pr coil])}]
                    if {$rc <= 0} { set rc 1e-9 }
                    apply $stampG [my NodeOf $name.c1] [my NodeOf $name.c2] [expr {1.0/$rc}]
                }
                capacitor {
                    if {[dict exists $state capState $name]} {
                        lassign [dict get $state capState $name] geq ieq
                        set na [my NodeOf $name.a] ; set nb [my NodeOf $name.b]
                        apply $stampG $na $nb $geq
                        apply $stampI $na $nb $ieq
                    }
                    # (DC steady state: capacitor is an open circuit -> nothing)
                }
                inductor {
                    if {[dict exists $state indState $name]} {
                        lassign [dict get $state indState $name] geq ieq
                        set na [my NodeOf $name.a] ; set nb [my NodeOf $name.b]
                        apply $stampG $na $nb $geq
                        apply $stampI $na $nb $ieq
                    }
                }
            }
        }

        # --- diodes (nonlinear, linearised at diodeV) ---
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "diode"} continue
            set pr [dict get $comp params]
            set Is [expr {double([dict get $pr is])}]
            set nf [expr {double([dict get $pr n])}]
            set Vt [expr {0.025852 * $nf}]
            set vd [expr {[dict exists $state diodeV $name] ? \
                [dict get $state diodeV $name] : 0.0}]
            # Companion model: Id = Is(exp(vd/Vt)-1); Geq = dId/dvd.
            set e [expr {exp($vd/$Vt)}]
            set Id [expr {$Is*($e-1.0)}]
            set Geq [expr {$Is*$e/$Vt}]
            if {$Geq < 1e-12} { set Geq 1e-12 }
            set Ieq [expr {$Id - $Geq*$vd}]
            set na [my NodeOf $name.a] ; set nk [my NodeOf $name.k]
            apply $stampG $na $nk $Geq
            # Companion current source: constant part of the linearised
            # diode current (anode->cathode), same sign convention as the
            # capacitor/inductor companions above.
            apply $stampI $na $nk $Ieq
        }

        # --- branches (voltage sources / ideal conductors) ---
        for {set k 0} {$k < $B} {incr k} {
            set b [lindex $branches $k]
            set row [expr {$N + $k}]
            set p [dict get $b p] ; set q [dict get $b q]
            if {$p != 0} {
                lset A [expr {$p-1}] $row [expr {[lindex $A [expr {$p-1}] $row] + 1.0}]
                lset A $row [expr {$p-1}] [expr {[lindex $A $row [expr {$p-1}]] + 1.0}]
            }
            if {$q != 0} {
                lset A [expr {$q-1}] $row [expr {[lindex $A [expr {$q-1}] $row] - 1.0}]
                lset A $row [expr {$q-1}] [expr {[lindex $A $row [expr {$q-1}]] - 1.0}]
            }
            lset z $row [dict get $b emf]
        }

        set x [::schem::la::solve $A $z]
        return [dict create v $x N $N B $B]
    }

    # ================================================================
    #  Operating-point solve: Newton (diodes) + fixed point (devices).
    # ================================================================
    method SolveOP {state {mode dc}} {
        set diodeV [expr {[dict exists $state diodeV] ? [dict get $state diodeV] : [dict create]}]
        dict set state diodeV $diodeV

        for {set newton 0} {$newton < 100} {incr newton} {
            set branches [my Branches $mode]
            set sol [my AssembleSolve $branches $state]
            set x [dict get $sol v]
            set N [dict get $sol N]

            # node-voltage accessor over this solution
            set nodeV {nid {
                upvar 1 x x
                expr {$nid == 0 ? 0.0 : [lindex $x [expr {$nid-1}]]}
            }}

            # Update diode junction voltages with damping (limit big swings).
            set maxd 0.0
            dict for {name comp} $Comp {
                if {[dict get $comp type] ne "diode"} continue
                set vnew [expr {[apply $nodeV [my NodeOf $name.a]] - \
                                [apply $nodeV [my NodeOf $name.k]]}]
                set vold [expr {[dict exists $diodeV $name] ? [dict get $diodeV $name] : 0.0}]
                # Damp to keep exp() well-behaved.
                if {$vnew - $vold > 0.5}  { set vnew [expr {$vold + 0.5}] }
                if {$vold - $vnew > 0.5}  { set vnew [expr {$vold - 0.5}] }
                set d [expr {abs($vnew-$vold)}]
                if {$d > $maxd} { set maxd $d }
                dict set diodeV $name $vnew
            }
            dict set state diodeV $diodeV
            if {$maxd < 1e-9} break
        }
        return [dict create sol $sol branches $branches state $state]
    }

    # ================================================================
    #  Public DC solve.
    # ================================================================
    method solve {} {
        my BuildNodes
        set Result [dict create]
        set Faults {}
        set state [dict create]

        # Outer fixed-point over stateful devices (relays, fuses, breakers).
        set energized [dict create]
        for {set outer 0} {$outer < 200} {incr outer} {
            dict set Result energized $energized
            if {[catch {my SolveOP $state} res opts]} {
                if {[lrange [dict get $opts -errorcode] 0 1] eq {SCHEM SINGULAR}} {
                    lappend Faults [dict create kind short \
                        detail "short circuit or inconsistent sources: ideal conductors form a loop with a source"]
                    set Result [dict create v {} branches {} faults $Faults short 1]
                    return $Result
                }
                return -options $opts $res
            }
            set sol [dict get $res sol]
            set branches [dict get $res branches]
            set state [dict get $res state]
            set x [dict get $sol v]
            set N [dict get $sol N]

            my StoreResult $sol $branches
            set changed [my UpdateDevices $branches energized]
            if {!$changed} break
        }
        set Result [dict replace $Result faults $Faults]
        my CheckOverload
        return $Result
    }

    # StoreResult -- record node voltages and branch currents.
    method StoreResult {sol branches} {
        set x [dict get $sol v]
        set N [dict get $sol N]
        set vmap [dict create]
        dict for {t nid} $Node {
            dict set vmap $t [expr {$nid == 0 ? 0.0 : [lindex $x [expr {$nid-1}]]}]
        }
        set imap [dict create]
        for {set k 0} {$k < [llength $branches]} {incr k} {
            set owner [dict get [lindex $branches $k] owner]
            dict set imap $owner [lindex $x [expr {$N + $k}]]
        }
        dict set Result vmap $vmap
        dict set Result imap $imap
        dict set Result branches $branches
    }

    # UpdateDevices -- re-evaluate relay coils, fuses and breakers against
    # the freshly solved currents.  Returns 1 if any state changed (so the
    # fixed-point loop must re-solve), 0 once everything is consistent.
    method UpdateDevices {branches energizedVar} {
        upvar 1 $energizedVar energized
        set changed 0
        set imap [dict get $Result imap]
        set vmap [dict get $Result vmap]

        dict for {name comp} $Comp {
            set type [dict get $comp type]
            set pr [dict get $comp params]
            switch $type {
                relay {
                    set vc [expr {abs([dict get $vmap $name.c1] - [dict get $vmap $name.c2])}]
                    set rc [expr {double([dict get $pr coil])}]
                    set ic [expr {$rc > 0 ? $vc/$rc : 0.0}]
                    set pickup [expr {double([dict get $pr pickup])}]
                    set now [expr {$ic >= $pickup}]
                    set was [dict exists $energized $name]
                    if {$now && !$was} { dict set energized $name 1 ; set changed 1 }
                    if {!$now && $was} { dict unset energized $name ; set changed 1 }
                }
                fuse {
                    if {[dict get $pr state] eq "intact" && [dict exists $imap $name]} {
                        set i [expr {abs([dict get $imap $name])}]
                        if {$i > [dict get $pr rating]} {
                            my set $name state blown
                            lappend Faults [dict create kind fuse-blown component $name \
                                current $i rating [dict get $pr rating] \
                                detail "fuse $name blew at [format %.3g $i] A (rating [dict get $pr rating] A) -- irreversible"]
                            set changed 1
                        }
                    }
                }
                breaker {
                    if {[dict get $pr state] eq "closed" && [dict exists $imap $name]} {
                        set i [expr {abs([dict get $imap $name])}]
                        if {$i > [dict get $pr rating]} {
                            my set $name state tripped
                            lappend Faults [dict create kind breaker-tripped component $name \
                                current $i rating [dict get $pr rating] \
                                detail "breaker $name tripped at [format %.3g $i] A (rating [dict get $pr rating] A) -- resettable"]
                            set changed 1
                        }
                    }
                }
            }
        }
        dict set Result energized $energized
        return $changed
    }

    # CheckOverload -- flag gauged wires carrying more than their ampacity.
    method CheckOverload {} {
        variable ::schem::AMPACITY
        if {![dict exists $Result imap]} return
        set imap [dict get $Result imap]
        set wi 0
        foreach c $Conns {
            lassign $c a b awg
            if {$awg ne "" && [dict exists $imap wire$wi]} {
                set i [expr {abs([dict get $imap wire$wi])}]
                if {[info exists AMPACITY($awg)] && $i > $AMPACITY($awg)} {
                    lappend Faults [dict create kind wire-overload \
                        wire "$a-$b" awg $awg current $i ampacity $AMPACITY($awg) \
                        detail "wire $a-$b ($awg AWG) overloaded: [format %.3g $i] A > $AMPACITY($awg) A ampacity"]
                }
            }
            incr wi
        }
        dict set Result faults $Faults
    }

    # ================================================================
    #  Measurement tools (probe / meter / continuity tester).
    # ================================================================

    # probe -- node voltage at a terminal (volts, ground-referenced).
    method probe {term} {
        my ResolveTerm $term
        if {![dict exists $Result vmap]} { my solve }
        return [dict get $Result vmap $term]
    }

    # voltage -- potential difference between two terminals.
    method voltage {ta tb} {
        return [expr {[my probe $ta] - [my probe $tb]}]
    }

    # current -- current through a branch component (battery, switch,
    # fuse, breaker, ammeter, ...) in amps.  For two-terminal resistive
    # parts, computes I = V/R from Ohm's law.
    method current {name} {
        if {![dict exists $Result vmap]} { my solve }
        if {[dict exists $Result imap $name]} {
            return [expr {abs([dict get $Result imap $name])}]
        }
        set type [dict get $Comp $name type]
        set pr [dict get $Comp $name params]
        switch $type {
            resistor {
                set r [expr {double([dict get $pr r])}]
                return [expr {abs([my voltage $name.a $name.b]) / $r}]
            }
            relay {
                set r [expr {double([dict get $pr coil])}]
                return [expr {abs([my voltage $name.c1 $name.c2]) / $r}]
            }
        }
        return 0.0
    }

    # continuity -- is there a conductive path between two terminals
    # *right now* (given current switch/relay/fuse states)?  This is the
    # continuity tester: it walks the conductive graph, not the solution.
    method continuity {ta tb} {
        my ResolveTerm $ta ; my ResolveTerm $tb
        my BuildNodes
        # Build adjacency over conductive edges in the present state.
        set adj [dict create]
        set link {{a b} {
            upvar 1 adj adj
            dict lappend adj $a $b
            dict lappend adj $b $a
        }}
        foreach c $Conns {
            lassign $c a b awg
            apply $link $a $b
        }
        dict for {name comp} $Comp {
            set type [dict get $comp type] ; set pr [dict get $comp params]
            switch $type {
                switch - button {
                    if {[dict get $pr state] in {closed pressed}} { apply $link $name.a $name.b }
                }
                breaker { if {[dict get $pr state] eq "closed"} { apply $link $name.a $name.b } }
                fuse    { if {[dict get $pr state] eq "intact"} { apply $link $name.a $name.b } }
                ammeter { apply $link $name.a $name.b }
                resistor - inductor { apply $link $name.a $name.b }
                relay {
                    if {[my RelayEnergized $name]} { apply $link $name.com $name.no } \
                    else { apply $link $name.com $name.nc }
                }
            }
        }
        # BFS from ta.
        set seen [dict create $ta 1]
        set queue [list $ta]
        while {[llength $queue]} {
            set cur [lindex $queue 0]
            set queue [lrange $queue 1 end]
            if {$cur eq $tb} { return 1 }
            foreach nb [expr {[dict exists $adj $cur] ? [dict get $adj $cur] : {}}] {
                if {![dict exists $seen $nb]} {
                    dict set seen $nb 1
                    lappend queue $nb
                }
            }
        }
        return 0
    }

    # faults -- list of fault dicts from the most recent solve.
    method faults {} {
        if {[dict exists $Result faults]} { return [dict get $Result faults] }
        return {}
    }

    method energized {name} { return [dict exists $Result energized $name] }

    # report -- a human-readable summary of the last solve: node voltages,
    # component currents and any faults.  Solves first if needed.
    method report {} {
        if {![dict exists $Result vmap]} { my solve }
        set out {}
        lappend out "Schematic: $Name"
        lappend out "Nodes (voltages, ground = 0 V):"
        # Group terminals by node id.
        set byNode [dict create]
        dict for {t nid} $Node { dict lappend byNode $nid $t }
        foreach nid [lsort -integer [dict keys $byNode]] {
            set v [expr {$nid == 0 ? 0.0 : [dict get $Result vmap [lindex [dict get $byNode $nid] 0]]}]
            set label [expr {$nid == 0 ? "node 0 (GND)" : "node $nid"}]
            lappend out [format "  %-14s %9.4f V   {%s}" $label $v [join [lsort [dict get $byNode $nid]] " "]]
        }
        lappend out "Currents:"
        dict for {name comp} $Comp {
            set type [dict get $comp type]
            if {$type in {ground bus junction}} continue
            if {[catch {my current $name} i] || $i == 0.0} {
                if {$type ni {battery resistor relay inductor capacitor switch button fuse breaker ammeter diode}} continue
            }
            lappend out [format "  %-12s %-9s %10.5f A" $name $type $i]
        }
        set f [my faults]
        if {[llength $f]} {
            lappend out "Faults:"
            foreach fault $f { lappend out "  ! [dict get $fault detail]" }
        } else {
            lappend out "Faults: none"
        }
        return [join $out \n]
    }
}
