# Performance Analysis Guide

## Overview

This document describes how to measure and analyze performance metrics for FemtoRV32 PetitPipe in simulation and integrated SoC environments.

## Key Performance Metrics

### 1. Instructions Per Cycle (IPC)

**Definition**: Average number of instructions completed per clock cycle.

**Range**: 0.4 - 1.0 (pipelined, 2-stage IF/EX)
- Theoretical max = 1.0 (one instruction per cycle)
- Practical limit = 0.6-0.8 due to:
  - Cache misses (instruction prefetch stalls)
  - Load-use hazards
  - Branch misprediction (partially mitigated by cache)

**Measurement**: 
```python
IPC = instruction_count / total_cycles
```

**In simulation: use `analyze_performance.py`**
```bash
python3 scripts/analyze_performance.py build/results/tb_femtorv32_wb.log
```

### 2. Cache Hit Rate

**Definition**: Percentage of instruction fetches that hit the cache line.

**Target**: > 80% for sequential code
- 4-word (16-byte) cache line
- Prefetch from miss address + 1, 2, 3
- Sequential code: expect 75-90% hit rate
- Tight loops: expect 95%+ hit rate

**Calculation**:
```
Cache Hits = (Total Fetch Cycles - Fill Overhead) / Total Cycles × 100%
Fill Overhead = (Line Fills × Burst Latency) per fill
```

**Monitoring in Testbench**:
```verilog
// In tb_femtorv32_wb.v or wrapper
@(posedge clk) begin
    if (iwb_stb && iwb_ack && iwb_cti == 3'b111) begin
        cache_fills++;  // End of 4-word burst
    end
end
```

### 3. Memory Bus Utilization

#### Instruction Bus (Pipelined)
- **Metrics**:
  - Total beats (ACK pulses)
  - Burst efficiency (beats per fill / 4)
  - Idle cycles

- **Target**: 60-80% utilization
  - Sequential code: 70-80% (good cache)
  - Jump-heavy: 40-60% (more cache misses)

#### Data Bus (Classic)
- **Metrics**:
  - Load/Store transaction count
  - Read/Write ratio

- **Target**: Varies by workload
  - Integer workload: 10-30% utilization
  - Memory-intensive: 40-60%

### 4. Stall Cycle Breakdown

**Sources**:
1. **Load-Use Stall**: Register needed by next instruction still loading
   - Detection: load in cycle N, dependent op in cycle N+1
   - Cost: 1 cycle minimum (can cascade)

2. **Cache Miss Stall**: Core waiting for instruction prefetch
   - Detection: dwb_cyc high, but no progress
   - Cost: 3-4 cycles per miss (variable latency)

3. **Memory Conflict**: Both I-bus and D-bus accessing memory simultaneously
   - Cost: 1-2 cycles (depends on arbitration priority)

**Measurement** (using `perf_monitor.v`):
```verilog
always @(posedge clk) begin
    if (core_stall)
        stall_cycles++;
end

IPC_actual = (total_cycles - stall_cycles) / total_cycles;
```

## Benchmarking Methodology

### Quick Test (5-10 seconds)
```bash
# Run basic testbench, extract summary
wsl make sim-wb 2>&1 | grep -E "(fills|beats|transactions|FUNCTIONAL)"
```

**Expected Output**:
```
Cache line fills completed: 24
Total instruction bus beats (CTI=010/111): 87
Data bus transactions (reads/writes): 20
[PIPELINED CORE WITH INSTRUCTION CACHE FUNCTIONAL]
```

### Full Profiling Session (1-2 minutes)

1. **Run simulation with comprehensive logging**:
   ```bash
   wsl make sim-wb > build/results/tb_femtorv32_wb.log 2>&1
   ```

2. **Analyze results**:
   ```bash
   python3 scripts/analyze_performance.py build/results/tb_femtorv32_wb.log
   ```

