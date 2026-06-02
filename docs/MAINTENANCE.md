# Codebase health & maintenance plan

Schem is already in good shape — ~18 K lines, zero `TODO`/`FIXME` markers, a
green ~430-case suite, one doc per subsystem.  This is the plan to keep it
neat, hygienic, and easy to contribute to as it grows.  Items are grouped by
priority; checked items are already in place.

## Done (the foundation)

- [x] **One-command test runner** — `make test` / `tclsh tests/run.tcl`, picks
      the right interpreter per suite, single summary, nonzero exit on failure.
- [x] **CI** — `.github/workflows/ci.yml` runs the suite on Linux (under Xvfb,
      with the Zig backend) and the engine suites on macOS, on every push/PR.
- [x] **Contributor docs** — `CONTRIBUTING.md` (layout, conventions, how to add
      a component/part/backend), issue + PR templates.
- [x] **Install docs** — `docs/INSTALL.md` per platform (Windows/macOS/Linux).
- [x] **Correctness assessment** — `docs/ASSESSMENT.md`, reproducible.
- [x] **Lint target** — `make lint` (trailing whitespace, tabs).
- [x] **Consistent style already** — 4-space indent, no tabs, per-file header
      comments, lower/Upper method export convention.

## Near-term (low effort, high tidiness)

- [ ] **Split `src/gui.tcl` (1962 lines).**  It's the one large file.  Carve
      into `gui_canvas.tcl` (draw/interaction), `gui_panels.tcl` (parts bin,
      inspector, toolbar), `gui_dialogs.tcl` (transient/AC/compile/netlist),
      keeping the `App` class via `oo::define` across files — exactly how the
      engine is already split.  Mechanical, no behaviour change.
- [ ] **Split `src/backend.tcl` (1806 lines)** by backend (zig / dcref /
      digref) the same way.
- [ ] **A `VERSION` constant + `CHANGELOG.md`.**  Tag releases (`v0.1.0`) so
      users can cite a version; the assessment already implies a baseline.
- [ ] **`make lint` → fail (not warn) on whitespace/tabs**, and wire it as a
      separate CI step that blocks (already a step; make it strict).
- [ ] **Pin a Tcl version matrix in CI** (8.6 and 9.0) to catch the `callback`
      / `encoding` differences before users hit them.

## Medium-term (organisation & robustness)

- [ ] **A real syntax-lint.**  `make lint` currently checks whitespace; add a
      pass that `source`s each file under a guarded interp and reports genuine
      parse errors, plus a check that every `proc`/`method` referenced by a
      `callback`/`do` action actually exists (catches the class of bug we hit
      with unexported callbacks).
- [ ] **Coverage of the slow path.**  The bombe full-scan is the only
      multi-second test; gate it behind `SCHEM_SLOW=1` so the default `make
      test` stays fast, and run the full version in CI.
- [ ] **Golden-file tests for outputs.**  Snapshot a known-good KiCad netlist,
      BOM, SVG and emitted Zig for a reference board; diff on change so output
      regressions are caught, not just engine ones.
- [ ] **Document the IR contract** (`docs/IR.md` exists — extend it with a
      stability note so backend authors know what they can rely on).
- [ ] **A symbols-refresh script.**  Record how `lib/symbols/standard.kicad_lib`
      was vendored (which KiCad release, which symbols) and a script to
      re-extract, so it can be updated deliberately.

## Longer-term (contributor scale)

- [ ] **Plugin discovery for parts and backends.**  `lib/parts.tcl` is one
      file; let `lib/parts/*.tcl` be auto-sourced so part libraries can be
      contributed independently (rectifiers, regulators, logic, RF…).
- [ ] **A component/parts reference page generated from the source** (the META
      table + the parts DB) so docs can't drift from code.
- [ ] **Property-based engine tests** — random ladder networks checked against
      an independent nodal solve, to harden the MNA core beyond hand cases.
- [ ] **Examples as tests.**  Run every `examples/*.tcl` in CI and assert it
      exits clean, so examples can't rot.

## Conventions to hold the line on

These are what keep the codebase coherent; enforce them in review:

1. **The schematic is the source of truth.**  Netlist/IR/SVG/PCB/Zig are
   derived; never make a derived form editable-as-truth.
2. **No new runtime deps.**  Tcl/Tk only; optional tools degrade gracefully.
3. **Every engine change ships a hand-verified test.**  An electrical claim
   without a number you can check by hand doesn't merge.
4. **One file per subsystem, one doc per subsystem, one test suite per
   subsystem.**  When a file crosses ~1500 lines, split it along its seams.
5. **Public = lower-case method, internal = Capitalised.**  GUI callbacks go
   through `dispatch`.
6. **Comments say *why*, in electrical terms.**

## Health metrics to watch

| Metric | Now | Keep |
|--------|-----|------|
| Test suites / cases | 19 / ~430 | grows with features |
| `TODO`/`FIXME` count | 0 | 0 |
| Largest source file | gui.tcl 1962 | < 1500 after split |
| CI status | (new) green | green on main |
| Docs per subsystem | 1:1 | 1:1 |
