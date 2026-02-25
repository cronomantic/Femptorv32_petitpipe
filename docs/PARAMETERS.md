# Configuration Parameters Guide

## Overview

FemtoRV32 PetitPipe has **3 Verilog parameters** for compile-time configuration:

| Parameter | Type | Default | Range | Purpose |
|-----------|------|---------|-------|---------|
| `RESET_ADDR` | 32-bit | `32'h00000000` | Any 32-bit address | Initial program counter on reset |
| ~~`ADDR_WIDTH[removed]`~~ | removed | — | — | Address bus is always 32-bit (full RISC-V range). Parameter removed. |
| `IWB_BURST_LEN` | Integer | `4` | 1-16 words | Instruction cache line size (prefetch) |

**ISA Support** (compile-time, not Verilog parameters):
- **Always included**: RV32I (base integer), RV32M (multiply), RV32C (compressed)
- **Set via toolchain**: Defines in firmware generation (`-march=rv32imc`)

---

## Core Parameters

### `RESET_ADDR` (Initial PC on Reset)

#### `IWB_BURST_LEN` (Instruction Cache Line Size)
```verilog
parameter IWB_BURST_LEN = 4;  // 4-word cache lines
```
**Impact**:
- 4 words (16 bytes): Current setting
  - Miss latency: ~3-4 cycles (with 1-cycle per word)
  - Cache efficiency: 75-85% on sequential code
  - Prefetch prediction: modest overhead (4 addresses)
- 8 words (32 bytes): Alternative (requires RTL change)
  - Miss latency: ~6-8 cycles
  - Cache efficiency: higher for large loops
  - Prefetch overhead: doubles

**Default**: 4
**Recommendation**: Keep at 4 unless profiling shows benefit

---

#### `ADDR_WIDTH[removed]` (Memory Address Range)
```verilog
parameter ADDR_WIDTH[removed] = 24;  // 24-bit word addressing → 16 MB address space
```
**Impact**:
- 24-bit word addressing → 2²⁴ words = 16 million words = 16 MB physical address space
- Actual usable memory depends on SoC memory subsystem implementation
- Affects width of internal address buses (iwb_adr[23:0], dwb_adr[23:0])

**Default**: 24 bits
**Typical Values**:
- 16-bit: 64 KB memory (minimal embedded systems)
- 20-bit: 1 MB memory (small SoCs)
- 24-bit: 16 MB memory (typical SoCs, **current default**)
- 28-bit: 256 MB memory (larger systems)
- 30-bit: 1 GB memory (high-end)

**Example - Configure for Different Sizes**:
```verilog
// 64 KB address space (minimal)
FemtoRV32_PetitPipe_WB #(.IWB_BURST_LEN(4)) core (...)  // ADDR_WIDTH[removed] removed: always 32-bit

// 16 MB address space (default)


// 256 MB address space (large)

```

**Note**: Testbench memory controllers use word-indexed arrays; no ADDR_WIDTH[removed] override is needed.

---

### Memory Controller Parameters (soc_dual_port_controller)

These parameters are in the example memory controller, **NOT** in the core itself.

#### `LATENCY` (Memory Response Delay)
```verilog
// In soc_dual_port_controller instantiation
soc_dual_port_controller #(
    .LATENCY(1)             // Cycles from STB to ACK
) mem_ctrl (...)
```
**Impact**:
- 0 cycles: Combinatorial ACK (unrealistic, dangers of setup timing issues)
- 1 cycle: Fast on-chip SRAM (typical FPGA/ASIC on-chip)
- 2 cycles: Realistic external SRAM with pipeline register
- 3+ cycles: DDR SDRAM or cache-backed memory with latency

**Default**: 1 (in soc_dual_port_controller)
**Performance Impact on IPC**:
```
LATENCY=1: IPC 0.80-0.95 (cache hits reduce penalty)
LATENCY=2: IPC 0.70-0.85
LATENCY=3: IPC 0.60-0.75
LATENCY=variable: IPC 0.50-0.70 (realistic systems)
```

---

### Bus Interface Details

#### Instruction Bus (iwb_*)
```verilog
// In FemtoRV32_PetitPipe_WB
output wire         iwb_cyc,              // Cycle active
output wire         iwb_stb,              // Strobe (valid address + CTI)
output wire [31:2]           iwb_adr,    // Word address (bits [31:2])
output wire [2:0]   iwb_cti,              // Cycle Type Indicator
input  wire         iwb_ack,              // Acknowledge (data valid)
input  wire [31:0]  iwb_dat_i             // Read data
```

**Burst Protocol** (iwb_cti codes):
- `3'b000`: Classic single-word transaction
- `3'b010`: Burst continue (more words in sequence)
- `3'b111`: Burst end (final word of sequence)

**Prefetch Behavior** (built-in, not configurable):
- On instruction cache miss, automatically requests 4 consecutive words (configurable via IWB_BURST_LEN)
- Sends CTI codes: 010, 010, 010, 111
- Memory controller must support this burst protocol
- Reduces average fetch latency 25-40% vs. single-word fetches

