# Schem -- a visual electrical programming language.
# Pure Tcl/Tk: nothing to build.  These targets just run and check it.

TCLSH ?= tclsh

.PHONY: help test test-engine gui lint examples clean

help:
	@echo "Schem -- make targets:"
	@echo "  make test         run the full regression suite"
	@echo "  make test-engine  run only the headless engine suites (no Tk)"
	@echo "  make gui          launch the visual workbench (needs Tk)"
	@echo "  make examples     run the runnable example circuits"
	@echo "  make lint         basic source checks (syntax, trailing whitespace)"
	@echo ""
	@echo "  Set SCHEM_ZIG=/path/to/zig to also run the compiled-backend checks."

# Full suite (GUI/symbol suites self-skip without Tk/display).
test:
	@$(TCLSH) tests/run.tcl

# Just the engine/physics suites that need no Tk.
test-engine:
	@$(TCLSH) tests/run.tcl schem parts pcb acdc ac zoom bus io cir catalog format logic seq standard tools svg bombe

gui:
	@$(TCLSH) bin/schem gui

# Run every standalone example (the .tcl ones; .schem.tcl builders need `run`).
examples:
	@for ex in examples/power_supply.tcl examples/ac_dc_supply.tcl examples/bombe_break.tcl; do \
		echo "== $$ex =="; $(TCLSH) $$ex >/dev/null && echo OK || echo FAIL; done
	@for ex in examples/*.schem.tcl; do \
		echo "== $$ex =="; $(TCLSH) bin/schem run $$ex >/dev/null && echo OK || echo FAIL; done

# Lightweight hygiene checks.
lint:
	@echo "Checking for trailing whitespace..."
	@! grep -rnE ' +$$' src/ lib/ tests/ --include='*.tcl' || echo "  ^ trailing whitespace found"
	@echo "Checking for tabs in source..."
	@! grep -rlP '\t' src/ lib/ --include='*.tcl' || echo "  ^ tabs found (use spaces)"

clean:
	@rm -f tests/z*.zig tests/ztmp*.zig tests/*tmp*.schem tests/svgtmp*.svg
	@echo "cleaned scratch files"
