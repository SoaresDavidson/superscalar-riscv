# Each testbench is tb/<suite>/<name>_tb.sv (suites: unit, integration) and
# compiles against every file in rtl/. A testbench signals success by printing
# "PASS" and failure through $fatal. Test names must be unique across suites.

# Packages come first: iverilog resolves `import` in command-line order, so a
# consumer compiled before its package is a syntax error. Both lists are
# sorted, because the order `find` returns is not stable.
PKGS   := $(shell find rtl -name '*_pkg.sv' | sort)
MODS   := $(shell find rtl -name '*.sv' ! -name '*_pkg.sv' | sort)
RTL    := $(PKGS) $(MODS)
SUITES := unit integration
BUILD  := build

suite_tests = $(patsubst tb/$(1)/%_tb.sv,%,$(wildcard tb/$(1)/*_tb.sv))
UNIT_TESTS        := $(call suite_tests,unit)
INTEGRATION_TESTS := $(call suite_tests,integration)
TESTS := $(UNIT_TESTS) $(INTEGRATION_TESTS)

vpath %_tb.sv $(addprefix tb/,$(SUITES))

# Parameter sets a testbench must pass; a test without an entry runs once.
PARAMS_register_rename := MODE=0 MODE=1 MODE=2
PARAMS_decode          := WIDTH=1 WIDTH=2 WIDTH=3 WIDTH=4

T ?= $(TESTS)

.PHONY: test test-unit test-integration lint clean $(TESTS)

test: $(T)
test-unit: $(UNIT_TESTS)
test-integration: $(INTEGRATION_TESTS)

$(TESTS): %: %_tb.sv $(RTL) | $(BUILD)
	@set -e; for p in $(or $(PARAMS_$@),none); do \
	  flag=$$( [ $$p = none ] || echo "-P$@_tb.$$p" ); \
	  iverilog -g2012 -Wall -s $@_tb $$flag -o $(BUILD)/$@.vvp $(RTL) $<; \
	  out=$$(vvp -n $(BUILD)/$@.vvp 2>&1) || true; echo "$$out"; \
	  echo "$$out" | grep -q PASS || { echo "$@ ($$p) FAIL"; exit 1; }; \
	done

# Every pipeline block is its own top module until a core top exists, so
# MULTITOP ("you probably forgot --top-module") is expected here and is the
# only warning silenced. Verilator still elaborates and lints EVERY top: a
# defect in any block fails this target.
lint:
	verilator --lint-only -Wall -Wno-MULTITOP $(RTL)

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
