# lib/parts.tcl --
#
# A library of REAL parts -- actual devices with datasheet specifications and
# rated limits, the way an engineer actually designs.  You don't drop in "a
# diode"; you drop in a 1N4007 (1000 V, 1 A, ~0.7 V drop) or a 1N5819 Schottky
# (40 V, 1 A, ~0.3 V drop), and they behave -- and fail -- differently.
#
# Each part binds two things to a Schem primitive type:
#   * model  -- the engine parameters that make it simulate like the real part.
#               These come straight from the manufacturer's SPICE .model (the
#               same IS/N/RS/BV/etc. LTspice and TI ship), so the operating
#               point the engine solves matches the datasheet curves.
#   * limits -- the absolute-maximum ratings from the datasheet (PIV, I_F, V_DS,
#               P_d, ripple current, voltage derating, ...).  The simulator
#               checks the solved operating point against these and warns when a
#               design exceeds a part's rating -- the design-review an engineer
#               does by hand, automated.
#
# Sourced from manufacturer datasheets and the SPICE models LTspice / TI /
# Diodes Inc / Vishay publish.  Values are typical/maximum at 25 C unless
# noted.  This is a starting catalog aimed at POWER-SUPPLY design first
# (rectifiers, smoothing, regulators, switchers) and grows outward.

namespace eval ::schem::parts {
    # part db: id -> dict {
    #   type     <schem primitive>      mfr <maker>    desc <one line>
    #   category <rectifier|smoothing|regulator|...>
    #   model    {param value ...}      (engine params, from the SPICE model)
    #   limits   {name {max <v> unit <u> sense <how to measure>} ...}
    #   pkg      <through-hole/SMD package>
    # }
    variable DB [dict create]
}

# def -- register a part.
proc ::schem::parts::def {id spec} {
    variable DB
    dict set DB $id $spec
}

# get / ids / byCategory / byType -- catalog queries.
proc ::schem::parts::get {id} {
    variable DB
    if {![dict exists $DB $id]} { return -code error "no such part \"$id\"" }
    return [dict get $DB $id]
}
proc ::schem::parts::ids {} { variable DB ; return [lsort [dict keys $DB]] }
proc ::schem::parts::byCategory {cat} {
    variable DB ; set out {}
    dict for {id s} $DB { if {[dict get $s category] eq $cat} { lappend out $id } }
    return [lsort $out]
}
proc ::schem::parts::byType {type} {
    variable DB ; set out {}
    dict for {id s} $DB { if {[dict get $s type] eq $type} { lappend out $id } }
    return [lsort $out]
}
proc ::schem::parts::categories {} {
    variable DB ; set c {}
    dict for {id s} $DB { dict set c [dict get $s category] 1 }
    return [lsort [dict keys $c]]
}

# place -- add a real part to a schematic: create the primitive, apply the
# part's engine model params, and tag the instance with its part id so the
# ratings checker and the BOM know what it really is.
proc ::schem::parts::place {s name id args} {
    set spec [::schem::parts::get $id]
    set type [dict get $spec type]
    $s add $type $name {*}$args
    dict for {k v} [dict get $spec model] { catch {$s set $name $k $v} }
    # remember the part id on the instance (stored as a layer-ish attr via a
    # parallel registry, since the engine params are electrical only)
    ::schem::parts::tag $s $name $id
    return $name
}

# A side registry mapping (schematic, instance) -> part id, so we can recover
# "this R is a real PWR221 shunt" after placement without polluting the model.
namespace eval ::schem::parts { variable TAG [dict create] }
proc ::schem::parts::tag {s name id} {
    variable TAG ; dict set TAG [list $s $name] $id
}
proc ::schem::parts::idOf {s name} {
    variable TAG
    set k [list $s $name]
    if {[dict exists $TAG $k]} { return [dict get $TAG $k] }
    # Not tagged in this session (e.g. the board was loaded from a .schem): try
    # to recover the part by matching the instance's model params to a catalog
    # entry of the same type.  A part whose engine params exactly match a known
    # device IS that device -- so identity survives a save/load round-trip.
    return [::schem::parts::identify $s $name]
}

# identify -- which catalog part (if any) an instance's current params match.
proc ::schem::parts::identify {s name} {
    variable DB
    if {[catch {$s typeof $name} type]} { return "" }
    if {[catch {$s get $name} params]} { return "" }
    dict for {id spec} $DB {
        if {[dict get $spec type] ne $type} continue
        set model [dict get $spec model]
        if {[dict size $model] == 0} continue   ;# nothing distinctive to match
        set match 1
        dict for {k v} $model {
            if {![dict exists $params $k]} { set match 0 ; break }
            set pv [dict get $params $k]
            if {[string is double -strict $v] && [string is double -strict $pv]} {
                if {abs($pv - $v) > abs($v)*1e-6 + 1e-12} { set match 0 ; break }
            } elseif {$pv ne $v} { set match 0 ; break }
        }
        if {$match} { return $id }
    }
    return ""
}

