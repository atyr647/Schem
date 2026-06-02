# The Enigma & the Turing Bombe

This is the project's headline machine: a historically faithful Wehrmacht
Enigma and the electromechanical **bombe** Turing designed to break it —
the bombe expressed as an actual Schem circuit whose own continuity finds
the key, with the heavy search compiled to Zig.

```sh
tclsh examples/bombe_break.tcl     # a full break, end to end
tclsh tests/test_bombe.tcl         # the whole chain, asserted
SCHEM_ZIG=/path/to/zig tclsh tests/test_bombe.tcl   # incl. the compiled scan
```

## Why the bombe is a *circuit*

A stop is an **electrical closure**. This is the insight that makes the
bombe a Schem program rather than a program *about* a bombe.

- Each letter the crib touches gets a **26-wire cable** — one wire per
  possible steckered value.
- A **scrambler** is an Enigma with the plugboard removed, frozen at one
  rotor position. The reflector makes it an *involution* (`S(S(x)) = x`),
  so between two cables it is just 26 bidirectional wires: cable A wire `w`
  joins cable B wire `P(w)`.
- **Welchman's diagonal board** wires in the plugboard's reciprocity (if A
  steckers to B then B steckers to A): cable A's wire labelled `b` joins
  cable B's wire labelled `a`.
- Energise one wire of the **test register** and current floods every wire
  the menu forces to share its potential. A **wrong** rotor guess closes
  the menu's loops back on themselves and lights the whole register; the
  **right** guess collapses it to a single live wire. *Not all 26 the same*
  is the stop.

The Schem engine already computes exactly this closure — it merges
connected terminals into shared nodes. So the bombe board *is* solved by
the same Ohm/Kirchhoff machinery as a lamp circuit, and the stop is read
off an **indicator lamp** the engine lights from continuity.

## The pieces

| file | what it is |
|------|-----------|
| `lib/enigma.tcl`      | the bench **oracle**: a historically exact Enigma I (rotors I–V, reflectors B/C, ring settings, plugboard, **double-stepping**). Makes the crib and verifies the recovered key. Not a circuit — the calibrated meter on the bench. |
| `lib/bombe.tcl`       | menu construction, the closure (union-find), the stop test, and the 26³ scan. |
| `lib/bombe_schem.tcl` | the bombe as a **Schem schematic**: cables, scramblers, diagonal board, pull-downs, the seed battery, and the stop lamps. ~500 components per candidate. |
| `lib/bombe_zig.tcl`   | emits the 26³ scan as a self-contained **Zig** program — the heavy sweep, compiled. |
| `examples/bombe_break.tcl` | the full story: intercept → crib → bombe lamps → decrypt. |
| `tests/test_bombe.tcl`     | asserts every link, including Zig agreement. |

## The Enigma oracle is the real machine

Verified against the canonical vectors:

- `AAAAA → BDZGO` (UKW-B, wheels I-II-III, rings AAA, ground AAA, no plugs)
- 26 × `A` → `BDZGOWCXLTKSBTMCDLPBMUQOFX`
- the **double-step** window sequence `ADV AEW BFX BFY BFZ` (the middle
  rotor steps twice in a row when it sits on its own notch)
- reciprocity (the same setting deciphers), and no letter ever enciphers to
  itself (the property the crib exploits).

## A worked break

`examples/bombe_break.tcl` encrypts a weather report under a secret ground
`QER` and hands the bombe only the ciphertext and the crib
`WETTERVORHERSAGE`:

```
ciphertext : SZDGNYKCFYXHECKYHBLQPVZFUCPIJBVJTLCHTS
menu cables : A C D E F G H K N O R S T V W X Y Z
test register: E
STOP QER  --  one lamp lit: stecker E-E
QER -> WETTERVORHERSAGEBERLINDIENSTAGSECHSUHR   <== GERMAN!
```

The full 26³ scan returns a short list of stops (`DYA QER RFR` for this
crib). Two are false stops — historically authentic, filtered by trying
each on the machine; only the key yields German. A longer crib (more
loops) removes them.

## The compiled scan

The interpreted 26³ sweep is ~79 s; the emitted Zig, built
`-OReleaseFast`, runs the identical search — same stops, stop for stop — in
**~0.25 s** (a ~300× speedup). The emitter bakes the rotor windings, the
ring setting, the menu and the reflector into the program, so the `.zig`
is self-contained:

```sh
# inside a builder, or from the API:
set src [::bombe::emitZig $edges {I II III} AAA B E]
# write to bombe.zig, then:
zig run -OReleaseFast bombe.zig
```

The Zig scanner mirrors `lib/bombe.tcl` line for line — the same stepping
(with the double-step), the same scrambler, the same union-find over the
menu and diagonal board — which is what the test pins down: the compiled
and interpreted scans must agree.

## Limits & honesty

- The lamp panel reads the *single-live* stop directly; the dual
  *single-dead* stop (a wire isolated rather than energised) is reported by
  the union-find / Zig scan but divides its seed current below the glow
  threshold on the board, so the panel naturally shows the strongest stops.
  The true key is always among the scan's stops.
- False stops are a real property of the bombe, not a bug. Hut 6 removed
  them with longer cribs and the checking machine; here, trying each stop
  on the oracle does the same job.
