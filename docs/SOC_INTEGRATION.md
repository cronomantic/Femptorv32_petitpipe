# SoC Integration Guide for FemtoRV32 PetitPipe

## Overview

This guide walks through integrating FemtoRV32_PetitPipe_WB into a larger System-on-Chip (SoC) design. The core exports two Wishbone bus interfaces for instruction and data memory access (PetitPipe), or a single shared bus (Gracilis), plus interrupt lines and a simple clock/reset interface.

## Core Module Interface

### Top-Level Entity

```verilog
module FemtoRV32_PetitPipe_WB #(
    parameter RESET_ADDR       = 32'h00000000,
    parameter integer IWB_BURST_LEN = 4
) (
    input  clk,
    input  reset_n,                  // Active LOW, synchronous

    // Instruction Bus (Wishbone B4 Pipelined)
    output [31:0] iwb_adr_o,         // Byte address (word-aligned)
    output [31:0] iwb_dat_o,         // Write data (always 0)
    output  [3:0] iwb_sel_o,         // Byte select (always 4'b1111)
    output        iwb_we_o,          // Write enable (always 0)
    output        iwb_cyc_o,         // Cycle active during burst
    output        iwb_stb_o,         // Strobe (one per beat)
    output  [2:0] iwb_cti_o,         // CTI: 010=continue, 111=end
    output  [1:0] iwb_bte_o,         // Burst type (always 2'b00)
    input  [31:0] iwb_dat_i,         // Read data from slave
    input         iwb_ack_i,         // Acknowledge (data valid)

    // Data Bus (Wishbone B4 Classic)
    output [31:0] dwb_adr_o,         // Byte address
    output [31:0] dwb_dat_o,         // Write data
    output  [3:0] dwb_sel_o,         // Byte select
    output        dwb_we_o,          // Write enable
    output        dwb_cyc_o,         // Cycle active
    output        dwb_stb_o,         // Strobe
    output  [2:0] dwb_cti_o,         // CTI (always 3'b111)
    output  [1:0] dwb_bte_o,         // Burst type (always 2'b00)
    input  [31:0] dwb_dat_i,         // Read data from slave
    input         dwb_ack_i,         // Acknowledge

    // Interrupts
    input   [7:0] irq_i              // Interrupt requests (irq_i[0]=highest)
);
```

### Signal Definitions

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `clk` | In | 1 | Main clock (rising edge triggered) |
| `reset_n` | In | 1 | Active LOW synchronous reset |
| `iwb_cyc_o` | Out | 1 | Instruction bus cycle active |
| `iwb_stb_o` | Out | 1 | Instruction strobe (one per beat) |
| `iwb_adr_o` | Out | 32 | Instruction address (byte-aligned, word address) |
| `iwb_cti_o` | Out | 3 | CTI: 010=burst continue, 111=burst end |
| `iwb_dat_i` | In | 32 | Instruction data from memory |
| `iwb_ack_i` | In | 1 | Instruction beat acknowledged |
| `dwb_cyc_o` | Out | 1 | Data bus cycle active |
| `dwb_stb_o` | Out | 1 | Data strobe |
| `dwb_we_o` | Out | 1 | Write enable (1=write, 0=read) |
| `dwb_sel_o` | Out | 4 | Byte select (1=enabled byte) |
| `dwb_adr_o` | Out | 32 | Data address (byte-aligned) |
| `dwb_dat_o` | Out | 32 | Data write to memory |
| `dwb_dat_i` | In | 32 | Data read from memory |
| `dwb_ack_i` | In | 1 | Data transaction complete |
| `irq_i[7:0]` | In | 8 | Interrupt request lines (irq_i[0]=highest priority) |

## Reset Sequence

```verilog
// SoC reset controller
initial begin
    reset_n = 1'b0;            // Assert LOW (reset active)
    #(10 * CLK_PERIOD);
    reset_n = 1'b1;            // Release HIGH (reset inactive)
end

// Core begins execution at address 0x00000000
// Fetch of reset vector happens after reset_n goes HIGH
```

