# Validation & Protocol Checking

This directory contains verification infrastructure for ensuring FemtoRV32 PetitPipe SoC designs are correct and compliant.

## Contents

### protocol_checkers.v

Industrial-strength compliance and correctness checkers for Wishbone B4 and cache protocols.

#### 1. `wishbone_protocol_checker`

Verifies Wishbone B4 protocol compliance for individual bus interfaces (I-bus or D-bus).

**Checks Performed**:
1. **Signal Sequencing**
   - CYC must not be HIGH unless STB follows
   - STB must not be HIGH unless CYC is HIGH
   - ACK must only assert during transaction
   
2. **Burst Protocol** (pipelined I-bus)
   - CTI codes must be valid (000, 010, 111 only)
   - CTI sequence: 010 → 010 → ... → 111 (no breaks)
   - No mixed CTI codes in same burst
   
3. **Data/Address Stability**
   - Address must remain stable while STB HIGH and ACK LOW
   - Write data must remain stable
   - Byte select must not change mid-transaction
   
4. **Transaction Termination**
   - CYC must not drop before ACK asserts
   - Clean handoff between transactions

**Instantiation**:
```verilog
wishbone_protocol_checker chk_i (
    .clk(clk),
    .rst(rst),
    
    // I-bus signals
    .cyc(iwb_cyc),
    .stb(iwb_stb),
    .we(1'b0),              // I-bus read-only
    .ack(iwb_ack),
    .cti(iwb_cti),          // Important for I-bus
    .sel(4'b1111),
    .addr(iwb_adr),
    .data_i(iwb_dat_i),
    .data_o(32'h0),
    
    .bus_type(4'h0),        // 0 = pipelined I-bus
    
    .protocol_error(i_error),
    .error_msg(i_error_msg)
);

// Assert on error
always @(posedge i_error) begin
    $error("I-BUS PROTOCOL ERROR: %s", i_error_msg);
    $finish;
end
```

**Error Messages**:
- "CYC high without STB (classic protocol)"
- "STB high without CYC"
- "Invalid CTI code: XXX"
- "Address changed during transaction: ... → ..."
- "Write data changed during transaction"
- "CYC terminated before ACK"

---

#### 2. `cache_protocol_checker`

Validates correct instruction cache burst sequences for the prefetch subsystem.

**Checks Performed**:
1. **Burst Sequencing**
   - CTI=010 followed by sequential address increments
   - CTI=111 terminates burst correctly
   
2. **Cache Line Alignment**
   - All 4-word bursts must be naturally aligned
   - Previous address + N must equal current address
   
3. **Burst Timeout Detection**
   - If CTI=010 stays HIGH for >100 cycles without CTI=111, error
   - Prevents deadlock on stalled prefetch
   
4. **Burst Completeness**
   - Expects 4 words per cache line (configurable)
   - Warns if short burst completes early

**Instantiation**:
```verilog
cache_protocol_checker cache_chk (
    .clk(clk),
    .rst(rst),
    
    .iwb_stb(iwb_cyc && iwb_stb),
    .iwb_ack(iwb_ack),
    .iwb_cti(iwb_cti),
    .iwb_addr(iwb_adr),     // Word-aligned address
    
    .cache_error(cache_error),
    .error_msg(cache_error_msg)
);

always @(posedge cache_error) begin
    $error("CACHE ERROR: %s", cache_error_msg);
end
```

**Error Messages**:
- "Cache burst timeout (CTI=010 for >100 cycles)"
- "Non-sequential cache burst address: ... != ..."
- "Cache burst exceeded 4 words without CTI=111"
- "Classic CTI=000 received during burst"

**Warnings**:
- "Short burst completed: N words" (less than 4)

---

#### 3. `interrupt_protocol_checker`

Ensures interrupt handling meets RISC-V specification requirements.

**Checks Performed**:
1. **mcause Integrity**
   - mcause[31] bits indicates interrupt (vs exception)
   - mcause[3:0] contains valid IRQ code (0-7)
   - mcause[31] remains HIGH during interrupt service
   
2. **Interrupt Nesting Prevention**
   - mcause lock: cannot change while service in progress
   - Enforces mutual exclusion (no re-entrant interrupts)
   
3. **Interrupt Acknowledge Timing**
   - irq_ack only asserts when interrupt active
   - Proper CSR synchronization
   
4. **ISR State Machine**
   - Tracks interrupt entry/exit per CSR writes

