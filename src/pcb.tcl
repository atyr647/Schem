# pcb.tcl --
#
# Export a Schem schematic to the files a board house (PCBWay, JLCPCB, OSH
# Park, ...) needs to manufacture it.  Schem's source is an *electrical*
# schematic -- components and the nets joining them -- which is exactly the
# input a PCB layout tool consumes.  So the robust, standard bridge is:
#
#     Schem schematic  ->  KiCad netlist (.net)  +  BOM (.csv)
#                              |
#                              v
#                       KiCad: place + route + DRC
#                              |
#                              v
#                       Gerber + Excellon  ->  PCBWay
#
# We emit a KiCad-format netlist (the same s-expression flavour `eeschema`
# writes) and a CSV bill of materials.  An engineer imports the netlist into
# KiCad's PCB editor (Pcbnew), which pulls in the footprints named here, then
# lays out and exports the Gerbers the fab wants.  Nothing here invents board
# geometry it cannot know (placement, track widths) -- that is the layout
# engineer's job; we hand off a correct, complete connectivity + parts list.
#
# This is a derived artifact, like the netlist IR: the .schem schematic stays
# the source of truth.

namespace eval ::schem::pcb {
    # Per component type: the reference-designator prefix an engineer expects
    # (R, C, U, ...), a sensible default KiCad footprint, and whether the part
    # is a real placeable device (vs. a schematic-only node like a net label).
    #   prefix  : RefDes letter(s) per IEEE 315 / common practice
    #   fp      : KiCad footprint "library:footprint" -- a through-hole default
    #             that exists in KiCad's standard libraries, so the import
    #             resolves without extra setup.  The engineer can re-assign.
    #   place   : 1 = a physical part that goes on the board and in the BOM
    #             0 = a connectivity construct (ground, bus, junction) -- it
    #                 still forms nets, but is not itself a placed component.
    variable MAP
    array set MAP {
        battery     {prefix BT fp {Connector_BarrelJack:BarrelJack_Horizontal}          place 1 desc "Battery / DC source"}
        resistor    {prefix R  fp {Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal} place 1 desc "Resistor"}
        capacitor   {prefix C  fp {Capacitor_THT:CP_Radial_D5.0mm_P2.50mm}              place 1 desc "Capacitor"}
        inductor    {prefix L  fp {Inductor_THT:L_Radial_D7.5mm_P5.00mm}                place 1 desc "Inductor"}
        switch      {prefix SW fp {Button_Switch_THT:SW_PUSH_6mm}                       place 1 desc "Switch"}
        button      {prefix SW fp {Button_Switch_THT:SW_PUSH_6mm}                       place 1 desc "Pushbutton"}
        relay       {prefix K  fp {Relay_THT:Relay_SPDT_Schrack-RT1-FormC_RM5mm}        place 1 desc "Relay (SPDT)"}
        breaker     {prefix CB fp {Connector_THT:Screw_Terminal_01x02_P5.08mm}          place 1 desc "Circuit breaker"}
        fuse        {prefix F  fp {Fuse:Fuseholder_Cylinder-5x20mm_Schurter_0031_8201}  place 1 desc "Fuse"}
        diode       {prefix D  fp {Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal}          place 1 desc "Diode"}
        mosfet      {prefix Q  fp {Package_TO_SOT_THT:TO-92_Inline}                     place 1 desc "MOSFET"}
        bjt         {prefix Q  fp {Package_TO_SOT_THT:TO-92_Inline}                     place 1 desc "Transistor (BJT)"}
        transformer {prefix T  fp {Transformer_THT:Transformer_Toroid_Vertical_D20.0mm} place 1 desc "Transformer"}
        memory      {prefix U  fp {Package_DIP:DIP-24_W7.62mm}                          place 1 desc "Memory"}
        buffer      {prefix U  fp {Package_TO_SOT_THT:TO-92_Inline}                     place 1 desc "Tri-state buffer"}
        ammeter     {prefix M  fp {Connector_THT:Screw_Terminal_01x02_P5.08mm}          place 1 desc "Ammeter (in-line)"}
        lamp        {prefix LP fp {LED_THT:LED_D5.0mm}                                   place 1 desc "Indicator lamp"}
        nixie       {prefix V  fp {Display_7Segment:CNZ1145}                            place 1 desc "Nixie tube"}
        core        {prefix MC fp {Inductor_THT:L_Toroid_Horizontal_D10.0mm}            place 1 desc "Magnetic core"}
        ground      {prefix GND fp {}  place 0 desc "Ground (net)"}
        bus         {prefix NET fp {}  place 0 desc "Bus (net)"}
        junction    {prefix NET fp {}  place 0 desc "Junction (net)"}
    }

