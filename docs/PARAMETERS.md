# Configuration Parameters Guide

## Overview

FemtoRV32 PetitPipe has **two Verilog parameters** for compile-time configuration.
The address bus is always 32 bits (full RISC-V address space); there is no
`ADDR_WIDTH` parameter.

| Parameter | Type | Default | Range | Purpose |
|-----------|------|---------|-------|---------|
| `RESET_ADDR` | 32-bit | `32'h00000000` | Any 32-bit address | Initial program counter on reset |
| `IWB_BURST_LEN` | Integer | `4` | 1–16 words | Instruction cache line size (prefetch) |

**ISA support** (compile-time, not Verilog parameters):
- **Always included**: RV32I (base integer), RV32M (multiply/divide), RV32C (compressed)
- **Set via toolchain**: Use `-march=rv32imc` when compiling firmware

---

## Parameter Reference

### `RESET_ADDR` — Initial Program Counter

```verilog
parameter RESET_ADDR = 32'h00000000;
```

The core jumps to this address on the first clock cycle after `reset_n` is released.
There must be a valid instruction at this address in the memory system.

**Typical values**:

| `RESET_ADDR` | Use case |
|---|---|
| `32'h0000_0000` | Boot ROM / Flash at address 0 (default) |
| `32'h8000_0000` | SRAM in the upper half of the address map |
| `32'hFFFF_0000` | On-chip boot ROM at top of address space |

**Instantiation example**:
```verilog
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR(32'h8000_0000)   // Boot from SRAM at 0x80000000
) core (
    .clk(clk),
    .reset_n(reset_n),
    // ...
);
```

---

### `IWB_BURST_LEN` — Instruction Cache Line Size

```verilog
parameter IWB_BURST_LEN = 4;  // 4-word cache lines (default)
```

Sets the number of 32-bit words fetched per cache line fill on the pipelined
instruction bus (`iwb_*`).  On a cache miss the core issues a burst of exactly
`IWB_BURST_LEN` beats, sending CTI=`3'b010` for all but the final beat and
CTI=`3'b111` for the last beat.

**Performance trade-off**:

| `IWB_BURST_LEN` | Hit rate | Miss latency | Area | Recommended |
|---|---|---|---|---|
| 2 | 65–75 % | 2 cycles | minimal | constrained designs |
| **4 (default)** | **75–85 %** | **4 cycles** | **small** | **general purpose** |
| 8 | 85–95 % | 8 cycles | medium | larger code loops |
| 16 | 90–97 % | 16 cycles | large | ASIC with abundant SRAM |

> Keep at 4 unless workload profiling shows a clear benefit from longer bursts.

---

## Memory Controller Parameters (`soc_dual_port_controller`)

These parameters belong to the example memory controller in
`examples/soc_examples.v`, **not** to the core itself.

### `LATENCY` — Memory Response Delay

```verilog
soc_dual_port_controller #(
    .LATENCY(1)   // Clock cycles from STB to ACK
) mem_ctrl (...);
```

| `LATENCY` | Typical source | Approx. IPC impact |
|---|---|---|
| 0 | Combinatorial (not recommended) | — |
| 1 | Fast on-chip SRAM (FPGA/ASIC) | 0.80–0.95 |
| 2 | Registered on-chip SRAM | 0.70–0.85 |
| 3+ | External SRAM or cached DDR | 0.60–0.75 |

---

## Bus Interface Summary

### Instruction Bus (`iwb_*`)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `iwb_cyc_o` | Out | 1 | Cycle active throughout burst |
| `iwb_stb_o` | Out | 1 | Strobe — one per beat |
| `iwb_adr_o` | Out | 32 | Byte address (word-aligned, bits [1:0] = 0) |
| `iwb_cti_o` | Out | 3 | CTI: `010` = continue, `111` = end |
| `iwb_bte_o` | Out | 2 | Burst type (always `2'b00`, linear) |
| `iwb_we_o`  | Out | 1 | Write enable (always `0`, read-only) |
| `iwb_sel_o` | Out | 4 | Byte select (always `4'b1111`) |
| `iwb_dat_o` | Out | 32 | Write data (always `0`, not used) |
| `iwb_dat_i` | In  | 32 | Instruction word read from memory |
| `iwb_ack_i` | In  | 1 | Beat acknowledged (data valid) |

