# netlist.tcl --
#
# The derived netlist / IR.  This is NOT the source -- the schematic is.
# The netlist is a build artifact: a flattened, continuity-resolved view of
# the schematic object model that the interpreter (and, in future, exporters
# to C / WASM / HDL) consume.  It is regenerated from the schematic on
# demand and may be cached, but editing it would mean nothing -- the
# schematic is always the source of truth.
#
#     schematic (source)  ->  derive  ->  netlist/IR (cache)  ->  backends

oo::define ::schem::Schematic {

    # netlist -- derive the IR from the current schematic.  Returns a dict:
    #   name      schematic name
    #   nodes     dict nodeId -> {terminal ...}   (node 0 = ground / 0 V)
    #   elements  list of {name type params terminals {pin nodeId ...}}
    #   ports     dict port -> terminal
    # Continuity is resolved exactly as the solver sees it (ideal couplings,
    # buses, junctions and harnesses merge terminals into shared nodes).
    method netlist {} {
        my BuildNodes
        variable ::schem::META

        set nodes [dict create]
        dict for {t nid} $Node { dict lappend nodes $nid $t }

        set elements {}
        dict for {name comp} $Comp {
            set type [dict get $comp type]
            set terms [dict create]
            foreach pin [dict get $META($type) terminals] {
                dict set terms $pin [dict get $Node $name.$pin]
            }
            lappend elements [dict create \
                name $name type $type \
                params [dict get $comp params] terminals $terms]
        }

        return [dict create \
            name $Name \
            nodes $nodes \
            elements $elements \
            ports [my ports]]
    }

    # netlistText -- a readable rendering of the derived IR, clearly marked
    # as a derived artifact (not the source).
    method netlistText {} {
        set ir [my netlist]
        set out {}
        lappend out "# derived netlist for schematic \"[dict get $ir name]\""
        lappend out "# (build artifact -- the .schem schematic is the source)"
        lappend out "nodes [dict size [dict get $ir nodes]]:"
        foreach nid [lsort -integer [dict keys [dict get $ir nodes]]] {
            set label [expr {$nid == 0 ? "0(GND)" : $nid}]
            lappend out [format "  N%-7s %s" $label \
                [join [lsort [dict get $ir nodes $nid]] " "]]
        }
        lappend out "elements [llength [dict get $ir elements]]:"
        foreach e [dict get $ir elements] {
            set map {}
            dict for {pin nid} [dict get $e terminals] { lappend map "$pin=N$nid" }
            set ps {}
            dict for {k v} [dict get $e params] { lappend ps "$k=$v" }
            lappend out [format "  %-12s %-10s %-22s %s" \
                [dict get $e name] [dict get $e type] [join $map " "] [join $ps " "]]
        }
        set p [dict get $ir ports]
        if {[dict size $p]} {
            lappend out "ports:"
            dict for {pn term} $p { lappend out "  $pn -> $term" }
        }
        return [join $out \n]
    }
}
