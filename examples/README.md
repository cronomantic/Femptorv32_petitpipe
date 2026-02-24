# SoC Integration Examples

This directory contains reference implementations for integrating FemtoRV32 PetitPipe into complete System-on-Chip designs.

## Contents

### soc_examples.v

Complete, synthesizable Verilog examples including:

#### 1. `soc_dual_port_controller`
A Wishbone B4-compatible memory controller with separate instruction and data ports.

**Features**:
- Dual-port SRAM (instruction + data address spaces)
- Configurable address width (16 bits = 64KB default)
- Pipelined read response (1-cycle latency by default)
- Byte-selectable write support (dwb_sel[3:0])
- Optional initialization from hex file

**Parameters**:
```verilog
soc_dual_port_controller #(
    .ADDR_WIDTH(16),         // 64KB address space each
    .word_addr_width(14),    // Derived from ADDR_WIDTH
    .INIT_FILE(""),          // Optional: program.hex
    .LATENCY(1)              // 1-cycle SRAM latency
) mem_ctrl (...)
```

**Usage**:
```verilog
soc_dual_port_controller mem_ctrl (
    .clk(sys_clk),
    .rst(sys_rst),
    
    // Instruction bus
    .iwb_cyc(iwb_cyc),
    .iwb_stb(iwb_stb),
    .iwb_adr(iwb_adr[13:0]),      // 14-bit word address
    .iwb_cti(iwb_cti),             // Burst indicator
    .iwb_ack(iwb_ack),
    .iwb_dat_o(iwb_dat_o),
    
    // Data bus
    .dwb_cyc(dwb_cyc),
    .dwb_stb(dwb_stb),
    .dwb_we(dwb_we),
    .dwb_sel(dwb_sel),
    .dwb_adr(dwb_adr[13:0]),
    .dwb_dat_i(dwb_dat_i),
    .dwb_ack(dwb_ack),
    .dwb_dat_o(dwb_dat_o),
    
    // Optional debug port
    .dbg_adr(debug_addr),
    .dbg_dat_o(debug_data)
);
```

**Performance**:
- LATENCY=1: Achieves 0.8-1.0 IPC on sequential code
- Hit rate: 80-95% (4-word cache line prefetch)

---

#### 2. `soc_simple_arbiter`
Priority-based bus arbiter for shared-port memory configurations.

**Purpose**: When I and D memory share a single port, this arbiter multiplexes requests with strict I-bus priority (prefetch is time-critical).

**Features**:
- Fixed I-bus priority (i_wins = iwb_cyc && iwb_stb)
- D-bus lower priority (d_wins = dwb_cyc && dwb_stb && !iwb_cyc)
- Multiplexes address, data, control signals
- Feedback: ACK routed to winner only

**Usage**:
```verilog
soc_simple_arbiter arbiter (
    .clk(clk),
    .rst(rst),
    
    // I-bus request (pipelined)
    .iwb_cyc(iwb_cyc),
    .iwb_stb(iwb_stb),
    .iwb_adr(iwb_adr),
    .iwb_cti(iwb_cti),
    .iwb_ack(iwb_ack),
    .iwb_dat(iwb_dat),
    
    // D-bus request (classic, lower priority)
    .dwb_cyc(dwb_cyc),
    .dwb_stb(dwb_stb),
    .dwb_we(dwb_we),
    .dwb_adr(dwb_adr),
    .dwb_sel(dwb_sel),
    .dwb_wdat(dwb_wdat),
    .dwb_ack(dwb_ack),
    .dwb_rdat(dwb_rdat),
    
    // Shared memory interface
    .mem_cyc(mem_cyc),
    .mem_stb(mem_stb),
    .mem_we(mem_we),
    .mem_adr(mem_adr),
    .mem_sel(mem_sel),
    .mem_wdat(mem_wdat),
    .mem_ack(mem_ack),
    .mem_rdat(mem_rdat)
);
```

