# format.tcl --
#
# The .schem project file: the serialized Schematic object model and the
# *source of truth* of a Schem program.
#
# Per the language architecture, the source is the schematic -- not text,
# not JSON, not the rendered image, not the derived netlist.  So the on-disk
# form is a compact, opaque BINARY container that is only meant to be opened
# through Schem tooling.  It stores the object-model primitives directly:
#
#     components · terminals · couplings (wires) · junctions · buses ·
#     harnesses · ports · layers · positions · ratings · state · hierarchy
#
# A reader could of course decompress the bytes, but those bytes are not a
# programming language -- they are a saved schematic.  Text is never the
# source; this file is just persistence.
#
# Container layout:
#     offset 0  : magic            "SCHM"            (4 bytes)
#            4  : container ver     u8               (1)
#            5  : flags             u8               (bit0 = zlib payload)
#            6  : payload length    u32 big-endian   (uncompressed)
#           10  : payload           zlib-compressed structured record stream
#
# Payload record stream (all integers big-endian; strings = u32 length +
# UTF-8 bytes; maps = u32 count + key/value string pairs):
#     u8 model_ver_major, u8 model_ver_minor
#     str  schematic name
#     u32  component count   { str name, str type, map params, str pos, str layer }
#     u32  coupling count    { str a, str b, str awg, str harness }
#     u32  harness count     { str name, str layer, u32 members { str a, str b } }
#     u32  port count        { str port, str term }

namespace eval ::schem::fmt {
    variable MAGIC "SCHM"
    variable CONTAINER_VER 1
    variable MODEL_VER {1 0}
}

# ---- low-level byte buffer writers -------------------------------------

proc ::schem::fmt::PutStr {bufVar s} {
    upvar 1 $bufVar buf
    set b [encoding convertto utf-8 $s]
    append buf [binary format I [string length $b]] $b
}
proc ::schem::fmt::PutU8  {bufVar n} { upvar 1 $bufVar buf ; append buf [binary format c [expr {$n & 0xff}]] }
proc ::schem::fmt::PutU32 {bufVar n} { upvar 1 $bufVar buf ; append buf [binary format I $n] }
proc ::schem::fmt::PutMap {bufVar m} {
    upvar 1 $bufVar buf
    PutU32 buf [expr {[dict size $m]}]
    dict for {k v} $m { PutStr buf $k ; PutStr buf $v }
}

# ---- cursor-based readers ----------------------------------------------

proc ::schem::fmt::GetStr {dataVar idxVar} {
    upvar 1 $dataVar data $idxVar idx
    binary scan $data @${idx}I len ; incr idx 4
    set b [string range $data $idx [expr {$idx + $len - 1}]] ; incr idx $len
    return [encoding convertfrom utf-8 $b]
}
proc ::schem::fmt::GetU8  {dataVar idxVar} {
    upvar 1 $dataVar data $idxVar idx
    binary scan $data @${idx}c n ; incr idx 1 ; return [expr {$n & 0xff}]
}
proc ::schem::fmt::GetU32 {dataVar idxVar} {
    upvar 1 $dataVar data $idxVar idx
    binary scan $data @${idx}I n ; incr idx 4 ; return $n
}
proc ::schem::fmt::GetMap {dataVar idxVar} {
    upvar 1 $dataVar data $idxVar idx
    set n [GetU32 data idx] ; set m [dict create]
    for {set i 0} {$i < $n} {incr i} {
        set k [GetStr data idx] ; set v [GetStr data idx]
        dict set m $k $v
    }
    return $m
}

# ---- public: save / load -----------------------------------------------

