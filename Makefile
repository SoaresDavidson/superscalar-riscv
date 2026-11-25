# Each testbench is tb/<suite>/<name>_tb.sv (suites: unit, integration) and
# compiles against every file in rtl/. A testbench signals success by printing
# "PASS" and failure through $fatal. Test names must be unique across suites.

# Packages come first: iverilog resolves `import` in command-line order, so a
# consumer compiled before its package is a syntax error. Both lists are
# sorted, because the order `find` returns is not stable. execute_pkg goes
# before every other package, because the others import it (dispatch_pkg would
# otherwise sort ahead of it).
BASE_PKG := rtl/execute/execute_pkg.sv
# LibreLane writes its runs (netlists included) into rtl/<block>/runs/: those
# .v files redeclare the RTL modules, so every runs/ folder is skipped.
SKIP_RUNS := -path '*/runs' -prune -o
PKGS   := $(BASE_PKG) $(filter-out $(BASE_PKG),$(shell find rtl $(SKIP_RUNS) -name '*_pkg.sv' -print | sort))
MODS   := $(shell find rtl $(SKIP_RUNS) \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' -print | sort)
RTL    := $(PKGS) $(MODS)
SUITES := unit integration
BUILD  := build

suite_tests = $(patsubst tb/$(1)/%_tb.sv,%,$(wildcard tb/$(1)/*_tb.sv))
UNIT_TESTS        := $(call suite_tests,unit)
INTEGRATION_TESTS := $(call suite_tests,integration)
TESTS := $(UNIT_TESTS) $(INTEGRATION_TESTS)

vpath %_tb.sv $(addprefix tb/,$(SUITES))

# Parameter sets a testbench must pass; a test without an entry runs once.
# No PARAMS_register_rename: there is no `register_rename` test. The rename
# tests are PRFRename and PRFRenameBundle, and they take no parameter sets --
# PRFRename_tb fixes W = 1 and PRFRenameBundle_tb fixes W = 3, WB_N = 2.
PARAMS_decode := WIDTH=1 WIDTH=2 WIDTH=3 WIDTH=4
PARAMS_PipeFifo := DEPTH=1 DEPTH=2 DEPTH=3 DEPTH=4 DEPTH=8
PARAMS_retire_team := DEEP2=0 DEEP2=1
PARAMS_backend := DEEP2=0 DEEP2=1
PARAMS_core := DEEP2=0 DEEP2=1
PARAMS_fetch := WIDTH=1 WIDTH=2 WIDTH=3 WIDTH=4

T ?= $(TESTS)

# Physical design runs inside the LibreLane image (Dockerfile.pnr); the host
# needs only docker and a Ciel PDK folder. PNR_CONFIG picks the block's
# config, relative to the repository root. Without it, the target runs the
# LibreLane `spm` example in build/spm: a check that the flow and the PDK work.
# The core top (rtl/core) has no config yet: Branch Unit and Memory are still
# ports, not RTL.
PNR_IMAGE  := superscalar-riscv-pnr
PNR_CONFIG ?=
PDK_ROOT   ?= $(HOME)/.ciel
PNR_ARGS   := $(if $(PNR_CONFIG),/work/$(PNR_CONFIG),--run-example spm)
PNR_RUN    := docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp \
	  -e PDK_ROOT=/pdk -v "$(PDK_ROOT)":/pdk -v "$(CURDIR)":/work

# pnr-all runs every rtl/*/config*.json, one LibreLane per config; with -jN,
# N at once. Each run lands in runs/ next to its config. Two configs share a
# folder (execute/, issue/), so the run tag carries the config name, plus one
# timestamp per make invocation so no run overwrites an older one.
PNR_CONFIGS := $(wildcard rtl/*/config*.json)
PNR_STAMP   := $(shell date +%Y-%m-%d_%H-%M-%S)

.PHONY: test test-unit test-integration lint pnr pnr-image pnr-all pnr-status clean $(TESTS)
.PHONY: $(PNR_CONFIGS:%=pnr-run/%)

test: $(T)
test-unit: $(UNIT_TESTS)
test-integration: $(INTEGRATION_TESTS)

$(TESTS): %: %_tb.sv $(RTL) | $(BUILD)
	@set -e; for p in $(or $(PARAMS_$@),none); do \
	  flag=$$( [ $$p = none ] || echo "-P$@_tb.$$p" ); \
	  iverilog -g2012 -Wall -I rtl -s $@_tb $$flag -o $(BUILD)/$@.vvp $(RTL) $<; \
	  out=$$(vvp -n $(BUILD)/$@.vvp 2>&1) || true; echo "$$out"; \
	  echo "$$out" | grep -q PASS || { echo "$@ ($$p) FAIL"; exit 1; }; \
	done

# Every pipeline block is its own top module until a core top exists, so
# MULTITOP ("you probably forgot --top-module") is expected here and is the
# only warning silenced. Verilator still elaborates and lints EVERY top: a
# defect in any block fails this target.
lint:
	verilator --lint-only -Wall -Wno-MULTITOP -Irtl $(RTL)

# Runs as the host user so the outputs in runs/ are not owned by root.
# --run-example refuses to overwrite an existing copy, hence the rm.
pnr: pnr-image | $(BUILD)
	$(if $(PNR_CONFIG),,rm -rf $(BUILD)/spm)
	$(PNR_RUN) -w /work/$(BUILD) $(PNR_IMAGE) librelane $(PNR_ARGS)

# A separate target so that, under -j, the image is built once before any run.
pnr-image:
	docker build -f Dockerfile.pnr -t $(PNR_IMAGE) .

pnr-all: $(PNR_CONFIGS:%=pnr-run/%)

# The console output is discarded: LibreLane already writes it to flow.log in
# the run folder (and each step's log to its own folder). Only a failure
# before the run folder exists (bad JSON, missing file, docker error) is lost;
# rerun that config alone with `make pnr PNR_CONFIG=...` to see it.
$(PNR_CONFIGS:%=pnr-run/%): pnr-run/%: pnr-image
	@echo "pnr: $* started"
	@$(PNR_RUN) -w /work $(PNR_IMAGE) librelane --hide-progress-bar \
	  --run-tag $(basename $(notdir $*))_$(PNR_STAMP) /work/$* > /dev/null 2>&1 \
	  && echo "pnr: $* OK" \
	  || { echo "pnr: $* FAIL, see $(dir $*)runs/$(basename $(notdir $*))_$(PNR_STAMP)/flow.log"; exit 1; }

# Progress of the latest run of each config: steps done and the current step.
# A full Classic run of these configs creates 74 step folders (80 steps, 6
# gated off), so the total is approximate for a config with other RUN_* flags.
# A run killed midway keeps showing "running". Use: watch -n 10 make -s pnr-status
PNR_STEPS := 74
pnr-status:
	@for c in $(PNR_CONFIGS); do \
	  r=$$(ls -td $$(dirname $$c)/runs/$$(basename $$c .json)_*/ 2>/dev/null | head -1); \
	  if [ -z "$$r" ]; then s="not run"; n=0; step=-; else \
	    n=$$(find $$r -maxdepth 1 -name '[0-9]*-*' | wc -l); \
	    step=$$(ls $$r | grep -E '^[0-9]+-' | sort -n | tail -1 | cut -d- -f2-); \
	    if tail -1 $$r/flow.log 2>/dev/null | grep -q 'Flow complete'; then s=done; \
	    elif [ -s $$r/error.log ]; then s=FAIL; else s=running; fi; \
	  fi; \
	  printf '%-30s %-8s %3s/%s  %s\n' $$c "$$s" $$n $(PNR_STEPS) "$$step"; \
	done

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
