# Each testbench is tb/<suite>/<name>_tb.sv (suites: unit, integration) and
# compiles against every file in rtl/. A testbench signals success by printing
# "PASS" and failure through $fatal. Test names must be unique across suites.

# Packages come first: iverilog resolves `import` in command-line order, so a
# consumer compiled before its package is a syntax error. Both lists are
# sorted, because the order `find` returns is not stable. execute_pkg goes
# before every other package, because the others import it (dispatch_pkg would
# otherwise sort ahead of it).
BASE_PKG := rtl/execute/execute_pkg.sv
PKGS   := $(BASE_PKG) $(filter-out $(BASE_PKG),$(shell find rtl -name '*_pkg.sv' | sort))
MODS   := $(shell find rtl \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
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
PARAMS_fetch := WIDTH=1 WIDTH=2 WIDTH=3 WIDTH=4

T ?= $(TESTS)

# Physical design runs inside the LibreLane image (Dockerfile.pnr); the host
# needs only docker and a Ciel PDK folder. PNR_CONFIG picks the block's
# config, relative to the repository root. Without it, the target runs the
# LibreLane `spm` example in build/spm: a check that the flow and the PDK work
# while there is no core top to harden.
PNR_IMAGE  := superscalar-riscv-pnr
PNR_CONFIG ?=
PDK_ROOT   ?= $(HOME)/.ciel
PNR_ARGS   := $(if $(PNR_CONFIG),/work/$(PNR_CONFIG),--run-example spm)

.PHONY: test test-unit test-integration lint pnr clean $(TESTS)

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
pnr: | $(BUILD)
	docker build -f Dockerfile.pnr -t $(PNR_IMAGE) .
	$(if $(PNR_CONFIG),,rm -rf $(BUILD)/spm)
	docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp \
	  -e PDK_ROOT=/pdk -v "$(PDK_ROOT)":/pdk -v "$(CURDIR)":/work \
	  -w /work/$(BUILD) $(PNR_IMAGE) librelane $(PNR_ARGS)

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
