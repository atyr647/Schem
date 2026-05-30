# transient.tcl --
#
# Time-domain simulation for ::schem::Schematic.  Capacitors and inductors
# only express behaviour over time, so this analyser steps the schematic
# forward in fixed increments dt using companion models (backward Euler):
#
#   capacitor   Geq = C/dt      I(a->b) = Geq*Vab - Geq*V_prev
#   inductor    Geq = dt/L      I(a->b) = Geq*Vab + I_prev
#
# Each step reuses the same operating-point solver as the DC analysis, so
# diodes, relays, fuses and breakers all behave correctly in time too.
# Relay contacts switch with a one-step (dt) delay -- a small physical
# lag that is exactly what lets relay oscillators and timers oscillate.

oo::define ::schem::Schematic {

    # NodeVoltageFromX -- voltage at a terminal given a raw solution vector.
    method NodeVoltageFromX {x term} {
        set nid [dict get $Node $term]
        return [expr {$nid == 0 ? 0.0 : [lindex $x [expr {$nid-1}]]}]
    }

    # run -- transient analysis.
    #   run -duration T -dt DT ?-record {term|comp ...}?
    # Returns a dict: {t {..times..} <signal> {..values..} ...}.  Recorded
    # signals are terminal names (node voltage) or component names (branch
    # current where available, else 0).
    method run {args} {
        set duration 0.01
        set dt 1e-4
        set record {}
        set events {}
        foreach {k v} $args {
            switch -- $k {
                -duration { set duration $v }
                -dt       { set dt $v }
                -record   { set record $v }
                -events   { set events $v }
                default   { return -code error "run: unknown option $k" }
            }
        }
        if {$dt <= 0}       { return -code error "run: -dt must be positive" }
        if {$duration <= 0} { return -code error "run: -duration must be positive" }

        # Timed stimulus: a schedule of {time {operation ...} ...} -- the
        # bench operator working the panel over time (or a cam-timer drum
        # closing and opening contacts).  Each operation is a method on this
        # schematic, e.g. {close SW}, {open SW}, {press B}, {release B}.
        # They only change contact state, never topology, so the node map
        # built once below stays valid.
        set sched {}
        foreach {t op} $events { lappend sched [list [expr {double($t)}] $op] }
        set sched [lsort -real -index 0 $sched]

        my BuildNodes
        set Faults {}

        # Initial reactive state from component parameters.
        set capV [dict create] ; set indI [dict create]
        dict for {name comp} $Comp {
            switch [dict get $comp type] {
                capacitor { dict set capV $name [expr {double([dict get $comp params v0])}] }
                inductor  { dict set indI $name [expr {double([dict get $comp params i0])}] }
            }
        }

        set energized [dict create]
        set pend      [dict create]   ;# per-relay pending contact transitions
        set coilI     [dict create]   ;# per-relay coil current (inductive coils)
        dict for {name comp} $Comp {
            if {[dict get $comp type] eq "relay" && \
                [dict get $comp params coilL] > 0} { dict set coilI $name 0.0 }
        }
        set diodeV    [dict create]
        set heat      [dict create]   ;# fuse/breaker accumulated I^2t
        set xfmrI     [dict create]   ;# per-transformer winding currents {I1 I2}
        dict for {name comp} $Comp {
            if {[dict get $comp type] eq "transformer"} { dict set xfmrI $name {0.0 0.0} }
        }
        set memout [dict create]      ;# per-memory output word (one-dt lag)

        set out [dict create t {}]
        foreach sig $record { dict set out $sig {} }

        set nsteps [expr {int(ceil($duration/$dt))}]
        for {set step 0} {$step <= $nsteps} {incr step} {
            set tnow [expr {$step * $dt}]

            # Apply any scheduled stimulus that is now due (time <= tnow).
            while {[llength $sched] && [lindex $sched 0 0] <= $tnow + 1e-12} {
                set ev [lindex $sched 0]
                set sched [lrange $sched 1 end]
                my {*}[lindex $ev 1]
            }

            # Build companion models for this step from the stored state.
            set state [dict create diodeV $diodeV]
            set capState [dict create] ; set indState [dict create]
            set coilState [dict create] ; set xfmrState [dict create]
            dict for {name comp} $Comp {
                set pr [dict get $comp params]
                switch [dict get $comp type] {
                    relay {
                        # An inductive coil (coilL>0) is an R+L companion, so
                        # its current ramps with the coil*coilL time constant.
                        set cL [expr {double([dict get $pr coilL])}]
                        if {$cL > 0} {
                            set rc [expr {double([dict get $pr coil])}]
                            set cgeq [expr {$dt/($rc*$dt + $cL)}]
                            set cieq [expr {$cgeq*($cL/$dt)*[dict get $coilI $name]}]
                            dict set coilState $name [list $cgeq $cieq]
                        }
                    }
                    capacitor {
                        # Backward-Euler companion for a capacitor with series
                        # ESR: the branch is ESR in series with C, so its
                        # conductance is 1/(esr + dt/C).  capV holds the
                        # internal capacitor voltage.
                        set C [expr {double([dict get $pr c])}]
                        set esr [expr {double([dict get $pr esr])}]
                        set geq [expr {1.0/($esr + $dt/$C)}]
                        dict set capState $name [list $geq [expr {-$geq*[dict get $capV $name]}]]
                    }
                    inductor {
                        # Companion for an inductor with series winding
                        # resistance r: conductance dt/(r*dt + L).
                        set L [expr {double([dict get $pr l])}]
                        set rL [expr {double([dict get $pr r])}]
                        set geq [expr {$dt/($rL*$dt + $L)}]
                        set ieq [expr {$geq*($L/$dt)*[dict get $indI $name]}]
                        dict set indState $name [list $geq $ieq]
                    }
                    transformer {
                        # Companion = dt * inv(L) where L = [[L1,M],[M,L2]],
                        # M = k*sqrt(L1*L2).  Coupling coefficient k<1 keeps the
                        # inductance matrix nonsingular.
                        set L1 [expr {double([dict get $pr l1])}]
                        set L2 [expr {double([dict get $pr l2])}]
                        set k  [expr {double([dict get $pr k])}]
                        if {$k >= 1.0}  { set k 0.999 }
                        if {$k <= -1.0} { set k -0.999 }
                        set M [expr {$k*sqrt($L1*$L2)}]
                        set det [expr {$L1*$L2 - $M*$M}]
                        if {$det <= 0} { set det 1e-12 }
                        lassign [dict get $xfmrI $name] i1p i2p
                        dict set xfmrState $name [list \
                            [expr {$dt*$L2/$det}] [expr {-$dt*$M/$det}] \
                            [expr {-$dt*$M/$det}] [expr {$dt*$L1/$det}] $i1p $i2p]
                    }
                }
            }
            dict set state capState $capState
            dict set state indState $indState
            dict set state coilState $coilState
            dict set state xfmrState $xfmrState

            # Solve this instant, holding relay/fuse/breaker state and the
            # memory output word fixed (decided by the *previous* step -> dt
            # lag, the same physical latency that lets sequential logic clock).
            dict set Result energized $energized
            dict set Result memout $memout
            set res [my SolveOP $state tran]
            set sol [dict get $res sol]
            set branches [dict get $res branches]
            set diodeV [dict get [dict get $res state] diodeV]
            set x [dict get $sol v]
            my StoreResult $sol $branches

            # Advance reactive state, and publish each reactive element's
            # current into the result so `current`/`-record` can read it.
            set imap [dict get $Result imap]
            dict for {name comp} $Comp {
                switch [dict get $comp type] {
                    capacitor {
                        lassign [dict get $capState $name] cgeq cieq
                        set vab [expr {[my NodeVoltageFromX $x $name.a] - \
                                       [my NodeVoltageFromX $x $name.b]}]
                        # Branch current, then advance the internal cap voltage.
                        set i [expr {$cgeq*$vab + $cieq}]
                        set C [expr {double([dict get $comp params c])}]
                        dict set imap $name $i
                        dict set capV $name [expr {[dict get $capV $name] + ($dt/$C)*$i}]
                    }
                    inductor {
                        lassign [dict get $indState $name] geq ieq
                        set vab [expr {[my NodeVoltageFromX $x $name.a] - \
                                       [my NodeVoltageFromX $x $name.b]}]
                        set inew [expr {$geq*$vab + $ieq}]
                        dict set imap $name $inew
                        dict set indI $name $inew
                    }
                    relay {
                        if {[dict exists $coilState $name]} {
                            lassign [dict get $coilState $name] cgeq cieq
                            set vc [expr {[my NodeVoltageFromX $x $name.c1] - \
                                          [my NodeVoltageFromX $x $name.c2]}]
                            set inew [expr {$cgeq*$vc + $cieq}]
                            dict set coilI $name $inew
                            dict set imap $name $inew
                        }
                    }
                    transformer {
                        if {[dict exists $xfmrState $name]} {
                            lassign [dict get $xfmrState $name] g11 g12 g21 g22 i1p i2p
                            set v1 [expr {[my NodeVoltageFromX $x $name.p1] - \
                                          [my NodeVoltageFromX $x $name.n1]}]
                            set v2 [expr {[my NodeVoltageFromX $x $name.p2] - \
                                          [my NodeVoltageFromX $x $name.n2]}]
                            set i1 [expr {$g11*$v1 + $g12*$v2 + $i1p}]
                            set i2 [expr {$g21*$v1 + $g22*$v2 + $i2p}]
                            dict set xfmrI $name [list $i1 $i2]
                            dict set imap $name.pri $i1
                            dict set imap $name.sec $i2
                        }
                    }
                }
            }
            dict set Result imap $imap
            my StoreDiodeCurrents $diodeV

            # Record requested signals.
            dict lappend out t $tnow
            foreach sig $record {
                if {[dict exists $Comp $sig]} {
                    dict lappend out $sig [my current $sig]
                } else {
                    dict lappend out $sig [my probe $sig]
                }
            }

            # Inverse time-current tripping for fuses/breakers (I^2t curve).
            my TripThermal heat $dt

            # Decide relay/fuse/breaker state for the *next* step, honouring
            # each relay's propagation delay (operate / release time) and the
            # actual (ramping) current of any inductive coil.  Devices with an
            # i2t curve are handled by TripThermal above, not instantly here.
            my UpdateDevices $branches energized pend $tnow $coilI 1

            # Clock the memory: latch a write on this step's rising CLK edge and
            # recompute the word it drives next step, then remember the clock
            # level so the next step can detect the following edge.
            set memwrote [dict create]
            my UpdateMemory memout memwrote
            my MemLatchClock
        }
        dict set Result faults $Faults
        return $out
    }
}