**Reset effects on core**:
- PC ← 0x00000000
- All registers ← 0
- Cache cleared
- No pending interrupts

## Integration Steps

### Step 1: Memory Subsystem

Create a memory controller that responds to both bus interfaces:

```verilog
// Example: soc_dual_port_controller in examples/soc_examples.v
wire        iwb_cyc, iwb_stb, iwb_ack;
wire [31:0] iwb_adr;
wire  [2:0] iwb_cti;
wire [31:0] iwb_dat_i;

wire        dwb_cyc, dwb_stb, dwb_we, dwb_ack;
wire  [3:0] dwb_sel;
wire [31:0] dwb_adr;
wire [31:0] dwb_wdata, dwb_rdata;

// Recommended: 16KB instruction memory + 8KB data memory minimum
soc_dual_port_controller #(
    .LATENCY(1)             // 1-cycle latency (on-chip SRAM)
) mem_ctrl (
    .clk(clk),
    .rst(!reset_n),   // soc_dual_port_controller uses active-HIGH rst; invert reset_n here
    
    .iwb_cyc(iwb_cyc),
    .iwb_stb(iwb_stb),
    .iwb_adr(iwb_adr),
    .iwb_cti(iwb_cti),
    .iwb_ack(iwb_ack),
    .iwb_dat_o(iwb_dat_i),
    
    .dwb_cyc(dwb_cyc),
    .dwb_stb(dwb_stb),
    .dwb_we(dwb_we),
    .dwb_sel(dwb_sel),
    .dwb_adr(dwb_adr),
    .dwb_dat_i(dwb_wdata),
    .dwb_ack(dwb_ack),
    .dwb_dat_o(dwb_rdata)
);
```

### Step 2: Interrupt Controller

Connect interrupt lines and implement priority encoding:

```verilog
// Simple priority encoder (irq[0] = highest priority)
wire [2:0] irq_priority;
wire irq_pending;

assign irq_pending = |irq;  // Any interrupt active

// Encode priority (irq[0] highest)
always @(*) begin
    if      (irq[0]) irq_priority = 3'h0;
    else if (irq[1]) irq_priority = 3'h1;
    else if (irq[2]) irq_priority = 3'h2;
    else if (irq[3]) irq_priority = 3'h3;
    else if (irq[4]) irq_priority = 3'h4;
    else if (irq[5]) irq_priority = 3'h5;
    else if (irq[6]) irq_priority = 3'h6;
    else             irq_priority = 3'h7;
end

// Gate interrupt request by software enable (see CSR_REFERENCE.md)
// Core samples irq[] on every cycle for mstatus.MIE check
```

**Interrupt Register Mapping**:
```
CSR 0x300 (mstatus):        Machine status register
  [3] MIE = Machine Interrupt Enable (software write)
  [0] UIE = User Interrupt Enable (unused in PetitPipe)

CSR 0x305 (mtvec):          Handler base address (24-bit effective)
  [0] MODE = 0 (direct jump to address)

CSR 0x342 (mcause):         Interrupt cause
  [31] = 1 (interrupt flag)
  [3:0] = IRQ priority code (0-7)
  
CSR 0x341 (mepc):           Return address after interrupt service

CSR 0xC00/0xC80 (cycles):   64-bit cycle counter
```

### Step 3: Clock and Power Distribution

