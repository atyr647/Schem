# import_yosys.tcl --
#
# Import a Yosys `write_json` netlist into Schem's digital-netlist IR.
#
# This is the universal front door for "any RTL an open tool can read": a
# user synthesises their design with Yosys (`read_verilog ...; synth;
# techmap; write_json out.json`) and this file turns that JSON into the
# bit-blasted, gate-level IR that the cycle-accurate digital kernel consumes.
#
# Yosys JSON, in one paragraph: the file has a top-level `modules` object;
# each module carries `ports` (each with a `direction` and a `bits` vector),
# `cells` (each with a `type`, `connections` mapping a port name to a bit
# vector, plus `parameters`/`attributes`/`port_directions`), and `netnames`.
# A *bit vector* is a list whose elements are either an integer (a unique id
# for one 1-bit net, SHARED across every place that net appears) or one of the
# constant strings "0", "1", "x", "z".  Bit vectors are LSB-first.  We remap
# Yosys integer bit-ids onto our own netId space (reserving 0=const0,
# 1=const1, 2=const-x), bit-blast every multi-bit connection into a list of
# 1-bit netIds, and emit the SHARED IR CONTRACT dict documented in docs/FPGA.md.
#
# Tcl has no guaranteed `json` package here, so we ship a small tolerant
# recursive-descent JSON reader (Parse* procs below).  It handles the subset
# Yosys emits: objects, arrays, strings, integers and the bare words
# true/false/null.  Public entry points are lower-case (`parse`,
# `parseString`); internal helpers are Capitalised, per Schem convention.

package require Tcl 8.6-

namespace eval ::schem::digital::yosys {
    namespace export parse parseString

    # Reserved netIds in the shared IR.  Yosys integer bit-ids are remapped
    # to fresh ids starting at $FIRSTNET so they never collide with these.
    variable CONST0 0
    variable CONST1 1
    variable CONSTX 2
    variable FIRSTNET 3
}

# ====================================================================
#  Public entry points
# ====================================================================

# parse -- read a Yosys JSON file and return the digital-netlist IR dict.
#   topModule (optional) selects which module is the top; default is the
#   module flagged with the "top" attribute, else the sole/first module.
proc ::schem::digital::yosys::parse {jsonfile {topModule {}}} {
    # Yosys JSON is UTF-8; pin it so a non-UTF-8 system locale (iso8859-1
    # under a bare C locale on Tcl 9) cannot mis-decode names/attributes.
    set fh [open $jsonfile r] ; fconfigure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    return [parseString $text $topModule]
}

# parseString -- same as `parse` but from an in-memory JSON string (used by
# the tests so they need no temp files).
proc ::schem::digital::yosys::parseString {text {topModule {}}} {
    set doc [ParseJson $text]
    return [BuildIr $doc $topModule]
}

# ====================================================================
#  IR construction
# ====================================================================

# BuildIr -- turn a parsed Yosys document (a nested dict) into the shared IR.
proc ::schem::digital::yosys::BuildIr {doc topModule} {
    variable CONST0
    variable CONST1
    variable CONSTX
    variable FIRSTNET

    if {![dict exists $doc modules]} {
        return -code error "yosys json: no 'modules' key"
    }
    set modules [dict get $doc modules]

    # Pick the top module.
    set topName [PickTop $modules $topModule]
    set mod [dict get $modules $topName]

    # netMap: Yosys bit-id (an integer, as a string) -> our netId.
    # Seeded with the constants so "0"/"1"/"x" map to reserved ids.
    set netMap [dict create]
    set nextNet $FIRSTNET

    # --- ports ----------------------------------------------------------
    set inputs  [dict create]
    set outputs [dict create]
    if {[dict exists $mod ports]} {
        dict for {pname pdef} [dict get $mod ports] {
            set dir [dict get $pdef direction]
            set bits {}
            foreach b [dict get $pdef bits] {
                lappend bits [MapBit $b netMap nextNet]
            }
            # bits are LSB-first already in Yosys json.
            switch -- $dir {
                input  { dict set inputs  $pname $bits }
                output { dict set outputs $pname $bits }
                inout  {
                    # treat an inout as appearing on both sides; the kernel
                    # decides drive direction per-cycle.
                    dict set inputs  $pname $bits
                    dict set outputs $pname $bits
                }
            }
        }
    }

    # --- cells ----------------------------------------------------------
    set cells {}
    set clocks {}
    if {[dict exists $mod cells]} {
        dict for {cname cdef} [dict get $mod cells] {
            set mapped [MapCell $cname $cdef netMap nextNet]
            if {$mapped eq ""} { continue }
            lappend cells $mapped
            # Collect clock nets from sequential cells.
            set conn [dict get $mapped conn]
            if {[dict exists $conn CLK]} {
                foreach n [dict get $conn CLK] {
                    if {$n ni $clocks} { lappend clocks $n }
                }
            }
        }
    }

    # nbits: how many distinct 1-bit nets exist.  netIds run 0..nextNet-1,
    # so the count is exactly nextNet (the reserved constants are included,
    # which the kernel wants -- it needs storage for net 0,1,2 too).
    set nbits $nextNet

    return [dict create \
        name    $topName \
        nbits   $nbits \
        inputs  $inputs \
        outputs $outputs \
        clocks  $clocks \
        cells   $cells]
}

