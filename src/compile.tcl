# compile.tcl --
#
# The Circuit IR (CIR) compiler.  This lowers a schematic into a flat,
# continuity-resolved, backend-agnostic description in which every element is
# classified by its electrical ROLE and carries its derived quantities
# (conductances, companion/Shockley parameters) and control semantics (a
# relay's pick-up/drop-out/delay -> contact mapping, a protective device's
# rating, a switch's state).  The CIR is the single artifact every backend
# consumes -- the present Tcl MNA solver, and (via src/backend.tcl) emitters
# to Zig / C / WASM / HDL.
#
#     schematic (source)
#        -> resolve continuity (BuildNodes)            == netlist (structural)
#        -> classify each element by electrical role   == Circuit IR (lowered)
#        -> backend (MNA solver | Zig | C | ...)
#
# The CIR is a derived artifact, never the source; it is recompiled from the
# schematic on demand.  It sits one level below `netlist`: the netlist says
# "what connects to what", the CIR says "what each element *does*
# electrically", which is exactly what a code generator needs.
#
# CIR dict (version 2):
#   cir       2
#   name      <schematic name>
#   nodes     {count <N>  ground 0  map {<nid> -> {terminal ...}}}
#   ports     {<port> -> <nid>}
#   elements  [ <element> ... ]   (each: name type class nodes ...; see below)
#   analysis  {reactive 0|1  nonlinear 0|1  stateful 0|1}
#
# `class` is the role a backend dispatches on:
#   conductance  resistor, relay coil          g siemens between two nodes
#   source       battery                        emf + series rs
#   switch       switch / button                ideal conductor when closed
#   relay        coil (conductance, +L) + a state-controlled contact
#   nonlinear    diode                          Shockley is/n (+rs, +bv)
#   reactive     capacitor / inductor           value + initial state + parasitics
#   coupled      transformer                     two windings, mutual M
#   protective   fuse / breaker                  ideal conductor + trip rating/i2t
#   meter        ammeter                         0 V branch, reads current
#   conductor    gauged wire                     0 V branch (+ resistance, ampacity)

