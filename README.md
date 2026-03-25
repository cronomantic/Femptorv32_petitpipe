# FemtoRV32 PetitPipe

A minimal, synthesisable **2-stage pipelined RISC-V RV32IMC** soft-core written in
Verilog, built for FPGA and ASIC targets.  The repository also includes two
reference cores (*Gracilis* and *Pipedream*) that share the same ISA but use a
simpler state-machine micro-architecture, making cycle-accurate comparisons easy.

---

## Features

| Feature | Details |
|---|---|
| **ISA** | RV32IMC — base integer, M-extension (multiply/divide), C-extension (compressed) |
| **Pipeline** | 2-stage in-order (IF / EX) with split instruction and data buses |
| **Instruction cache** | 4-word line prefetch via pipelined Wishbone burst (configurable) |
| **Interrupt support** | 8-priority encoder, RISC-V privileged-spec `mcause` encoding |
| **CSRs** | `mstatus`, `mtvec`, `mepc`, `mcause`, `cycles` / `cyclesh` |
| **Bus interface** | Wishbone B4 — pipelined I-bus (`iwb_*`), classic D-bus (`dwb_*`) |
| **Reset** | Synchronous, active-LOW (`reset_n`) |
| **Technology** | Single clock domain, fully synchronous |

---

## Core Variants

Three synthesisable cores are provided in `rtl/`:

| Core | File | Architecture | Buses | I-cache |
|---|---|---|---|---|
| **PetitPipe** | `femtorv32_petitpipe.v` | 2-stage IF/EX pipeline | Split I-bus + D-bus (Wishbone B4) | 4-word burst prefetch |
| **Gracilis** | `femtorv32_gracilis_wb.v` | 4-state FSM | Single classic Wishbone | None |
| **Pipedream** | `femtorv32_pipedream.v` | 4-state FSM + exec-time prefetch | Single classic Wishbone | None |

### Performance comparison (sequential ALU code)

| Core | Cycles / instruction | Notes |
|---|---|---|
| PetitPipe | ~1 (pipeline steady-state) | Cache hit needed; stalls on miss, divide, load-use |
| Pipedream | 2 | Exec-prefetch skips FETCH state |
| Gracilis | 3 | One full FETCH + WAIT + EXECUTE cycle per instruction |

---

## Quick Start

### Prerequisites

```bash
# Ubuntu / Debian
sudo apt-get install -y verilator build-essential \
    gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf
```

```bash
# macOS (Homebrew)
brew install verilator riscv-gnu-toolchain
```

### Build and run

```bash
# Cross-compile all RV32I assembly tests to ELF + Verilog hex
make compile

# Syntax-check testbench files (uses stub RTL — no simulation)
make tb-check

# Run PetitPipe simulation (Wishbone testbench with instruction cache)
make sim-wb

# Run Gracilis reference simulation
make sim-gracilis-wb

# Run all tests on Gracilis and Pipedream
make sim-gracilis
make sim-pipedream

# Compare cycle counts: PetitPipe vs Gracilis
make perf-compare

# Remove generated artefacts
make clean

# List all available targets
make help
```

> **Note**: All generated artefacts land in `build/` — this directory is never committed.

---

## Repository Layout

```
rtl/                  Synthesisable Verilog source
  femtorv32_petitpipe.v         2-stage pipelined core (primary)
  femtorv32_gracilis_wb.v       4-state FSM reference core
  femtorv32_pipedream.v         Exec-prefetch variant of Gracilis
  perf_monitor.v                Cycle-accurate performance counters
  stub/                         Syntax-check stubs (not for synthesis)

tb/                   Verilator testbenches (C++ driver + Verilog models)
  sim_main.cpp                  Shared C++ cosimulation harness
  tb_femtorv32_wb.v             PetitPipe + instruction cache
  tb_femtorv32_gracilis_wb.v    Gracilis Wishbone testbench
  tb_riscv_tests_gracilis_wb.v  RISC-V compliance tests on Gracilis
  tb_riscv_tests_pipedream_wb.v RISC-V compliance tests on Pipedream
  tb_perf_compare.v             Cycle-count comparison harness

tests/                RISC-V assembly test programs
  common/link.ld                Linker script (all tests)
  common/test_macros.h          Assertion macros
  rv32i/                        RV32I instruction tests (ADD, branch, load/store, …)

docs/                 Detailed reference documentation
  WISHBONE_INTERFACE.md         Pin-by-pin bus specification
  CSR_REFERENCE.md              CSR register map and usage
  PARAMETERS.md                 Verilog parameters and defaults
  SOC_INTEGRATION.md            Step-by-step SoC integration guide
  PERFORMANCE_METRICS.md        Benchmarking methodology
  VERILATOR_BUILD_GUIDE.md      Build and simulation guide

examples/             Reference SoC implementations (synthesisable)
  soc_examples.v                Dual-port controller, arbiter, soc_top
  README.md                     How to use the example modules

scripts/              Helper scripts
  analyze_performance.py        Post-simulation performance analysis
  run_riscv_tests.py            Official RISC-V test-suite runner
  riscv_tests_link.ld           Linker script for official tests

validation/           Protocol compliance checkers
  protocol_checkers.v           Wishbone B4, cache, and interrupt checkers
  README.md                     Validation infrastructure overview

build/                Generated artefacts — never committed
```