3. **Review recommendations** in output:
   ```
   📈 Calculated Performance:
     Instructions Per Cycle:    0.65 (estimated)
     Cache Hit Rate:            78.5% (estimated)
     I-Bus Utilization:         74.3%
     D-Bus Utilization:         12.1%
   ```

### VCD Waveform Analysis

For detailed cycle-by-cycle analysis:

1. **Generate VCD in testbench**:
   ```verilog
   initial begin
       $dumpfile("build/waves/tb_femtorv32_wb.vcd");
       $dumpvars(0, tb_femtorv32_wb);
   end
   ```

2. **Open in waveform viewer** (if gtkwave available):
   ```bash
   gtkwave build/waves/tb_femtorv32_wb.vcd
   ```

3. **Key signals to observe**:
   - `iwb_stb`, `iwb_ack`, `iwb_cti` - Instruction prefetch progress
   - `dwb_stb`, `dwb_ack`, `dwb_we` - Data transaction timing
   - `core_pc` - Program counter (look for stalls visible as PC hold)

## Performance Monitor Module

### Integration

Add `perf_monitor.v` to your SoC for cycle-accurate statistics:

```verilog
perf_monitor perf (
    .clk(clk),
    .rst(!rst),
    
    .iwb_stb(iwb_cyc && iwb_stb),
    .iwb_ack(iwb_ack),
    .iwb_cyc(iwb_cyc),
    .iwb_cti(iwb_cti),
    
    .dwb_stb(dwb_cyc && dwb_stb),
    .dwb_ack(dwb_ack),
    
    .core_stall(core_stall_signal),
    .core_pc(core_pc),
    
    .cycle_count(perf_cycles),
    .icache_line_fills(perf_icache_fills),
    .icache_beats_count(perf_icache_beats),
    .dbus_transactions(perf_dbus_trans),
    .stall_cycles(perf_stalls),
    .burst_fills_completed(perf_bursts)
);
```

### Reading Counters

At test completion, dump statistics:

```verilog
// In testbench
$display("[PERF] Cycle Count: %d", perf_cycles);
$display("[PERF] I-Cache Fills: %d", perf_icache_fills);
$display("[PERF] Burst Efficiency: %.1f%%", 
         (perf_icache_beats * 100.0) / (perf_icache_fills * 4));
```

## SoC Integration Performance Considerations

### Memory Timing

**Single-cycle latency (RECOMMENDED)**:
- Memory responds with ACK same cycle as STB
- Allows 1.0 IPC in best case
- Realistic for on-chip SRAM

**Two-cycle latency**:
- Memory responds with 1-cycle delay
- Reduces peak IPC to ~0.8
- Typical for cache-backed external memory

**Multi-cycle latency** (variable):
- Use LFSR in controller to simulate real systems
- Expect IPC 0.4-0.6 depending on hit rate

### Arbitration Impact

**Shared I/D Memory (split with arbiter)**:
- I-bus priority typically reduces D-bus peak throughput
- Minimal impact on IPC (prefetch asynchronous to execution)
- Recommend: I-bus > D-bus priority (prefetch time-critical)

**Separate I/D Memory** (this design):
- No arbitration needed
- Peak performance: both buses simultaneously active
- Board area cost: 2× memory (16KB I + 8KB D typical)

## Optimization Strategies

### To Improve Cache Hit Rate
1. Increase cache line size (currently 4 words)
   - Trade: more memory, higher prefetch latency on miss
   
2. Implement prefetch-on-branch
   - Requres: branch target buffer (not in PetitPipe)
   
3. Use branch-less code patterns
   - Leverage predication, ternary ops in compiler

### To Reduce Load-Use Stalls
1. **Compiler optimization**: Schedule independent instructions between load and use
   - Example: delay consumer of load by 2+ cycles
   
2. **Hardware**: Implement load-use bypass path
   - Forward result to ALU before register file write
   - Not in current 2-stage pipeline (would need 3-stage)

### To Improve Overall Performance
1. Monitor and eliminate busy-waiting loops
   - Use timer interrupts instead of polling

