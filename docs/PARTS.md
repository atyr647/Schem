# Real parts & the ratings review

Schem designs with **real parts** -- actual devices with datasheet
specifications and rated limits -- not anonymous primitives.  You don't drop in
"a diode"; you drop in a 1N4007 (1000 V, 1 A, ~0.7 V drop) or a 1N5819 Schottky
(40 V, 1 A, ~0.3 V drop), and they behave -- and fail -- differently.

```sh
tclsh examples/power_supply.tcl      # three real failure modes
tclsh examples/ac_dc_supply.tcl      # a full-wave bridge with a design review
tclsh tests/test_parts.tcl           # the catalog + ratings, asserted
```

## What a part carries

Each entry in `lib/parts.tcl` binds a Schem primitive to two things:

- **a SPICE model** -- the engine parameters (IS, N, RS, BV, beta, VTO, ...)
  from the manufacturer's published model, the same ones LTspice / TI / Diodes
  Inc / Vishay ship.  So the operating point the engine solves matches the
  datasheet curves: a Schottky really does drop less than a silicon rectifier.
- **rated limits** -- the absolute-maximum ratings (Vrrm, I_F, P_d, V_DS,
  ripple current, V_z, I_sat, ...).  The design review checks the solved
  operating point against these.

```tcl
source lib/parts.tcl
::schem::parts::place $s D1 1N4007    ;# add a diode with the 1N4007 model
::schem::parts::byCategory rectifier  ;# {1N4007 1N5408 1N5819}
::schem::parts::get 1N4007            ;# the full spec
```

## The catalog (power-supply first)

| id | type | what it is |
|----|------|-----------|
| 1N4007 | diode | 1000 V 1 A general rectifier |
| 1N5408 | diode | 1000 V 3 A rectifier (mains front end) |
| 1N5819 | diode | 40 V 1 A Schottky (low drop, DC-DC) |
| 1N4148 | diode | 100 V 200 mA fast signal diode |
| 1N4733A / 1N4742A | diode | 5.1 V / 12 V 1 W Zener (shunt reference) |
| 2N3904 / 2N2222A | bjt | 40 V NPN small-signal / switch |
| BD139 | bjt | 80 V 1.5 A NPN medium-power pass |
| IRFZ44N | mosfet | 55 V 49 A N-channel switch |
| IRLZ44N | mosfet | 55 V 47 A logic-level N-channel |
| CAP_100u_25V / 470u_35V / 1000u_16V | capacitor | electrolytic smoothing |
| CAP_100n_50V | capacitor | X7R ceramic decoupling |
| IND_100u_3A | inductor | shielded power inductor |
| R_PWR_1W / 5W | resistor | power resistors |

## The design review

`lib/ratings.tcl` is the bench check a tech does by hand, automated.  After a
solve it measures each real part's stress (reverse voltage, forward current,
power, cap voltage, V_ce, V_ds, ...) against its ratings and returns a verdict:

- **over** -- above the rating; the part will fail.
- **marginal** -- above 80 % of the rating (the derating headroom a careful
  designer keeps).
- **ok** -- within ratings with margin.

```tcl
source lib/ratings.tcl
puts [::schem::ratings::report $s]       ;# grouped human review
::schem::ratings::check $s               ;# the raw findings (for the GUI)
```

The point: the same circuit passes or fails depending on the **part**, not the
math.  A 1N4148 in a quarter-amp rectifier solves identically to a 1N4007 --
and is flagged 117 % over its 200 mA forward-current rating.  A 16 V cap on a
24 V rail reads 145 % over.  That is the failure a simulator that ignores part
ratings happily passes; here the part turns red.

## Adding a part

```tcl
::schem::parts::def MY_PART {
    type diode  mfr "..."  category rectifier  pkg DO-41
    desc "..."
    model  {is 1e-8 n 1.8 rs 0.02 bv 600}     ;# from the SPICE .model
    limits {
        Vrrm {max 600 unit V sense reverse-voltage}
        If   {max 2.0 unit A sense forward-current}
        Pd   {max 5.0 unit W sense power}
    }
}
```

The `sense` of each limit tells the review how to measure the stress from the
solved board (see `lib/ratings.tcl` for the full list).
