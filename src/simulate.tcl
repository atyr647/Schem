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
                        emf [expr {double([dict get $pr emf])}] \
                        rs [expr {double([dict get $pr esr])}]]
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
                inductor {
                    if {$mode eq "dc"} {
                        # At DC steady state an inductor is its winding
                        # resistance r (a short when r = 0): a branch carrying
                        # the series resistance on its own row.
                        lappend br [dict create owner $name kind inductor \
                            p [my NodeOf $name.a] q [my NodeOf $name.b] emf 0.0 \
                            rs [expr {double([dict get $pr r])}]]
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
                    # The coil is a resistance at DC; in transient, if it has
                    # inductance (coilL), it is an R+L companion so its current
                    # ramps and interrupting it produces back-EMF (kickback).
                    if {[dict exists $state coilState $name]} {
                        lassign [dict get $state coilState $name] cgeq cieq
                        apply $stampG [my NodeOf $name.c1] [my NodeOf $name.c2] $cgeq
                        apply $stampI [my NodeOf $name.c1] [my NodeOf $name.c2] $cieq
                    } else {
                        apply $stampG [my NodeOf $name.c1] [my NodeOf $name.c2] [expr {1.0/$rc}]
                    }
                    # contacts: com-no closed when energised, com-nc when not.
                    set gc [expr {1.0/$::schem::RSMALL}]
                    if {[my RelayEnergized $name]} {
                        apply $stampG [my NodeOf $name.com] [my NodeOf $name.no] $gc
                    } else {
                        apply $stampG [my NodeOf $name.com] [my NodeOf $name.nc] $gc
                    }
                }
                switch - button {
                    if {[dict get $pr state] in {closed pressed}} {
                        apply $stampG [my NodeOf $name.a] [my NodeOf $name.b] \
                            [expr {1.0/$::schem::RSMALL}]
                    }
                }
                capacitor {
                    set na [my NodeOf $name.a] ; set nb [my NodeOf $name.b]
                    # Leakage: a real capacitor self-discharges through a large
                    # parallel resistance (rleak); present at DC and in transient.
                    set rleak [expr {double([dict get $pr rleak])}]
                    if {$rleak > 0} { apply $stampG $na $nb [expr {1.0/$rleak}] }
                    if {[dict exists $state capState $name]} {
                        lassign [dict get $state capState $name] geq ieq
                        apply $stampG $na $nb $geq
                        apply $stampI $na $nb $ieq
                    }
                    # (DC steady state: the capacitor itself is an open circuit.)
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

        # --- diodes (nonlinear, linearised at the junction voltage diodeV) ---
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "diode"} continue
            set pr [dict get $comp params]
            set rs [expr {double([dict get $pr rs])}]
            set vj [expr {[dict exists $state diodeV $name] ? \
                [dict get $state diodeV $name] : 0.0}]
            # Junction current Id and conductance gj (incl. reverse breakdown).
            lassign [my DiodeGI $name $vj] Id gj
            # Fold any series (bulk) resistance into the terminal conductance:
            # G_t = gj/(1+gj*rs); linearise about the terminal voltage vd0.
            set Gt  [expr {$gj/(1.0 + $gj*$rs)}]
            set vd0 [expr {$vj + $Id*$rs}]
            set Ieq [expr {$Id - $Gt*$vd0}]
            set na [my NodeOf $name.a] ; set nk [my NodeOf $name.k]
            apply $stampG $na $nk $Gt
            # Companion current source: constant part of the linearised diode
            # current (anode->cathode), same sign as the R/C/L companions.
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
            # A source's internal resistance sits in series on its own branch
            # row: Vp - Vq - rs*I = emf (the branch current is negative on
            # discharge here), so the terminal voltage sags as rs*|I| under
            # load and the short-circuit current is bounded by emf/rs.
            set rs [expr {[dict exists $b rs] ? [dict get $b rs] : 0.0}]
            if {$rs != 0} {
                lset A $row $row [expr {[lindex $A $row $row] - $rs}]
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

            # Update diode *junction* voltages with damping (limit big swings).
            # With series resistance the junction sits behind the terminal
            # voltage by the rs*I drop, so back it out: vj = vd - I*rs.
            set maxd 0.0
            dict for {name comp} $Comp {
                if {[dict get $comp type] ne "diode"} continue
                set vd [expr {[apply $nodeV [my NodeOf $name.a]] - \
                              [apply $nodeV [my NodeOf $name.k]]}]
                set vold [expr {[dict exists $diodeV $name] ? [dict get $diodeV $name] : 0.0}]
                set rs [expr {double([dict get $comp params rs])}]
                if {$rs > 0} {
                    lassign [my DiodeGI $name $vold] Id gj
                    set Gt [expr {$gj/(1.0 + $gj*$rs)}]
                    set Ieq [expr {$Id - $Gt*($vold + $Id*$rs)}]
                    set Ibranch [expr {$Gt*$vd + $Ieq}]
                    set vnew [expr {$vd - $Ibranch*$rs}]
                } else {
                    set vnew $vd
                }
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

        # Seed the fixed-point from the *persistent* relay state.  This is
        # what gives sequential circuits memory: a sealed-in latch that was
        # energised stays energised across solves until something resets it.
        set energized $Energized
        set seen [dict create]
        for {set outer 0} {$outer < 200} {incr outer} {
            dict set Result energized $energized
            if {[catch {my SolveOP $state} res opts]} {
                if {[lrange [dict get $opts -errorcode] 0 1] eq {SCHEM SINGULAR}} {
                    lappend Faults [dict create kind short \
                        detail "short circuit or inconsistent sources: ideal conductors form a loop with a source"]
                    set Result [dict create v {} branches {} faults $Faults short 1 energized $energized]
                    return $Result
                }
                return -options $opts $res
            }
            set sol [dict get $res sol]
            set branches [dict get $res branches]
            set state [dict get $res state]

            my StoreResult $sol $branches
            set changed [my UpdateDevices $branches energized]
            if {!$changed} break

            # Oscillation: if a relay state recurs without settling, the
            # circuit is astable (e.g. a buzzer).  Stop and note it -- a
            # stable DC operating point does not exist; use transient.
            set key [lsort [dict keys $energized]]
            if {[dict exists $seen $key]} {
                lappend Faults [dict create kind astable \
                    detail "no stable DC state (relay feedback oscillates): use transient analysis (run)"]
                break
            }
            dict set seen $key 1
        }
        set Energized $energized   ;# persist for the next solve
        if {[dict exists $state diodeV]} { my StoreDiodeCurrents [dict get $state diodeV] }
        set Result [dict replace $Result faults $Faults]
        my CheckOverload
        my CheckShort
        return $Result
    }

    # StoreDiodeCurrents -- record each diode's branch current (the junction
    # current at the converged junction voltage) into imap, so `current` and
    # `power` read the true current rather than recomputing it from the
    # terminal voltage (which is wrong when a diode has series resistance).
    method StoreDiodeCurrents {diodeV} {
        if {![dict exists $Result imap]} return
        set imap [dict get $Result imap]
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "diode"} continue
            set vj [expr {[dict exists $diodeV $name] ? [dict get $diodeV $name] : 0.0}]
            dict set imap $name [my DiodeCurrent $name $vj]
        }
        dict set Result imap $imap
    }

    # CheckShort -- a short is an unintended *near-ideal-conductor* path
    # across a source, not merely a large current: a legitimate low-resistance
    # load (a starter motor, a welder) can draw thousands of amps and is not a
    # fault.  So we judge by the effective external resistance the source sees
    # (terminal voltage / delivered current): if it is on the order of an
    # ideal conductor (a few * RSMALL), the source is shorted through
    # contacts/wires rather than feeding a real load.  (A truly ill-posed
    # short -- ideal conductors looping an ideal source -- is caught earlier
    # as a singular matrix.)
    method CheckShort {} {
        variable ::schem::SHORT_R
        if {![dict exists $Result imap]} return
        foreach name [my components] {
            if {[my typeof $name] ne "battery"} continue
            if {![dict exists $Result imap $name]} continue
            set i [expr {abs([dict get $Result imap $name])}]
            if {$i <= 1e-9} continue
            set reff [expr {abs([my voltage $name.pos $name.neg]) / $i}]
            if {$reff <= $::schem::SHORT_R} {
                lappend Faults [dict create kind short component $name \
                    reff $reff current $i \
                    detail "short circuit: source $name sees ~[format %.3g $reff] ohm -- a near-ideal-conductor path delivering [format %.3g $i] A"]
            }
        }
        dict set Result faults $Faults
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
    #
    # In transient analysis a relay can also have a propagation delay: its
    # contacts move only after the coil condition has *persisted* for the
    # relay's operate/release time.  Pass `pendVar` (a dict tracking pending
    # transitions) and the current time `tnow` to enable it; without them
    # (DC solve) relays switch immediately, as before.
    method UpdateDevices {branches energizedVar {pendVar {}} {tnow 0} {coilI {}}} {
        upvar 1 $energizedVar energized
        if {$pendVar ne ""} { upvar 1 $pendVar pend }
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
                    # Use the actual (possibly ramping) coil current when the
                    # coil is inductive; otherwise Ohm's law on the coil.
                    set ic [expr {[dict exists $coilI $name] ? abs([dict get $coilI $name]) \
                                  : ($rc > 0 ? $vc/$rc : 0.0)}]
                    set pickup [expr {double([dict get $pr pickup])}]
                    # Hysteresis: a real relay needs the full pick-up current to
                    # close, but holds in until the coil falls to the lower
                    # drop-out current.  (Defaults to no hysteresis if the
                    # part predates the dropout parameter.)
                    set dropout [expr {[dict exists $pr dropout] ? \
                        double([dict get $pr dropout]) : $pickup}]
                    if {$dropout > $pickup} { set dropout $pickup }
                    set was [dict exists $energized $name]
                    set now [expr {$was ? ($ic >= $dropout) : ($ic >= $pickup)}]
                    set delay [expr {[dict exists $pr delay] ? \
                        double([dict get $pr delay]) : 0.0}]
                    if {$pendVar eq "" || $delay <= 0} {
                        # Immediate (DC, or a relay with no propagation delay).
                        if {$now && !$was} { dict set energized $name 1 ; set changed 1 }
                        if {!$now && $was} { dict unset energized $name ; set changed 1 }
                    } elseif {$now == $was} {
                        # Desired state already matches: cancel any pending move
                        # (a coil glitch shorter than the delay is ignored).
                        dict unset pend $name
                    } else {
                        # A transition is wanted: time how long it has persisted.
                        if {![dict exists $pend $name] || \
                            [lindex [dict get $pend $name] 0] != $now} {
                            dict set pend $name [list $now $tnow]
                        }
                        if {$tnow - [lindex [dict get $pend $name] 1] >= $delay} {
                            if {$now} { dict set energized $name 1 } \
                            else      { dict unset energized $name }
                            dict unset pend $name
                            set changed 1
                        }
                    }
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
    #
    # By default returns the magnitude.  With -signed it returns the
    # *directed* current the Meter would read: positive when conventional
    # current flows from the component's first terminal to its second
    # (a -> b; pos -> neg for a battery; c1 -> c2 for a relay coil).
    method current {name args} {
        set signed [expr {"-signed" in $args}]
        if {![dict exists $Result vmap]} { my solve }
        set i ""
        if {[dict exists $Result imap $name]} {
            set i [dict get $Result imap $name]
        } elseif {[string match *.contact $name]} {
            # relay contact current: "<relay>.contact" via its closed throw.
            set rel [string range $name 0 end-8]
            set thr [expr {[my energized $rel] ? "no" : "nc"}]
            set i [expr {[my voltage $rel.com $rel.$thr] / $::schem::RSMALL}]
        } else {
            set type [dict get $Comp $name type]
            set pr [dict get $Comp $name params]
            switch $type {
                resistor {
                    set i [expr {[my voltage $name.a $name.b] / double([dict get $pr r])}]
                }
                relay {
                    set i [expr {[my voltage $name.c1 $name.c2] / double([dict get $pr coil])}]
                }
                switch - button {
                    # closed contact modelled as RSMALL -> I = Vdrop / RSMALL.
                    set i [expr {[my voltage $name.a $name.b] / $::schem::RSMALL}]
                }
                diode {
                    # Shockley current at the solved junction voltage (with any
                    # reverse-breakdown contribution); positive a -> k forward.
                    set i [my DiodeCurrent $name [my voltage $name.a $name.k]]
                }
                default { return 0.0 }
            }
        }
        return [expr {$signed ? $i : abs($i)}]
    }

    # DiodeGI -- the diode junction current Id and small-signal conductance gj
    # at junction voltage vj, from the Shockley model plus optional Zener/
    # avalanche reverse breakdown (the diode conducts hard below -bv).
    method DiodeGI {name vj} {
        set pr [dict get $Comp $name params]
        set Is [expr {double([dict get $pr is])}]
        set nf [expr {double([dict get $pr n])}]
        set Vt [expr {0.025852 * $nf}]
        set ef [expr {exp(min($vj/$Vt, 80.0))}]
        set Id [expr {$Is*($ef-1.0)}]
        set gj [expr {$Is*$ef/$Vt}]
        set bv [expr {double([dict get $pr bv])}]
        if {$bv > 0 && $vj < -$bv} {
            set eb [expr {exp(min((-$vj-$bv)/$Vt, 80.0))}]
            set Id [expr {$Id - $Is*($eb-1.0)}]
            set gj [expr {$gj + $Is*$eb/$Vt}]
        }
        if {$gj < 1e-12} { set gj 1e-12 }
        return [list $Id $gj]
    }

    # DiodeCurrent -- the diode current (anode->cathode) at junction voltage vj.
    method DiodeCurrent {name vj} {
        return [lindex [my DiodeGI $name $vj] 0]
    }

    # power -- instantaneous power at a component (watts).  Sign convention:
    # positive = absorbing/dissipating, negative = delivering (a source).
    # P = V(first->second) * I(first->second).
    method power {name} {
        if {![dict exists $Result vmap]} { my solve }
        switch [dict get $Comp $name type] {
            battery { set pins {pos neg} }
            relay   { set pins {c1 c2} }
            diode   { set pins {a k} }
            resistor - capacitor - inductor - switch - button -
            fuse - breaker - ammeter { set pins {a b} }
            default { return 0.0 }
        }
        lassign $pins p q
        return [expr {[my voltage $name.$p $name.$q] * [my current $name -signed]}]
    }

    # energy -- energy stored in a reactive component (joules):
    # a capacitor holds 1/2 C V^2, an inductor holds 1/2 L I^2.
    method energy {name} {
        if {![dict exists $Result vmap]} { my solve }
        set pr [dict get $Comp $name params]
        switch [dict get $Comp $name type] {
            capacitor {
                set v [my voltage $name.a $name.b]
                return [expr {0.5 * double([dict get $pr c]) * $v * $v}]
            }
            inductor {
                set i [my current $name -signed]
                return [expr {0.5 * double([dict get $pr l]) * $i * $i}]
            }
            default { return 0.0 }
        }
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
        # dlink: a one-way conductive edge (a -> b only), for diodes.
        set dlink {{a b} {
            upvar 1 adj adj
            dict lappend adj $a $b
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
                diode   { apply $dlink $name.a $name.k }
                relay {
                    apply $link $name.c1 $name.c2
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