# ===========================================================================
#  The catalog.  Power-supply parts first.
# ===========================================================================

# ---- Rectifier diodes -----------------------------------------------------
::schem::parts::def 1N4007 {
    type diode  mfr "Diodes Inc"  category rectifier  pkg DO-41
    desc "1000 V 1 A general-purpose silicon rectifier"
    model {is 7.02e-9 n 1.8 rs 0.033 bv 1000}
    limits {
        Vrrm  {max 1000 unit V sense reverse-voltage  note "peak repetitive reverse voltage"}
        If    {max 1.0  unit A sense forward-current   note "average rectified forward current"}
        Ifsm  {max 30   unit A sense surge-current     note "8.3 ms surge"}
        Pd    {max 3.0  unit W sense power}
    }
}
::schem::parts::def 1N4148 {
    type diode  mfr "Vishay"  category signal  pkg DO-35
    desc "100 V 200 mA fast small-signal switching diode"
    model {is 2.52e-9 n 1.752 rs 0.568 bv 100}
    limits {
        Vrrm {max 100  unit V sense reverse-voltage}
        If   {max 0.2  unit A sense forward-current}
        Pd   {max 0.5  unit W sense power}
    }
}
::schem::parts::def 1N5819 {
    type diode  mfr "ON Semi"  category rectifier  pkg DO-41
    desc "40 V 1 A Schottky -- low 0.3 V drop, fast, for DC-DC"
    model {is 3.2e-5 n 1.05 rs 0.07 bv 40}
    limits {
        Vrrm {max 40   unit V sense reverse-voltage}
        If   {max 1.0  unit A sense forward-current}
        Ifsm {max 25   unit A sense surge-current}
        Pd   {max 0.875 unit W sense power}
    }
}
::schem::parts::def 1N5408 {
    type diode  mfr "Diodes Inc"  category rectifier  pkg DO-201AD
    desc "1000 V 3 A rectifier -- mains AC-DC front end"
    model {is 1.0e-8 n 1.9 rs 0.02 bv 1000}
    limits {
        Vrrm {max 1000 unit V sense reverse-voltage}
        If   {max 3.0  unit A sense forward-current}
        Ifsm {max 200  unit A sense surge-current}
        Pd   {max 6.5  unit W sense power}
    }
}

# ---- Zener (reference / shunt regulation) ---------------------------------
::schem::parts::def 1N4733A {
    type diode  mfr "ON Semi"  category zener  pkg DO-41
    desc "5.1 V 1 W Zener -- shunt reference / clamp"
    model {is 1e-9 n 1.2 rs 1.0 bv 5.1}
    limits {
        Vz  {max 5.1  unit V sense reverse-voltage note "nominal zener voltage"}
        Pd  {max 1.0  unit W sense power}
        Iz  {max 0.178 unit A sense reverse-current note "max zener current at 1 W"}
    }
}
::schem::parts::def 1N4742A {
    type diode  mfr "ON Semi"  category zener  pkg DO-41
    desc "12 V 1 W Zener -- shunt reference / clamp"
    model {is 1e-9 n 1.2 rs 2.0 bv 12}
    limits {
        Vz {max 12 unit V sense reverse-voltage}
        Pd {max 1.0 unit W sense power}
        Iz {max 0.076 unit A sense reverse-current}
    }
}

# ---- Bipolar transistors (pass / switch) ----------------------------------
::schem::parts::def 2N3904 {
    type bjt  mfr "ON Semi"  category transistor  pkg TO-92
    desc "40 V 200 mA NPN small-signal switch/amplifier"
    model {is 6.73e-15 beta 300 n 1.0 vaf 74 type n}
    limits {
        Vceo {max 40   unit V sense ce-voltage}
        Ic   {max 0.2  unit A sense collector-current}
        Pd   {max 0.625 unit W sense power}
    }
}
::schem::parts::def 2N2222A {
    type bjt  mfr "ON Semi"  category transistor  pkg TO-92
    desc "40 V 800 mA NPN -- general switch / small pass"
    model {is 1.0e-14 beta 200 n 1.0 vaf 100 type n}
    limits {
        Vceo {max 40   unit V sense ce-voltage}
        Ic   {max 0.8  unit A sense collector-current}
        Pd   {max 0.625 unit W sense power}
    }
}
::schem::parts::def BD139 {
    type bjt  mfr "ST"  category transistor  pkg TO-126
    desc "80 V 1.5 A NPN medium-power -- linear pass element"
    model {is 1.0e-13 beta 100 n 1.0 vaf 100 type n}
    limits {
        Vceo {max 80   unit V sense ce-voltage}
        Ic   {max 1.5  unit A sense collector-current}
        Pd   {max 12.5 unit W sense power note "with heatsink; ~1.25 W free-air"}
    }
}

