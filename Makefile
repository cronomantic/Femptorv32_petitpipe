# SPDX-License-Identifier: BSD-3-Clause
# Makefile for FemptorV32_petitpipe testing infrastructure
#
# Targets
# -------
#   make compile      Compile all RV32I assembly tests to ELF + Verilog hex
#   make tb-check     Verify testbench syntax using the stub RTL (no simulation)
#   make sim          Build simulator and run all tests (requires real RTL in rtl/)
#   make sim-TESTNAME Run a single test, e.g. make sim-test_add
#   make clean        Remove all build artefacts
#   make help         Print this help

# ---------------------------------------------------------------------------
# Toolchain – override on the command line if needed, e.g.:
#   make RISCV_PREFIX=riscv32-unknown-elf-
# ---------------------------------------------------------------------------
RISCV_PREFIX ?= riscv64-unknown-elf-
CC           := $(RISCV_PREFIX)gcc
OBJCOPY      := $(RISCV_PREFIX)objcopy
OBJDUMP      := $(RISCV_PREFIX)objdump

ARCH_FLAGS   := -march=rv32i -mabi=ilp32
CFLAGS       := $(ARCH_FLAGS) -nostdlib -nostartfiles -static -Wall \
                -Wl,--no-warn-rwx-segments

IVERILOG     ?= iverilog
VVP          ?= vvp
IVFLAGS      := -g2012

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
REPO_ROOT  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL_DIR    := $(REPO_ROOT)rtl
TB_DIR     := $(REPO_ROOT)tb
TEST_DIR   := $(REPO_ROOT)tests
COMMON_DIR := $(TEST_DIR)/common
BUILD_DIR  := $(REPO_ROOT)build

LINK_SCRIPT := $(COMMON_DIR)/link.ld