2. Profile with real workloads
   - Benchmark-specific optimizations (cache prefetch width, frequency)

3. Consider frequency scaling
   - IPC is independent of clock; raising clock frequency improves throughput
   - Power trade-off: P ∝ f

## Testing and Validation

### Regression Test
```bash
# Compare performance against baseline
wsl make sim-wb > current.log
diff -u baseline.log current.log
```

### Performance Target Validation
```python
# Simple Python script to validate targets
import re

with open('build/results/tb_femtorv32_wb.log') as f:
    content = f.read()
    
fills = int(re.search(r'Cache line fills: (\d+)', content).group(1))
beats = int(re.search(r'bus beats: (\d+)', content).group(1))

icache_eff = beats / (fills * 4)
assert icache_eff > 0.75, f"Cache efficiency too low: {icache_eff:.1%}"
```

## Reference Measurements

### Sequential Code (tight loop)
```
Cycles:     1000
I-Cache Fills:  4
IPC:        0.95
Cache Hit:  97%
D-Bus:      2% (stack ops only)
Assessment: Excellent pipeline utilization
```

### Mixed Code (branches, stores)
```
Cycles:     1000
I-Cache Fills:  12
IPC:        0.72
Cache Hit:  85%
D-Bus:      18%
Assessment: Good performance, some pipeline stalls
```

### Memory-Intensive (heavy loads)
```
Cycles:     1000
I-Cache Fills:  8
IPC:        0.55
Cache Hit:  78%
D-Bus:      45%
Assessment: Load-use stalls dominating, cache adequate
```

## Next Steps

1. **Profiling your specific code**:
   - Compile your program to `build/test.hex`
   - Update testbench to load your hex file
   - Run analysis and compare to reference benchmarks

2. **Hardware implementation validation**:
   - Synthesize to FPGA (Xilinx/Altera/ECP5)
   - Use on-chip logic analyzer or ChipScope to profile
   - Compare to simulation metrics

3. **Performance targets for your SoC**:
   - Define acceptable IPC range for your workload
   - Establish cache hit rate minimum
   - Monitor in continuous integration

---

## Cross-Core Performance Comparison

A dedicated testbench `tb/tb_perf_compare.v` runs the same hex program on both
`FemtoRV32_PetitPipe_WB` and `FemtoRV32_Gracilis_WB` simultaneously and reports
the cycle count for each.

```
make perf-compare-<test>
# or
vvp build/sim/tb_perf_compare +hex_file=<path> +test_name=<name>
```

### Example results (3-instruction ALU loop, zero-wait-state Wishbone)

| Loop iters | PetitPipe cycles | Gracilis cycles | PP speedup |
|:----------:|:----------------:|:---------------:|:----------:|
|          1 |               19 |              20 |     1.05x  |
|          5 |               47 |              56 |     1.19x  |
|         10 |               82 |             101 |     1.23x  |
|         50 |              362 |             461 |     1.27x  |
|        100 |              712 |             911 |     1.28x  |

PetitPipe's 4-word burst I-cache eliminates most refetch overhead once the loop
body fits within a single cache line.  Gracilis fetches every instruction
individually (no cache) so its cycle count scales linearly with iteration count.

### Architectural note

- **PetitPipe**: 2-stage pipeline, dual Wishbone buses (I-bus pipelined burst,
  D-bus classic), 4-word instruction prefetch cache.
- **Gracilis**: 4-state machine (FETCH\_INSTR → WAIT\_INSTR → EXECUTE →
  WAIT\_ALU\_OR\_MEM), single shared classic Wishbone bus, no instruction cache.

### I-bus testbench timing note

For correct burst simulation the PetitPipe I-bus slave must provide **combinatorial
read data** (wire, not registered) together with a 1-cycle registered ack.  If
data is registered from the same edge as the ack, the burst wrapper's buffer
index has already advanced, causing each word to land in the wrong cache slot.
`tb_perf_compare.v` uses a combinatorial `assign` for `pp_iwb_dat_i`.

