# CSR (Control/Status Registers) Reference

## Overview

Standard RISC-V machine-mode CSRs with additional cycle counter support.

---

## CSR Address Map

| CSR Name | Address | RW | Description |
|----------|---------|----|----|
| `mstatus` | 0x300 | RW | Machine status (interrupt enable) |
| `mtvec` | 0x305 | RW | Interrupt handler base address |
| `mepc` | 0x341 | RW | Saved PC for exception return |
| `mcause` | 0x342 | RW | Exception/interrupt cause |
| `cycles` | 0xC00 | RO | Cycle counter (lower 32 bits) |
| `cyclesh` | 0xC80 | RO | Cycle counter (upper 32 bits) |

---

## mstatus - Machine Status Register (0x300)

```
Field     | Bits | Reset | RW | Description
----------|------|-------|----|-----------
Reserved  | 31:4 |   0   | -  |
MIE       | 3    |   0   | RW | **Machine Interrupt Enable**
Reserved  | 2:0  |   0   | -  |

Full Width: 32 bits (read returns 0x000000X8 where X is MIE)
```

### Bit 3: MIE (Machine Interrupt Enable)

```verilog
// Reading
mie_bit = csr_read_mstatus[3];

// Writing
csrw mstatus, t0    // Write full value from t0[3]
csrrs mstatus, t0   // OR with t0 (set bits)
csrs mstatus, 8     // Set bit 3 (MIE = 1)
csrrc mstatus, t0   // AND NOT with t0 (clear bits)
csrc mstatus, 8     // Clear bit 3 (MIE = 0)
```

**Interrupt Behavior**:
- If MIE=0: Interrupts held pending, not serviced
- If MIE=1 AND irq_i asserted: Handler invoked on next cycle
- Handler automatically clears MIE (nested interrupts blocked)
- MRET restores MIE via mcause clear

---

## mtvec - Machine Trap Vector (0x305)

```
Field     | Bits | Reset | RW | Description
----------|------|-------|----|-----------
BASE      | 23:0 |   0   | RW | Handler base address
Reserved  | 31:24|   0   | -  |

Full Width: 32 bits (bits 31:24 ignored, user should zero)
```

### Usage

```c
// Set interrupt handler at 0x8000
li t0, 0x8000
csrw mtvec, t0

// Read handler address
csrr t1, mtvec    // t1 = 0x00008000
```

**Handler Invocation**:
```
PC jumps to: {mtvec[ADDR_WIDTH-1:0]}
At start of handler:
  - mepc contains PC of interrupted instruction
  - mcause contains interrupt code (bit 31=1 for interrupts)
```

---

## mepc - Machine Exception PC (0x341)

```
Field     | Bits | Reset | RW | Description
----------|------|-------|----|-----------
PC        | 23:0 |   0   | RW | Saved instruction address
Reserved  | 31:24|   0   | -  |
```

### Usage

```c
// Jump back to interrupted instruction
csrr t0, mepc
jalr x0, 0(t0)    // Implicit: PC = mepc, then execute MRET

// Or use MRET instruction
mret              // PC ← mepc, then clear mcause for next interrupt
```

**Auto-Saved On Interrupt**:
```verilog
// Automatic save (in hardware):
if (interrupt/*in* ex_fire) begin
    mepc <= PC_new;    // PC that would execute next
end
```

---

## mcause - Machine Cause Register (0x342)

```
Field       | Bits | Reset | RW | Description
------------|------|-------|----|-----------
Interrupt   | 31   |   X   | RW | 1 = interrupt, 0 = exception
Exception   | 30:0 |   X   | RW | Cause code
```

### Interrupt Flag (Bit 31)

```verilog
if (mcause[31]) begin  // Interrupt
    cause_code = mcause[3:0];  // Which IRQ line
end else begin         // Exception
    // (not implemented in P2)
end
```

### Cause Codes (For Interrupts)