# ---------------------------------------------------------------------------
# Source lists
# ---------------------------------------------------------------------------
TESTS_SRC  := $(wildcard $(TEST_DIR)/rv32i/*.S)
TESTS_NAME := $(notdir $(TESTS_SRC:.S=))

ELFS    := $(patsubst %, $(BUILD_DIR)/elfs/%.elf,   $(TESTS_NAME))
HEXES   := $(patsubst %, $(BUILD_DIR)/hexes/%.hex,  $(TESTS_NAME))
DISASMS := $(patsubst %, $(BUILD_DIR)/disasm/%.dis, $(TESTS_NAME))

SIM_EXE := $(BUILD_DIR)/sim/tb_top
SIM_STUB_EXE := $(BUILD_DIR)/sim/tb_stub
WB_SIM_EXE := $(BUILD_DIR)/sim/tb_femtorv32_wb
GRACILIS_WB_SIM_EXE := $(BUILD_DIR)/sim/tb_femtorv32_gracilis_wb
GRACILIS_RISCV_SIM_EXE := $(BUILD_DIR)/sim/tb_riscv_tests_gracilis_wb

# Test bench files
TB_FILES  := $(TB_DIR)/tb_top.v $(TB_DIR)/mem_model.v
WB_TB_FILES := $(TB_DIR)/tb_femtorv32_wb.v $(REPO_ROOT)validation/protocol_checkers.v
GRACILIS_WB_TB_FILES := $(TB_DIR)/tb_femtorv32_gracilis_wb.v $(REPO_ROOT)validation/protocol_checkers.v
GRACILIS_RISCV_TB_FILES := $(TB_DIR)/tb_riscv_tests_gracilis_wb.v

# Real RTL files (empty if not yet committed)
RTL_FILES := $(wildcard $(RTL_DIR)/*.v)

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------
.PHONY: all
all: help

# Preserve intermediate ELF files
.PRECIOUS: $(BUILD_DIR)/elfs/%.elf

# Compile assembly tests → ELF
# ---------------------------------------------------------------------------
$(BUILD_DIR)/elfs/%.elf: $(TEST_DIR)/rv32i/%.S $(LINK_SCRIPT) $(COMMON_DIR)/test_macros.h
	@mkdir -p $(BUILD_DIR)/elfs
	$(CC) $(CFLAGS) -I$(COMMON_DIR) -T$(LINK_SCRIPT) -o $@ $<

# ---------------------------------------------------------------------------
# ELF → Verilog hex (for $readmemh)
# ---------------------------------------------------------------------------
$(BUILD_DIR)/hexes/%.hex: $(BUILD_DIR)/elfs/%.elf
	@mkdir -p $(BUILD_DIR)/hexes
	$(OBJCOPY) -O verilog $< $@

# ---------------------------------------------------------------------------
# ELF → disassembly (optional but useful for debugging)
# ---------------------------------------------------------------------------
$(BUILD_DIR)/disasm/%.dis: $(BUILD_DIR)/elfs/%.elf
	@mkdir -p $(BUILD_DIR)/disasm
	$(OBJDUMP) -d $< > $@

# ---------------------------------------------------------------------------
# Compile all tests
# ---------------------------------------------------------------------------
.PHONY: compile
compile: $(HEXES) $(DISASMS)
	@echo "All test programs compiled successfully."

# ---------------------------------------------------------------------------
# Build simulator with stub RTL (testbench syntax check only)
# ---------------------------------------------------------------------------
$(SIM_STUB_EXE): $(TB_FILES) $(RTL_DIR)/stub/FemptorV32_petitpipe.v
	@mkdir -p $(BUILD_DIR)/sim
	$(IVERILOG) $(IVFLAGS) -I$(TB_DIR) \
	    -o $@ $^

.PHONY: tb-check
tb-check: $(SIM_STUB_EXE)
	@echo "Testbench syntax OK (stub build)."

# ---------------------------------------------------------------------------
# Build simulator with real RTL
# ---------------------------------------------------------------------------
ifeq ($(RTL_FILES),)
$(SIM_EXE):
	@echo "ERROR: No RTL files found in $(RTL_DIR)/"
	@echo "       Add FemptorV32_petitpipe.v (and any supporting modules) to rtl/"
	@exit 1
else
$(SIM_EXE): $(TB_FILES) $(RTL_FILES)
	@mkdir -p $(BUILD_DIR)/sim
	$(IVERILOG) $(IVFLAGS) -I$(TB_DIR) \
	    -o $@ $^
endif

# ---------------------------------------------------------------------------
# Build Wishbone test bench with real RTL
# FemtoRV32_PetitPipe_WB is defined in femtorv32_petitpipe.v
# ---------------------------------------------------------------------------
ifeq ($(RTL_FILES),)
$(WB_SIM_EXE):
	@echo "ERROR: No RTL files found in $(RTL_DIR)/"
	@echo "       Add femtorv32_petitpipe.v (contains FemtoRV32_PetitPipe_WB) to rtl/"
	@exit 1
else
$(WB_SIM_EXE): $(WB_TB_FILES) $(RTL_FILES)
	@mkdir -p $(BUILD_DIR)/sim
	$(IVERILOG) $(IVFLAGS) -I$(TB_DIR) \
	    -o $@ $^
endif

# ---------------------------------------------------------------------------
# Run Wishbone test bench
# ---------------------------------------------------------------------------
.PHONY: sim-wb
sim-wb: $(WB_SIM_EXE)
	@mkdir -p $(BUILD_DIR)/results
	$(VVP) $(WB_SIM_EXE) | tee $(BUILD_DIR)/results/tb_femtorv32_wb.log
	@if grep -q "INSTRUCTION CACHE FUNCTIONAL" $(BUILD_DIR)/results/tb_femtorv32_wb.log; then \
	    echo ""; echo "[TB PASS] Wishbone test bench with instruction cache passed"; \
	else \
	    echo ""; echo "[TB FAIL] Wishbone test bench with instruction cache failed"; exit 1; \
	fi

# ---------------------------------------------------------------------------
# Build Gracilis Wishbone test bench
# FemtoRV32_Gracilis_WB is defined in femtorv32_gracilis_wb.v
# ---------------------------------------------------------------------------
ifeq ($(RTL_FILES),)
$(GRACILIS_WB_SIM_EXE):
	@echo "ERROR: No RTL files found in $(RTL_DIR)/"
	@echo "       Add femtorv32_gracilis_wb.v (contains FemtoRV32_Gracilis_WB) to rtl/"
	@exit 1
else
$(GRACILIS_WB_SIM_EXE): $(GRACILIS_WB_TB_FILES) $(RTL_FILES)
	@mkdir -p $(BUILD_DIR)/sim
	$(IVERILOG) $(IVFLAGS) -I$(TB_DIR) \
	    -o $@ $^
endif

# ---------------------------------------------------------------------------
# Run Gracilis Wishbone test bench
# ---------------------------------------------------------------------------
.PHONY: sim-gracilis-wb
sim-gracilis-wb: $(GRACILIS_WB_SIM_EXE)
	@mkdir -p $(BUILD_DIR)/results
	$(VVP) $(GRACILIS_WB_SIM_EXE) | tee $(BUILD_DIR)/results/tb_femtorv32_gracilis_wb.log
	@if grep -q "GRACILIS WB CORE FUNCTIONAL" $(BUILD_DIR)/results/tb_femtorv32_gracilis_wb.log; then \
	    echo ""; echo "[TB PASS] Gracilis Wishbone test bench passed"; \
	else \
	    echo ""; echo "[TB FAIL] Gracilis Wishbone test bench failed"; exit 1; \
	fi

# ---------------------------------------------------------------------------
# Build Gracilis riscv-tests Wishbone test bench
# ---------------------------------------------------------------------------
ifeq ($(RTL_FILES),)
$(GRACILIS_RISCV_SIM_EXE):
	@echo "ERROR: No RTL files found in $(RTL_DIR)/"
	@echo "       Add femtorv32_gracilis_wb.v (contains FemtoRV32_Gracilis_WB) to rtl/"
	@exit 1
else
$(GRACILIS_RISCV_SIM_EXE): $(GRACILIS_RISCV_TB_FILES) $(RTL_FILES)
	@mkdir -p $(BUILD_DIR)/sim
	$(IVERILOG) $(IVFLAGS) -I$(TB_DIR) \
	    -o $@ $^
endif

# ---------------------------------------------------------------------------
# Run a single riscv-test on Gracilis WB
#   make sim-gracilis-<testname>  e.g.  make sim-gracilis-test_add
# ---------------------------------------------------------------------------
.PHONY: sim-gracilis-%
sim-gracilis-%: $(BUILD_DIR)/hexes/%.hex $(GRACILIS_RISCV_SIM_EXE)
	@mkdir -p $(BUILD_DIR)/results
	$(VVP) $(GRACILIS_RISCV_SIM_EXE) +hex_file=$< \
	    | tee $(BUILD_DIR)/results/gracilis_$*.log

# ---------------------------------------------------------------------------
# Run all riscv-tests on Gracilis WB
# ---------------------------------------------------------------------------
GRACILIS_RESULTS := $(patsubst %, $(BUILD_DIR)/results/gracilis_%.log, $(TESTS_NAME))

$(BUILD_DIR)/results/gracilis_%.log: $(BUILD_DIR)/hexes/%.hex $(GRACILIS_RISCV_SIM_EXE)
	@mkdir -p $(BUILD_DIR)/results
	$(VVP) $(GRACILIS_RISCV_SIM_EXE) +hex_file=$< | tee $@

.PHONY: sim-gracilis
sim-gracilis: $(GRACILIS_RESULTS)
	@echo ""
	@echo "==============================="
	@echo " Gracilis simulation results"
	@echo "==============================="
	@grep -h "\[TB" $(GRACILIS_RESULTS) || true
	@echo ""
	@if grep -q "\[TB FAIL\]\|\[TB TIMEOUT\]" $(GRACILIS_RESULTS) 2>/dev/null; then \
	    echo "RESULT: SOME TESTS FAILED"; exit 1; \
	else \
	    echo "RESULT: ALL TESTS PASSED"; \
	fi

# ---------------------------------------------------------------------------
# Run a single test
# ---------------------------------------------------------------------------
$(BUILD_DIR)/results/%.log: $(BUILD_DIR)/hexes/%.hex $(SIM_EXE)
	@mkdir -p $(BUILD_DIR)/results
	$(VVP) $(SIM_EXE) +hex_file=$< | tee $@

# Convenience target: make sim-test_add
.PHONY: sim-%
sim-%: $(BUILD_DIR)/hexes/%.hex $(SIM_EXE)
	@mkdir -p $(BUILD_DIR)/results
	$(VVP) $(SIM_EXE) +hex_file=$< | tee $(BUILD_DIR)/results/$*.log

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
RESULTS := $(patsubst %, $(BUILD_DIR)/results/%.log, $(TESTS_NAME))

.PHONY: sim
sim: $(RESULTS)
	@echo ""
	@echo "==============================="
	@echo " Simulation results summary"
	@echo "==============================="
	@grep -h "\[TB" $(RESULTS) || true
	@echo ""
	@if grep -q "\[TB FAIL\]\|\[TB TIMEOUT\]" $(RESULTS) 2>/dev/null; then \
	    echo "RESULT: SOME TESTS FAILED"; exit 1; \
	else \
	    echo "RESULT: ALL TESTS PASSED"; \
	fi

# ---------------------------------------------------------------------------
# Lint (requires Verilator)
# ---------------------------------------------------------------------------
.PHONY: lint
lint:
	verilator --lint-only -Wall --top-module tb_top \
	    $(TB_FILES) $(RTL_DIR)/stub/FemptorV32_petitpipe.v \
	    2>&1 | grep -v "^%Warning-DECLFILENAME" || true

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "FemptorV32_petitpipe test infrastructure"
	@echo "========================================="
	@echo ""
	@echo "Targets:"
	@echo "  compile          Compile all RV32I assembly tests to ELF + hex"
	@echo "  tb-check         Verify testbench syntax with stub RTL (iverilog)"
	@echo "  sim              Run all simulation tests (requires RTL in rtl/)"
	@echo "  sim-<name>       Run a single test, e.g. sim-test_add"
	@echo "  sim-wb           Run PetitPipe Wishbone test bench (pipelined cache prefetch)"
	@echo "  sim-gracilis-wb  Run Gracilis Wishbone test bench (state-machine core)"
	@echo "  sim-gracilis     Run all riscv-tests on FemtoRV32_Gracilis_WB"
	@echo "  sim-gracilis-<n> Run a single riscv-test on Gracilis, e.g. sim-gracilis-test_add"
	@echo "  lint             Lint Verilog sources with Verilator"
	@echo "  clean            Remove build artefacts"
	@echo ""
	@echo "Toolchain variables (override as needed):"
	@echo "  RISCV_PREFIX     RISC-V toolchain prefix (default: riscv64-unknown-elf-)"
	@echo "  IVERILOG         Icarus Verilog compiler (default: iverilog)"
	@echo "  VVP              Icarus Verilog runtime (default: vvp)"
	@echo ""
