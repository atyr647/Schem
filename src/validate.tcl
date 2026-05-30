# validate.tcl --
#
# The validator.  It reads the schematic object model and reports problems
# against the language's correctness and "anti-spaghetti" rules.  Like the
# interpreter and the viewer, it consumes the schematic itself -- it never
# parses text.
#
# Findings are dicts: {severity error|warning|info  rule NAME  message TEXT
# ?component NAME?}.  Errors mean the schematic cannot run correctly;
# warnings mean it likely does not do what was intended; info are style /
# scale suggestions.

namespace eval ::schem {
    # Board-size thresholds (the editor "warns when complexity is excessive").
    variable MAX_COMPONENTS 50
    variable MAX_COUPLINGS  80
    # Standard organisational layers and the terminal contract names.
    variable LAYERS   {power control signal fault ground default}
    variable CONTRACT {IN OUT FAULT GND}
}

oo::define ::schem::Schematic {

    # Snapshot / RestoreSnapshot -- capture and restore the mutable solve
    # state so validation's trial solve leaves the schematic untouched
    # (e.g. it must not actually blow a fuse).
    method Snapshot {} {
        return [dict create comp $Comp result $Result faults $Faults \
            diode $Diode energized $Energized]
    }
    method RestoreSnapshot {s} {
        set Comp      [dict get $s comp]
        set Result    [dict get $s result]
        set Faults    [dict get $s faults]
        set Diode     [dict get $s diode]
        set Energized [dict get $s energized]
    }

    # validate -- return a list of findings for this schematic.
    method validate {} {
        variable ::schem::META
        variable ::schem::MAX_COMPONENTS
        variable ::schem::MAX_COUPLINGS
        variable ::schem::LAYERS
        variable ::schem::CONTRACT

        set findings {}
        set comps [my components]

        # terminals that participate in at least one coupling
        set connected [dict create]
        foreach co [my conns] {
            lassign $co a b
            dict set connected $a 1 ; dict set connected $b 1
        }

        # classify components
        set grounds {} ; set batteries {}
        foreach c $comps {
            switch [my typeof $c] {
                ground  { lappend grounds $c }
                battery { lappend batteries $c }
            }
        }
        set ports [my ports]
        set isCircuit [expr {[dict size $ports] > 0}]

        # --- electrical reference & drive ---
        if {[llength $grounds] == 0} {
            lappend findings [dict create severity error rule no-ground \
                message "no ground reference: every schematic needs a 0 V reference (add a ground)"]
        }
        if {[llength $batteries] == 0 && !$isCircuit} {
            lappend findings [dict create severity warning rule no-source \
                message "no source: nothing drives current (add a battery, or expose ports if this is a reusable circuit)"]
        }

        # --- connectivity ---
        # types whose every pin must be wired for the part to function
        set strict {resistor capacitor inductor battery diode fuse breaker switch button ammeter}
        foreach c $comps {
            set type [my typeof $c]
            set pins [dict get $META($type) terminals]
            set wiredPins 0 ; set floating {}
            foreach pin $pins {
                if {[dict exists $connected $c.$pin]} { incr wiredPins } else { lappend floating $pin }
            }
            if {$wiredPins == 0 && $type ne "ground"} {
                lappend findings [dict create severity warning rule isolated-component \
                    component $c message "$type \"$c\" is placed but not connected to anything"]
            } elseif {$type in $strict && [llength $floating] > 0 && $wiredPins > 0} {
                lappend findings [dict create severity warning rule floating-terminal \
                    component $c message "$type \"$c\" has unconnected terminal(s): [join $floating {, }] (broken continuity)"]
            }
        }

        # --- terminal contract (reusable circuits) ---
        if {$isCircuit} {
            set haveGnd 0
            dict for {pn term} $ports {
                set base [regsub {[0-9]+$} $pn ""]
                if {$pn eq "GND"} { set haveGnd 1 }
                if {$base ni $CONTRACT && $pn ni {+ -}} {
                    lappend findings [dict create severity warning rule terminal-contract \
                        message "exposed port \"$pn\" is not a standard contract terminal (IN, OUT, FAULT, GND)"]
                }
            }
            if {!$haveGnd} {
                lappend findings [dict create severity info rule terminal-contract \
                    message "circuit exposes no GND port; most circuits should share a ground contract"]
            }
        }

        # --- layers ---
        foreach c $comps {
            set lyr [string tolower [dict get [my attrs $c] layer]]
            if {$lyr ni $LAYERS} {
                lappend findings [dict create severity info rule layer-unknown \
                    component $c message "\"$c\" is on non-standard layer \"[dict get [my attrs $c] layer]\" (use Power/Control/Signal/Fault/Ground)"]
            }
        }

        # --- board limits (decompose into circuits/panels/grids) ---
        if {[llength $comps] > $MAX_COMPONENTS} {
            lappend findings [dict create severity info rule board-limit \
                message "[llength $comps] components exceeds $MAX_COMPONENTS: consider decomposing into circuits/panels"]
        }
        if {[llength [my conns]] > $MAX_COUPLINGS} {
            lappend findings [dict create severity info rule board-limit \
                message "[llength [my conns]] couplings exceeds $MAX_COUPLINGS: consider named buses and harnesses"]
        }

        # --- floating nodes (static DC-topology check) ---
        # A node is floating if it has no finite-resistance path to ground: only
        # the 1 pF regulariser "connects" it so the solved voltage is undefined.
        # BFS from node 0 over every conducting element (resistors, closed
        # switches / fuses / breakers, batteries, inductors, relay coils and
        # contacts, diodes, transistors) -- open capacitors are NOT edges.
        if {[llength $grounds] > 0} {
            my BuildNodes
            set adjFN [dict create 0 {}]
            set addE {{a b} { upvar 1 adjFN adjFN
                dict lappend adjFN $a $b ; dict lappend adjFN $b $a }}
            foreach c $comps {
                set t [my typeof $c]
                switch $t {
                    battery   { apply $addE [my NodeOf $c.pos] [my NodeOf $c.neg] }
                    resistor  { apply $addE [my NodeOf $c.a]   [my NodeOf $c.b] }
                    switch - button {
                        if {[my get $c state] in {closed pressed}} {
                            apply $addE [my NodeOf $c.a] [my NodeOf $c.b]
                        }
                    }
                    fuse    { if {[my get $c state] eq "intact"} { apply $addE [my NodeOf $c.a] [my NodeOf $c.b] } }
                    breaker { if {[my get $c state] eq "closed"} { apply $addE [my NodeOf $c.a] [my NodeOf $c.b] } }
                    ammeter     { apply $addE [my NodeOf $c.a]  [my NodeOf $c.b] }
                    inductor    { apply $addE [my NodeOf $c.a]  [my NodeOf $c.b] }
                    relay {
                        apply $addE [my NodeOf $c.c1] [my NodeOf $c.c2]
                        apply $addE [my NodeOf $c.com] [my NodeOf $c.nc]
                        apply $addE [my NodeOf $c.com] [my NodeOf $c.no]
                    }
                    transformer {
                        apply $addE [my NodeOf $c.p1] [my NodeOf $c.n1]
                        apply $addE [my NodeOf $c.p2] [my NodeOf $c.n2]
                    }
                    diode  { apply $addE [my NodeOf $c.a] [my NodeOf $c.k] }
                    mosfet { apply $addE [my NodeOf $c.d] [my NodeOf $c.s] }
                    bjt    { apply $addE [my NodeOf $c.b] [my NodeOf $c.e]
                             apply $addE [my NodeOf $c.c] [my NodeOf $c.e] }
                    memory { foreach pin [my terminals $c] { apply $addE [my NodeOf $c.$pin] 0 } }
                    buffer { apply $addE [my NodeOf $c.in]  0
                             apply $addE [my NodeOf $c.oe]  0
                             apply $addE [my NodeOf $c.out] 0 }
                }
            }
            foreach co [my conns] {
                lassign $co ta tb awg
                if {$awg ne ""} { apply $addE [my NodeOf $ta] [my NodeOf $tb] }
            }
            # BFS from ground
            set visitedFN [dict create 0 1] ; set qFN [list 0]
            while {[llength $qFN]} {
                set cur [lindex $qFN 0] ; set qFN [lrange $qFN 1 end]
                if {![dict exists $adjFN $cur]} continue
                foreach nb [dict get $adjFN $cur] {
                    if {![dict exists $visitedFN $nb]} { dict set visitedFN $nb 1 ; lappend qFN $nb }
                }
            }
            # build term -> node map for readable messages
            set byNode [dict create]
            dict for {term nid} $Node { dict lappend byNode $nid $term }
            for {set nid 1} {$nid <= $NNodes} {incr nid} {
                if {[dict exists $visitedFN $nid]} continue
                set terms [lsort [dict get $byNode $nid]]
                set label [join [lrange $terms 0 2] ", "]
                if {[llength $terms] > 3} { append label ", …" }
                lappend findings [dict create severity warning rule floating-node \
                    message "node $nid ($label) has no DC path to ground (capacitor-only or undriven)"]
            }
        }

        # --- electrical faults (trial solve, no side effects) ---
        if {[llength $grounds] > 0} {
            set snap [my Snapshot]
            if {[catch {my solve} _ opts]} {
                if {[lrange [dict get $opts -errorcode] 0 1] eq {SCHEM SINGULAR}} {
                    lappend findings [dict create severity error rule short-circuit \
                        message "short circuit: ideal conductors form a loop with a source"]
                }
            } else {
                foreach flt [my faults] {
                    set sev [expr {[dict get $flt kind] eq "short" ? "error" : "warning"}]
                    lappend findings [dict create severity $sev rule [dict get $flt kind] \
                        message [dict get $flt detail]]
                }
                # bus-contention: two tri-state buffers simultaneously driving
                # the same output node with OE high after the fixed point settles.
                set driven [dict create]
                foreach c $comps {
                    if {[my typeof $c] ne "buffer"} continue
                    set thr [expr {double([my get $c vhigh]) / 2.0}]
                    if {[my probe $c.oe] > $thr} {
                        set outNode [my NodeOf $c.out]
                        if {[dict exists $driven $outNode]} {
                            set other [dict get $driven $outNode]
                            lappend findings [dict create severity error rule bus-contention \
                                component "$c+$other" \
                                message "buffers $c and $other both drive node $outNode simultaneously (bus contention)"]
                        } else {
                            dict set driven $outNode $c
                        }
                    }
                }
            }
            my RestoreSnapshot $snap
        }

        # order: errors, then warnings, then info
        return [lsort -command {apply {{x y} {
            expr {[dict get {error 0 warning 1 info 2} [dict get $x severity]] -
                  [dict get {error 0 warning 1 info 2} [dict get $y severity]]}
        }}} $findings]
    }

    # validateText -- a readable validation report.
    method validateText {} {
        set f [my validate]
        if {![llength $f]} { return "validation: OK ([llength [my components]] components, no issues)" }
        set out {}
        set ne 0 ; set nw 0 ; set ni 0
        foreach x $f {
            switch [dict get $x severity] { error {incr ne} warning {incr nw} info {incr ni} }
        }
        lappend out "validation: $ne error(s), $nw warning(s), $ni info"
        foreach x $f {
            set mark [dict get {error "ERR " warning "WARN" info "INFO"} [dict get $x severity]]
            set comp [expr {[dict exists $x component] ? " \[[dict get $x component]\]" : ""}]
            lappend out [format "  %s %-18s %s%s" $mark [dict get $x rule] [dict get $x message] $comp]
        }
        return [join $out \n]
    }
}