# ---- Power MOSFETs (switching converters) ---------------------------------
::schem::parts::def IRFZ44N {
    type mosfet  mfr "Infineon"  category mosfet  pkg TO-220
    desc "55 V 49 A N-channel -- buck/boost low-side switch"
    model {vto 4.0 kp 24.0 lambda 0.0 type n}
    limits {
        Vds {max 55  unit V sense ds-voltage}
        Id  {max 49  unit A sense drain-current}
        Pd  {max 94  unit W sense power note "with heatsink"}
    }
}
::schem::parts::def IRLZ44N {
    type mosfet  mfr "Infineon"  category mosfet  pkg TO-220
    desc "55 V 47 A logic-level N-channel -- MCU-driven switch"
    model {vto 2.0 kp 22.0 lambda 0.0 type n}
    limits {
        Vds {max 55  unit V sense ds-voltage}
        Id  {max 47  unit A sense drain-current}
        Pd  {max 83  unit W sense power}
    }
}

# ---- Electrolytic capacitors (smoothing / bulk) ---------------------------
::schem::parts::def CAP_100u_25V {
    type capacitor  mfr "generic"  category smoothing  pkg "radial 6.3mm"
    desc "100 uF 25 V aluminium electrolytic -- output smoothing"
    model {c 100e-6 esr 0.5}
    limits {
        Vdc    {max 25    unit V sense cap-voltage note "rated DC; derate to 80%"}
        Iripple {max 0.2  unit A sense cap-current note "max RMS ripple at 100 Hz"}
    }
}
::schem::parts::def CAP_470u_35V {
    type capacitor  mfr "generic"  category smoothing  pkg "radial 10mm"
    desc "470 uF 35 V electrolytic -- bulk reservoir after a bridge"
    model {c 470e-6 esr 0.1}
    limits {
        Vdc     {max 35   unit V sense cap-voltage}
        Iripple {max 0.8  unit A sense cap-current}
    }
}
::schem::parts::def CAP_1000u_16V {
    type capacitor  mfr "generic"  category smoothing  pkg "radial 10mm"
    desc "1000 uF 16 V electrolytic -- 5 V rail reservoir"
    model {c 1000e-6 esr 0.05}
    limits {
        Vdc     {max 16   unit V sense cap-voltage}
        Iripple {max 1.2  unit A sense cap-current}
    }
}

# ---- Ceramic capacitors (decoupling / HF) ---------------------------------
::schem::parts::def CAP_100n_50V {
    type capacitor  mfr "generic"  category decoupling  pkg "0805 X7R"
    desc "100 nF 50 V X7R ceramic -- decoupling / bypass"
    model {c 100e-9 esr 0.01}
    limits {
        Vdc {max 50 unit V sense cap-voltage note "X7R; derate, value drops with bias"}
    }
}

# ---- Inductors (switching energy storage) ---------------------------------
::schem::parts::def IND_100u_3A {
    type inductor  mfr "generic"  category power-inductor  pkg "shielded 12mm"
    desc "100 uH 3 A shielded power inductor -- buck/boost"
    model {l 100e-6 r 0.05}
    limits {
        Isat {max 3.0  unit A sense inductor-current note "saturation current"}
    }
}

# ---- Resistors (sense / load) ---------------------------------------------
::schem::parts::def R_PWR_1W {
    type resistor  mfr "generic"  category power-resistor  pkg "axial 1W"
    desc "1 W metal-film -- bleeder / current-sense (set -r)"
    model {}
    limits {
        Pd {max 1.0 unit W sense power note "derate above 70 C"}
    }
}
::schem::parts::def R_PWR_5W {
    type resistor  mfr "generic"  category power-resistor  pkg "wirewound 5W"
    desc "5 W wirewound -- dummy load / inrush limiter (set -r)"
    model {}
    limits {
        Pd {max 5.0 unit W sense power}
    }
}

package provide schem_parts 1.0
