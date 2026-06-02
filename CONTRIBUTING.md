# Contributing to Schem

Thanks for your interest!  Schem is a visual electrical programming language —
**the schematic is the program** — implemented in pure Tcl/Tk.  This guide
covers how the code is organised, the conventions to follow, and how to get a
change merged.

## Ground rules

- **Every change keeps the suite green.**  `make test` must pass before you
  open a PR.  New behaviour needs a new test.
- **The physics must be right.**  This is an electrical simulator; a change to
  the engine must be cross-checked against a value you can compute by hand
  (Ohm's law, a time constant, a corner frequency).  See `docs/ASSESSMENT.md`
  for the style.
- **The schematic stays the source of truth.**  The netlist, IR, SVG, PCB and
  Zig outputs are *derived artifacts*.  Never make a derived form
  authoritative.

## Project layout

```
bin/        schem (CLI launcher), schem-gui (Tk launcher)
src/        the engine + tooling
  schem.tcl       entry point; sources everything in order
  engine.tcl      object model + component metadata (the META table)
  solver.tcl      linear algebra (Gaussian elimination)
  simulate.tcl    nodal analysis: MNA + Newton + fixed-point
  ac.tcl          AC / frequency-domain analysis
  transient.tcl   time-domain analysis
  hierarchy.tcl   Component -> Circuit -> Panel -> Grid
  bus.tcl         bus / bank / repeat / connect drafting primitives
  netlist.tcl     derived netlist IR
  compile.tcl     the Circuit IR (backend-agnostic compile target)
  backend.tcl     backends over the IR (zig, dcref, ...)
  format.tcl      binary .schem save / load
  render.tcl      ASCII schematic viewer
  svg.tcl         SVG renderer + semantic zoom
  zoom.tcl        level-of-detail collapse
  pcb.tcl         PCB export (KiCad netlist + BOM)
  symbols.tcl     hand-drawn fallback symbols
  ksym.tcl        KiCad symbol importer (the primary symbols)
  editor.tcl      headless terminal editor core
  gui.tcl         the Tk workbench
lib/        libraries built ON the engine
  logic.tcl, standard.tcl, catalog.tcl   relay logic / circuits
  parts.tcl       real parts: datasheet SPICE models + ratings
  ratings.tcl     design review against absolute-max ratings
  enigma*.tcl, bombe*.tcl                 the worked cryptanalysis machine
  symbols/standard.kicad_lib              vendored KiCad symbols
docs/       one markdown file per subsystem
tests/      one test_<area>.tcl per subsystem + run.tcl (the runner)
examples/   runnable circuits
```

## Coding conventions

The codebase is consistent; match what's already there.

- **Tcl style**: 4-space indent, no tabs, no trailing whitespace.  `make lint`
  checks the last two.
- **TclOO**: the engine is one class `::schem::Schematic`, extended across
  files with `oo::define`.  Public methods are lower-case (exported);
  internal helpers are Capitalised (unexported).  In the GUI, `bind`/`-command`
  callbacks route through the exported `dispatch` forwarder (Tk runs them at
  global scope where unexported methods aren't visible).
- **Comments explain *why*, in electrical terms.**  Each file opens with a
  block comment stating its job.  A method that stamps an MNA matrix says what
  physical law it encodes, not just what the code does.
- **Namespaces**: engine in `::schem`, sub-areas in `::schem::<area>`
  (`::schem::pcb`, `::schem::ksym`, `::schem::gui`, …).
- **No new runtime dependencies.**  Tcl/Tk only.  Optional tools (Zig, an SVG
  rasteriser) must degrade gracefully when absent.

## Adding things

### A new component (engine primitive)
1. Add it to the `META` array in `src/engine.tcl` (terminals + default params).
2. Stamp its behaviour in `src/simulate.tcl` (DC), and `transient.tcl`/`ac.tcl`
   if it's reactive/dynamic.
3. If it should appear on a PCB, add a footprint mapping in `src/pcb.tcl`.
4. Add a symbol: map it in `src/ksym.tcl`'s `TYPEMAP` to a KiCad symbol, or add
   a hand-drawn drawer in `src/symbols.tcl`.
5. Write `tests/test_<area>.tcl` cases with a hand-checked value.

### A new real part
Add a `::schem::parts::def` block in `lib/parts.tcl` with the manufacturer's
SPICE `model` parameters and datasheet `limits`.  See `docs/PARTS.md`.

### A new backend
Add `proc ::schem::backend::<name>` in `src/backend.tcl` consuming the Circuit
IR (`$s compile`).  It's auto-discovered by `::schem::backends`.

## Tests

```sh
make test                          # all suites
tclsh tests/run.tcl parts pcb      # only matching suites
SCHEM_ZIG=/path/to/zig make test   # also the compiled-backend cross-checks
```

Test files print `N passed, M failed` (or use tcltest) and exit nonzero on
failure.  GUI/symbol suites self-skip without Tk or a display, so they're safe
in headless CI.  Keep tests deterministic and fast (the bombe full-scan is the
one slow case — keep new tests well under a second).

## Submitting a change

1. Branch from the current development branch.
2. Make the change; add/adjust tests; run `make test` and `make lint`.
3. Write a clear commit message: what changed and *why* (the electrical
   reasoning, if relevant).
4. Open a PR describing the change, the test you added, and the value you
   verified by hand.

## Reporting bugs

Open an issue with: what you built (the smallest schematic that shows it), what
you expected electrically, what you got, and your Tcl/Tk version
(`echo 'puts $tcl_patchLevel' | tclsh`).