---

## Bus Interface Summary

### Instruction Bus (`iwb_*`) — Wishbone B4 Pipelined

```
iwb_cyc_o   out  Cycle active (asserted for full burst)
iwb_stb_o   out  Strobe (one per beat)
iwb_adr_o   out  [31:0] Byte address (word-aligned)
iwb_cti_o   out  [2:0]  CTI: 010 = burst continue, 111 = burst end
iwb_bte_o   out  [1:0]  Burst type (always 2'b00, linear)
iwb_we_o    out  Write enable (always 0, read-only)
iwb_sel_o   out  [3:0]  Byte select (always 4'b1111)
iwb_dat_o   out  [31:0] Write data (always 0, not used)
iwb_dat_i   in   [31:0] Instruction word from memory
iwb_ack_i   in   Beat acknowledged (data valid)
```

### Data Bus (`dwb_*`) — Wishbone B4 Classic

```
dwb_cyc_o   out  Cycle active
dwb_stb_o   out  Strobe
dwb_we_o    out  Write enable
dwb_sel_o   out  [3:0] Byte select
dwb_adr_o   out  [31:0] Byte address
dwb_dat_o   out  [31:0] Write data
dwb_cti_o   out  [2:0]  CTI (always 3'b111, classic single-word)
dwb_bte_o   out  [1:0]  Burst type (always 2'b00)
dwb_dat_i   in   [31:0] Read data
dwb_ack_i   in   Transaction complete
```

See [`docs/WISHBONE_INTERFACE.md`](docs/WISHBONE_INTERFACE.md) for timing diagrams and the
complete Gracilis/Pipedream single-bus interface.

---

## Instantiation Example

```verilog
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR   (32'h0000_0000),  // PC on reset
    .IWB_BURST_LEN(4)               // Cache line size (words)
) cpu (
    .clk       (clk),
    .reset_n   (reset_n),           // Active LOW, synchronous

    // Instruction bus (pipelined burst)
    .iwb_cyc_o (iwb_cyc),
    .iwb_stb_o (iwb_stb),
    .iwb_adr_o (iwb_adr),
    .iwb_cti_o (iwb_cti),
    .iwb_bte_o (),                  // tie off if not used
    .iwb_we_o  (),                  // always 0 — read-only
    .iwb_sel_o (),                  // always 4'b1111
    .iwb_dat_o (),                  // always 0
    .iwb_dat_i (iwb_dat_i),
    .iwb_ack_i (iwb_ack),

    // Data bus (classic single-transaction)
    .dwb_cyc_o (dwb_cyc),
    .dwb_stb_o (dwb_stb),
    .dwb_we_o  (dwb_we),
    .dwb_sel_o (dwb_sel),
    .dwb_adr_o (dwb_adr),
    .dwb_dat_o (dwb_wdata),
    .dwb_cti_o (),                  // always 3'b111
    .dwb_bte_o (),                  // always 2'b00
    .dwb_dat_i (dwb_rdata),
    .dwb_ack_i (dwb_ack),

    // Interrupts
    .irq_i     (irq)                // [7:0], irq_i[0] = highest priority
);
```

---

## Documentation Index

| Document | Description |
|---|---|
| [`DOCUMENTATION.md`](DOCUMENTATION.md) | Architecture deep-dive and integration checklist |
| [`docs/INSTRUCTION_TIMING.md`](docs/INSTRUCTION_TIMING.md) | Per-instruction cycle counts for PetitPipe, Pipedream, and Gracilis |
| [`docs/WISHBONE_INTERFACE.md`](docs/WISHBONE_INTERFACE.md) | Complete Wishbone pin descriptions and timing diagrams |
| [`docs/CSR_REFERENCE.md`](docs/CSR_REFERENCE.md) | CSR address map, field definitions, and assembly examples |
| [`docs/PARAMETERS.md`](docs/PARAMETERS.md) | Verilog `parameter` reference with defaults and constraints |
| [`docs/SOC_INTEGRATION.md`](docs/SOC_INTEGRATION.md) | Memory, interrupt, reset integration walkthrough |
| [`docs/PERFORMANCE_METRICS.md`](docs/PERFORMANCE_METRICS.md) | IPC analysis, cache hit rate, stall breakdown |
| [`docs/VERILATOR_BUILD_GUIDE.md`](docs/VERILATOR_BUILD_GUIDE.md) | Verilator 5.0+ build instructions and troubleshooting |
| [`examples/README.md`](examples/README.md) | SoC example modules (`soc_dual_port_controller`, `soc_top`) |
| [`validation/README.md`](validation/README.md) | Protocol checkers for Wishbone, cache, and interrupts |

---

## License

BSD 3-Clause — see [`LICENSE`](LICENSE).

Original FemtoRV32 *Gracilis* core by Bruno Levy and Matthias Koch (2020–2021),
used under the same BSD-3-Clause licence.
Wishbone adaptation, 2-stage pipeline, instruction cache, and interrupt extensions
by Cronomantic (2026).