# schem::save -- serialize a schematic to a .schem binary project file.
proc ::schem::save {schem path} {
    variable fmt::MAGIC ; variable fmt::CONTAINER_VER ; variable fmt::MODEL_VER

    set buf ""
    ::schem::fmt::PutU8  buf [lindex $MODEL_VER 0]
    ::schem::fmt::PutU8  buf [lindex $MODEL_VER 1]
    ::schem::fmt::PutStr buf [$schem name]

    # Components.
    set names [$schem components]
    ::schem::fmt::PutU32 buf [llength $names]
    foreach name $names {
        set c [$schem comp $name]
        set attrs [dict get $c attrs]
        ::schem::fmt::PutStr buf $name
        ::schem::fmt::PutStr buf [dict get $c type]
        ::schem::fmt::PutMap buf [dict get $c params]
        ::schem::fmt::PutStr buf [dict get $attrs pos]
        ::schem::fmt::PutStr buf [dict get $attrs layer]
    }

    # Couplings (wires).
    set conns [$schem conns]
    ::schem::fmt::PutU32 buf [llength $conns]
    foreach co $conns {
        lassign $co a b awg hn
        ::schem::fmt::PutStr buf $a
        ::schem::fmt::PutStr buf $b
        ::schem::fmt::PutStr buf $awg
        ::schem::fmt::PutStr buf $hn
    }

    # Harnesses.
    set har [$schem harnesses]
    ::schem::fmt::PutU32 buf [dict size $har]
    dict for {hname h} $har {
        ::schem::fmt::PutStr buf $hname
        ::schem::fmt::PutStr buf [dict get $h layer]
        set mem [dict get $h members]
        ::schem::fmt::PutU32 buf [llength $mem]
        foreach pr $mem { lassign $pr a b ; ::schem::fmt::PutStr buf $a ; ::schem::fmt::PutStr buf $b }
    }

    # Ports.
    set ports [$schem ports]
    ::schem::fmt::PutU32 buf [dict size $ports]
    dict for {pn term} $ports { ::schem::fmt::PutStr buf $pn ; ::schem::fmt::PutStr buf $term }

    # Compress and frame.
    set payload [zlib compress $buf]
    set out [binary format a4cc $MAGIC $CONTAINER_VER 1]
    append out [binary format I [string length $buf]]
    append out $payload

    set fh [open $path wb]
    fconfigure $fh -translation binary
    puts -nonewline $fh $out
    close $fh
    return [string length $out]
}

# schem::load -- read a .schem binary project file into a fresh schematic.
proc ::schem::load {path} {
    variable fmt::MAGIC
    set fh [open $path rb]
    fconfigure $fh -translation binary
    set raw [read $fh]
    close $fh

    binary scan $raw a4cc magic cver flags
    if {$magic ne $MAGIC} {
        return -code error -errorcode {SCHEM BADFILE} \
            "not a Schem project file (bad magic)"
    }
    binary scan $raw @6I ulen
    set payload [string range $raw 10 end]
    set data [expr {($flags & 1) ? [zlib decompress $payload] : $payload}]
    if {[string length $data] != $ulen} {
        return -code error -errorcode {SCHEM BADFILE} "corrupt payload"
    }

    set idx 0
    ::schem::fmt::GetU8 data idx ; ::schem::fmt::GetU8 data idx   ;# model version
    set name [::schem::fmt::GetStr data idx]
    set s [::schem::new $name]

    set nc [::schem::fmt::GetU32 data idx]
    for {set i 0} {$i < $nc} {incr i} {
        set cn   [::schem::fmt::GetStr data idx]
        set ct   [::schem::fmt::GetStr data idx]
        set par  [::schem::fmt::GetMap data idx]
        set pos  [::schem::fmt::GetStr data idx]
        set lyr  [::schem::fmt::GetStr data idx]
        $s add $ct $cn
        dict for {k v} $par { $s set $cn $k $v }
        if {$pos ne {}} { lassign $pos x y ; $s place $cn $x $y }
        if {$lyr ne {} && $lyr ne "default"} { $s layer $cn $lyr }
    }

    set nco [::schem::fmt::GetU32 data idx]
    for {set i 0} {$i < $nco} {incr i} {
        set a   [::schem::fmt::GetStr data idx]
        set b   [::schem::fmt::GetStr data idx]
        set awg [::schem::fmt::GetStr data idx]
        set hn  [::schem::fmt::GetStr data idx]
        # Harness couplings are re-created by the harness records below.
        if {$hn ne {}} continue
        if {$awg ne {}} { $s wire $a $b -awg $awg } else { $s wire $a $b }
    }

    set nh [::schem::fmt::GetU32 data idx]
    for {set i 0} {$i < $nh} {incr i} {
        set hname [::schem::fmt::GetStr data idx]
        set lyr   [::schem::fmt::GetStr data idx]
        set nm    [::schem::fmt::GetU32 data idx]
        set pairs {}
        for {set j 0} {$j < $nm} {incr j} {
            lappend pairs [::schem::fmt::GetStr data idx] [::schem::fmt::GetStr data idx]
        }
        $s harness $hname $pairs -layer $lyr
    }

    set np [::schem::fmt::GetU32 data idx]
    for {set i 0} {$i < $np} {incr i} {
        set pn   [::schem::fmt::GetStr data idx]
        set term [::schem::fmt::GetStr data idx]
        $s expose $pn $term
    }
    return $s
}