    # Default fields that fill the BOM "Value" column from a component's params,
    # formatted the way an engineer reads them (10k, 1uF, 9V).  When a type has
    # no obvious single value, the type name is used.
    variable VALUEPARAM
    array set VALUEPARAM {
        resistor  r  capacitor c  inductor l  battery emf
        fuse rating  breaker rating  diode {}  lamp {}
    }
}

# eng -- format a number in engineering notation with an optional unit, the way
# a schematic prints it: 1000 -> "1k", 1e-6 -> "1u", 9 -> "9".
proc ::schem::pcb::eng {x {unit ""}} {
    if {![string is double -strict $x]} { return $x }
    if {$x == 0} { return "0$unit" }
    set neg [expr {$x < 0}] ; set x [expr {abs($x)}]
    set prefixes {-12 p -9 n -6 u -3 m 0 "" 3 k 6 M 9 G}
    set e [expr {int(floor(log10($x)/3.0))*3}]
    if {$e < -12} { set e -12 } ; if {$e > 9} { set e 9 }
    set m [expr {$x / pow(10,$e)}]
    set p [dict get $prefixes $e]
    # trim trailing zeros in the mantissa
    set ms [string trimright [format %.3f $m] 0] ; set ms [string trimright $ms .]
    return "[expr {$neg ? "-" : ""}]$ms$p$unit"
}

# value -- the human value string for a component (for the symbol and the BOM).
proc ::schem::pcb::value {type params} {
    variable VALUEPARAM
    set units {r Ω c F l H emf V rating A}
    if {[info exists VALUEPARAM($type)] && [dict get [array get VALUEPARAM] $type] ne ""} {
        set pk $VALUEPARAM($type)
        if {[dict exists $params $pk]} {
            set u [expr {[dict exists $units $pk] ? [dict get $units $pk] : ""}]
            return [::schem::pcb::eng [dict get $params $pk] $u]
        }
    }
    return $type
}

# refmap -- assign every placeable component a reference designator (R1, C1,
# U1, ...), numbered per prefix in first-seen order.  Returns name -> refdes.
proc ::schem::pcb::refmap {s} {
    variable MAP
    set counter [dict create] ; set ref [dict create]
    foreach name [$s components] {
        set type [$s typeof $name]
        if {![info exists MAP($type)]} continue
        array set m $MAP($type)
        if {!$m(place)} continue
        set p $m(prefix)
        dict incr counter $p
        dict set ref $name "$p[dict get $counter $p]"
    }
    return $ref
}

# nets -- the named nets of the schematic: node id -> {netname {comp pin ...}}.
# Ground (node 0) is the special net "GND"; other nets take the name of a bus/
# junction on them if one exists (an engineer's net label), else "Net-N".
proc ::schem::pcb::nets {s} {
    set ir [$s netlist]
    set ref [::schem::pcb::refmap $s]
    set out [dict create]
    dict for {nid terms} [dict get $ir nodes] {
        # choose a net name
        if {$nid == 0} {
            set nname GND
        } else {
            set nname "Net-$nid"
            foreach t $terms {
                lassign [split $t .] comp pin
                if {[$s typeof $comp] in {bus junction}} { set nname $comp ; break }
            }
        }
        # pins on this net that belong to *placed* parts
        set pins {}
        foreach t $terms {
            lassign [split $t .] comp pin
            if {[dict exists $ref $comp]} { lappend pins [list [dict get $ref $comp] $pin $comp] }
        }
        if {[llength $pins]} { dict set out $nid [list $nname $pins] }
    }
    return $out
}

# kicadNetlist -- emit a KiCad-format netlist (.net): the s-expression flavour
# eeschema writes and Pcbnew imports.  It lists every placed component (refdes,
# value, footprint) and every net (name + the pins on it), which is all a PCB
# layout tool needs to instantiate footprints and pull the ratsnest.
proc ::schem::pcb::kicadNetlist {s} {
    variable MAP
    set ref [::schem::pcb::refmap $s]
    set stamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]

    set out {}
    lappend out "(export (version \"E\")"
    lappend out "  (design"
    lappend out "    (source \"[$s name].schem\")"
    lappend out "    (date \"$stamp\")"
    lappend out "    (tool \"Schem PCB export\"))"

    # --- components ---
    lappend out "  (components"
    foreach name [$s components] {
        set type [$s typeof $name]
        if {![info exists MAP($type)]} continue
        array set m $MAP($type)
        if {!$m(place)} continue
        set rd [dict get $ref $name]
        set val [::schem::pcb::value $type [$s get $name]]
        lappend out "    (comp (ref \"$rd\")"
        lappend out "      (value \"$val\")"
        lappend out "      (footprint \"$m(fp)\")"
        lappend out "      (fields (field (name \"Schem_Name\") \"$name\") (field (name \"Schem_Type\") \"$type\"))"
        lappend out "      (sheetpath (names \"/\") (tstamps \"/\"))"
        lappend out "      (tstamps \"$rd\"))"
        array unset m
    }
    lappend out "  )"

    # --- nets ---
    lappend out "  (nets"
    set code 1
    dict for {nid spec} [::schem::pcb::nets $s] {
        lassign $spec nname pins
        lappend out "    (net (code \"$code\") (name \"$nname\")"
        foreach p $pins {
            lassign $p rd pin comp
            lappend out "      (node (ref \"$rd\") (pin \"[::schem::pcb::pinNumber $s $comp $pin]\") (pinfunction \"$pin\"))"
        }
        lappend out "    )"
        incr code
    }
    lappend out "  )"
    lappend out ")"
    return [join $out \n]
}

