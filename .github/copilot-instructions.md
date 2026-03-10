# Copilot Coding Agent Instructions

## Project Overview

**FemtoRV32 PetitPipe** is a small RISC-V processor implementation written in Verilog. It implements a 2-stage (IF/EX) pipeline with an instruction cache and a Wishbone bus interface.

Key characteristics:
- **ISA**: RV32IMC (base integer + multiply/divide extension + compressed instructions)
- **Pipeline**: 2-stage (Instruction Fetch / Execute) with split instruction and data buses
- **Instruction Cache**: 4-word line prefetch using pipelined Wishbone burst transfers
- **Interrupts**: 8-priority encoder with CSR support (RISC-V privileged spec)
- **Bus Interface**: Wishbone B4 — pipelined instruction bus (`iwb_*`), classic data bus (`dwb_*`)
- **Reference core**: `femtorv32_gracilis_wb.v` — a 4-state state-machine core used for comparison
- **Optimised reference**: `femtorv32_pipedream.v` — single-bus 2-cycle-per-instruction core derived from Gracilis via exec-time prefetch

## Repository Layout

```
rtl/           Synthesisable Verilog source files
  femtorv32_petitpipe.v        Main pipelined processor (2-stage IF/EX, split buses)
  femtorv32_gracilis_wb.v      Reference state-machine core (single WB bus)
  femtorv32_pipedream.v        Optimised single-bus core (exec-time prefetch variant of Gracilis)
  perf_monitor.v               Performance monitoring module
  stub/                        Syntax-check stubs (not for synthesis)
tb/            Verilator testbench (C++ driver + Verilog memory model)
tests/rv32i/   RISC-V assembly test programs
tests/common/  Shared linker script and test macros
docs/          Detailed reference documentation (Wishbone, CSR, parameters, …)
scripts/       Helper scripts (build, analysis)
validation/    Protocol checkers
build/         Generated artefacts — never commit this directory
```

## Tech Stack and Tools

- **HDL**: Verilog (IEEE 1364-2001 / 1800-2012 style used in the existing RTL)
- **Simulator**: Verilator (C++ cosimulation driver in `tb/sim_main.cpp`)
- **Cross-compiler**: `riscv64-unknown-elf-gcc` for assembly tests
- **Build system**: GNU Make (`Makefile` at repo root)
- **CI**: GitHub Actions (`.github/workflows/ci.yml`)

## How to Build and Test

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt-get install -y verilator build-essential \
    gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf

# Cross-compile all RV32I assembly tests
make compile

# Verify testbench and memory-model syntax (uses stub RTL)
make tb-check

# Lint RTL with Verilator
make lint

# Run full simulation (requires RTL committed to rtl/)
make sim

# Compare cycle counts between PetitPipe and Gracilis
make perf-compare

# Remove generated artefacts
make clean
```

Always run `make tb-check` after editing testbench files, and `make compile` after editing assembly tests, before pushing.

## Coding Standards

### Verilog
- Follow the style of the existing RTL files (`femtorv32_petitpipe.v`, `femtorv32_gracilis_wb.v`).
- Use `always @(posedge clk)` for synchronous logic; use `always @(*)` for combinational logic.
- Prefix module ports consistently: `iwb_` for instruction-bus signals, `dwb_` for data-bus signals.
- Use named parameters (`parameter`) for all configuration knobs; document defaults.
- Add a one-line comment at the start of each always block explaining its purpose.
- Keep line length ≤ 100 characters.

### Assembly / C
- Test programs live in `tests/rv32i/` and follow the macro conventions in `tests/common/test_macros.h`.
- Use the linker script `tests/common/link.ld` for all test programs.

### Scripts
- Python scripts in `scripts/` follow standard PEP 8 style.

## Pull Request Guidelines

- Reference the issue number in the PR description.
- Include a brief description of *what* changed and *why*.
- Ensure `make tb-check` and `make compile` pass before requesting review.
- For RTL changes, include simulation results or waveform notes if they demonstrate correctness.
- For performance-sensitive changes, run `make perf-compare` and include the output.

## Restrictions

- Do **not** commit files under `build/` — this directory is for generated artefacts only.
- Do **not** modify `.github/workflows/ci.yml` unless the task is specifically about CI configuration.
- Do **not** add new external dependencies (libraries, tools) without updating `README.md` and the CI workflow.
- Do **not** commit binary files (ELFs, object files) to the repository.
- Do **not** expose secrets, credentials, or hardware-specific configuration values.
- The `rtl/stub/` directory contains dummy modules for syntax checking only — do **not** use them in simulation or synthesis targets.