**Trade-offs**:
- **Pro**: Memory area savings (single port instead of dual)
- **Con**: Peak D-bus throughput reduced during I-bus activity

**Typical Impact**: 5-10% IPC reduction under heavy memory load.

---

#### 3. `soc_top`
Complete, integrated SoC combining core + dual-port controller.

**Features**:
- FemtoRV32_PetitPipe_WB core instance
- Dual-port memory controller
- 16KB instruction + 8KB data memory
- Interrupt support (8 lines, ext_irq[7:0])
- Optional debug port

**Module Definition**:
```verilog
module soc_top #(
    parameter IMEM_SIZE = 16'h4000,  // 16KB instruction
    parameter DMEM_SIZE = 16'h2000   // 8KB data
) (
    input clk,
    input rst,           // Active HIGH reset
    input [7:0] ext_irq, // External interrupts
    
    // Debug interface (optional)
    input  [31:0] dbg_addr,
    output [31:0] dbg_rdata,
    input  [31:0] dbg_wdata,
    input         dbg_we
);
```

**Instantiation**:
```verilog
soc_top #(
    .IMEM_SIZE(16'h4000),   // 16KB
    .DMEM_SIZE(16'h2000)    // 8KB
) my_soc (
    .clk(sys_clk),
    .rst(!sys_rst_n),       // Negate external active-LOW reset
    .ext_irq(interrupt_lines),
    .dbg_addr(jtag_addr),
    .dbg_rdata(jtag_rdata),
    .dbg_wdata(jtag_wdata),
    .dbg_we(jtag_we)
);

// Load program before simulation
initial $readmemh("firmware.hex", my_soc.mem_ctrl.imem);
```

---

## Using These Examples

### Option 1: Use as Testbench Template

Copy `soc_top` as starting point for your SoC simulation:

```bash
# Instantiate in your testbench
cp examples/soc_examples.v tb/tb_my_soc.v

# Edit tb/tb_my_soc.v:
# 1. Add clock/reset generation
# 2. Load your program hex file
# 3. Add stimulus/assertions
# 4. Define test timeline
```

### Option 2: Synthesize for FPGA/ASIC

The examples are fully synthesizable:

```bash
# Xilinx
synth_design -top soc_top -part xc7a100tcsg324-1

# Altera/Intel  
qsys soc_top.qsys

# Generic synthesis
yosys> read_verilog examples/soc_examples.v
yosys> synth_xilinx -top soc_top
```

### Option 3: Expand with Peripherals

Use as foundation for adding peripherals:

```verilog
// Extend soc_top with UART, timer, GPIO
module soc_top_extended (
    input clk, rst,
    input [7:0] ext_irq,
    
    // Add peripheral ports here
    input uart_rx,
    output uart_tx,
    input [7:0] gpio_in,
    output [7:0] gpio_out
);
    // Core + memory
    FemtoRV32_PetitPipe_WB core (...)
    soc_dual_port_controller mem_ctrl (...)
    
    // Address decoder
    wire uart_sel = (dwb_adr[31:16] == 16'h2000);
    wire gpio_sel = (dwb_adr[31:16] == 16'h3000);
    // ... etc
    
    // Instantiate peripherals
    uart_controller uart (
        .clk(clk), .rst(rst),
        .sel(uart_sel && dwb_cyc && dwb_stb),
        .we(dwb_we),
        .ack(uart_ack),
        // ... connections
    );
endmodule
```

---

## Performance Verification

### Simulation Measurement

```bash
# Run soc_top in testbench
wsl make sim-wb 2>&1 | tail -20

# Expected output
Cache line fills completed: 24
Total instruction bus beats (CTI=010/111): 87
Data bus transactions (reads/writes): 20
[PIPELINED CORE WITH INSTRUCTION CACHE FUNCTIONAL]
```

### Analysis

