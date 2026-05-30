# Lamps, Nixie tubes & magnetic-core memory

Three parts that let a Schem board *show* and *hold* values the way period
hardware did -- a glowing indicator lamp, a Nixie numeral display, and a
ferrite magnetic-core bit. They are ordinary electrical components: the
engine solves them with the same Ohm/Kirchhoff machinery as everything
else, and their behaviour is read back after a solve with a few queries.

```sh
tclsh tests/test_io.tcl                  # the physics, asserted
bin/schem examples/display_panel.schem.tcl   # a panel that lights up
```

## Indicator lamp (`lamp`)

A filament across two terminals. Electrically it is just a resistance that
dissipates power; whether it is *visibly* lit is decided from the current
it draws.

| pin | meaning |
|-----|---------|
| `a` `b` | the filament (a resistance `r`) |

| param | default | meaning |
|-------|---------|---------|
| `r`   | 240 Ω   | filament resistance |
| `ion` | 0.01 A  | glow threshold: the current at which it lights |

```tcl
$s add lamp L -r 240 -ion 0.01
$s lit L          ;# 1 when |current| >= ion
$s brightness L   ;# current / ion  (0 = dark, 1 = just lit, >1 = brighter)
$s lampCurrent L  ;# filament current (A)
```

## Nixie tube (`nixie`)

A cold-cathode numeral display: one common anode and ten cathodes, one per
digit. The digit whose cathode is pulled low (while the anode is high)
glows. Each cathode is modelled as a glow-discharge resistance from the
anode.

| pin | meaning |
|-----|---------|
| `a`        | common anode |
| `k0`..`k9` | the ten digit cathodes |

| param | default | meaning |
|-------|---------|---------|
| `r`   | 47 kΩ   | per-cathode series resistance |
| `ion` | 0.1 mA  | strike threshold for a cathode to glow |

```tcl
$s add nixie N
$s wire N.k7 GND.t   ;# pull cathode 7 low
$s digit N           ;# -> 7   (the lit digit; -1 when dark)
```

The lit digit is the cathode drawing the most current above `ion`; with no
cathode pulled low the tube is dark and `digit` returns `-1`.

## Magnetic-core memory (`core`)

A single ferrite core: one bit stored as the remanent magnetisation of the
ring. It is written and read by **coincident current** -- the addressing
trick of every core plane -- and it is **non-volatile**: the bit survives a
power cycle, because the magnetisation is physical, not electrical.

| pin | meaning |
|-----|---------|
| `xp` `xn` | the X drive line threading the core (one turn) |
| `yp` `yn` | the Y drive line threading the core |
| `s`       | sense winding output (drives high on a destructive read) |

| param | default | meaning |
|-------|---------|---------|
| `iswitch` | 1.0 A  | full switching current |
| `rline`   | 1 mΩ   | resistance of a drive line through the core |
| `vhigh`   | 12 V   | sense-line drive level on a read |
| `rout`    | 1 mΩ   | sense-line output resistance |

**Write.** The net drive is the ampere-sum of the two lines,
`(Vx + Vy) / rline`. When it reaches `+iswitch` the core stores a 1; at
`-iswitch` it stores a 0. A *half-select* -- one line alone, driven at
~0.6·`iswitch` in use -- stays below threshold, so only the cell where two
selected lines cross actually switches. That is how one plane addresses a
whole grid of cores from a handful of lines.

**Read is destructive.** A read is just a reset drive (both lines toward
0). If the core held a 1, it flips down to 0 and the sense winding fires a
pulse on `s`; if it already held 0, nothing happens. So a read *clears* the
bit -- real core memory rewrites after every read. While the pulse is up,
`s` is driven to `vhigh` so a downstream sense amplifier (a relay latch)
can catch it.

```tcl
$s add core C -iswitch 1.0
# ... drive xp/xn and yp/yn with coincident current ...
$s coreBit C       ;# the stored remanent bit (0/1)
$s coreSensed C    ;# 1 if the last solve's read pulse flipped this core 1->0
$s degauss         ;# bulk-erase every core to 0 (a power cycle does NOT)
```

Because cores are non-volatile, `powerReset` (the power-on condition) leaves
them untouched; only `degauss` clears them.
