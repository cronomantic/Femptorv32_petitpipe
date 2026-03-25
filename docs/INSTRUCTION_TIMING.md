# Instruction Timing Reference

Per-instruction cycle counts for all three synthesisable cores in this repository.

## Cores Covered

| Core | File | Architecture |
|---|---|---|
| **PetitPipe** | `femtorv32_petitpipe.v` | 2-stage IF/EX pipeline, 4-word burst I-cache, split I/D buses |
| **Pipedream** | `femtorv32_pipedream.v` | 4-state FSM, exec-time prefetch, single shared bus |
| **Gracilis**  | `femtorv32_gracilis_wb.v` | 4-state FSM, no prefetch, single shared bus |

---

## Assumptions

All cycle counts below assume:

1. **Instruction cache hit** (PetitPipe only) — no I-bus refill penalty.
2. **Single-cycle memory latency** — Wishbone `ack` arrives one cycle after `stb` is asserted;
   `d_rbusy` / `d_wbusy` / `i_rbusy` deassert after that single cycle.
3. **No pending interrupt** at the time of execution.
4. **Steady-state pipeline** (PetitPipe) — the pipeline is already primed; the first instruction
   after reset or a flush pays one extra cycle.
5. **Steady-state exec-prefetch** (Pipedream) — the exec-prefetch optimisation is already active;
   the very first instruction after reset uses the slower 3-cycle path.