# PickTop -- choose the top module name.
proc ::schem::digital::yosys::PickTop {modules want} {
    if {$want ne ""} {
        if {![dict exists $modules $want]} {
            return -code error "yosys json: requested top '$want' not present"
        }
        return $want
    }
    # Prefer a module with attribute top=...1.
    dict for {mname mdef} $modules {
        if {[dict exists $mdef attributes top]} {
            set t [dict get $mdef attributes top]
            if {[string match *1 $t] || $t == 1} { return $mname }
        }
    }
    # Fall back to the first module.
    return [lindex [dict keys $modules] 0]
}

# MapBit -- translate one Yosys bit (an integer id or a constant string) into
# our netId, allocating a fresh id for never-before-seen integer ids.
# netMapVar/nextVar are caller variable names (passed by reference).
proc ::schem::digital::yosys::MapBit {bit netMapVar nextVar} {
    variable CONST0
    variable CONST1
    variable CONSTX
    upvar 1 $netMapVar netMap $nextVar nextNet

    switch -- $bit {
        0 - "0" { return $CONST0 }
        1 - "1" { return $CONST1 }
        x - X   { return $CONSTX }
        z - Z   { return $CONSTX }
    }
    # An integer net id: remap stably.
    if {[dict exists $netMap $bit]} {
        return [dict get $netMap $bit]
    }
    set id $nextNet
    dict set netMap $bit $id
    incr nextNet
    return $id
}

# MapConn -- bit-blast a whole connections entry (a Yosys bit vector) into a
# list of netIds, LSB-first (the order Yosys already uses).
proc ::schem::digital::yosys::MapConn {bits netMapVar nextVar} {
    upvar 1 $netMapVar netMap $nextVar nextNet
    set out {}
    foreach b $bits { lappend out [MapBit $b netMap nextNet] }
    return $out
}

# ====================================================================
#  Cell mapping:  Yosys cell type -> Schem primitive
# ====================================================================
#
# Returns a cell dict {name <inst> type <PRIM> params <dict> conn <dict>} or
# "" to skip.  See docs/FPGA.md for the full mapping table.  IMPLEMENTED here:
# the minimal "runs anything" gate set ($_NOT_,$_AND_,$_OR_,$_XOR_,$_MUX_) and
# the positive-edge D flip-flop ($_DFF_P_).  Everything else hits the `default`
# arm and raises a clear error, so nothing is silently dropped.
#
# TODO -- the rest of the minimal-plus set (extend the switch below):
#   $_DFF_N_              -> DFF {clkpol 0 ...}
#   $_DFFE_[NP][NP]_      -> DFF {enable 1, enpol from name}, +EN port
#   $_SDFF_[NP][NP][01]_  -> DFF sync reset {async 0 rstval 0/1}, +R port
#   $_DFF_[NP][NP][01]_   -> DFF async reset {async 1 ...}, +R port
#   $_DLATCH_[NP][01]_    -> DLATCH {E D R Q}
#   $_AOI3_/$_OAI3_/...   -> compound gate, or a LUT with computed init
# Coarse cells that survive a bare `synth` (run `techmap` to avoid them):
#   $dff/$adff/$dffe/$sdff -> word DFF, WIDTH-wide; bit-blast D/Q/EN
#   $mux                  -> word MUX, WIDTH-wide
#   $and/$or/$xor/$not    -> word gates, bit-blast A/B/Y
#   $add/$sub             -> ADD primitive (A_WIDTH/B_WIDTH/Y_WIDTH)
#   $eq/$ne/$lt/$gt       -> comparator primitives
#   $mem_v2/$mem          -> MEM {abits dbits words rdsync}, RD/WR ports