oo::define ::schem::Schematic {

    # compile -- lower the current schematic to the Circuit IR (a dict).
    method compile {} {
        my BuildNodes
        variable ::schem::META
        variable ::schem::RSMALL
        variable ::schem::AMPACITY
        variable ::schem::RESPERM

        # Node table: id -> sorted terminals (traceability back to the source).
        set raw [dict create]
        dict for {t nid} $Node { dict lappend raw $nid $t }
        set nmap [dict create]
        foreach nid [lsort -integer [dict keys $raw]] {
            dict set nmap $nid [lsort [dict get $raw $nid]]
        }

        set reactive 0 ; set nonlinear 0 ; set stateful 0
        set elements {}

        # Gauged wires: real conductors with resistance (AWG x len) + ampacity.
        set wi 0
        foreach c $Conns {
            lassign $c a b awg hn len
            if {$awg ne ""} {
                set amp [expr {[info exists AMPACITY($awg)] ? $AMPACITY($awg) : ""}]
                set rwire 0.0
                if {$len ne "" && [info exists RESPERM($awg)]} {
                    set rwire [expr {$RESPERM($awg) * double($len)}]
                }
                lappend elements [dict create name wire$wi type wire class conductor \
                    nodes [dict create a [my NodeOf $a] b [my NodeOf $b]] \
                    awg $awg len $len r $rwire ampacity $amp]
            }
            incr wi
        }

        dict for {name comp} $Comp {
            set type [dict get $comp type]
            set pr [dict get $comp params]
            set nd [dict create]
            foreach pin [my terminals $name] {
                dict set nd $pin [dict get $Node $name.$pin]
            }
            switch $type {
                resistor {
                    set r [expr {double([dict get $pr r])}]
                    lappend elements [dict create name $name type resistor class conductance \
                        nodes [dict create a [dict get $nd a] b [dict get $nd b]] \
                        r $r g [expr {$r != 0 ? 1.0/$r : ""}]]
                }
                battery {
                    lappend elements [dict create name $name type battery class source \
                        nodes [dict create pos [dict get $nd pos] neg [dict get $nd neg]] \
                        emf [expr {double([dict get $pr emf])}] \
                        rs [expr {double([dict get $pr esr])}]]
                }
                switch - button {
                    set stateful 1
                    lappend elements [dict create name $name type $type class switch \
                        nodes [dict create a [dict get $nd a] b [dict get $nd b]] \
                        state [dict get $pr state] r_closed $RSMALL]
                }
                relay {
                    set stateful 1
                    set rc [expr {double([dict get $pr coil])}]
                    lappend elements [dict create name $name type relay class relay \
                        coil [dict create \
                            nodes [dict create c1 [dict get $nd c1] c2 [dict get $nd c2]] \
                            r $rc g [expr {$rc != 0 ? 1.0/$rc : ""}] \
                            l [expr {double([dict get $pr coilL])}]] \
                        pickup [expr {double([dict get $pr pickup])}] \
                        dropout [expr {double([dict get $pr dropout])}] \
                        delay [expr {double([dict get $pr delay])}] \
                        contact [dict create \
                            nodes [dict create com [dict get $nd com] no [dict get $nd no] nc [dict get $nd nc]] \
                            r_closed $RSMALL]]
                }
                diode {
                    set nonlinear 1
                    lappend elements [dict create name $name type diode class nonlinear \
                        nodes [dict create a [dict get $nd a] k [dict get $nd k]] \
                        model [dict create is [expr {double([dict get $pr is])}] \
                                           n  [expr {double([dict get $pr n])}] \
                                           rs [expr {double([dict get $pr rs])}] \
                                           bv [expr {double([dict get $pr bv])}]]]
                }
                capacitor {
                    set reactive 1
                    lappend elements [dict create name $name type capacitor class reactive \
                        nodes [dict create a [dict get $nd a] b [dict get $nd b]] \
                        c [expr {double([dict get $pr c])}] \
                        v0 [expr {double([dict get $pr v0])}] \
                        esr [expr {double([dict get $pr esr])}] \
                        rleak [expr {double([dict get $pr rleak])}] dc open]
                }
                inductor {
                    set reactive 1
                    lappend elements [dict create name $name type inductor class reactive \
                        nodes [dict create a [dict get $nd a] b [dict get $nd b]] \
                        l [expr {double([dict get $pr l])}] \
                        i0 [expr {double([dict get $pr i0])}] \
                        r [expr {double([dict get $pr r])}] dc short]
                }
                transformer {
                    set reactive 1
                    set l1 [expr {double([dict get $pr l1])}]
                    set l2 [expr {double([dict get $pr l2])}]
                    set k  [expr {double([dict get $pr k])}]
                    lappend elements [dict create name $name type transformer class coupled \
                        nodes [dict create p1 [dict get $nd p1] n1 [dict get $nd n1] \
                                            p2 [dict get $nd p2] n2 [dict get $nd n2]] \
                        l1 $l1 l2 $l2 k $k m [expr {$k*sqrt($l1*$l2)}]]
                }
                fuse {
                    set stateful 1
                    lappend elements [dict create name $name type fuse class protective \
                        nodes [dict create a [dict get $nd a] b [dict get $nd b]] \
                        rating [dict get $pr rating] state [dict get $pr state] \
                        i2t [expr {double([dict get $pr i2t])}] reset never]
                }
                breaker {
                    set stateful 1
                    lappend elements [dict create name $name type breaker class protective \
                        nodes [dict create a [dict get $nd a] b [dict get $nd b]] \
                        rating [dict get $pr rating] state [dict get $pr state] \
                        i2t [expr {double([dict get $pr i2t])}] reset manual]
                }
                ammeter {
                    lappend elements [dict create name $name type ammeter class meter \
                        nodes [dict create a [dict get $nd a] b [dict get $nd b]]]
                }
                memory {
                    set stateful 1
                    set mode [dict get $pr mode] ; set db [dict get $pr dbits]
                    set anodes {} ; set dinodes {} ; set donodes {}
                    set ab [expr {$mode eq "tape" ? 0 : [dict get $pr abits]}]
                    for {set i 0} {$i < $ab} {incr i} { lappend anodes  [dict get $nd A$i] }
                    for {set i 0} {$i < $db} {incr i} { lappend dinodes [dict get $nd DI$i] }
                    for {set i 0} {$i < $db} {incr i} { lappend donodes [dict get $nd DO$i] }
                    # tape: head moves LEFT/RIGHT over a sparse, unbounded store.
                    set move [expr {$mode eq "tape" ? \
                        [dict create left [dict get $nd LEFT] right [dict get $nd RIGHT]] : {}}]
                    lappend elements [dict create name $name type memory class memory \
                        abits $ab dbits $db mode $mode \
                        vhigh [expr {double([dict get $pr vhigh])}] \
                        rout [expr {double([dict get $pr rout])}] \
                        rin [expr {double([dict get $pr rin])}] \
                        address $anodes di $dinodes do $donodes move $move \
                        we [dict get $nd WE] clk [dict get $nd CLK] gnd [dict get $nd GND]]
                }
                buffer {
                    lappend elements [dict create name $name type buffer class buffer \
                        in [dict get $nd in] oe [dict get $nd oe] out [dict get $nd out] \
                        vhigh [expr {double([dict get $pr vhigh])}] \
                        rout [expr {double([dict get $pr rout])}] \
                        rin [expr {double([dict get $pr rin])}]]
                }
                ground - bus - junction {
                    # Pure connectivity: already folded into the node map.
                }
            }
        }

        return [dict create \
            cir 2 \
            name $Name \
            nodes [dict create count $NNodes ground 0 map $nmap] \
            ports [my ports] \
            elements $elements \
            analysis [dict create reactive $reactive nonlinear $nonlinear stateful $stateful]]
    }

    # cirText -- a canonical, line-oriented rendering of the Circuit IR,
    # clearly marked as a derived artifact.  Readable by a human or a tool.
    method cirText {} {
        set ir [my compile]
        set a [dict get $ir analysis]
        set tags {}
        foreach f {reactive nonlinear stateful} { if {[dict get $a $f]} { lappend tags $f } }
        if {![llength $tags]} { set tags {linear static} }

        set out {}
        lappend out "; Schem Circuit IR  v[dict get $ir cir]"
        lappend out "; compiled from schematic \"[dict get $ir name]\""
        lappend out "; derived artifact -- the .schem schematic is the source"
        lappend out "; analysis: [join $tags {, }]"
        lappend out ".nodes [dict get $ir nodes count]   ; + ground (node 0)"
        dict for {nid terms} [dict get $ir nodes map] {
            set label [expr {$nid == 0 ? "N0 (GND)" : "N$nid"}]
            lappend out [format "  %-9s {%s}" $label [join $terms " "]]
        }
        set ports [dict get $ir ports]
        lappend out ".ports [dict size $ports]"
        dict for {pn nidT} $ports { lappend out "  $pn -> $nidT" }
        lappend out ".elements [llength [dict get $ir elements]]"
        foreach e [dict get $ir elements] { lappend out [my CirElementText $e] }
        return [join $out \n]
    }

    # CirElementText -- render one lowered element as an IR instruction line.
    method CirElementText {e} {
        set head [format "  %-10s %-11s %-11s" \
            [dict get $e name] [dict get $e type] [dict get $e class]]
        set N {n {expr {"N$n"}}}
        switch [dict get $e class] {
            conductance {
                set nd [dict get $e nodes]
                return "$head a=[apply $N [dict get $nd a]] b=[apply $N [dict get $nd b]]  r=[dict get $e r] g=[dict get $e g]"
            }
            source {
                set nd [dict get $e nodes]
                return "$head pos=[apply $N [dict get $nd pos]] neg=[apply $N [dict get $nd neg]]  emf=[dict get $e emf] rs=[dict get $e rs]"
            }
            switch {
                set nd [dict get $e nodes]
                return "$head a=[apply $N [dict get $nd a]] b=[apply $N [dict get $nd b]]  state=[dict get $e state] rclosed=[dict get $e r_closed]"
            }
            relay {
                set cn [dict get $e coil nodes] ; set kn [dict get $e contact nodes]
                return "$head coil\[c1=[apply $N [dict get $cn c1]] c2=[apply $N [dict get $cn c2]] r=[dict get $e coil r] l=[dict get $e coil l]\] pickup=[dict get $e pickup] dropout=[dict get $e dropout] delay=[dict get $e delay] contact\[com=[apply $N [dict get $kn com]] no=[apply $N [dict get $kn no]] nc=[apply $N [dict get $kn nc]]\]"
            }
            nonlinear {
                set nd [dict get $e nodes] ; set m [dict get $e model]
                return "$head a=[apply $N [dict get $nd a]] k=[apply $N [dict get $nd k]]  is=[dict get $m is] n=[dict get $m n] rs=[dict get $m rs] bv=[dict get $m bv]"
            }
            reactive {
                set nd [dict get $e nodes]
                if {[dict get $e type] eq "capacitor"} {
                    return "$head a=[apply $N [dict get $nd a]] b=[apply $N [dict get $nd b]]  c=[dict get $e c] v0=[dict get $e v0] esr=[dict get $e esr] rleak=[dict get $e rleak]  (dc:open)"
                } else {
                    return "$head a=[apply $N [dict get $nd a]] b=[apply $N [dict get $nd b]]  l=[dict get $e l] i0=[dict get $e i0] r=[dict get $e r]  (dc:short)"
                }
            }
            coupled {
                set nd [dict get $e nodes]
                return "$head p1=[apply $N [dict get $nd p1]] n1=[apply $N [dict get $nd n1]] p2=[apply $N [dict get $nd p2]] n2=[apply $N [dict get $nd n2]]  l1=[dict get $e l1] l2=[dict get $e l2] k=[dict get $e k] m=[dict get $e m]"
            }
            protective {
                set nd [dict get $e nodes]
                return "$head a=[apply $N [dict get $nd a]] b=[apply $N [dict get $nd b]]  rating=[dict get $e rating] state=[dict get $e state] i2t=[dict get $e i2t] reset=[dict get $e reset]"
            }
            meter {
                set nd [dict get $e nodes]
                return "$head a=[apply $N [dict get $nd a]] b=[apply $N [dict get $nd b]]"
            }
            conductor {
                set nd [dict get $e nodes]
                return "$head a=[apply $N [dict get $nd a]] b=[apply $N [dict get $nd b]]  awg=[dict get $e awg] len=[dict get $e len] r=[dict get $e r] ampacity=[dict get $e ampacity]"
            }
            buffer {
                return "$head in=[apply $N [dict get $e in]] oe=[apply $N [dict get $e oe]] out=[apply $N [dict get $e out]]  vhigh=[dict get $e vhigh] rout=[dict get $e rout] (tri-state)"
            }
            memory {
                set fmt {l {join [lmap n $l {expr {"N$n"}}] ","}}
                set sel [expr {[dict get $e mode] eq "tape" ? \
                    "head\[L=[apply $N [dict get $e move left]] R=[apply $N [dict get $e move right]]\]" : \
                    "addr\[[apply $fmt [dict get $e address]]\]"}]
                return "$head [dict get $e abits]x[dict get $e dbits] mode=[dict get $e mode] $sel di\[[apply $fmt [dict get $e di]]\] do\[[apply $fmt [dict get $e do]]\] we=[apply $N [dict get $e we]] clk=[apply $N [dict get $e clk]] gnd=[apply $N [dict get $e gnd]] vhigh=[dict get $e vhigh]"
            }
        }
        return "$head ?"
    }
}
