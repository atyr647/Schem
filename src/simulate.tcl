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
        # Continuity depends only on the wiring, which does not change while a
        # circuit runs (switch/relay STATE is a stamp value, not a topology
        # change).  So resolve nodes once and reuse until an edit marks them
        # dirty -- a clocked run never recomputes this.
        if {!$NodeDirty && [dict size $Node] > 0} return
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
        set NodeDirty 0
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
        # Gauged wires are measurable conductors -> branches.  Given a length
        # they carry their real copper resistance (AWG ohms/m * len) on the
        # branch row; without one they are ideal 0 V conductors.
        variable ::schem::RESPERM
        set wi 0
        foreach c $Conns {
            lassign $c a b awg hn len
            if {$awg ne ""} {
                set rs 0.0
                if {$len ne "" && [info exists RESPERM($awg)]} {
                    set rs [expr {$RESPERM($awg) * double($len)}]
                }
                lappend br [dict create owner wire$wi kind wire awg $awg \
                    p [my NodeOf $a] q [my NodeOf $b] emf 0.0 rs $rs]
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
                transformer {
                    if {$mode eq "dc"} {
                        # At DC each ideal winding is a short (mutual coupling
                        # is a transient/dynamic effect): two 0 V branches.
                        lappend br [dict create owner $name.pri kind transformer \
                            p [my NodeOf $name.p1] q [my NodeOf $name.n1] emf 0.0]
                        lappend br [dict create owner $name.sec kind transformer \
                            p [my NodeOf $name.p2] q [my NodeOf $name.n2] emf 0.0]
                    }
                }
                memory {
                    # Each data-out pin is a logic driver: a source to ground
                    # at vhigh (bit 1) or 0 (bit 0) through a small output
                    # resistance.  The driven word comes from the fixed point
                    # (the addressed cell), held in Result memout.
                    set vh [expr {double([dict get $pr vhigh])}]
                    set ro [expr {double([dict get $pr rout])}]
                    set db [dict get $pr dbits]
                    set word [my MemWord $name]
                    for {set i 0} {$i < $db} {incr i} {
                        set bit [expr {([lindex $word $i]) ? $vh : 0.0}]
                        lappend br [dict create owner $name.DO$i kind memout \
                            p [my NodeOf $name.DO$i] q 0 emf $bit rs $ro]
                    }
                }
                buffer {
                    # A tri-state buffer drives its output ONLY when enabled
                    # (output-enable high), to vhigh/0 by its input, through the
                    # output resistance.  When disabled it is high-impedance --
                    # no branch at all -- so other drivers can own the bus.  The
                    # enable/drive decision is the fixed point's, held in
                    # Result bufdrv ({} = Hi-Z, else the driven voltage).
                    if {[dict exists $Result bufdrv $name]} {
                        lappend br [dict create owner $name.out kind bufout \
                            p [my NodeOf $name.out] q 0 \
                            emf [dict get $Result bufdrv $name] \
                            rs [expr {double([dict get $pr rout])}]]
                    }
                }
                core {
                    # The sense winding emits a pulse only on a destructive
                    # read -- the instant a stored 1 is flipped back to 0 by the
                    # read drive.  The fixed point records that event in Result
                    # coresense; while it is set the sense line is driven high so
                    # a downstream sense amplifier (a latch) can catch it.
                    if {[dict exists $Result coresense $name] && [dict get $Result coresense $name]} {
                        lappend br [dict create owner $name.s kind coresense \
                            p [my NodeOf $name.s] q 0 \
                            emf [expr {double([dict get $pr vhigh])}] \
                            rs [expr {double([dict get $pr rout])}]]
                    }
                }
            }
        }
        return $br
    }

    # MemWord -- the data word a memory is currently driving onto its DO pins,
    # decided by the fixed point (held in Result memout); defaults to all-zero.
    method MemWord {name} {
        if {[dict exists $Result memout $name]} { return [dict get $Result memout $name] }
        return [lrepeat [dict get $Comp $name params dbits] 0]
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

        # Sparse MNA matrix: an array keyed "row,col" -> value (0-based), so
        # only the non-zero entries exist.  z is a dense list of length sz.
        unset -nocomplain Asp
        array set Asp {}
        set z [::schem::la::zeros $sz]

        # gmin: a tiny conductance from every node to ground keeps floating
        # subnetworks solvable (standard SPICE practice).
        set gmin 1e-12
        for {set i 0} {$i < $N} {incr i} { set Asp($i,$i) $gmin }

        # Conductance stamp helper (node ids; 0 == ground == skipped).
        set stampG {{nA nB g} {
            upvar 1 Asp Asp
            set a [expr {$nA-1}] ; set b [expr {$nB-1}]
            if {$nA != 0} { ::schem::la::spacc Asp $a $a $g }
            if {$nB != 0} { ::schem::la::spacc Asp $b $b $g }
            if {$nA != 0 && $nB != 0} {
                ::schem::la::spacc Asp $a $b [expr {-$g}]
                ::schem::la::spacc Asp $b $a [expr {-$g}]
            }
        }}
        # Current-source stamp: pushes current I from node a to node b.
        set stampI {{nA nB I} {
            upvar 1 z z
            if {$nA != 0} { lset z [expr {$nA-1}] [expr {[lindex $z [expr {$nA-1}]] - $I}] }
            if {$nB != 0} { lset z [expr {$nB-1}] [expr {[lindex $z [expr {$nB-1}]] + $I}] }
        }}
        # Voltage-controlled current source: current g*(V_nC - V_nD) flows from
        # node nP to nN.  This is what couples a transformer's two windings.
        set stampVCCS {{nP nN nC nD g} {
            upvar 1 Asp Asp
            foreach {row col s} [list $nP $nC 1 $nP $nD -1 $nN $nC -1 $nN $nD 1] {
                if {$row != 0 && $col != 0} {
                    ::schem::la::spacc Asp [expr {$row-1}] [expr {$col-1}] [expr {$s*$g}]
                }
            }
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
                lamp {
                    # An indicator lamp is, electrically, a filament: a plain
                    # resistance that dissipates power.  Whether it is visibly
                    # lit is decided after the solve from the current it draws
                    # (see the `lit` query); here it is just a conductance.
                    set r [expr {double([dict get $pr r])}]
                    if {$r <= 0} { set r 1e-9 }
                    apply $stampG [my NodeOf $name.a] [my NodeOf $name.b] [expr {1.0/$r}]
                }
                nixie {
                    # A cold-cathode display: a common anode and ten cathodes,
                    # one per digit.  Each cathode glows when its glow-discharge
                    # path conducts, i.e. when that cathode is pulled low while
                    # the anode is high.  Model each cathode as a resistance from
                    # the anode; the lit digit is the conducting cathode.
                    set r [expr {double([dict get $pr r])}]
                    if {$r <= 0} { set r 1e-9 }
                    set na [my NodeOf $name.a]
                    for {set d 0} {$d < 10} {incr d} {
                        apply $stampG $na [my NodeOf $name.k$d] [expr {1.0/$r}]
                    }
                }
                core {
                    # A magnetic-core bit.  The X and Y drive lines each thread
                    # the core as a single turn -- electrically a near-ideal
                    # conductor, modelled as a tiny resistance so the line
                    # current is measurable and many cores can string along one
                    # line (a real core plane).  The magnetisation itself is
                    # decided in the fixed point (UpdateCore); the sense output
                    # is a branch source added in Branches when a read flips it.
                    set rl [expr {double([dict get $pr rline])}]
                    if {$rl <= 0} { set rl 1e-9 }
                    apply $stampG [my NodeOf $name.xp] [my NodeOf $name.xn] [expr {1.0/$rl}]
                    apply $stampG [my NodeOf $name.yp] [my NodeOf $name.yn] [expr {1.0/$rl}]
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
                transformer {
                    # Two magnetically coupled windings: the backward-Euler
                    # companion is a 2x2 conductance block (the inverse of the
                    # inductance matrix scaled by dt) plus a current source per
                    # winding.  This couples the windings so a changing primary
                    # current induces a secondary voltage (and vice versa).
                    if {[dict exists $state xfmrState $name]} {
                        lassign [dict get $state xfmrState $name] g11 g12 g21 g22 i1p i2p
                        set p1 [my NodeOf $name.p1] ; set n1 [my NodeOf $name.n1]
                        set p2 [my NodeOf $name.p2] ; set n2 [my NodeOf $name.n2]
                        apply $stampVCCS $p1 $n1 $p1 $n1 $g11
                        apply $stampVCCS $p1 $n1 $p2 $n2 $g12
                        apply $stampVCCS $p2 $n2 $p1 $n1 $g21
                        apply $stampVCCS $p2 $n2 $p2 $n2 $g22
                        apply $stampI $p1 $n1 $i1p
                        apply $stampI $p2 $n2 $i2p
                    }
                }
                memory {
                    # The address / data-in / control pins are high-impedance
                    # senses: a weak pull-down so an undriven pin reads LOW and
                    # the chip presents a real (large) input resistance.  Every
                    # pin except the driven data-out lines and ground is sensed
                    # this way (so both RAM address pins and a tape's LEFT/RIGHT
                    # move pins read correctly).
                    set gin [expr {1.0/double([dict get $pr rin])}]
                    foreach pin [my terminals $name] {
                        if {[string match DO* $pin] || $pin eq "GND"} continue
                        apply $stampG [my NodeOf $name.$pin] 0 $gin
                    }
                }
                buffer {
                    # in / oe are high-impedance senses (weak pull-downs); out
                    # is driven by a branch (only when enabled), never pulled.
                    set gin [expr {1.0/double([dict get $pr rin])}]
                    apply $stampG [my NodeOf $name.in] 0 $gin
                    apply $stampG [my NodeOf $name.oe] 0 $gin
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

        # --- MOSFETs (nonlinear, linearised at operating point vgs0/vds0) ---
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "mosfet"} continue
            set op [expr {[dict exists $state mosfetOP $name] ? \
                [dict get $state mosfetOP $name] : {0.0 0.0}}]
            lassign $op vgs0 vds0
            lassign [my MosfetGI $name $vgs0 $vds0] Id gm gds
            set ng [my NodeOf $name.g]
            set nd [my NodeOf $name.d]
            set ns [my NodeOf $name.s]
            # gds: drain-source output conductance
            apply $stampG $nd $ns $gds
            # VCCS: gm*(Vg - Vs) drives current from D to S
            apply $stampVCCS $nd $ns $ng $ns $gm
            # Constant part: Ieq = Id - gm*vgs0 - gds*vds0
            apply $stampI $nd $ns [expr {$Id - $gm*$vgs0 - $gds*$vds0}]
        }

        # --- BJTs (nonlinear, linearised at operating point vbe0/vce0) ---
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "bjt"} continue
            set op [expr {[dict exists $state bjtOP $name] ? \
                [dict get $state bjtOP $name] : {0.0 0.0}}]
            lassign $op vbe0 vce0
            lassign [my BjtGI $name $vbe0 $vce0] Ic Ib gm gbe gce
            set nb [my NodeOf $name.b]
            set nc [my NodeOf $name.c]
            set ne [my NodeOf $name.e]
            # gbe: base-emitter conductance (drives base current)
            apply $stampG $nb $ne $gbe
            apply $stampI $nb $ne [expr {$Ib - $gbe*$vbe0}]
            # VCCS: gm*(Vb - Ve) drives collector current from C to E
            apply $stampVCCS $nc $ne $nb $ne $gm
            # gce: Early-effect collector-emitter conductance
            apply $stampG $nc $ne $gce
            apply $stampI $nc $ne [expr {$Ic - $gm*$vbe0 - $gce*$vce0}]
        }

        # --- branches (voltage sources / ideal conductors) ---
        for {set k 0} {$k < $B} {incr k} {
            set b [lindex $branches $k]
            set row [expr {$N + $k}]
            set p [dict get $b p] ; set q [dict get $b q]
            if {$p != 0} {
                ::schem::la::spacc Asp [expr {$p-1}] $row 1.0
                ::schem::la::spacc Asp $row [expr {$p-1}] 1.0
            }
            if {$q != 0} {
                ::schem::la::spacc Asp [expr {$q-1}] $row -1.0
                ::schem::la::spacc Asp $row [expr {$q-1}] -1.0
            }
            # A source's internal resistance sits in series on its own branch
            # row: Vp - Vq - rs*I = emf (the branch current is negative on
            # discharge here), so the terminal voltage sags as rs*|I| under
            # load and the short-circuit current is bounded by emf/rs.
            set rs [expr {[dict exists $b rs] ? [dict get $b rs] : 0.0}]
            if {$rs != 0} { ::schem::la::spacc Asp $row $row [expr {-$rs}] }
            lset z $row [dict get $b emf]
        }

        set x [::schem::la::solve_sparse Asp $z $sz]
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

            # Update MOSFET operating points (vgs, vds) with damping.
            set mosfetOP [expr {[dict exists $state mosfetOP] ? \
                [dict get $state mosfetOP] : [dict create]}]
            dict for {name comp} $Comp {
                if {[dict get $comp type] ne "mosfet"} continue
                set ns [my NodeOf $name.s]
                set vgs [expr {[apply $nodeV [my NodeOf $name.g]] - [apply $nodeV $ns]}]
                set vds [expr {[apply $nodeV [my NodeOf $name.d]] - [apply $nodeV $ns]}]
                set old [expr {[dict exists $mosfetOP $name] ? \
                    [dict get $mosfetOP $name] : {0.0 0.0}}]
                lassign $old vgs0 vds0
                if {$vgs - $vgs0 >  0.5} { set vgs [expr {$vgs0 + 0.5}] }
                if {$vgs0 - $vgs >  0.5} { set vgs [expr {$vgs0 - 0.5}] }
                if {$vds - $vds0 >  0.5} { set vds [expr {$vds0 + 0.5}] }
                if {$vds0 - $vds >  0.5} { set vds [expr {$vds0 - 0.5}] }
                set d [expr {max(abs($vgs-$vgs0), abs($vds-$vds0))}]
                if {$d > $maxd} { set maxd $d }
                dict set mosfetOP $name [list $vgs $vds]
            }
            dict set state mosfetOP $mosfetOP

            # Update BJT operating points (vbe, vce) with damping.
            set bjtOP [expr {[dict exists $state bjtOP] ? \
                [dict get $state bjtOP] : [dict create]}]
            dict for {name comp} $Comp {
                if {[dict get $comp type] ne "bjt"} continue
                set ne [my NodeOf $name.e]
                set vbe [expr {[apply $nodeV [my NodeOf $name.b]] - [apply $nodeV $ne]}]
                set vce [expr {[apply $nodeV [my NodeOf $name.c]] - [apply $nodeV $ne]}]
                set old [expr {[dict exists $bjtOP $name] ? \
                    [dict get $bjtOP $name] : {0.0 0.0}}]
                lassign $old vbe0 vce0
                if {$vbe - $vbe0 >  0.5} { set vbe [expr {$vbe0 + 0.5}] }
                if {$vbe0 - $vbe >  0.5} { set vbe [expr {$vbe0 - 0.5}] }
                if {$vce - $vce0 >  0.5} { set vce [expr {$vce0 + 0.5}] }
                if {$vce0 - $vce >  0.5} { set vce [expr {$vce0 - 0.5}] }
                set d [expr {max(abs($vbe-$vbe0), abs($vce-$vce0))}]
                if {$d > $maxd} { set maxd $d }
                dict set bjtOP $name [list $vbe $vce]
            }
            dict set state bjtOP $bjtOP
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
        set memout [dict create] ; set memwrote [dict create]
        set bufdrv [dict create]
        set seen [dict create]
        # Fresh per-solve record of which cores fired their sense line on a
        # destructive read (so a new solve starts with no pulse pending).
        dict set Result coresense [dict create]
        for {set outer 0} {$outer < 200} {incr outer} {
            dict set Result energized $energized
            dict set Result memout $memout
            dict set Result bufdrv $bufdrv
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
            set chD [my UpdateDevices $branches energized]
            set chB [my UpdateBuffers bufdrv]
            # A clocked write must sample the *settled* address/data.  When the
            # bus feeding a memory's address or data pins is driven by relays or
            # tri-state buffers, those must converge first -- otherwise the
            # rising-edge write (which fires once per solve) would latch the
            # bus's pre-settled value.  So permit the write only once relays and
            # buffers are stable this pass; the combinational read runs always.
            set chM [my UpdateMemory memout memwrote [expr {!$chD && !$chB}]]
            set chC [my UpdateCore]
            if {!$chD && !$chM && !$chB && !$chC} break

            # Oscillation: if device state recurs without settling, the
            # circuit is astable (e.g. a buzzer).  Stop and note it -- a
            # stable DC operating point does not exist; use transient.
            set key [list [lsort [dict keys $energized]] $memout $bufdrv]
            if {[dict exists $seen $key]} {
                lappend Faults [dict create kind astable \
                    detail "no stable DC state (relay feedback oscillates): use transient analysis (run)"]
                break
            }
            dict set seen $key 1
        }
        set Energized $energized   ;# persist for the next solve
        my MemLatchClock         ;# remember each memory's clock level for edge detection
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
    method UpdateDevices {branches energizedVar {pendVar {}} {tnow 0} {coilI {}} {transient 0}} {
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
                    # With an I^2t rating the transient analyser trips this on
                    # an inverse-time curve (see TripThermal); here we trip only
                    # the instantaneous case (DC steady state, or no i2t curve).
                    set i2t [expr {[dict exists $pr i2t] ? double([dict get $pr i2t]) : 0.0}]
                    if {[dict get $pr state] eq "intact" && [dict exists $imap $name] \
                        && !($transient && $i2t > 0)} {
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
                    set i2t [expr {[dict exists $pr i2t] ? double([dict get $pr i2t]) : 0.0}]
                    if {[dict get $pr state] eq "closed" && [dict exists $imap $name] \
                        && !($transient && $i2t > 0)} {
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

    # TripThermal -- inverse time-current tripping for fuses and breakers in
    # transient analysis.  A device over its rating heats up at a rate of
    # (I^2 - rating^2); when the accumulated I^2t exceeds the device's i2t
    # rating it blows/trips -- so a small overload trips slowly and a large
    # one fast, like a real time-current curve.  Below rating it cools.
    # heatVar names a dict of accumulated heat (A^2 s) per device.
    method TripThermal {heatVar dt} {
        upvar 1 $heatVar heat
        dict for {name comp} $Comp {
            set type [dict get $comp type]
            if {$type ni {fuse breaker}} continue
            set pr [dict get $comp params]
            set i2t [expr {double([dict get $pr i2t])}]
            if {$i2t <= 0} continue
            set okstate [expr {$type eq "fuse" ? "intact" : "closed"}]
            if {[dict get $pr state] ne $okstate} continue
            set rating [expr {double([dict get $pr rating])}]
            set i [expr {abs([my current $name])}]
            set h [expr {[dict exists $heat $name] ? [dict get $heat $name] : 0.0}]
            if {$i > $rating} {
                set h [expr {$h + ($i*$i - $rating*$rating)*$dt}]
            } else {
                set h [expr {max(0.0, $h - $rating*$rating*$dt)}]
            }
            if {$h >= $i2t} {
                if {$type eq "fuse"} {
                    my set $name state blown
                    lappend Faults [dict create kind fuse-blown component $name \
                        current $i rating $rating \
                        detail "fuse $name blew on I^2t at [format %.3g $i] A (rating $rating A) -- irreversible"]
                } else {
                    my set $name state tripped
                    lappend Faults [dict create kind breaker-tripped component $name \
                        current $i rating $rating \
                        detail "breaker $name tripped on inverse-time at [format %.3g $i] A (rating $rating A) -- resettable"]
                }
                set h 0.0
            }
            dict set heat $name $h
        }
    }

    # MemBits / MemAddr -- read a memory's pins from the solved node voltages.
    method MemHigh {name pin thr} { return [expr {[dict get $Result vmap $name.$pin] > $thr}] }

    # UpdateBuffers -- tri-state buffers in the fixed point.  A buffer drives its
    # output (to vhigh/0 by its input) only while its output-enable is high; when
    # disabled it is high-impedance (no entry -> no branch), so another driver
    # owns the shared bus.  bufdrv maps an enabled buffer -> its driven voltage.
    # Returns 1 if any buffer's drive state changed (so the fixed point re-solves).
    method UpdateBuffers {bufdrvVar} {
        upvar 1 $bufdrvVar bufdrv
        if {![dict exists $Result vmap]} { return 0 }
        set changed 0
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "buffer"} continue
            set pr [dict get $comp params]
            set thr [expr {double([dict get $pr vhigh]) / 2.0}]
            if {[my MemHigh $name oe $thr]} {
                set v [expr {[my MemHigh $name in $thr] ? double([dict get $pr vhigh]) : 0.0}]
                if {![dict exists $bufdrv $name] || [dict get $bufdrv $name] != $v} {
                    dict set bufdrv $name $v ; set changed 1
                }
            } elseif {[dict exists $bufdrv $name]} {
                dict unset bufdrv $name ; set changed 1   ;# released -> Hi-Z
            }
        }
        return $changed
    }

    # UpdateCore -- magnetic-core write/read by coincident current, evaluated
    # each fixed-point pass.  A core's net drive is the ampere-sum of its two
    # threading lines, (Vx+Vy)/rline.  It flips to 1 once the net reaches
    # +iswitch and to 0 at -iswitch; a half-select on one line alone (driven at
    # ~0.6*iswitch in use) stays below threshold, so only the cell where both
    # selected lines cross actually switches -- the coincidence that lets one
    # plane address many cores.  A read is simply a reset drive: flipping a
    # stored 1 down to 0 is a *destructive* read and fires the sense line,
    # recorded in Result coresense and held set for the rest of this solve so a
    # downstream sense amplifier (a latch) can catch the pulse.  Returns 1 if
    # any core changed state (so the fixed point re-solves).
    method UpdateCore {} {
        if {![dict exists $Result vmap]} { return 0 }
        set vmap [dict get $Result vmap]
        set changed 0
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "core"} continue
            set pr [dict get $comp params]
            set rl [expr {double([dict get $pr rline])}]
            if {$rl <= 0} { set rl 1e-9 }
            set isw [expr {double([dict get $pr iswitch])}]
            set net [expr {([dict get $vmap $name.xp] - [dict get $vmap $name.xn] \
                          + [dict get $vmap $name.yp] - [dict get $vmap $name.yn]) / $rl}]
            set was [my coreBit $name]
            if {$net >= $isw} {
                if {!$was} { dict set Core $name 1 ; set changed 1 }
            } elseif {$net <= -$isw} {
                if {$was} {
                    dict set Core $name 0 ; set changed 1
                    dict set Result coresense $name 1   ;# destructive-read sense pulse
                }
            }
        }
        return $changed
    }

    # UpdateMemory -- a memory chip in the fixed point: drive its data-out pins
    # with the addressed cell (combinational read), and on a rising clock edge
    # (vs the previous solve) with write-enable, store data-in into that cell.
    # Returns 1 if the driven word changed (so the fixed point re-solves).
    method UpdateMemory {memoutVar memwroteVar {allowWrite 1}} {
        upvar 1 $memoutVar memout $memwroteVar memwrote
        if {![dict exists $Result vmap]} { return 0 }
        set changed 0
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "memory"} continue
            set pr [dict get $comp params]
            set db [dict get $pr dbits] ; set mode [dict get $pr mode]
            set thr [expr {double([dict get $pr vhigh]) / 2.0}]
            set cells [expr {[dict exists $Mem $name cells] ? [dict get $Mem $name cells] : [dict create]}]
            set clk [my MemHigh $name CLK $thr] ; set we [my MemHigh $name WE $thr]
            set prevclk [expr {[dict exists $Mem $name prevclk] ? [dict get $Mem $name prevclk] : 0}]
            # The cell the head/address selects: an integer index into the sparse
            # store.  RAM decodes its address pins; the tape tracks a head that
            # moves on the clock -- so its store is unbounded, never 2^N cells.
            if {$mode eq "tape"} {
                set idx [expr {[dict exists $Mem $name head] ? [dict get $Mem $name head] : 0}]
            } else {
                set idx 0 ; set ab [dict get $pr abits]
                for {set i 0} {$i < $ab} {incr i} {
                    if {[my MemHigh $name A$i $thr]} { set idx [expr {$idx | (1 << $i)}] }
                }
            }
            # rising-edge action (once per solve): write DI to the selected cell
            # when WE; a tape then steps its head one cell LEFT/RIGHT.
            if {$allowWrite && ![dict exists $memwrote $name] && $clk && !$prevclk} {
                if {$we} {
                    set di {}
                    for {set i 0} {$i < $db} {incr i} { lappend di [expr {[my MemHigh $name DI$i $thr] ? 1 : 0}] }
                    dict set cells $idx $di
                    dict set Mem $name cells $cells
                    set changed 1
                }
                if {$mode eq "tape"} {
                    set nidx $idx
                    if {[my MemHigh $name RIGHT $thr]} { incr nidx }
                    if {[my MemHigh $name LEFT  $thr]} { incr nidx -1 }
                    dict set Mem $name head $nidx
                    set idx $nidx
                }
                dict set memwrote $name 1
            }
            set word [expr {[dict exists $cells $idx] ? [dict get $cells $idx] : [lrepeat $db 0]}]
            if {![dict exists $memout $name] || [dict get $memout $name] ne $word} {
                dict set memout $name $word ; set changed 1
            }
        }
        return $changed
    }

    # MemLatchClock -- remember each memory's clock level (for next solve's
    # rising-edge detection).
    method MemLatchClock {} {
        if {![dict exists $Result vmap]} return
        dict for {name comp} $Comp {
            if {[dict get $comp type] ne "memory"} continue
            set thr [expr {double([dict get $comp params vhigh]) / 2.0}]
            dict set Mem $name prevclk [expr {[my MemHigh $name CLK $thr] ? 1 : 0}]
        }
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
                mosfet {
                    set vgs [my voltage $name.g $name.s]
                    set vds [my voltage $name.d $name.s]
                    set i [lindex [my MosfetGI $name $vgs $vds] 0]
                }
                bjt {
                    set vbe [my voltage $name.b $name.e]
                    set vce [my voltage $name.c $name.e]
                    set i [lindex [my BjtGI $name $vbe $vce] 0]
                }
                default { return 0.0 }
            }
        }
        return [expr {$signed ? $i : abs($i)}]
    }

    # BjtGI -- Ebers-Moll forward-active BJT: collector current Ic (C→E
    # convention), base current Ib (B→E), transconductance gm, base-emitter
    # conductance gbe, and Early-effect collector-emitter conductance gce,
    # all at the linearisation point (vbe, vce).  For PNP the voltages are
    # negated internally; the returned Ic and Ib are negative (current flows
    # E→C and E→B, the PNP convention).
    method BjtGI {name vbe vce} {
        set pr [dict get $Comp $name params]
        set Is   [expr {double([dict get $pr is])}]
        set beta [expr {double([dict get $pr beta])}]
        set nf   [expr {double([dict get $pr n])}]
        set Vaf  [expr {double([dict get $pr vaf])}]
        set pnp  [expr {[dict get $pr type] eq "p"}]
        if {$pnp} { set vbe [expr {-$vbe}] ; set vce [expr {-$vce}] }
        set Vt [expr {0.025852 * $nf}]
        set ef [expr {exp(min($vbe/$Vt, 80.0))}]
        # Early effect: Ic scales with (1 + Vce/Vaf), clamped so it stays positive.
        set early [expr {$Vaf > 0 ? max(0.01, 1.0 + $vce/$Vaf) : 1.0}]
        set Ic  [expr {$Is * ($ef - 1.0) * $early}]
        set gm  [expr {max($Is * $ef / $Vt * $early, 1e-12)}]
        set gce [expr {$Vaf > 0 ? max($Is * ($ef - 1.0) / $Vaf, 1e-12) : 1e-12}]
        set Ib  [expr {$Ic / $beta}]
        set gbe [expr {max($gm / $beta, 1e-12)}]
        if {$pnp} { set Ic [expr {-$Ic}] ; set Ib [expr {-$Ib}] }
        return [list $Ic $Ib $gm $gbe $gce]
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

    # MosfetGI -- drain current Id (D→S convention), transconductance gm, and
    # output conductance gds at the linearisation point (vgs, vds).  Uses the
    # Shichman-Hodges model.  For PMOS (`type p`) the voltages are negated
    # internally so the equations use the equivalent-NMOS quantities; the
    # returned Id is negative (conventional current flows S→D for a PMOS).
    method MosfetGI {name vgs vds} {
        set pr [dict get $Comp $name params]
        set vto    [expr {double([dict get $pr vto])}]
        set kp     [expr {double([dict get $pr kp])}]
        set lambda [expr {double([dict get $pr lambda])}]
        set pmos   [expr {[dict get $pr type] eq "p"}]
        if {$pmos} { set vgs [expr {-$vgs}] ; set vds [expr {-$vds}] }
        set vov [expr {$vgs - $vto}]
        if {$vov <= 0.0} {
            # Cutoff: below threshold, no channel.
            set Id 0.0 ; set gm 0.0 ; set gds 1e-12
        } elseif {$vds <= 0.0} {
            # Below-pinch-off triode (Vds ≤ 0): device symmetric around Vds=0.
            # Use linear first-order model: Id ≈ gds_0 * Vds.
            set gds [expr {$kp * $vov}]
            set Id  [expr {$gds * $vds}]
            set gm  0.0
        } elseif {$vds < $vov} {
            set lv [expr {1.0 + $lambda * $vds}]
            set Id  [expr {$kp * ($vov*$vds - $vds*$vds*0.5) * $lv}]
            set gm  [expr {$kp * $vds * $lv}]
            set gds [expr {$kp*($vov-$vds)*$lv + $kp*($vov*$vds-$vds*$vds*0.5)*$lambda}]
        } else {
            set lv [expr {1.0 + $lambda * $vds}]
            set Id  [expr {$kp * 0.5 * $vov*$vov * $lv}]
            set gm  [expr {$kp * $vov * $lv}]
            set gds [expr {$kp * 0.5 * $vov*$vov * $lambda}]
        }
        if {$gds < 1e-12} { set gds 1e-12 }
        if {$pmos} { set Id [expr {-$Id}] }
        return [list $Id $gm $gds]
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
            mosfet {
                return [expr {[my voltage $name.d $name.s] * [my current $name -signed]}]
            }
            bjt {
                # Total power = Vce*Ic + Vbe*Ib
                set vbe [my voltage $name.b $name.e]
                set vce [my voltage $name.c $name.e]
                lassign [my BjtGI $name $vbe $vce] Ic Ib
                return [expr {$vce * $Ic + $vbe * $Ib}]
            }
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

    # ---- indicator lamp / Nixie read-outs -------------------------------

    # lampCurrent -- filament current of an indicator lamp from the last solve.
    method lampCurrent {name} {
        set pr [dict get $Comp $name params]
        set r [expr {double([dict get $pr r])}]
        if {$r <= 0} { set r 1e-9 }
        expr {([dict get $Result vmap $name.a] - [dict get $Result vmap $name.b]) / $r}
    }
    # lit -- is the lamp glowing?  True once its current reaches the glow
    # threshold ion.  brightness gives that current relative to the threshold
    # (0 = dark, 1 = just lit, >1 = driven harder/brighter).
    method lit {name} {
        expr {abs([my lampCurrent $name]) >= double([dict get $Comp $name params ion])}
    }
    method brightness {name} {
        set thr [expr {double([dict get $Comp $name params ion])}]
        if {$thr <= 0} { set thr 1e-12 }
        expr {abs([my lampCurrent $name]) / $thr}
    }

    # digit -- the digit a Nixie tube is showing: the cathode drawing the most
    # current, provided it is above the glow threshold; -1 when the tube is
    # dark (no cathode pulled low).
    method digit {name} {
        set pr [dict get $Comp $name params]
        set r [expr {double([dict get $pr r])}]
        if {$r <= 0} { set r 1e-9 }
        set thr [expr {double([dict get $pr ion])}]
        set va [dict get $Result vmap $name.a]
        set best -1 ; set bestI $thr
        for {set d 0} {$d < 10} {incr d} {
            set i [expr {($va - [dict get $Result vmap $name.k$d]) / $r}]
            if {$i >= $bestI} { set bestI $i ; set best $d }
        }
        return $best
    }

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
                if {$type ni {battery resistor relay inductor capacitor switch button fuse breaker ammeter diode mosfet bjt}} continue
            }
            lappend out [format "  %-12s %-9s %10.5f A" $name $type $i]
        }
        # Indicators / displays / non-volatile cells -- the parts whose job is
        # to *show* or *hold* a value rather than carry a measurable current.
        set ind {}
        dict for {name comp} $Comp {
            switch [dict get $comp type] {
                lamp  {
                    lappend ind [format "  %-12s lamp   %s" $name \
                        [expr {[my lit $name] ? "(*) lit" : "( ) dark"}]]
                }
                nixie {
                    set d [my digit $name]
                    lappend ind [format "  %-12s nixie  %s" $name \
                        [expr {$d < 0 ? "(dark)" : $d}]]
                }
                core  {
                    lappend ind [format "  %-12s core   %d%s" $name [my coreBit $name] \
                        [expr {[my coreSensed $name] ? "  <- sense pulse" : ""}]]
                }
            }
        }
        if {[llength $ind]} { lappend out "Indicators:" ; lappend out {*}$ind }
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
