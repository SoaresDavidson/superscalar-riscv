# Each testbench is tb/<suite>/<name>_tb.sv (suites: unit, integration) and
# compiles against every file in rtl/. A testbench signals success by printing
# "PASS" and failure through $fatal. Test names must be unique across suites.

RTL    := $(shell find rtl -name '*.sv')
SUITES := unit integration
BUILD  := build

suite_tests = $(patsubst tb/$(1)/%_tb.sv,%,$(wildcard tb/$(1)/*_tb.sv))
UNIT_TESTS        := $(call suite_tests,unit)
INTEGRATION_TESTS := $(call suite_tests,integration)
TESTS := $(UNIT_TESTS) $(INTEGRATION_TESTS)

vpath %_tb.sv $(addprefix tb/,$(SUITES))

# Parameter sets a testbench must pass; a test without an entry runs once.
PARAMS_register_rename := MODE=0 MODE=1 MODE=2

T ?= $(TESTS)

.PHONY: test test-unit test-integration lint clean $(TESTS)

test: $(T)
test-unit: $(UNIT_TESTS)
test-integration: $(INTEGRATION_TESTS)

$(TESTS): %: %_tb.sv $(RTL) | $(BUILD)
	@set -e; for p in $(or $(PARAMS_$@),none); do \
	  flag=$$( [ $$p = none ] || echo "-P$@_tb.$$p" ); \
	  iverilog -g2012 -Wall -s $@_tb $$flag -o $(BUILD)/$@.vvp $(RTL) $<; \
	  out=$$(vvp -n $(BUILD)/$@.vvp); echo "$$out"; \
	  echo "$$out" | grep -q PASS || { echo "$@ ($$p) FAIL"; exit 1; }; \
	done

lint:
	verilator --lint-only -Wall $(RTL)

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