proc ::schem::digital::yosys::MapCell {cname cdef netMapVar nextVar} {
    upvar 1 $netMapVar netMap $nextVar nextNet
    set type [dict get $cdef type]
    set params [expr {[dict exists $cdef parameters] ? [dict get $cdef parameters] : {}}]

    # Map every connection port through the bit-blaster up front.
    set conn [dict create]
    if {[dict exists $cdef connections]} {
        dict for {port bits} [dict get $cdef connections] {
            dict set conn $port [MapConn $bits netMap nextNet]
        }
    }

    switch -exact -- $type {
        {$_NOT_} {
            return [Cell $cname NOT {} [dict create A [G $conn A] Y [G $conn Y]]]
        }
        {$_AND_} - {$_OR_} - {$_XOR_} - {$_NAND_} - {$_NOR_} - {$_XNOR_} - {$_ANDNOT_} - {$_ORNOT_} {
            # 2-input single-bit gates: A,B -> Y.  Strip $_ and trailing _.
            set prim [string range $type 2 end-1]
            return [Cell $cname $prim {} \
                [dict create A [G $conn A] B [G $conn B] Y [G $conn Y]]]
        }
        {$_MUX_} {
            # Y = S ? B : A
            return [Cell $cname MUX {} \
                [dict create A [G $conn A] B [G $conn B] S [G $conn S] Y [G $conn Y]]]
        }
        {$_DFF_P_} {
            # Positive-edge D flip-flop: C(clock) D Q.  No reset/enable.
            set p [dict create clkpol 1 rstpol 0 rstval 0 async 0 enable 0]
            return [Cell $cname DFF $p \
                [dict create CLK [G $conn C] D [G $conn D] Q [G $conn Q]]]
        }
        default {
            return -code error \
                "yosys import: unsupported cell type '$type' (instance '$cname');\
                 run 'techmap' to reduce to the gate set, or extend MapCell"
        }
    }
}

# Cell -- assemble a cell dict in the IR shape.
proc ::schem::digital::yosys::Cell {name type params conn} {
    return [dict create name $name type $type params $params conn $conn]
}

# G -- fetch a port's bit-blasted netId list from a mapped-connections dict,
# erroring helpfully if the expected port is absent.
proc ::schem::digital::yosys::G {conn port} {
    if {![dict exists $conn $port]} {
        return -code error "yosys import: expected port '$port' on cell"
    }
    return [dict get $conn $port]
}

# ====================================================================
#  Tolerant JSON reader  (subset Yosys emits)
# ====================================================================
#
# ParseJson returns nested Tcl dicts (for JSON objects) and lists (for JSON
# arrays); strings/numbers/bools become plain Tcl values.  It is deliberately
# small: it accepts the well-formed JSON Yosys writes, not arbitrary JSON.

proc ::schem::digital::yosys::ParseJson {text} {
    set state [dict create text $text len [string length $text] pos 0]
    SkipWs state
    set val [ParseValue state]
    SkipWs state
    return $val
}

proc ::schem::digital::yosys::SkipWs {stateVar} {
    upvar 1 $stateVar st
    set text [dict get $st text]
    set len  [dict get $st len]
    set pos  [dict get $st pos]
    while {$pos < $len} {
        set c [string index $text $pos]
        if {$c ne " " && $c ne "\t" && $c ne "\n" && $c ne "\r"} { break }
        incr pos
    }
    dict set st pos $pos
}

proc ::schem::digital::yosys::Peek {stateVar} {
    upvar 1 $stateVar st
    return [string index [dict get $st text] [dict get $st pos]]
}

proc ::schem::digital::yosys::ParseValue {stateVar} {
    upvar 1 $stateVar st
    SkipWs st
    set c [Peek st]
    switch -- $c {
        "\{"   { return [ParseObject st] }
        "\["   { return [ParseArray st] }
        "\""   { return [ParseStr st] }
        t - f  { return [ParseLiteral st] }
        n      { return [ParseLiteral st] }
        default { return [ParseNumber st] }
    }
}