### Data Bus (`dwb_*`)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `dwb_cyc_o` | Out | 1 | Cycle active |
| `dwb_stb_o` | Out | 1 | Strobe |
| `dwb_we_o`  | Out | 1 | Write enable (`1` = write, `0` = read) |
| `dwb_sel_o` | Out | 4 | Byte select |
| `dwb_adr_o` | Out | 32 | Byte address |
| `dwb_dat_o` | Out | 32 | Write data |
| `dwb_cti_o` | Out | 3 | CTI (always `3'b111`, classic single-word) |
| `dwb_bte_o` | Out | 2 | Burst type (always `2'b00`) |
| `dwb_dat_i` | In  | 32 | Read data from memory |
| `dwb_ack_i` | In  | 1 | Transaction complete |

---

## Interrupt Interface

The interrupt subsystem is **fixed at 8 priority levels** and is not configurable
through Verilog parameters.

| Signal | Width | Description |
|---|---|---|
| `irq_i` | 8 | Interrupt request lines; `irq_i[0]` = highest priority |

`mcause[3:0]` is set to the index of the highest-priority asserted line (0–7).
See [`docs/CSR_REFERENCE.md`](CSR_REFERENCE.md) for full details.

---

## Complete Instantiation Template

```verilog
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR   (32'h0000_0000),  // Boot address
    .IWB_BURST_LEN(4)               // Cache line size
) cpu (
    .clk       (clk),
    .reset_n   (reset_n),           // Synchronous, active LOW

    // Instruction bus (pipelined burst)
    .iwb_cyc_o (iwb_cyc),
    .iwb_stb_o (iwb_stb),
    .iwb_adr_o (iwb_adr),
    .iwb_cti_o (iwb_cti),
    .iwb_bte_o (iwb_bte),
    .iwb_we_o  (),                  // always 0
    .iwb_sel_o (),                  // always 4'b1111
    .iwb_dat_o (),                  // unused
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
    .irq_i     (irq)                // [7:0]
);
```

---

## Configuration Examples

### Minimal embedded SoC (boot from address 0, 1-cycle SRAM)
```verilog
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR   (32'h0000_0000),
    .IWB_BURST_LEN(4)
) core (...);

soc_dual_port_controller #(.LATENCY(1)) mem_ctrl (...);
// Expected IPC: 0.80–0.95
```

### FPGA SoC booting from upper SRAM
```verilog
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR   (32'h8000_0000),
    .IWB_BURST_LEN(4)
) core (...);

soc_dual_port_controller #(.LATENCY(2)) mem_ctrl (...);
// Expected IPC: 0.70–0.85
```

### High-performance design with 8-word cache lines
```verilog
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR   (32'h0000_0000),
    .IWB_BURST_LEN(8)               // Larger cache line
) core (...);

soc_dual_port_controller #(.LATENCY(1)) mem_ctrl (...);
// Expected IPC: 0.85–0.98 (for code with large sequential runs)
```

---

## ISA Support (Compile-Time Only)

The core **always** supports the full RV32IMC ISA:
- **RV32I**: All base integer instructions (ADD, LW, BEQ, JAL, …)
- **RV32M**: MUL, MULH, MULHU, MULHSU, DIV, DIVU, REM, REMU
- **RV32C**: All standard compressed (16-bit) instructions

Use `-march=rv32imc -mabi=ilp32` in the cross-compiler to produce matching code.
Extensions cannot be disabled without modifying the RTL.