```verilog
// SoC clock tree (example)
module soc_clk_tree (
    input  clk_in,          // External oscillator or PLL
    output clk_core,        // FemtoRV32 clock
    output clk_periph       // Peripheral clock (may differ)
);

// For simplicity, use same clock for core and memory:
assign clk_core = clk_in;
assign clk_periph = clk_in;

endmodule

// SoC top-level integration
module soc_top (
    input clk_in,
    input rst_n,            // External reset (active LOW)
    
    // Peripherals...
);

wire clk, reset_n;

// Clock generation
soc_clk_tree clk_tree (.clk_in(clk_in), .clk_core(clk));

// Reset synchronizer: rst_n (external, active LOW) → reset_n (core domain)
wire reset_sync_n;
sync_reset #(.WIDTH(2)) rst_sync (
    .clk(clk),
    .async_rst_n(rst_n),
    .sync_rst_n(reset_sync_n)
);
assign reset_n = reset_sync_n;

// Core instantiation
FemtoRV32_PetitPipe_WB core (
    .clk(clk),
    .reset_n(reset_n),
    
    .iwb_cyc_o(iwb_cyc),
    .iwb_stb_o(iwb_stb),
    .iwb_adr_o(iwb_adr),
    .iwb_cti_o(iwb_cti),
    .iwb_bte_o(),
    .iwb_we_o(),
    .iwb_sel_o(),
    .iwb_dat_o(),
    .iwb_dat_i(iwb_dat_i),
    .iwb_ack_i(iwb_ack),
    
    .dwb_cyc_o(dwb_cyc),
    .dwb_stb_o(dwb_stb),
    .dwb_we_o(dwb_we),
    .dwb_sel_o(dwb_sel),
    .dwb_adr_o(dwb_adr),
    .dwb_dat_o(dwb_wdata),
    .dwb_cti_o(),
    .dwb_bte_o(),
    .dwb_dat_i(dwb_rdata),
    .dwb_ack_i(dwb_ack),
    
    .irq_i(irq_lines)
);

endmodule
```

### Step 4: Address Decoding (Optional Multi-Peripheral)

If you have multiple memory-mapped peripherals:

```verilog
// Wishbone crossbar or simple decoder
// Address map:
//   0x_00000000 - 0x_00003FFF : Instruction RAM (16KB)
//   0x_10000000 - 0x_10001FFF : Data RAM (8KB)
//   0x_20000000 - 0x_20000003 : UART peripheral
//   0x_30000000 - 0x_30000007 : Timer peripheral

wire          dec_imem_sel;
wire          dec_dmem_sel;
wire          dec_uart_sel;
wire          dec_timer_sel;

// Decode from address
assign dec_imem_sel  = (iwb_adr[31:14] == 18'h0);          // 0x00000000
assign dec_dmem_sel  = (dwb_adr[31:13] == 19'h10000);      // 0x10000000
assign dec_uart_sel  = (dwb_adr[31:2]  == 30'h0800_0000);  // 0x20000000
assign dec_timer_sel = (dwb_adr[31:3]  == 29'h0c00_0000);  // 0x30000000

// Mux ACKs and data
wire [31:0] imem_dat, uart_dat, timer_dat;
wire imem_ack, uart_ack, timer_ack;

assign iwb_ack   = dec_imem_sel  ? imem_ack  : 1'b0;
assign iwb_dat_i = dec_imem_sel  ? imem_dat  : 32'hXXXX_XXXX;

assign dwb_ack   = dec_dmem_sel  ? dmem_ack  : 
                   dec_uart_sel  ? uart_ack  :
                   dec_timer_sel ? timer_ack : 1'b0;

assign dwb_dat_i = dec_dmem_sel  ? dmem_dat  :
                   dec_uart_sel  ? uart_dat  :
                   dec_timer_sel ? timer_dat : 32'h0000_0000;
```

## Typical SoC Configuration

### Minimal SoC (FPGA)
```
Memory:
  - 16KB I-SRAM (BRAM)
  - 8KB D-SRAM (BRAM)
  - 1-cycle latency
  
Peripherals:
  - UART (transmit/receive)
  - Timer (interrupt-capable)
  
Performance:
  - ~1000 cycles for 100-instruction program
  - IPC ≈ 0.8 with sequential code
```