proc ::schem::digital::yosys::ParseObject {stateVar} {
    upvar 1 $stateVar st
    # consume the opening brace
    dict set st pos [expr {[dict get $st pos] + 1}]
    set obj [dict create]
    SkipWs st
    if {[Peek st] eq "\}"} {
        dict set st pos [expr {[dict get $st pos] + 1}]
        return $obj
    }
    while {1} {
        SkipWs st
        set key [ParseStr st]
        SkipWs st
        if {[Peek st] ne ":"} { return -code error "json: expected ':' after key '$key'" }
        dict set st pos [expr {[dict get $st pos] + 1}]
        set val [ParseValue st]
        dict set obj $key $val
        SkipWs st
        set c [Peek st]
        if {$c eq ","} {
            dict set st pos [expr {[dict get $st pos] + 1}]
            continue
        } elseif {$c eq "\}"} {
            dict set st pos [expr {[dict get $st pos] + 1}]
            break
        } else {
            return -code error "json: expected ',' or '\}' in object, got '$c'"
        }
    }
    return $obj
}

proc ::schem::digital::yosys::ParseArray {stateVar} {
    upvar 1 $stateVar st
    # consume the opening bracket
    dict set st pos [expr {[dict get $st pos] + 1}]
    set arr {}
    SkipWs st
    if {[Peek st] eq "\]"} {
        dict set st pos [expr {[dict get $st pos] + 1}]
        return $arr
    }
    while {1} {
        set val [ParseValue st]
        lappend arr $val
        SkipWs st
        set c [Peek st]
        if {$c eq ","} {
            dict set st pos [expr {[dict get $st pos] + 1}]
            continue
        } elseif {$c eq "\]"} {
            dict set st pos [expr {[dict get $st pos] + 1}]
            break
        } else {
            return -code error "json: expected ',' or '\]' in array, got '$c'"
        }
    }
    return $arr
}

proc ::schem::digital::yosys::ParseStr {stateVar} {
    upvar 1 $stateVar st
    set text [dict get $st text]
    set pos  [dict get $st pos]
    if {[string index $text $pos] ne "\""} {
        return -code error "json: expected string at byte $pos"
    }
    incr pos
    set out ""
    while {1} {
        set c [string index $text $pos]
        if {$c eq ""} { return -code error "json: unterminated string" }
        if {$c eq "\""} { incr pos ; break }
        if {$c eq "\\"} {
            incr pos
            set e [string index $text $pos]
            switch -- $e {
                "\"" { append out "\"" }
                "\\" { append out "\\" }
                "/"  { append out "/" }
                n    { append out "\n" }
                t    { append out "\t" }
                r    { append out "\r" }
                b    { append out "\b" }
                f    { append out "\f" }
                u {
                    set hex [string range $text [expr {$pos+1}] [expr {$pos+4}]]
                    append out [format %c [scan $hex %x]]
                    incr pos 4
                }
                default { append out $e }
            }
            incr pos
            continue
        }
        append out $c
        incr pos
    }
    dict set st pos $pos
    return $out
}

proc ::schem::digital::yosys::ParseNumber {stateVar} {
    upvar 1 $stateVar st
    set text [dict get $st text]
    set pos  [dict get $st pos]
    set start $pos
    set len [dict get $st len]
    while {$pos < $len} {
        set c [string index $text $pos]
        if {[string match {[-+0-9.eE]} $c]} { incr pos } else { break }
    }
    set tok [string range $text $start [expr {$pos-1}]]
    dict set st pos $pos
    if {$tok eq ""} { return -code error "json: expected number at byte $start" }
    return $tok
}

proc ::schem::digital::yosys::ParseLiteral {stateVar} {
    upvar 1 $stateVar st
    set text [dict get $st text]
    set pos  [dict get $st pos]
    foreach {word val} {true 1 false 0 null {}} {
        set n [string length $word]
        if {[string range $text $pos [expr {$pos+$n-1}]] eq $word} {
            dict set st pos [expr {$pos+$n}]
            return $val
        }
    }
    return -code error "json: unexpected literal at byte $pos"
}
