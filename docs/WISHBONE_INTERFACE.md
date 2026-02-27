# Wishbone Interface Specification

## Overview

FemtoRV32_PetitPipe_WB implements two independent Wishbone B4 buses (32-bit addresses):
- **Instruction Bus (iwb_*)**: Pipelined protocol with burst prefetch
- **Data Bus (dwb_*)**: Classic single-transaction protocol

---

## Instruction Wishbone Bus (Pipelined)

### Output Signals (Master → Slave)

| Signal | Width | Type | Description |
|--------|-------|------|-------------|
| `iwb_adr_o` | 32 | Out | Address (byte-aligned, word-addressing for internal use) |
| `iwb_dat_o` | 32 | Out | Data (always 0, read-only) |
| `iwb_sel_o` | 4 | Out | Byte select (always 4'b1111) |
| `iwb_we_o` | 1 | Out | Write enable (always 0, read-only) |
| `iwb_cyc_o` | 1 | Out | Cycle active during burst |
| `iwb_stb_o` | 1 | Out | Strobe (same as cyc_o) |
| `iwb_cti_o` | 3 | Out | Cycle Type Indicator |
| `iwb_bte_o` | 2 | Out | Burst Type Extension (always 2'b00, linear) |

### Input Signals (Slave → Master)

| Signal | Width | Type | Description |
|--------|-------|------|-------------|
| `iwb_dat_i` | 32 | In | Read data from slave |
| `iwb_ack_i` | 1 | In | Acknowledge (slave ready) |

### Burst Protocol (CTI Codes)

```verilog
iwb_cti_o == 3'b010  // INCR - Burst continue, next beat coming
iwb_cti_o == 3'b111  // END  - Burst end, this is final beat
```

**Timing Example** (4-word line fill):
```
Cycle: 0     1     2     3     4
cyc_o: 0 --1-----------1--0
stb_o: 0 --1-----------1--0
cti_o: X --010-010-010-111--X
ack_i: 0 -----1-----1-----1--0
adr_o: XX  A  A+1   A+2   A+3  XX
dat_i: XX  D0  D1   D2   D3  XX
```

### Performance Characteristics

- **Burst Length**: Configurable (default 4 words per line)
- **Prefetch Trigger**: On cache miss, entire line fetched in parallel
- **Latency**: 0-3 cycles per word (testbench varies for realism)
- **Max Throughput**: 1 word/cycle during burst
- **Idle**: No cycles wasted between bursts (pipelined ready)

---

## Data Wishbone Bus (Classic)

### Output Signals (Master → Slave)

| Signal | Width | Type | Description |
|--------|-------|------|-------------|
| `dwb_adr_o` | 32 | Out | Address (byte-addressed) |
| `dwb_dat_o` | 32 | Out | Write data |
| `dwb_sel_o` | 4 | Out | Byte select mask |
| `dwb_we_o` | 1 | Out | Write enable |
| `dwb_cyc_o` | 1 | Out | Cycle active |
| `dwb_stb_o` | 1 | Out | Strobe (same as cyc_o) |
| `dwb_cti_o` | 3 | Out | Cycle Type Indicator (always 3'b111 = END) |
| `dwb_bte_o` | 2 | Out | Burst Type Extension (always 2'b00) |

### Input Signals (Slave → Master)

| Signal | Width | Type | Description |
|--------|-------|------|-------------|
| `dwb_dat_i` | 32 | In | Read data from slave |
| `dwb_ack_i` | 1 | In | Acknowledge (transaction complete) |

### Classic Transaction Protocol

**Read (Load) Cycle**:
```
Cycle: 0     1     2
cyc_o: 0 --1-----1--0
stb_o: 0 --1-----1--0
we_o:  X --0-----0--X
ack_i: 0 -----1-----0
adr_o: XX  A     A  XX
sel_o: XX  F     F  XX
dat_i: XX  XX    D  XX
```

**Write (Store) Cycle**:
```
Cycle: 0     1     2
cyc_o: 0 --1-----1--0
stb_o: 0 --1-----1--0
we_o:  X --1-----1--X
ack_i: 0 -----1-----0
adr_o: XX  A     A  XX
sel_o: XX  M     M  XX
dat_o: XX  D     D  XX
```

### Byte Select (dwb_sel_o)

```
dwb_sel_o[0] = byte[7:0]   write enable
dwb_sel_o[1] = byte[15:8]  write enable
dwb_sel_o[2] = byte[23:16] write enable
dwb_sel_o[3] = byte[31:24] write enable
```

**Examples**:
```
Byte write at [1]:    sel=4'b0010
Halfword write at [0]: sel=4'b0011
Word write:           sel=4'b1111
```

### Performance Characteristics

- **Load Latency**: 1-N cycles (depends on slave)
- **Store Latency**: 1-N cycles (write-ack blocking)
- **No Bursting**: Each transaction independent
- **Max Throughput**: 1 word/cycle (if slave responds immediately)
- **Isolation**: Doesn't interfere with instruction prefetch

---

## Clock and Reset

| Signal | Type | Description |
|--------|------|-------------|
| `clk` | In | Main clock, all state updates on rising edge |
| `reset_n` | In | **Synchronous reset, active low** |
| `irq_i[7:0]` | In | Interrupt requests (8-level priority) |

### Reset Timing
```
reset_n: 1---0100...PCstarts driving instructionon 100...
         ^       ^^                         ^
    before rst   rstrst release (edges are synchronous)
```

---

## Integration Checklist

- [ ] Memory controller accepts both buses independently
- [ ] Data bus is **not** blocked by instruction prefetch
- [ ] Burst prefetch (CTI 010/111) supported or must insert wait states
- [ ] Both buses run on same clock
- [ ] Reset applied for ≥2 cycles before first instruction
- [ ] Interrupt lines stable (or synchronized if async source)

---

## FemtoRV32_Gracilis_WB — Single Wishbone Bus

`FemtoRV32_Gracilis_WB` uses a **single shared classic Wishbone bus** for both instruction fetch and data access. Because the gracilis state machine never issues an instruction fetch and a data access simultaneously, no arbitration is required.

### Interface

```
output [31:0]  wb_adr_o   // byte address (word-aligned)
output [31:0]  wb_dat_o   // write data
output  [3:0]  wb_sel_o   // byte enables
output         wb_we_o    // write enable
output         wb_cyc_o   // bus cycle
output         wb_stb_o   // strobe
output  [2:0]  wb_cti_o   // cycle type indicator (3'b111 = end of cycle)
output  [1:0]  wb_bte_o   // burst type extension (2'b00)
input  [31:0]  wb_dat_i   // read data
input          wb_ack_i   // acknowledge
```

### Protocol

Classic Wishbone (no burst). Each instruction fetch and each data access is a single transaction:
- `CTI = 3'b111` (end-of-cycle) on all transactions
- `BTE = 2'b00`
- Zero or more wait cycles permitted (ack may take multiple cycles)
- Instruction fetch and data access are mutually exclusive

### No Instruction Cache

Unlike `FemtoRV32_PetitPipe_WB`, the Gracilis core has **no instruction prefetch cache**. Every instruction is fetched from the bus individually. This simplifies the interface at the cost of higher fetch latency on memories with wait states.