# pinNumber -- a stable 1-based pin number for a component's named terminal, in
# the order the type declares its terminals.  KiCad nets reference pads by
# number; the pinfunction keeps the human name (pos/neg/a/b/...).
proc ::schem::pcb::pinNumber {s comp pin} {
    set terms [$s terminals $comp]
    set i [lsearch -exact $terms $pin]
    return [expr {$i < 0 ? 1 : $i+1}]
}

# bomCsv -- a bill of materials grouped by identical (value, footprint, type):
# the table a board house or parts supplier reads.  Columns are the common
# JLCPCB/PCBWay style: Item, Qty, Value, Footprint, Refs, Description.
proc ::schem::pcb::bomCsv {s} {
    variable MAP
    set ref [::schem::pcb::refmap $s]
    set groups [dict create]    ;# key -> {value fp desc refs}
    foreach name [$s components] {
        set type [$s typeof $name]
        if {![info exists MAP($type)]} continue
        array set m $MAP($type)
        if {!$m(place)} { array unset m ; continue }
        set val [::schem::pcb::value $type [$s get $name]]
        set key [list $val $m(fp) $type]
        if {![dict exists $groups $key]} {
            dict set groups $key [dict create value $val fp $m(fp) desc $m(desc) refs {}]
        }
        dict with groups $key { lappend refs [dict get $ref $name] }
        array unset m
    }
    set rows {}
    lappend rows "Item,Qty,Value,Footprint,References,Description"
    set item 1
    dict for {key g} $groups {
        set refs [lsort -dictionary [dict get $g refs]]
        lappend rows [::schem::pcb::csvRow [list $item [llength $refs] \
            [dict get $g value] [dict get $g fp] [join $refs " "] [dict get $g desc]]]
        incr item
    }
    return [join $rows \n]
}

# csvRow -- join fields as a CSV row, quoting any field with a comma/quote.
proc ::schem::pcb::csvRow {fields} {
    set out {}
    foreach f $fields {
        if {[string match {*[,\"]*} $f]} {
            set f \"[string map {\" \"\"} $f]\"
        }
        lappend out $f
    }
    return [join $out ,]
}

# manufacturability -- a short pre-flight an engineer would want before handing
# a netlist to layout: parts with no footprint, single-pin nets (likely a
# wiring slip), and nets with only one connection.  Returns a list of warnings.
proc ::schem::pcb::manufacturability {s} {
    variable MAP
    set warn {}
    set ref [::schem::pcb::refmap $s]
    foreach name [$s components] {
        set type [$s typeof $name]
        if {![info exists MAP($type)]} { lappend warn "no PCB mapping for type '$type' ($name)" ; continue }
        array set m $MAP($type)
        if {$m(place) && $m(fp) eq ""} { lappend warn "$name: no footprint assigned" }
        array unset m
    }
    dict for {nid spec} [::schem::pcb::nets $s] {
        lassign $spec nname pins
        if {[llength $pins] == 1} {
            lappend warn "net '$nname' has only one pin ([lindex [lindex $pins 0] 0]) -- floating?"
        }
    }
    return $warn
}

# export -- write the .net and .csv next to a base path; returns a dict of the
# files written and any manufacturability warnings.
proc ::schem::pcb::export {s base} {
    set netf "$base.net" ; set bomf "$base.csv"
    set fh [open $netf w] ; puts $fh [::schem::pcb::kicadNetlist $s] ; close $fh
    set fh [open $bomf w] ; puts $fh [::schem::pcb::bomCsv $s] ; close $fh
    return [dict create netlist $netf bom $bomf \
        warnings [::schem::pcb::manufacturability $s]]
}