```bash
# Extract performance metrics
python3 scripts/analyze_performance.py build/results/tb_femtorv32_wb.log

# Should show
IPC: 0.65-0.95 (depends on code)
Cache Hit Rate: 75-95%
I-Bus Utilization: 50-80%
```

---

## Memory Configuration

### Default Configuration
```
Start Address: 0x00000000
I-Memory:      0x00000000 - 0x00003FFF (16KB)
D-Memory:      0x00000000 - 0x00001FFF (8KB)
Total:         24KB on-chip SRAM
```

All buses 30-bit (bits [31:2] used as word address).

### Modifying Sizes

For smaller embedded systems:

```verilog
soc_dual_port_controller #(
    .ADDR_WIDTH(14)      // 16KB total (8KB I + 8KB D)
) mem_ctrl (...)
```

For larger systems:

```verilog
soc_dual_port_controller #(
    .ADDR_WIDTH(18)      // 256KB total (128KB I + 128KB D)
) mem_ctrl (...)
```

---

## Address Decoding for Peripherals

If adding memory-mapped peripherals, use address mapping:

```
0x_0000_0000 - 0x_0000_3FFF   Instruction RAM (16KB)
0x_1000_0000 - 0x_1000_1FFF   Data RAM (8KB)
0x_2000_0000 - 0x_2000_0003   UART
0x_3000_0000 - 0x_3000_0007   Timer
0x_4000_0000 - 0x_4000_00FF   GPIO
```

### Adding Decoder

```verilog
// In soc_top_extended
wire imem_sel  = (iwb_adr[31:14] == 18'h0);
wire dmem_sel  = (dwb_adr[31:13] == 19'h10000);
wire uart_sel  = (dwb_adr[31:2]  == 30'h800000);
wire timer_sel = (dwb_adr[31:3]  == 29'hc00000);

// Mux responses
assign iwb_ack = imem_sel ? imem_ack : 1'b0;
assign dwb_ack = dmem_sel  ? dmem_ack  :
                 uart_sel  ? uart_ack  :
                 timer_sel ? timer_ack : 1'b0;

assign iwb_dat_i = imem_dat;
assign dwb_dat_i = dmem_sel  ? dmem_dat  :
                   uart_sel  ? uart_dat  :
                   timer_sel ? timer_dat : 32'h0;
```

---

## Debugging Tips

### Signals to Monitor (in gtkwave VCD)
```
clk                         Main clock
rst                         Reset signal
iwb_cyc, iwb_stb, iwb_ack  Instruction bus handshake
iwb_adr, iwb_cti, iwb_dat  Instruction address, burst type, data
dwb_cyc, dwb_stb, dwb_ack  Data bus handshake
dwb_we, dwb_sel            Write enable, byte select
core_pc                    Program counter progression
```

### Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Core stuck at PC=0 | No reset release | Check reset LOW deassert timing |
| Bus never responds | Address mismatch | Verify address masking in decoder |
| Garbage in output | Uninitialized memory | Load .hex file with $readmemh |
| Slow execution | High latency | Reduce LATENCY parameter |

---

## Integration Workflow

1. **Start with `soc_top`** - Minimal verified SoC
2. **Simulate with real program** - Load your hex file
3. **Add protocol checkers** - Verify Wishbone compliance
4. **Profile performance** - Run analyze_performance.py
5. **Add peripherals** - Extend with UART, GPIO, timer
6. **Synthesize** - Target FPGA or ASIC
7. **Hardware verify** - Compare silicon vs simulation

---

## References

- Complete integration guide: [docs/SOC_INTEGRATION.md](../docs/SOC_INTEGRATION.md)
- Wishbone specification: [docs/WISHBONE_INTERFACE.md](../docs/WISHBONE_INTERFACE.md)
- Performance analysis: [docs/PERFORMANCE_METRICS.md](../docs/PERFORMANCE_METRICS.md)
- CSR reference: [docs/CSR_REFERENCE.md](../docs/CSR_REFERENCE.md)
