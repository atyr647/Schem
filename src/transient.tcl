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
        set diodeV    [dict create]
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
            dict for {name comp} $Comp {
                set pr [dict get $comp params]
                switch [dict get $comp type] {
                    capacitor {
                        set C [expr {double([dict get $pr c])}]
                        set geq [expr {$C/$dt}]
                        dict set capState $name [list $geq [expr {-$geq*[dict get $capV $name]}]]
                    }
                    inductor {
                        set L [expr {double([dict get $pr l])}]
                        set geq [expr {$dt/$L}]
                        dict set indState $name [list $geq [dict get $indI $name]]
                    }
                }
            }
            dict set state capState $capState
            dict set state indState $indState

            # Solve this instant, holding relay/fuse/breaker state fixed
            # (their state was decided by the *previous* step -> dt lag).
            dict set Result energized $energized
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
                        set vprev [dict get $capV $name]
                        dict set imap $name [expr {$cgeq*($vab-$vprev)}]
                        dict set capV $name $vab
                    }
                    inductor {
                        lassign [dict get $indState $name] geq iprev
                        set vab [expr {[my NodeVoltageFromX $x $name.a] - \
                                       [my NodeVoltageFromX $x $name.b]}]
                        set inew [expr {$geq*$vab + $iprev}]
                        dict set imap $name $inew
                        dict set indI $name $inew
                    }
                }
            }
            dict set Result imap $imap

            # Record requested signals.
            dict lappend out t $tnow
            foreach sig $record {
                if {[dict exists $Comp $sig]} {
                    dict lappend out $sig [my current $sig]
                } else {
                    dict lappend out $sig [my probe $sig]
                }
            }

            # Decide relay/fuse/breaker state for the *next* step, honouring
            # each relay's propagation delay (operate / release time).
            my UpdateDevices $branches energized pend $tnow
        }
        dict set Result faults $Faults
        return $out
    }
}