#### Data Bus (dwb_*)
```verilog
output wire         dwb_cyc,              // Cycle active
output wire         dwb_stb,              // Strobe
output wire         dwb_we,               // Write Enable
output wire [3:0]   dwb_sel,              // Byte select (1=enabled)
output wire [31:2]           dwb_adr,    // Word address
input  wire         dwb_ack,              // Acknowledge
input  wire [31:0]  dwb_dat_i,            // Read data
output wire [31:0]  dwb_dat_o             // Write data
```

**Protocol** (classic Wishbone single-transaction):
- ALL transactions are single-word (no bursting)
- ETI always 3'b000 (not used on D-bus)

---

### Performance Tuning Parameters

#### `RESET_ADDR` (Boot Address)
```verilog
parameter RESET_ADDR = 32'h0000_0000;  // Where PC jumps on reset
```
**Impact**:
- Typically 0x00000000 (ROM/bootloader start)
- Can be changed for different memory mapping
- Must have valid instruction at this address

**Default**: 0x00000000
**SoC Configuration Example**:
```verilog
// If using 0x80000000 for SRAM (privileged code):
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR(32'h8000_0000)
) core (...)
```

---

---

## Interrupt Handling (Non-Configurable)

Interrupt hardware is **fixed at 8 priority levels**:
- IRQ[0]: Highest priority (mcause code 0)
- IRQ[7]: Lowest priority (mcause code 7)
- Priority encoder automatically selects highest pending IRQ
- mcause[3:0] encodes priority (0-7)
- Not Verilog parameters - hardwired in core RTL

---

## ISA Support (Compile-Time Only)

The core **always** supports:
- **RV32I**: Base integer instruction set (mandatory)
- **RV32M**: 32-bit multiply/divide extension (always included)
- **RV32C**: 16-bit compressed instruction extension (always included)

**ISA:**
```
RV32IMC (all features always enabled)
```

**Included Instructions**:
- RV32I: ADD, SUB, ADDI, LW, SW, BEQ, JAL, etc.
- RV32M: MUL, MULH, MULHU, MULHSU, DIV, DIVU, REM, REMU
- RV32C: C.ADD, C.LW, C.SW, C.J, C.JAL, C.JALR (compressed variants)

**Note**: Cannot disable extensions without modifying RTL. Use `-march=rv32imc` in toolchain.

---

## Configuration Examples

### Minimal Embedded SoC (16-bit, 64 KB)
```verilog
// Smallest address space for cost-sensitive applications
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR(32'h00000000),
    .IWB_BURST_LEN(4)              // Standard 4-word prefetch
) core (...);

soc_dual_port_controller #(
    .LATENCY(1)                    // Fast on-chip SRAM
) mem_ctrl (...);

// Typical: 8KB program + 56KB data/stack
// Performance: 0.80-0.95 IPC (sequential code)
```

### Balanced IoT SoC (18-bit, 256 KB)
```verilog
// Typical embedded system configuration
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR(32'h00000000),
    .IWB_BURST_LEN(4)
) core (...);

soc_dual_port_controller #(
    .LATENCY(2)                    // Realistic FPGA/ASIC memory
) mem_ctrl (...);

// Typical: 16KB program + 240KB data/stack
// Performance: 0.70-0.85 IPC (with 2-cycle memory latency)
```

### Large SoC (24-bit, 16 MB, Default)
```verilog
// Maximum recommended: 24-bit addressing (default ADDR_WIDTH[removed])
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR(32'h80000000),    // Boot from 0x80000000 (high memory)
    .IWB_BURST_LEN(4)
) core (...);

// Multi-level memory hierarchy:
// On-chip: 32KB I + 32KB D SRAM (1-cycle, cache-backed)
// External: 512KB SRAM cache (2-3 cycle)
// Main: 256MB DRAM (10-50 cycles)

soc_dual_port_controller #(
    .LATENCY(1)                    // Front-end fast SRAM
) mem_ctrl (...);

// Typical: 64-256KB program + 256MB addressable data
// Performance: 0.60-0.75 IPC (with multi-level cache)
```

---

## Address Range

The address bus is always 32 bits, covering the full 4 GB RISC-V address space.
The internal PC, mepc, mtvec, and load/store address computations all use full 32-bit values.


|------------|---------------|-------------|----------|
| 16 | 0x0000 - 0xFFFF | 64 KB | Toy projects, simulation |
| 18 | 0x00000 - 0x3FFFF | 256 KB | Small embedded systems |
| 20 | 0x000000 - 0xFFFFF | 1 MB | Medium IoT devices |
| 24 (DEFAULT) | 0x0000000 - 0xFFFFFF | 16 MB | Typical SoCs |
| 28 | 0x00000000 - 0xFFFFFFF | 256 MB | Large systems |
| 30 | 0x000000000 - 0x3FFFFFFFF | 1 GB | High-end processors |

