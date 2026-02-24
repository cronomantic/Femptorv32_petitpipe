# FemtoRV32 PetitPipe Documentation

## Quick Start

### Building and Testing
```bash
make compile       # Compile test programs
make tb-check      # Verify testbench syntax
make sim-wb        # Run Wishbone testbench with cache
```

### Test Results
- **Status**: ✅ PIPELINED CORE WITH INSTRUCTION CACHE FUNCTIONAL
- **Cache Statistics**: 24 line fills, 87 instruction bus beats, 20 data transactions
- **Coverage**: ALU ops, load/store, branches, interrupts, cache prefetch

---

## Architecture Overview

### Core Features
- **2-Stage Pipeline**: IF/EX with split I/D buses
- **ISA Support**: RV32IMC (base + M extension + compressed instructions)
- **Instruction Cache**: 4-word line prefetch on pipelined I-bus
- **Interrupts**: 8-priority encoder with CSR support
- **Performance**: Burst prefetch reduces fetch latency

### Bus Interfaces
- **Instruction Bus (iwb_*)**: Pipelined read with CTI burst codes
  - CTI 010 = burst continue
  - CTI 111 = burst end
- **Data Bus (dwb_*)**: Classic Wishbone single-transaction
  - Isolated from instruction traffic
  - Immediate write-ack

---

## Performance Metrics to Track

### Cache Efficiency
```
Cache Line Size:           4 words (configurable via IWB_BURST_LEN)
Typical Hit Rate:          > 80% on sequential code
Fill Latency:              Variable (0-3 cycles in testbench)
Burst Overhead:            ~4 cycles per line fill
```

### Pipeline Metrics
```
IPC (Instructions/Cycle):  0.8-1.0 (depends on cache/memory latency)
Stall Sources:
  - Cache miss:            ~4-7 cycles (burst prefetch)
  - Load-use hazard:       1 cycle (ALU bypass available)
  - Division:              Up to 32 cycles
```

### Memory Bus
```
Instruction Beats/Line:    4 (configurable)
Avg I-bus Utilization:     ~40% (with prefetch hits)
D-bus Utilization:         Data-dependent
Max Bandwidth:             32-bit/cycle both buses
```

---

## Integration Checklist

For SoC integration, you need:
- [ ] Memory controller with pipelined read support
- [ ] Interrupt controller connecting to `irq_i[7:0]`
- [ ] Arbiter for shared instruction/data memory
- [ ] Reset sequencer for synchronous `reset_n`
- [ ] Clock domain crossing (if multi-clock)

---

## Detailed References

See subdirectories:
- `docs/WISHBONE_INTERFACE.md` - Pin-by-pin specification
- `docs/CSR_REFERENCE.md` - Control/Status Register layout
- `docs/PARAMETERS.md` - Configuration options
