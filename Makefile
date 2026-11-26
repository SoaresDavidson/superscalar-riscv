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
SUITES := unit integration isa
BUILD  := build

suite_tests = $(patsubst tb/$(1)/%_tb.sv,%,$(wildcard tb/$(1)/*_tb.sv))
UNIT_TESTS        := $(call suite_tests,unit)
INTEGRATION_TESTS := $(call suite_tests,integration)
# The isa suite runs programs the core cannot execute yet (no Branch Unit, no
# store data path), so it is expected to fail for now and stays out of
# `make test` and CI. Run it with `make test-isa` or `make test T=core_isa`.
ISA_TESTS         := $(call suite_tests,isa)
TESTS := $(UNIT_TESTS) $(INTEGRATION_TESTS) $(ISA_TESTS)

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
PARAMS_core_isa := DEEP2=0 DEEP2=1
PARAMS_fetch := WIDTH=1 WIDTH=2 WIDTH=3 WIDTH=4

T ?= $(UNIT_TESTS) $(INTEGRATION_TESTS)

# Physical design runs inside the LibreLane image (Dockerfile.librelane); the host
# needs only docker and a Ciel PDK folder. LIBRELANE_CONFIG picks the block's
# config, relative to the repository root. Without it, the target runs the
# LibreLane `spm` example in build/spm: a check that the flow and the PDK work.
# The core top (rtl/core) has no config yet: Branch Unit and Memory are still
# ports, not RTL.
LIBRELANE_IMAGE  := superscalar-riscv-librelane
LIBRELANE_CONFIG ?=
PDK_ROOT   ?= $(HOME)/.ciel
LIBRELANE_ARGS   := $(if $(LIBRELANE_CONFIG),/work/$(LIBRELANE_CONFIG),--run-example spm)
LIBRELANE_RUN    := docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp \
	  -e PDK_ROOT=/pdk -v "$(PDK_ROOT)":/pdk -v "$(CURDIR)":/work

# librelane-all runs every rtl/*/config*.json, one LibreLane per config; with -jN,
# N at once. Each run lands in runs/ next to its config. Two configs share a
# folder (execute/, issue/), so the run tag carries the config name, plus one
# timestamp per make invocation so no run overwrites an older one.
LIBRELANE_CONFIGS := $(wildcard rtl/*/config*.json)
LIBRELANE_STAMP   := $(shell date +%Y-%m-%d_%H-%M-%S)

.PHONY: test test-unit test-integration test-isa lint librelane librelane-image librelane-all librelane-status clean $(TESTS)
.PHONY: $(LIBRELANE_CONFIGS:%=librelane-run/%)

test: $(T)
test-unit: $(UNIT_TESTS)
test-integration: $(INTEGRATION_TESTS)
test-isa: $(ISA_TESTS)

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
librelane: librelane-image | $(BUILD)
	$(if $(LIBRELANE_CONFIG),,rm -rf $(BUILD)/spm)
	$(LIBRELANE_RUN) -w /work/$(BUILD) $(LIBRELANE_IMAGE) librelane $(LIBRELANE_ARGS)

# A separate target so that, under -j, the image is built once before any run.
librelane-image:
	docker build -f Dockerfile.librelane -t $(LIBRELANE_IMAGE) .

librelane-all: $(LIBRELANE_CONFIGS:%=librelane-run/%)

# The console output is discarded: LibreLane already writes it to flow.log in
# the run folder (and each step's log to its own folder). Only a failure
# before the run folder exists (bad JSON, missing file, docker error) is lost;
# rerun that config alone with `make librelane LIBRELANE_CONFIG=...` to see it.
$(LIBRELANE_CONFIGS:%=librelane-run/%): librelane-run/%: librelane-image
	@echo "librelane: $* started"
	@$(LIBRELANE_RUN) -w /work $(LIBRELANE_IMAGE) librelane --hide-progress-bar \
	  --run-tag $(basename $(notdir $*))_$(LIBRELANE_STAMP) /work/$* > /dev/null 2>&1 \
	  && echo "librelane: $* OK" \
	  || { echo "librelane: $* FAIL, see $(dir $*)runs/$(basename $(notdir $*))_$(LIBRELANE_STAMP)/flow.log"; exit 1; }

# Progress of the latest run of each config: steps done and the current step.
# A full Classic run of these configs creates 74 step folders (80 steps, 6
# gated off), so the total is approximate for a config with other RUN_* flags.
# A run killed midway keeps showing "running". Use: watch -n 10 make -s librelane-status
LIBRELANE_STEPS := 74
librelane-status:
	@for c in $(LIBRELANE_CONFIGS); do \
	  r=$$(ls -td $$(dirname $$c)/runs/$$(basename $$c .json)_*/ 2>/dev/null | head -1); \
	  if [ -z "$$r" ]; then s="not run"; n=0; step=-; else \
	    n=$$(find $$r -maxdepth 1 -name '[0-9]*-*' | wc -l); \
	    step=$$(ls $$r | grep -E '^[0-9]+-' | sort -n | tail -1 | cut -d- -f2-); \
	    if tail -1 $$r/flow.log 2>/dev/null | grep -q 'Flow complete'; then s=done; \
	    elif [ -s $$r/error.log ]; then s=FAIL; else s=running; fi; \
	  fi; \
	  printf '%-30s %-8s %3s/%s  %s\n' $$c "$$s" $$n $(LIBRELANE_STEPS) "$$step"; \
	done

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