Additive penalties that apply on top of the base counts are listed in the
[Stall and Penalty Summary](#stall-and-penalty-summary) section.

---

## RV32I — U-Type (Upper-Immediate)

| Instruction | PetitPipe | Pipedream | Gracilis | Operation |
|---|:---:|:---:|:---:|---|
| `LUI rd, imm`   | 1 | 2 | 3 | `rd = imm << 12` |
| `AUIPC rd, imm` | 1 | 2 | 3 | `rd = PC + (imm << 12)` |

---

## RV32I — Unconditional Jumps

| Instruction | PetitPipe | Pipedream | Gracilis | Notes |
|---|:---:|:---:|:---:|---|
| `JAL rd, offset`      | 2 | 2 | 3 | PetitPipe: 1 execute + 1 pipeline-flush bubble |
| `JALR rd, rs1, offset` | 2 | 2 | 3 | PetitPipe: 1 execute + 1 pipeline-flush bubble |

> **PetitPipe note**: JAL and JALR flush the IF/EX pipeline register on the cycle they fire.
> The next instruction fetch begins immediately, but a 1-cycle bubble is inserted before
> the target instruction enters EX. Pipedream fires `exec_prefetch` to PC_new during EXECUTE,
> so no FETCH_INSTR state is needed; total remains 2 cycles. Gracilis has no pipeline to flush.

---

## RV32I — Conditional Branches

| Instruction | Condition | PetitPipe (NT) | PetitPipe (T) | Pipedream | Gracilis | Notes |
|---|---|:---:|:---:|:---:|:---:|---|
| `BEQ rs1, rs2, offset`  | `rs1 == rs2`         | 1 | 2 | 2 | 3 | |
| `BNE rs1, rs2, offset`  | `rs1 != rs2`         | 1 | 2 | 2 | 3 | |
| `BLT rs1, rs2, offset`  | signed `rs1 < rs2`   | 1 | 2 | 2 | 3 | |
| `BGE rs1, rs2, offset`  | signed `rs1 >= rs2`  | 1 | 2 | 2 | 3 | |
| `BLTU rs1, rs2, offset` | unsigned `rs1 < rs2` | 1 | 2 | 2 | 3 | |
| `BGEU rs1, rs2, offset` | unsigned `rs1 >= rs2`| 1 | 2 | 2 | 3 | |

**NT** = not-taken  **T** = taken

> **PetitPipe note**: A not-taken branch does not flush the pipeline; the already-fetched
> sequential instruction proceeds without penalty. A taken branch flushes the pipeline
> (1 bubble), identical to JAL.
>
> **Pipedream note**: Both taken and not-taken branches cost 2 cycles. `exec_prefetch` fires
> in EXECUTE using `PC_new` (branch target for taken, `PC+4`/`PC+2` for not-taken), so no
> FETCH_INSTR state is needed regardless of outcome.
>
> **Gracilis note**: Branch outcome does not affect cycle count; there is no pipeline to flush.

---

## RV32I — Loads

| Instruction | Width | PetitPipe | Pipedream | Gracilis | Notes |
|---|---|:---:|:---:|:---:|---|
| `LB  rd, offset(rs1)` | signed byte    | 1 + M | 4 + M | 4 + M | |
| `LH  rd, offset(rs1)` | signed half    | 1 + M | 4 + M | 4 + M | |
| `LW  rd, offset(rs1)` | word           | 1 + M | 4 + M | 4 + M | |
| `LBU rd, offset(rs1)` | unsigned byte  | 1 + M | 4 + M | 4 + M | |
| `LHU rd, offset(rs1)` | unsigned half  | 1 + M | 4 + M | 4 + M | |

**M** = additional memory-latency stall cycles (0 with single-cycle ack).

> **PetitPipe note**: The EX stage asserts `d_rstrb` and stalls (`ex_stall` high) while
> `d_rbusy` is asserted. With single-cycle memory (M = 0) the load completes in 1 cycle.
> The register file is written at the end of that cycle; a directly following instruction
> that reads the loaded register sees the correct value in the next cycle because the
> register-file read is combinatorial. If longer memory latency is used (M > 0), add
> M stall cycles. See also [Load-Use Hazard](#load-use-hazard-petitpipe) below.
>
> **Gracilis / Pipedream note**: The 4-cycle baseline breaks down as:
> `FETCH(1) + WAIT_INSTR(1) + EXECUTE(1) + WAIT_ALU_OR_MEM(1)`.
> With M extra memory-latency cycles, `WAIT_ALU_OR_MEM` stays until `d_rbusy` drops.

---

## RV32I — Stores

| Instruction | Width | PetitPipe | Pipedream | Gracilis | Notes |
|---|---|:---:|:---:|:---:|---|
| `SB rs2, offset(rs1)` | byte | 1 + M | 4 + M | 4 + M | |
| `SH rs2, offset(rs1)` | half | 1 + M | 4 + M | 4 + M | |
| `SW rs2, offset(rs1)` | word | 1 + M | 4 + M | 4 + M | |

**M** = additional memory-latency stall cycles (0 with single-cycle ack).

> **PetitPipe note**: EX stage asserts `d_wmask` and stalls while `d_wbusy` is asserted.
> Stores do not write back to the register file.
>
> **Gracilis / Pipedream note**: Same breakdown as loads; `WAIT_ALU_OR_MEM` waits for
> `d_wbusy` to deassert.

---

## RV32I — ALU Immediate (I-Type)

| Instruction | PetitPipe | Pipedream | Gracilis | Operation |
|---|:---:|:---:|:---:|---|
| `ADDI  rd, rs1, imm` | 1 | 2 | 3 | `rd = rs1 + imm` |
| `SLTI  rd, rs1, imm` | 1 | 2 | 3 | `rd = (signed rs1 < signed imm) ? 1 : 0` |
| `SLTIU rd, rs1, imm` | 1 | 2 | 3 | `rd = (unsigned rs1 < unsigned imm) ? 1 : 0` |
| `XORI  rd, rs1, imm` | 1 | 2 | 3 | `rd = rs1 ^ imm` |
| `ORI   rd, rs1, imm` | 1 | 2 | 3 | `rd = rs1 \| imm` |
| `ANDI  rd, rs1, imm` | 1 | 2 | 3 | `rd = rs1 & imm` |
| `SLLI  rd, rs1, shamt` | 1 | 2 | 3 | `rd = rs1 << shamt` |
| `SRLI  rd, rs1, shamt` | 1 | 2 | 3 | `rd = rs1 >> shamt` (logical) |
| `SRAI  rd, rs1, shamt` | 1 | 2 | 3 | `rd = rs1 >> shamt` (arithmetic) |

---

## RV32I — ALU Register (R-Type)

| Instruction | PetitPipe | Pipedream | Gracilis | Operation |
|---|:---:|:---:|:---:|---|
| `ADD  rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 + rs2` |
| `SUB  rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 - rs2` |
| `SLL  rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 << rs2[4:0]` |
| `SLT  rd, rs1, rs2` | 1 | 2 | 3 | `rd = (signed rs1 < signed rs2) ? 1 : 0` |
| `SLTU rd, rs1, rs2` | 1 | 2 | 3 | `rd = (unsigned rs1 < unsigned rs2) ? 1 : 0` |
| `XOR  rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 ^ rs2` |
| `SRL  rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 >> rs2[4:0]` (logical) |
| `SRA  rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 >> rs2[4:0]` (arithmetic) |
| `OR   rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 \| rs2` |
| `AND  rd, rs1, rs2` | 1 | 2 | 3 | `rd = rs1 & rs2` |

---

## RV32I — Memory Ordering

| Instruction | PetitPipe | Pipedream | Gracilis | Notes |
|---|:---:|:---:|:---:|---|
| `FENCE`   | 1 | 2 | 3 | Treated as NOP (single-bus, no re-ordering possible) |
| `FENCE.I` | 1 | 2 | 3 | Treated as NOP |

> These instructions are decoded as no-ops in all three cores. The single-bus Gracilis and
> Pipedream designs never re-order memory accesses; PetitPipe uses separate, independent
> I-bus and D-bus with no shared state, so no fence action is needed either.

---

## RV32I — System / CSR

### CSR Instructions

| Instruction | PetitPipe | Pipedream | Gracilis | Notes |
|---|:---:|:---:|:---:|---|
| `CSRRW  rd, csr, rs1`  | 1 | 2 | 3 | Atomic read-write CSR |
| `CSRRS  rd, csr, rs1`  | 1 | 2 | 3 | Atomic read-set CSR |
| `CSRRC  rd, csr, rs1`  | 1 | 2 | 3 | Atomic read-clear CSR |
| `CSRRWI rd, csr, uimm` | 1 | 2 | 3 | Atomic read-write CSR (immediate) |
| `CSRRSI rd, csr, uimm` | 1 | 2 | 3 | Atomic read-set CSR (immediate) |
| `CSRRCI rd, csr, uimm` | 1 | 2 | 3 | Atomic read-clear CSR (immediate) |

Supported CSRs: `mstatus` (0x300), `mtvec` (0x305), `mepc` (0x341), `mcause` (0x342),
`cycle` (0xC00), `cycleh` (0xC80). Reads from unrecognised CSR addresses return 0.

### Privileged / Trap-Return

| Instruction | PetitPipe | Pipedream | Gracilis | Notes |
|---|:---:|:---:|:---:|---|
| `MRET`   | 2 | 2 | 3 | Returns to `mepc`, clears `mcause`. PetitPipe: 1 + flush bubble. |
| `ECALL`  | 2 | 2 | 3 | Treated as `MRET` in this implementation (minimal core). |
| `EBREAK` | 2 | 2 | 3 | Treated as `MRET` in this implementation (minimal core). |

> All three instructions have `funct3 = 000` and `opcode = SYSTEM`. The cores detect
> them via `interrupt_return = isSYSTEM & (funct3 == 000)`, which covers MRET, ECALL,
> and EBREAK identically. A full trap-handler is not implemented.

---

## RV32M — Multiply

| Instruction | PetitPipe | Pipedream | Gracilis | Operation |
|---|:---:|:---:|:---:|---|
| `MUL    rd, rs1, rs2` | 1 | 2 | 3 | `rd = (rs1 × rs2)[31:0]` (lower 32 bits) |
| `MULH   rd, rs1, rs2` | 1 | 2 | 3 | `rd = (signed rs1 × signed rs2)[63:32]` |
| `MULHSU rd, rs1, rs2` | 1 | 2 | 3 | `rd = (signed rs1 × unsigned rs2)[63:32]` |
| `MULHU  rd, rs1, rs2` | 1 | 2 | 3 | `rd = (unsigned rs1 × unsigned rs2)[63:32]` |

> Implemented with a single-cycle 33 × 33-bit combinatorial multiplier. `isDivide`
> (`funct3[2] == 0` for MUL variants) is false, so no WAIT state is entered in any core.
> In Gracilis and Pipedream `needToWait` is false, so the state machine returns directly
> to `FETCH_INSTR` after `EXECUTE`.

---

## RV32M — Divide

| Instruction | PetitPipe | Pipedream | Gracilis | Operation |
|---|:---:|:---:|:---:|---|
| `DIV  rd, rs1, rs2`  | 33 | 35 | 35 | signed quotient |
| `DIVU rd, rs1, rs2`  | 33 | 35 | 35 | unsigned quotient |
| `REM  rd, rs1, rs2`  | 33 | 35 | 35 | signed remainder |
| `REMU rd, rs1, rs2`  | 33 | 35 | 35 | unsigned remainder |

> **All cores**: Division uses a non-restoring iterative algorithm that shifts a 32-bit
> mask (`quotient_msk`) from bit 31 down to bit 0, one bit per clock cycle.
> There is **no early termination** — the algorithm always performs exactly 32 steps
> regardless of the operand values.
>
> **PetitPipe**: The first `ex_fire` cycle starts the divide (sets `quotient_msk = 1<<31`,
> making `aluBusy = 1`). `ex_stall = isDivide & aluBusy` then holds the instruction in
> EX for each subsequent step. The final `ex_fire` occurs when `aluBusy` drops to 0 and
> writes back the correct result: **1 setup + 32 iterative steps = 33 cycles total**.
>
> **Gracilis / Pipedream**: The divide setup fires in `EXECUTE` (`aluWr` pulse). The state
> machine then enters `WAIT_ALU_OR_MEM` and remains there until `aluBusy` drops. Total:
> `FETCH(1) + WAIT_INSTR(1) + EXECUTE(1) + WAIT_ALU_OR_MEM(32)` = **35 cycles**.
> Any additional instruction-fetch memory latency adds to the `WAIT_INSTR` portion only
> and is not part of the divide computation itself.

---

## RV32C — Compressed Instructions

Compressed (16-bit) instructions are decoded by an in-line decompressor that expands each
RVC encoding to its canonical 32-bit equivalent before the instruction enters the EX stage.
The cycle cost is therefore **identical to the 32-bit form** listed in the tables above.

| Compressed | Expands to | Cycle cost |
|---|---|---|
| `C.ADDI4SPN rd', nzuimm`   | `ADDI rd', x2, nzuimm` | same as ADDI |
| `C.LW  rd', offset(rs1')`  | `LW rd', offset(rs1')` | same as LW |
| `C.SW  rs2', offset(rs1')` | `SW rs2', offset(rs1')` | same as SW |
| `C.ADDI rd, nzimm`         | `ADDI rd, rd, nzimm`  | same as ADDI |
| `C.JAL offset`             | `JAL x1, offset`      | same as JAL |
| `C.LI  rd, imm`            | `ADDI rd, x0, imm`    | same as ADDI |
| `C.ADDI16SP nzimm`         | `ADDI x2, x2, nzimm`  | same as ADDI |
| `C.LUI rd, nzuimm`         | `LUI rd, nzuimm`      | same as LUI |
| `C.SRLI rd', shamt`        | `SRLI rd', rd', shamt` | same as SRLI |
| `C.SRAI rd', shamt`        | `SRAI rd', rd', shamt` | same as SRAI |
| `C.ANDI rd', imm`          | `ANDI rd', rd', imm`  | same as ANDI |
| `C.SUB  rd', rs2'`         | `SUB rd', rd', rs2'`  | same as SUB |
| `C.XOR  rd', rs2'`         | `XOR rd', rd', rs2'`  | same as XOR |
| `C.OR   rd', rs2'`         | `OR  rd', rd', rs2'`  | same as OR |
| `C.AND  rd', rs2'`         | `AND rd', rd', rs2'`  | same as AND |
| `C.J   offset`             | `JAL x0, offset`      | same as JAL |
| `C.BEQZ rs1', offset`      | `BEQ rs1', x0, offset` | same as BEQ |
| `C.BNEZ rs1', offset`      | `BNE rs1', x0, offset` | same as BNE |
| `C.SLLI rd, shamt`         | `SLLI rd, rd, shamt`  | same as SLLI |
| `C.LWSP rd, offset`        | `LW rd, offset(x2)`   | same as LW |
| `C.JR   rs1`               | `JALR x0, rs1, 0`     | same as JALR |
| `C.MV   rd, rs2`           | `ADD rd, x0, rs2`     | same as ADD |
| `C.JALR rs1`               | `JALR x1, rs1, 0`     | same as JALR |
| `C.ADD  rd, rs2`           | `ADD rd, rd, rs2`     | same as ADD |
| `C.SWSP rs2, offset`       | `SW rs2, offset(x2)`  | same as SW |

> **Unaligned RVC boundary**: If a 32-bit instruction begins at `PC[1:0] = 2` (its upper
> half sits in the next aligned word), the IF stage requires a second I-bus access to
> assemble the full instruction. PetitPipe handles this with its `fetch_second_half`
> register; Gracilis and Pipedream re-enter `FETCH_INSTR` for the second half. This adds
> **1 extra fetch cycle** (one additional memory round-trip) to the affected instruction only.

---

## Stall and Penalty Summary

The base counts above assume ideal conditions. The following penalties are **additive**.

### Instruction Cache Miss (PetitPipe only)

| Cache line size | Miss penalty |
|:---:|:---:|
| 4 words (default) | +3 to +4 cycles per line fill |
| 8 words           | +7 to +8 cycles per line fill |

A miss triggers a 4-word pipelined burst on the I-bus. Subsequent instructions that hit
the newly filled line pay no further penalty. Sequential code running in a tight loop
should achieve >95% hit rate once the loop body fits in one cache line.

### Memory Latency (all cores, loads and stores)

| Wishbone ack latency | Extra stall cycles |
|:---:|:---:|
| 1-cycle (combinatorial ack) | 0 |
| 2-cycle (1-cycle registered ack) | +1 |
| N-cycle | +(N−1) |

`M` in the load/store tables equals (ack latency − 1).

### Load-Use Hazard (PetitPipe only)

PetitPipe performs a **combinatorial** register-file read in the EX stage. The load
writeback completes at the rising edge of the execution cycle; the following instruction
reads the updated register file combinatorially in the next cycle.

With a single-cycle ack there is **no hardware-enforced stall** for load-use. However,
if the memory interface uses a **registered ack** (d_rbusy remains high for 1 extra cycle),
an additional `d_rbusy` stall cycle is incurred:

| Memory ack style | Load-use penalty |
|---|:---:|
| Combinatorial ack (ack same cycle as stb) | 0 cycles |
| Registered 1-cycle ack (ack next cycle) | +1 cycle stall on the load itself |

The compiler should still schedule an independent instruction between a load and its
consumer when targeting lower-latency code or when using variable-latency memory.

### Divide Latency

Divide uses a non-restoring 32-bit iterative algorithm. The divisor is always processed
bit by bit regardless of its magnitude; there is **no early termination**. The number of
cycles is therefore always the same for any pair of operands:

| Core | Exact DIV/REM cycle count |
|---|:---:|
| PetitPipe | 33 cycles (1 setup + 32 iterative steps) |
| Pipedream | 35 cycles (3 baseline + 32 iterative steps) |
| Gracilis  | 35 cycles (3 baseline + 32 iterative steps) |

### Pipeline Flush (PetitPipe only)

Control-flow instructions that change the PC (taken branches, JAL, JALR, MRET, ECALL,
EBREAK, and any interrupt taken during execution) flush the IF/EX pipeline register.
This inserts a **1-cycle bubble** before the first instruction at the new PC can enter EX,
which is already reflected in the "+1" shown in the 2-cycle entries of the tables above.

---

## Quick-Reference Summary Table

Base cycle count at a glance (single-cycle memory, cache hit for PetitPipe,
steady-state for Pipedream, excluding memory-latency and cache-miss penalties).

| Instruction group | PetitPipe | Pipedream | Gracilis |
|---|:---:|:---:|:---:|
| ALU reg/imm (ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU, and immediate forms) | **1** | **2** | **3** |
| LUI, AUIPC | **1** | **2** | **3** |
| Branch — not taken | **1** | **2** | **3** |
| Branch — taken | **2** | **2** | **3** |
| JAL, JALR | **2** | **2** | **3** |
| MRET / ECALL / EBREAK | **2** | **2** | **3** |
| CSR (CSRRW, CSRRS, CSRRC, and immediate forms) | **1** | **2** | **3** |
| FENCE, FENCE.I | **1** | **2** | **3** |
| Load (LB, LH, LW, LBU, LHU) | **1** | **4** | **4** |
| Store (SB, SH, SW) | **1** | **4** | **4** |
| MUL, MULH, MULHSU, MULHU | **1** | **2** | **3** |
| DIV, DIVU, REM, REMU | **33** | **35** | **35** |

---

## Measurement Methodology

To measure actual cycle counts in simulation:

```bash
# Cross-compile a test program
make compile

# Run PetitPipe with the Wishbone testbench
make sim-wb

# Compare PetitPipe vs Gracilis on the same hex
make perf-compare
# or for a single test:
make perf-compare-<test-name>
```

The `cycles` CSR (`0xC00` / `0xC80`) is a 64-bit counter that increments every clock.
Read it before and after a code sequence to measure wall-clock cycles:

```asm
csrr  a0, cycle      # lower 32 bits
csrr  a1, cycleh     # upper 32 bits
# ... code under test ...
csrr  a2, cycle
sub   a0, a2, a0     # elapsed cycles (lower 32 bits, assuming no overflow)
```

For a detailed breakdown of cache, bus and stall statistics, integrate `perf_monitor.v`
into your SoC as described in [`PERFORMANCE_METRICS.md`](PERFORMANCE_METRICS.md).