```
irq_i[0] asserted  →  mcause = 0x80000000 (cause 0)
irq_i[1] asserted  →  mcause = 0x80000001 (cause 1)
irq_i[2] asserted  →  mcause = 0x80000002 (cause 2)
...
irq_i[7] asserted  →  mcause = 0x80000007 (cause 7)
```

### mcause Lock (Interrupt Nesting Prevention)

```verilog
if (mcause != 0) begin  // mcause_lock
    // Subsequent interrupts are held pending
    // Not registered until MRET clears mcause
end

// MRET clears mcause:
if (interrupt_return & ex_fire) begin
    mcause <= 32'b0;    // Next interrupt now eligible
end
```

**Typical Interrupt Handler Flow**:
```asm
; Handler entry (auto via mtvec)
; mcause = 0x80000000 | irq_num
; mepc = interrupted instruction

; Handle interrupt
...

; Return
mret  ; PC ← mepc, mcause ← 0, exit handler
```

---

## cycles / cyclesh - Cycle Counter (0xC00 / 0xC80)

### Combined 64-bit Counter

```
cycles[63:32]  ← Read via cyclesh CSR (0xC80)
cycles[31:0]   ← Read via cycles CSR (0xC00)
```

### Usage

```c
// Read lower 32 bits
uint32_t lo = read_csr(0xC00);

// Read upper 32 bits (may have incremented!)
uint32_t hi = read_csr(0xC80);

// Safe 64-bit read (re-try if overflow):
uint32_t hi1 = read_csr(0xC80);
uint32_t lo2 = read_csr(0xC00);
uint32_t hi2 = read_csr(0xC80);

// If hi1 != hi2: overflow occurred between reads,  retry
// Final value: {hi2, lo2}
```

### Counter Behavior

```verilog
// Increments every cycle
always @(posedge clk)
    cycles <= cycles + 1;

// Continues across interrupts (no freeze)
// Wraps at 64-bit overflow (no interrupt)
```

**Performance Measurement Example**:
```c
uint64_t start = read_cycles64();
critical_loop();
uint64_t end   = read_cycles64();
printf("Took %llu cycles\n", end - start);
```

---

## Read-Only Registers

| CSR | Access | Effect |
|-----|--------|--------|
| `cycles` | csrr | Returns lower 32 bits of cycle counter |
| `cyclesh` | csrr | Returns upper 32 bits of cycle counter |

**Write Attempts** (software attempted write):
- Ignored silently (RISC-V standard)
- No exception raised

---

## CSR Instruction Forms

```asm
# Read-modify-write patterns

csrw   reg_addr, rs1       # Write rs1 to CSR
csrr   rd, csr_addr        # Read CSR to rd
csrs   csr_addr, rs1       # Set bits: CSR |= rs1
csrc   csr_addr, rs1       # Clear bits: CSR &= ~rs1

# Immediate variants (ZIMM = 5-bit constant)
csrwi  csr_addr, zimm      # Write constant
csrrs  csr_addr, zimm      # Set constant bits
csrrci csr_addr, zimm      # Clear constant bits

# Example: Enable interrupts
csrrs mstatus, x0, 8       # Set bit 3 (MIE)

# Example: Set handler at 0x1000
li t0, 0x1000
csrw mtvec, t0
```

---

## Interrupt Handler Template

```c
// In startup (before main):
void setup_interrupts(void) {
    // Set handler address
    write_csr(mtvec, (uint32_t)&interrupt_handler);
    
    // Enable interrupts globally
    set_csr(mstatus, 8);  // MIE = 1
}

// Interrupt handler
void __attribute__((interrupt("machine"))) interrupt_handler(void) {
    uint32_t cause = read_csr(mcause);
    uint32_t irq_num = cause & 0x7F;
    
    switch (irq_num) {
        case 0: handle_irq_0(); break;
        case 1: handle_irq_1(); break;
        // ...
    }
    
    // Return (automatic via MRET by compiler)
}
```