### Full SoC (ASIC)
```
Memory:
  - 64KB L1 instruction cache (4-way, 16B lines) → hit rate ~95%
  - 32KB L1 data cache (4-way, 16B lines)
  - 256KB unified L2 cache
  - 4MB main memory (DRAM) at 40-200 cycle latency
  
Control:
  - Memory management unit (MMU)
  - Interrupt controller (PLIC) with 8+ external IRQs
  - Power management (clock/voltage scaling)
  - Debug interface (JTAG)
  
Peripherals:
  - UART (DMA-capable)
  - SPI interface
  - GPIO controller
  - Real-time clock
  - DDR SDRAM controller
  
Expected Performance:
  - 20-40 DMIPS at 100 MHz
  - 100-200 DMIPS at 500 MHz
```

## Troubleshooting Integration

### Symptoms & Causes

| Symptom | Cause | Solution |
|---------|-------|----------|
| Core stuck at PC=0 | No reset release | Check reset signal release timing |
| Bus ACK never asserts | Memory latency too high | Reduce wait-states in controller |
| Random wrong results | Address bus skew | Check byte-lane ordering, endianness |
| Interrupt never taken | IRQ not reaching core | Verify mstatus.MIE=1, IRQ line high for ≥2 cycles |
| Bus protocol error | STB/CYC timing wrong | Review Wishbone protocol spec in WISHBONE_INTERFACE.md |

### Verification Checklist

- [ ] Reset assertion/deassertion verified in simulation
- [ ] Memory controller responds to all addresses in legal range
- [ ] Read/write data paths tested with known patterns (0xAAAA5555, etc.)
- [ ] Interrupt vectoring to handler address confirmed
- [ ] All CSR reads return expected reset values
- [ ] Cycle counter increments every clock
- [ ] Bus protocol compliant (use `protocol_checkers.v`)

## Performance Optimization in SoC

### Memory Hierarchy

**On-Chip SRAM** (0-10 cycle latency):
- Instruction: 16-32 KB minimum
- Data: 8-16 KB minimum
- Provides high IPC (0.8+)

**Prefetch Strategy** (built-in to core):
- 4-word ligne fill on miss
- Addresses: miss_addr, miss_addr+1, miss_addr+2, miss_addr+3
- Asynchronous to execution (doesn't stall fetch)

**Cache Configuration** (if adding L1/L2):
- Instruction cache: 4-8 MB/s at 1 GHz (sufficient for most cores)
- Data cache: 2-4 MB/s at 1 GHz
- Consider write-through (simpler) vs write-back (higher performance)

### Bus Optimization

**Split vs Unified Memory**:
- Current: Split I/D (no arbitration) → full throughput
- Alternative: Shared memory + arbiter → half throughput but SRAM savings

**Burst Length**:
- Current: 4-word bursts (16 bytes)
- Tradeoff: Longer bursts (8/16 words) reduce miss overhead but increase miss latency

**Clock Frequency**:
- IPC independent of frequency (both measured in cycles)
- Higher frequency → more bandwidth but requires tighter timing

## Example: Minimal FPGA SoC

See [examples/soc_examples.v](../examples/soc_examples.v) for complete working code:

```verilog
// Instantiate: soc_top with integrated controller and arbiter
soc_top #(
    .IMEM_SIZE(16'h4000),   // 16KB
    .DMEM_SIZE(16'h2000)    // 8KB
) soc (
    .clk(sys_clk),
    .rst(!sys_rst_n),
    .ext_irq(uart_irq_i),
    
    .dbg_addr(jtag_addr),
    .dbg_rdata(jtag_rdata),
    .dbg_wdata(jtag_wdata),
    .dbg_we(jtag_we)
);

// Load program
initial $readmemh("firmware.hex", soc.mem_ctrl.imem);
```

## Next Steps

1. **Verify in simulation**:
   - Use provided tb_femtorv32_wb.v as reference
   - Add your memory model
   - Validate bus protocol compliance

2. **Synthesize to target**:
   - FPGA: Use Vivado/Quartus/Diamond synthesis
   - ASIC: Use DC/Cadence flow
   - Ensure timing closure at target frequency

3. **Profile performance**:
   - See PERFORMANCE_METRICS.md for measurement tools
   - Benchmark against reference implementations

4. **Document your SoC**:
   - Memory map
   - Interrupts and peripherals
   - Power domains
   - Clock topology