**Instantiation**:
```verilog
interrupt_protocol_checker irq_chk (
    .clk(clk),
    .rst(rst),
    
    .irq(ext_irq),          // Input interrupt requests
    .irq_ack(core_irq_ack),
    
    .mcause(core_mcause),
    .mepc(core_mepc),
    .mstatus(core_mstatus),
    
    .irq_error(irq_error),
    .error_msg(irq_error_msg)
);

always @(posedge irq_error) begin
    $error("INTERRUPT ERROR: %s", irq_error_msg);
end
```

**Error Messages**:
- "Invalid mcause IRQ code: X"
- "mcause changed during interrupt service (nested interrupt not allowed)"
- "IRQ acknowledge without active interrupt"

---

## Integration in Testbench

### Checker Instantiation Pattern

```verilog
module tb_with_validation (
);
    // ... clock, reset, DUT ...
    
    // Declare error signals
    wire proto_i_error, proto_d_error;
    wire cache_error, irq_error;
    wire [127:0] proto_i_msg, proto_d_msg, cache_msg, irq_msg;
    
    // Instantiate checkers
    wishbone_protocol_checker chk_i (
        .clk(clk), .rst(rst),
        .cyc(iwb_cyc), .stb(iwb_stb), .we(1'b0), .ack(iwb_ack),
        .cti(iwb_cti), .sel(4'b1111), .addr(iwb_adr),
        .data_i(iwb_dat_i), .data_o(32'h0),
        .bus_type(4'h0),
        .protocol_error(proto_i_error),
        .error_msg(proto_i_msg)
    );
    
    wishbone_protocol_checker chk_d (
        .clk(clk), .rst(rst),
        .cyc(dwb_cyc), .stb(dwb_stb), .we(dwb_we), .ack(dwb_ack),
        .cti(3'b000), .sel(dwb_sel), .addr(dwb_adr),
        .data_i(dwb_dat_i), .data_o(dwb_dat_o),
        .bus_type(4'h1),
        .protocol_error(proto_d_error),
        .error_msg(proto_d_msg)
    );
    
    cache_protocol_checker cache_chk (
        .clk(clk), .rst(rst),
        .iwb_stb(iwb_cyc && iwb_stb), .iwb_ack(iwb_ack),
        .iwb_cti(iwb_cti), .iwb_addr(iwb_adr),
        .cache_error(cache_error), .error_msg(cache_msg)
    );
    
    interrupt_protocol_checker irq_chk (
        .clk(clk), .rst(rst),
        .irq(ext_irq), .irq_ack(core_irq_ack),
        .mcause(core_mcause), .mepc(core_mepc), .mstatus(core_mstatus),
        .irq_error(irq_error), .error_msg(irq_msg)
    );
    
    // Assert on any error
    always @(posedge clk) begin
        if (proto_i_error) $error("I-BUS: %s", proto_i_msg);
        if (proto_d_error) $error("D-BUS: %s", proto_d_msg);
        if (cache_error)   $error("CACHE: %s", cache_msg);
        if (irq_error)     $error("IRQ:   %s", irq_msg);
    end
    
    // Run test
    initial begin
        // ... stimulus ...
    end
endmodule
```

### Running with Validation

```bash
# Compile with checkers (Verilator)
verilator --cc --exe --build --timing --trace -Wall -Wno-fatal \
    --top-module tb_femtorv32_wb --Mdir build/sim/obj_tb_femtorv32_wb \
    -CFLAGS "-DVM_TOP=Vtb_femtorv32_wb -DVM_TOP_HEADER=\\\"Vtb_femtorv32_wb.h\\\"" \
    -I tb -o build/sim_validated \
    rtl/femtorv32_petitpipe.v rtl/perf_monitor.v \
    validation/protocol_checkers.v examples/soc_examples.v \
    tb/tb_femtorv32_wb.v tb/sim_main.cpp

# Run - will report errors
./build/sim_validated 2>&1 | grep -E "ERROR|WARNING"
```

---

## Validation Scenarios

### Scenario 1: Clean Wishbone Protocol

**Setup**: Correct memory controller responding to all buses

**Expected**:
```
Run complete: No protocol errors
✓ All transactions complete properly
✓ ACK timing within spec
✓ Byte selects valid
```

### Scenario 2: Burst Protocol Violation

**Setup**: Memory raises ACK out of sequence

```verilog
// Bad: Skips burst end marker
if (iwb_cti == 3'b010) begin
    iwb_ack <= 1'b0;  // ERROR: Don't ACK continue
end
```

**Result**:
```
ERROR: I-BUS PROTOCOL VIOLATION: CYC high without STB
ERROR: CACHE ERROR: Cache burst timeout (CTI=010 for >100 cycles)
```

