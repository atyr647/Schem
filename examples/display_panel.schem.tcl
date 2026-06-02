# display_panel.schem.tcl --
#
# A little front panel built only from Schem parts: an indicator LAMP, a
# NIXIE tube showing a digit, and a magnetic CORE storing a bit.  No code,
# no loops -- just parts and wires.  Run it and read the Indicators section:
#
#   bin/schem examples/display_panel.schem.tcl
#
# Everything is the same electricity the engine solves for every other
# board: a lamp is a filament that glows past a current threshold, a Nixie
# glows on whichever cathode is pulled low, and a core flips its remanent
# bit when two drive lines coincide past its switching current.

$s add ground  GND

# --- an indicator lamp: 12 V across a 240 ohm filament -> 50 mA -> lit ---
$s add battery PWR -emf 12
$s add lamp    L1  -r 240 -ion 0.01
$s wire PWR.pos L1.a ; $s wire L1.b GND.t ; $s wire PWR.neg GND.t

# --- a Nixie tube reading "7": pull cathode k7 low under a 170 V anode ---
$s add battery HV -emf 170
$s add nixie   N1
$s wire HV.pos N1.a ; $s wire HV.neg GND.t
$s wire N1.k7  GND.t

# --- a magnetic core: two coincident half-select lines store a 1 ---------
# Each line carries ~0.6 A; together they pass the 1.0 A switching current,
# so the core latches a 1 (and keeps it with the power off).  The sense
# winding feeds its own lamp -- dark here, because writing a 1 is silent;
# only a destructive *read* would pulse it.
$s add core    C0 -iswitch 1.0 -rline 1e-3
$s add battery BX -emf 6 ; $s add resistor RX -r 10
$s add battery BY -emf 6 ; $s add resistor RY -r 10
$s add lamp    SENSE -r 240 -ion 0.01
$s wire BX.pos RX.a ; $s wire RX.b C0.xp ; $s wire C0.xn GND.t ; $s wire BX.neg GND.t
$s wire BY.pos RY.a ; $s wire RY.b C0.yp ; $s wire C0.yn GND.t ; $s wire BY.neg GND.t
$s wire C0.s   SENSE.a ; $s wire SENSE.b GND.t

$s solve
