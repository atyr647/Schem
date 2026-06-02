# Project correctness assessment

A snapshot of where Schem stands on correctness across every layer, with the
evidence behind each claim.  Re-run the suite to reproduce.

## Summary

| Layer | Status | Evidence |
|-------|--------|----------|
| Linear DC (Ohm, KVL, KCL) | ✅ correct | textbook cross-checks below |
| Nonlinear DC (diode, BJT, MOSFET) | ✅ correct | Newton solve; forward/reverse, switching verified |
| Transient (RC/RL, AC source) | ✅ correct | RC reaches 63.2 % at 1 τ |
| AC / frequency domain | ✅ correct | RC low-pass −3 dB at its corner, −20 dB/dec |
| Compile-to-Zig backend | ✅ matches engine | 53/53 cir tests with a real `zig` |
| Schematic symbols | ✅ standards-based | imported from KiCad (IEEE-315/IEC-60617) |
| Real parts + ratings | ✅ datasheet-bound | SPICE models + abs-max limits |
| PCB export (KiCad netlist + BOM) | ✅ parses as KiCad | round-tripped |
| GUI | ✅ exercised headlessly | 43 cases under Xvfb |

**Test totals: ~430 cases across 19 suites, 0 failures** (53 backend cases
require a `zig` compiler; they pass when `SCHEM_ZIG` is set, otherwise skip).

## Physics cross-checks (textbook values)

Verified directly against hand calculations:

```
Ohm: 9V/1k = 9mA                          PASS
Divider 1k/2k from 9V tap = 6V            PASS
Parallel 1k||1k total = 18mA              PASS
Diode forward drop in 0.6-0.8V band       PASS (0.693 V)
Series R current equal (KCL)              PASS
RC: Vc(1 tau) = 63.2% of 5V               PASS (3.16 V)
AC: -3dB at the RC corner (995 Hz)        PASS (-3.01 dB)
BJT NPN common-emitter turns ON           PASS (Vc 0.71 V, Ic 8.3 mA)
```

The solver is Modified Nodal Analysis with an inner Newton loop for nonlinear
junctions and an outer fixed-point loop for stateful devices (relays, fuses,
breakers) — the same structure SPICE uses.

## What ET1 (Navy ET) flagged, and the fixes

1. **"The diode is wrong, unless that is an SCR."** — The hand-drawn diode
   glyph was ambiguous.  Fixed by importing the real KiCad diode symbol
   (`src/ksym.tcl`, `lib/symbols/standard.kicad_lib`); it is unambiguously a
   2-terminal diode with the cathode bar, and its A/K pins map to the engine so
   forward bias conducts and reverse blocks (`tests/test_ksym.tcl`).
2. **"The battery isn't placed right."** — Replaced with KiCad's
   `Battery` symbol (correct long/short plates, + and − terminals).
3. **"The circuit as a whole isn't set correctly."** — `power_supply.tcl` had
   a DC source through a diode mislabelled as a *rectifier*.  Rectification is
   AC→DC; a series diode on a DC rail is reverse-polarity **protection**.
   Re-labelled accurately; the real full-wave bridge rectifier lives in
   `examples/ac_dc_supply.tcl` with an AC source.

## Known limitations (honest)

- **Component models are first-order.**  The diode is Shockley + series R +
  breakdown; the BJT is Ebers-Moll with Early effect; the MOSFET is
  Shichman-Hodges.  They reproduce datasheet operating points and the right
  qualitative behaviour, but not temperature, capacitance/charge storage at
  RF, or full SOA curves.  Good for learning and DC/low-frequency design; not a
  replacement for a foundry-grade simulator.
- **Ratings are static abs-max** (PIV, I_F, P_d, V_DS, ripple, …).  Thermal
  derating curves and junction-temperature rise are not yet modelled.
- **The GUI cannot run headless** for a human; it is driven and screenshotted
  under Xvfb for tests.  Tk is required to use it.
- **One snapshot of the KiCad library** is vendored (the symbols we map); it is
  not the full catalogue.

## How to reproduce

```sh
make test           # everything that runs without extra tooling
SCHEM_ZIG=/path/to/zig make test   # also the compiled-backend cross-checks
```