### Scenario 3: Address Change Mid-Transaction

**Setup**: Address changes after STB asserts

```verilog
// Bad: Address instability
always @(posedge clk) begin
    if (iwb_stb) iwb_adr <= $random;  // ERROR
end
```

**Result**:
```
ERROR: WISHBONE PROTOCOL VIOLATION: Address changed during transaction
```

### Scenario 4: Interrupt Nesting

**Setup**: IRQ arrives before previous ISR completes

```verilog
// Bad: mcause changes during interrupt service
always @(posedge clk) begin
    if (new_irq_request && irq_active)
        mcause <= {1'b1, new_irq_code};  // ERROR: nested not allowed
end
```

**Result**:
```
ERROR: INTERRUPT ERROR: mcause changed during interrupt service
```

---

## Performance Monitoring Integration

For cycle-accurate statistics with validation:

```verilog
// Add performance monitor alongside checkers
perf_monitor perf (
    .clk(clk), .rst(rst),
    .iwb_stb(iwb_cyc && iwb_stb), .iwb_ack(iwb_ack),
    .iwb_cti(iwb_cti),
    .dwb_stb(dwb_cyc && dwb_stb), .dwb_ack(dwb_ack),
    .core_stall(core_stall),
    .core_pc(core_pc),
    
    .cycle_count(total_cycles),
    .icache_line_fills(cache_fills),
    .icache_beats_count(i_beats),
    .dbus_transactions(d_trans),
    .stall_cycles(stalls),
    .burst_fills_completed(burst_fills)
);

// At end of test, dump results
initial begin
    #10_000_000;
    $display("[PERF] Cycles: %d", total_cycles);
    $display("[PERF] Cache Fills: %d", cache_fills);
    $display("[PERF] IPC: %.2f", (100 / total_cycles));
    $finish;
end
```

---

## Recommended Validation Flow

1. **Protocol Compliance** (continuous)
   - Run wishbone_protocol_checker on all buses
   - Monitor for any violations
   - Use as gating for test completion

2. **Burst Correctness** (cache-specific)
   - cache_protocol_checker detects malformed bursts
   - Catches prefetch deadlocks early
   - Validates CTI sequence state machine

3. **Interrupt Safety** (ISR validation)
   - interrupt_protocol_checker prevents nesting bugs
   - Ensures mcause integrity during ISR
   - Validates nested exception handling (advanced)

4. **Performance Analysis** (post-simulation)
   - Extract IPC, cache hit rate from perf_monitor
   - Compare against baseline metrics
   - Identify optimization opportunities

---

## Extending Validators

### Custom Checker Template

```verilog
module my_custom_checker (
    input clk,
    input rst,
    
    // Observed signals
    input [31:0] signal_a,
    input [31:0] signal_b,
    
    output reg my_error,
    output reg [127:0] my_error_msg
);
    
    reg [31:0] signal_a_prev;
    
    always @(posedge clk) begin
        if (rst) begin
            my_error <= 1'b0;
        end else begin
            // Your check logic
            if (signal_a != signal_a_prev && signal_a > 1000) begin
                my_error <= 1'b1;
                my_error_msg <= "Custom error detected";
            end
            signal_a_prev <= signal_a;
        end
    end

endmodule
```

### Added to Testbench

```verilog
my_custom_checker my_chk (
    .clk(clk), .rst(rst),
    .signal_a(some_signal),
    .signal_b(other_signal),
    .my_error(custom_error),
    .my_error_msg(custom_msg)
);

always @(posedge custom_error) begin
    $error("CUSTOM: %s", custom_msg);
end
```

---

## References

- Wishbone B4 spec details: [docs/WISHBONE_INTERFACE.md](../docs/WISHBONE_INTERFACE.md)
- RISC-V interrupt spec: [docs/CSR_REFERENCE.md](../docs/CSR_REFERENCE.md)
- Performance monitoring: [docs/PERFORMANCE_METRICS.md](../docs/PERFORMANCE_METRICS.md)
- RTL performance monitor: [rtl/perf_monitor.v](../rtl/perf_monitor.v)

---

## Quick Validation Checklist

- [ ] All testbenches compile with protocol_checkers.v
- [ ] No protocol errors on baseline test (tb_femtorv32_wb.v)
- [ ] Performance metrics within expected range
- [ ] Cache burst sequences complete properly
- [ ] Interrupt handler reaches mtvec address
- [ ] mcause lock prevents nesting (if tested)
- [ ] Stall cycle breakdown makes sense
- [ ] Byte selects valid on all writes