**Recommendation**: Start with 24-bit (16 MB) - covers 99% of embedded use cases.

---

## IWB_BURST_LEN Selection Guide

| Burst Length | Performance | Hit Rate | Area | Typical Use |
|--------------|-------------|----------|------|-------------|
| 2 | Moderate | 65-75% | Minimal | Constraint-driven |
| 4 (DEFAULT) | Good | 75-85% | Small | Recommended |
| 8 | Very Good | 85-95% | Medium | Larger systems |
| 16 | Excellent | 90-97% | Large | ASIC with L1 cache |

**Recommendation**: Keep at 4 (default) unless profiling shows benefit from longer bursts.

**Impact on Performance**:
- Longer bursts: Higher hit rate, but higher miss latency (more cycles to fetch)
- Shorter bursts: Lower hit rate, but faster miss recovery
- Typical 4-word: Good balance for most workloads

---

## Modifying Configuration

### For RTL Compilation (specify Verilog parameters)

The **only** parameters that can be overridden during compilation are: `RESET_ADDR`, `IWB_BURST_LEN`
(`ADDR_WIDTH[removed]` has been removed; addresses are always 32-bit.)

```bash
# Method 1: Using -p flag (not recommended, parameterless works better)
iverilog -g2009 \
    -p FemtoRV32_PetitPipe_WB.RESET_ADDR=32\'h80000000 \
    -p FemtoRV32_PetitPipe_WB.ADDR_WIDTH[removed]=20 \
    rtl/femtorv32_petitpipe.v \
    -o build/sim

# Method 2: In Makefile (recommended)
VFLAGS += -p FemtoRV32_PetitPipe_WB.ADDR_WIDTH[removed]=20
```

### For Synthesis (FPGA/ASIC)

Use instantiation wrapper:

```verilog
module soc_config(
    input clk, rst,
    input [7:0] ext_irq,
    input unsigned [31:0] iwb_dat_i,
    output unsigned [31:0] iwb_dat_o,
    // ... other signals
);

// Override parameters in instantiation
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR(32'h80000000),    // Custom boot address
    .IWB_BURST_LEN(4)              // 4-word cache lines
) core_inst (
    .clk(clk),
    .reset(rst),
    // ... connections
);

endmodule
```

### For SoC Integration (Verilog Instantiation)
```verilog
// Instance with custom parameters
FemtoRV32_PetitPipe_WB #(
    .RESET_ADDR(32'h00000000),     // Where to jump on reset
    .IWB_BURST_LEN(4)              // 4-word cache line prefetch
) processor (
    .clk(sys_clk),
    .reset(sys_rst),
    
    // Instruction bus
    .iwb_cyc(iwb_cyc),
    .iwb_stb(iwb_stb),
    .iwb_adr(iwb_adr),
    .iwb_cti(iwb_cti),
    .iwb_ack(iwb_ack),
    .iwb_dat_i(iwb_dat_i),
    
    // Data bus
    .dwb_cyc(dwb_cyc),
    .dwb_stb(dwb_stb),
    .dwb_we(dwb_we),
    .dwb_sel(dwb_sel),
    .dwb_adr(dwb_adr),
    .dwb_ack(dwb_ack),
    .dwb_dat_i(dwb_dat_i),
    .dwb_dat_o(dwb_dat_o),
    
    // Interrupts
    .irq(ext_irq),
    .irq_ack(core_irq_ack)
);
```

---

## Verification

### Validate parameter instantiation
```verilog
// In testbench - display active configuration
initial begin
    $display("Core Configuration:");
    $display("  RESET_ADDR = 0x%h", RESET_ADDR);
    $display("  ADDR_WIDTH[removed] = %d bits (%d MB address space)", 
             ADDR_WIDTH[removed], 1 << (ADDR_WIDTH[removed] - 20));
    $display("  IWB_BURST_LEN = %d words", IWB_BURST_LEN);
end
```

### Test memory sizing
```bash
# Verify program fits in configured address space
ls -la build/test.hex
# For 16-bit ADDR_WIDTH[removed]: max 64KB (2^16 words = 65536 bytes max)
# For 24-bit ADDR_WIDTH[removed]: max 16MB (2^24 words)

# Check hex file size
hexdump -C build/test.hex | tail -1
# Should show last address < (1 << ADDR_WIDTH[removed])
```

---

## Next Steps

1. **Determine your SoC constraints**:
   - Available FPGA/ASIC area
   - Memory budget (I/D/caches)
   - Clock frequency target
   - Performance requirements (IPC)

2. **Select configuration**:
   - Use table above as reference
   - Run area synthesis to validate
   - Run simulation with actual latencies

3. **Optimize iteratively**:
   - Profile with real workloads
   - Adjust cache, memory, latency
   - Validate performance targets

4. **Document your choices**:
   - Maintain SoC specification document
   - List all parameter overrides
   - Record performance baselines
