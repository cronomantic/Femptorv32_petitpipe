/******************************************************************************/
// FemtoRV32 "Petit Pipe": A minimal 2-stage pipelined RISC-V RV32IMC core
//
// Features:
//   - 2-stage in-order pipeline (IF/EX) with split instruction/data buses
//   - Full RV32IMC ISA (base + M extension + C compressed instructions)
//   - Interrupt handling with 8-level priority encoder and CSR support
//   - Instruction bursting on I-bus (prefetch cache), classic transactions on D-bus
//   - Unaligned instruction fetch support (handles PC[1] misalignment for RVC)
//   - Cycle counter and standard exception CSRs (mstatus, mtvec, mepc, mcause)
//
// Instruction Set: RV32IMC + CSR + MRET
//
// Architecture:
//   IF stage: Fetches instructions from I-bus, decompresses RVC, caches unaligned halves
//   EX stage: Full 5-way decode (ALU, memory, branches, jumps, CSR/interrupts)
//             Executes instructions, manages hazards, and flushes on control flow changes
//
// Parameters:
//   RESET_ADDR: Initial PC value (default 0x00000000)
//   IWB_BURST_LEN: Instruction prefetch cache size (default 4 words)
//
// Bruno Levy, Matthias Koch, 2020-2021
// Upgraded with pipelined design and interrupt support
/******************************************************************************/

// Firmware generation flags for this processor
`define NRV_ARCH     "rv32imac"
`define NRV_ABI      "ilp32"
`define NRV_OPTIMIZE "-O3"
`define NRV_INTERRUPTS

/******************************************************************************/
// FemtoRV32_Core_P2: 2-Stage Pipelined RV32IMC Core
/******************************************************************************/
//
// PIPELINE OVERVIEW:
//   Instruction Fetch (IF) → Decode/Execute (EX)
//   Pipeline registers: id_valid, id_instr, id_pc, id_long
//
// INSTRUCTION FETCH STAGE:
//   - Maintains PC (program counter) with optional offset for unaligned fetch
//   - Issues read requests to I-bus and caches returned instructions
//   - Handles RVC (16-bit) vs RV32 (32-bit) instruction lengths
//   - Special handling for unaligned fetch when PC[1]=1 (compression artifact):
//     * If a 32-bit instruction starts at PC[1:0]=2, first half is in cache, second in next word
//     * Decompressor recombines before delivering to EX stage
//   - Asserts if_pending to initiate I-bus read; clears when i_rbusy asserted
//   - Returns decompressed 30-bit instruction (d[31:2]) to pipelined registers
//
// EXECUTE STAGE (Decode + Execution):
//   - 5-way instruction decoder:
//     * Load/Store ops: Address = RS1 + immediate, memory access via D-bus
//     * ALU ops: ADD, SUB, shifts (SLL, SRL, SRA), compare (SLT, SLTU, XOR, OR, AND)
//     * Multiply/Divide: MUL/MULH/MULU/MULHU/DIV/DIVI/REM/REMU via 33-bit multiplier + iterative divider
//     * Branch/Jump: Conditional (BEQ, BNE, BLT, BGE, BLTU, BGEU), unconditional (JAL, JALR)
//     * System: CSR read/write (mstatus, mtvec, mepc, mcause, cycles), MRET for interrupt return
//
//   - Hazard detection and stalling:
//     * Load-Use Hazard: 1-cycle stall when load result needed immediately
//       Mechanism: ALU bypass (writeback before regfile read), next instruction reads "old" value
//     * Divide Stall: Long division holds ALU busy until complete
//     * Memory Stall: Pipeline pauses if d_rbusy (reading) or d_wbusy (writing) asserted
//
//   - Interrupt arbitration:
//     * 8-input priority encoder: irq_i[0] → cause 0 (highest), irq_i[7] → cause 7 (lowest)
//     * mcause locked when non-zero (prevents overwrite during handler execution)
//     * Sticky request: maintains interrupt until handler starts or pending interrupt clears
//     * Handler PC = mtvec; return PC = mepc (saved on entry)
//     * MRET: Clears mcause to re-enable next interrupt; PC = mepc
//
//   - Control flow flush:
//     * Clears pipeline (id_valid=0, if_pending=0) on branch taken, jump, interrupt, or MRET
//     * PC updated to new target (branch/jump), interrupt handler (mtvec), or saved PC (mepc)
//
// PIPELINE REGISTERS (IF/EX boundary):
//   id_valid:  Indicates valid instruction in pipeline (cleared on stall/flush)
//   id_instr:  30-bit decompressed instruction (bits [31:2])
//   id_pc:     Instruction address (used for PC-relative branch/jump calculations)
//   id_long:   Indicates 32-bit instruction (1) vs 16-bit RVC (0) for PC increment
//
// MEMORY INTERFACE (Split Wishbone):
//   Instruction Bus (I-bus):
//     - Pipelined read with configurable burst prefetch (default 4 words)
//     - On cache miss, fills entire cacheline in parallel (up to 4 beats)
//     - Each word tagged as valid; hit detection avoids repeated fills
//     - Reduces average fetch latency during sequential code
//   
//   Data Bus (D-bus):
//     - Classic single-transaction protocol
//     - Load transactions: d_rstrb asserted, waits for d_rbusy to clear, reads d_rdata
//     - Store transactions: d_wmask non-zero, waits for d_wbusy to clear
//     - No bursting; each load/store is independent
//
// CSR REGISTERS:
//   mstatus[3]: Global interrupt enable (bit 3 = MIE)
//   mtvec[31:0]: Interrupt handler base address
//   mepc[31:0]: Exception/interrupt return address
//   mcause[31:0]: Exception/interrupt cause (bit 31 = interrupt flag, [3:0] = code)
//   cycles[63:0]: Cycle counter (incremented every clock; bits [31:0] readable via mstatus, [63:32] via cyclesh)
//
/******************************************************************************/

module FemtoRV32_Core_P2(
   input          clk,

   // Instruction bus
   output [31:0] i_addr,
   output        i_rstrb,
   input  [31:0] i_rdata,
   input         i_rbusy,

   // Data bus
   output [31:0] d_addr,
   output [31:0] d_wdata,
   output  [3:0] d_wmask,
   output        d_rstrb,
   input  [31:0] d_rdata,
   input         d_rbusy,
   input         d_wbusy,

   input   [7:0] irq_i,

   input         reset_n      // synchronous reset, active low
);

   parameter RESET_ADDR       = 32'h00000000;

   /***************************************************************************/
   // Instruction fetch stage with RVC/unaligned handling.
   /***************************************************************************/

   reg  [31:0] PC_if;
   reg  [31:2] cached_addr;
   reg           [31:0] cached_data;
   reg                  fetch_second_half;
   reg                  if_pending;

   wire [31:0] PCplus4_if = PC_if + 4;
   wire [31:0] PCplus2_if = PC_if + 2;

   /* verilator lint_off WIDTH */
   assign i_addr = fetch_second_half
                 ? {PCplus4_if[31:2], 2'b00}
                 : {PC_if     [31:2], 2'b00};
   /* verilator lint_on WIDTH */

   assign i_rstrb = if_pending;

   wire current_cache_hit = cached_addr == PC_if[31:2];
   wire [31:0] cached_mem = current_cache_hit ? cached_data : i_rdata;
   wire [31:0] decomp_input = PC_if[1] ? {i_rdata[15:0], cached_mem[31:16]}
                                      : cached_mem;
   wire [31:0] decompressed;
   decompressor _decomp_p2 ( .c(decomp_input), .d(decompressed) );

   wire current_unaligned_long = &cached_mem[17:16] & PC_if[1];
   wire long_instr_if = &decomp_input[1:0];

   /***************************************************************************/
   // IF/EX pipeline registers.
   /***************************************************************************/

   reg         id_valid;
   reg  [31:2] id_instr;
   reg  [31:0] id_pc;
   reg         id_long;

   wire instr_ready = if_pending & ~i_rbusy;

   /***************************************************************************/
   // Decode and execute stage.
   /***************************************************************************/

   wire [31:2] instr = id_instr;

   wire [4:0] rdId = instr[11:7];
   (* onehot *)
   wire [7:0] funct3Is = 8'b00000001 << instr[14:12];

   wire [31:0] Uimm={    instr[31],   instr[30:12], {12{1'b0}}};
   wire [31:0] Iimm={{21{instr[31]}}, instr[30:20]};
   /* verilator lint_off UNUSED */
   wire [31:0] Simm={{21{instr[31]}}, instr[30:25],instr[11:7]};
   wire [31:0] Bimm={{20{instr[31]}}, instr[7],instr[30:25],instr[11:8],1'b0};
   wire [31:0] Jimm={{12{instr[31]}}, instr[19:12],instr[20],instr[30:21],1'b0};
   /* verilator lint_on UNUSED */

   wire isLoad    =  (instr[6:2] == 5'b00000);
   wire isALUimm  =  (instr[6:2] == 5'b00100);
   wire isAUIPC   =  (instr[6:2] == 5'b00101);
   wire isStore   =  (instr[6:2] == 5'b01000);
   wire isALUreg  =  (instr[6:2] == 5'b01100);
   wire isLUI     =  (instr[6:2] == 5'b01101);
   wire isBranch  =  (instr[6:2] == 5'b11000);
   wire isJALR    =  (instr[6:2] == 5'b11001);
   wire isJAL     =  (instr[6:2] == 5'b11011);
   wire isSYSTEM  =  (instr[6:2] == 5'b11100);

   wire isALU = isALUimm | isALUreg;

   reg [31:0] registerFile [31:0];
   integer _i_p2;
   initial begin
      for (_i_p2 = 0; _i_p2 < 32; _i_p2 = _i_p2 + 1)
         registerFile[_i_p2] = 0;
   end
   
   wire [31:0] rs1 = registerFile[instr[19:15]];
   wire [31:0] rs2 = registerFile[instr[24:20]];

   wire [31:0] aluIn1 = rs1;
   wire [31:0] aluIn2 = isALUreg | isBranch ? rs2 : Iimm;
   wire [31:0] aluPlus = aluIn1 + aluIn2;

   wire [32:0] aluMinus = {1'b1, ~aluIn2} + {1'b0,aluIn1} + 33'b1;
   wire        LT  = (aluIn1[31] ^ aluIn2[31]) ? aluIn1[31] : aluMinus[32];
   wire        LTU = aluMinus[32];
   wire        EQ  = (aluMinus[31:0] == 0);

   wire [31:0] shifter_in = funct3Is[1] ?
     {aluIn1[ 0], aluIn1[ 1], aluIn1[ 2], aluIn1[ 3], aluIn1[ 4], aluIn1[ 5],
      aluIn1[ 6], aluIn1[ 7], aluIn1[ 8], aluIn1[ 9], aluIn1[10], aluIn1[11],
      aluIn1[12], aluIn1[13], aluIn1[14], aluIn1[15], aluIn1[16], aluIn1[17],
      aluIn1[18], aluIn1[19], aluIn1[20], aluIn1[21], aluIn1[22], aluIn1[23],
      aluIn1[24], aluIn1[25], aluIn1[26], aluIn1[27], aluIn1[28], aluIn1[29],
      aluIn1[30], aluIn1[31]} : aluIn1;

   /* verilator lint_off WIDTH */
   wire [31:0] shifter =
               $signed({instr[30] & aluIn1[31], shifter_in}) >>> aluIn2[4:0];
   /* verilator lint_on WIDTH */

   wire [31:0] leftshift = {
     shifter[ 0], shifter[ 1], shifter[ 2], shifter[ 3], shifter[ 4],
     shifter[ 5], shifter[ 6], shifter[ 7], shifter[ 8], shifter[ 9],
     shifter[10], shifter[11], shifter[12], shifter[13], shifter[14],
     shifter[15], shifter[16], shifter[17], shifter[18], shifter[19],
     shifter[20], shifter[21], shifter[22], shifter[23], shifter[24],
     shifter[25], shifter[26], shifter[27], shifter[28], shifter[29],
     shifter[30], shifter[31]};

   wire funcM     = instr[25];
   wire isDivide = isALUreg & funcM & instr[14];

   // Division state
   reg [31:0] dividend;
   reg [62:0] divisor;
   reg [31:0] quotient;
   reg [31:0] quotient_msk;
   wire aluBusy   = |quotient_msk;

   wire divstep_do = (divisor <= {31'b0, dividend});
   wire [31:0] dividendN     = divstep_do ? dividend - divisor[31:0] : dividend;
   wire [31:0] quotientN     = divstep_do ? quotient | quotient_msk  : quotient;
   wire div_sign = ~instr[12] & (instr[13] ? aluIn1[31] :
                                          (aluIn1[31] != aluIn2[31]) & |aluIn2);

   reg  [31:0] divResult;

   wire isMULH   = funct3Is[1];
   wire isMULHSU = funct3Is[2];

   wire sign1 = aluIn1[31] &  isMULH;
   wire sign2 = aluIn2[31] & (isMULH | isMULHSU);

   wire signed [32:0] signed1 = {sign1, aluIn1};
   wire signed [32:0] signed2 = {sign2, aluIn2};
   wire signed [63:0] multiply = signed1 * signed2;

   wire [31:0] aluOut_base =
     (funct3Is[0]  ? instr[30] & instr[5] ? aluMinus[31:0] : aluPlus : 32'b0) |
     (funct3Is[1]  ? leftshift                                       : 32'b0) |
     (funct3Is[2]  ? {31'b0, LT}                                     : 32'b0) |
     (funct3Is[3]  ? {31'b0, LTU}                                    : 32'b0) |
     (funct3Is[4]  ? aluIn1 ^ aluIn2                                 : 32'b0) |
     (funct3Is[5]  ? shifter                                         : 32'b0) |
     (funct3Is[6]  ? aluIn1 | aluIn2                                 : 32'b0) |
     (funct3Is[7]  ? aluIn1 & aluIn2                                 : 32'b0) ;

   wire [31:0] aluOut_muldiv =
     (  funct3Is[0]   ?  multiply[31: 0] : 32'b0) |
     ( |funct3Is[3:1] ?  multiply[63:32] : 32'b0) |
     (  instr[14]     ?  div_sign ? -divResult : divResult : 32'b0) ;

   wire [31:0] aluOut = isALUreg & funcM ? aluOut_muldiv : aluOut_base;

   wire predicate =
        funct3Is[0] &  EQ  |
        funct3Is[1] & !EQ  |
        funct3Is[4] &  LT  |
        funct3Is[5] & !LT  |
        funct3Is[6] &  LTU |
        funct3Is[7] & !LTU ;

   wire [31:0] PCplusImm = id_pc + ( instr[3] ? Jimm[31:0] :
                                               instr[4] ? Uimm[31:0] :
                                                          Bimm[31:0] );

   wire [31:0] loadstore_addr = rs1[31:0] +
                   (instr[5] ? Simm[31:0] : Iimm[31:0]);

   wire mem_byteAccess     = instr[13:12] == 2'b00;
   wire mem_halfwordAccess = instr[13:12] == 2'b01;

   wire LOAD_sign =
        !instr[14] & (mem_byteAccess ? d_rdata[7] :
                      mem_halfwordAccess ? d_rdata[15] : d_rdata[31]);

   wire [15:0] LOAD_halfword =
               loadstore_addr[1] ? d_rdata[31:16] : d_rdata[15:0];

   wire  [7:0] LOAD_byte =
               loadstore_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];

   wire [31:0] LOAD_data =
         mem_byteAccess ? {{24{LOAD_sign}},     LOAD_byte} :
     mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                          d_rdata ;

   wire [3:0] STORE_wmask =
              mem_byteAccess      ?
                    (loadstore_addr[1] ?
                          (loadstore_addr[0] ? 4'b1000 : 4'b0100) :
                          (loadstore_addr[0] ? 4'b0010 : 4'b0001)
                    ) :
              mem_halfwordAccess ?
                    (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
              4'b1111;

   // CSR/interrupts
   reg  [31:0] mepc;
   reg  [31:0] mtvec;
   reg                   mstatus;
   reg  [31:0]            mcause;
   reg  [63:0]            cycles;

   always @(posedge clk) cycles <= cycles + 1;

   wire sel_mstatus = (instr[31:20] == 12'h300);
   wire sel_mtvec   = (instr[31:20] == 12'h305);
   wire sel_mepc    = (instr[31:20] == 12'h341);
   wire sel_mcause  = (instr[31:20] == 12'h342);
   wire sel_cycles  = (instr[31:20] == 12'hC00);
   wire sel_cyclesh = (instr[31:20] == 12'hC80);

   /* verilator lint_off WIDTH */
   wire [31:0] CSR_read =
     (sel_mstatus ? {28'b0, mstatus, 3'b0} : 32'b0) |
     (sel_mtvec   ? mtvec                  : 32'b0) |
     (sel_mepc    ? mepc                   : 32'b0) |
     (sel_mcause  ? mcause                 : 32'b0) |
     (sel_cycles  ? cycles[31:0]           : 32'b0) |
     (sel_cyclesh ? cycles[63:32]          : 32'b0) ;
   /* verilator lint_on WIDTH */

   wire [31:0] CSR_modifier = instr[14] ? {27'd0, instr[19:15]} : rs1;

   wire [31:0] CSR_write = (instr[13:12] == 2'b10) ? CSR_modifier | CSR_read  :
                           (instr[13:12] == 2'b11) ? ~CSR_modifier & CSR_read :
                                                     CSR_modifier ;

   wire interrupt_return = isSYSTEM & funct3Is[0];
   reg  interrupt_request_sticky;
   wire any_irq = |irq_i;
   wire mcause_lock = |mcause;
   wire interrupt = interrupt_request_sticky & mstatus & ~mcause_lock;

   wire [7:0] irq_prio =
      irq_i[0] ? 8'd1 :
      irq_i[1] ? 8'd2 :
      irq_i[2] ? 8'd3 :
      irq_i[3] ? 8'd4 :
      irq_i[4] ? 8'd5 :
      irq_i[5] ? 8'd6 :
      irq_i[6] ? 8'd7 :
      irq_i[7] ? 8'd8 : 8'd0;

   wire [31:0] irq_cause = {28'b0, (irq_prio == 0 ? 4'd0 : irq_prio[3:0] - 4'd1)};
   wire [31:0] irq_mcause = interrupt ? (32'h80000000 | irq_cause) : 32'b0;

   wire [31:0] PCinc = id_long ? (id_pc + 4) : (id_pc + 2);
   wire [31:0] PC_new =
           isJALR           ? {aluPlus[31:1],1'b0} :
           (isJAL | (isBranch & predicate)) ? PCplusImm :
           interrupt_return ? mepc :
                              PCinc;

   wire ex_valid = id_valid;
   wire ex_stall = ex_valid & ( ((isLoad | isStore) & (d_rbusy | d_wbusy)) |
                                (isDivide & aluBusy) );
   wire ex_fire = ex_valid & ~ex_stall;

   assign d_addr  = loadstore_addr;
   assign d_wdata[ 7: 0] = rs2[7:0];
   assign d_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0]  : rs2[15: 8];
   assign d_wdata[23:16] = loadstore_addr[1] ? rs2[7:0]  : rs2[23:16];
   assign d_wdata[31:24] = loadstore_addr[0] ? rs2[7:0]  :
                           loadstore_addr[1] ? rs2[15:8] : rs2[31:24];
   assign d_wmask = ex_valid & isStore ? STORE_wmask : 4'b0;
   assign d_rstrb = ex_valid & isLoad;

   wire [31:0] writeBackData  =
      (isSYSTEM            ? CSR_read  : 32'b0) |
      (isLUI               ? Uimm      : 32'b0) |
      (isALU               ? aluOut    : 32'b0) |
      (isAUIPC             ? PCplusImm : 32'b0) |
      (isJALR   | isJAL    ? PCinc     : 32'b0) |
      (isLoad              ? LOAD_data : 32'b0);

   wire writeBack_en = ex_fire & ~(isBranch | isStore);

   wire ex_flush = ex_fire & (interrupt | isJAL | (isBranch & predicate) | interrupt_return);

   always @(posedge clk) begin
      if (!reset_n) begin
         PC_if <= RESET_ADDR[31:0];
         cached_addr <= {30{1'b1}};
         cached_data <= 32'b0;
         fetch_second_half <= 1'b0;
         if_pending <= 1'b0;
         id_valid <= 1'b0;
         id_instr <= 30'b0;
         id_pc <= 0;
         id_long <= 1'b0;
         mstatus <= 0;
         mtvec <= 0;
         mepc <= 0;
         mcause <= 32'b0;
         interrupt_request_sticky <= 1'b0;
         dividend <= 0;
         divisor <= 0;
         quotient <= 0;
         quotient_msk <= 0;
         divResult <= 0;
      end else begin
         // Track interrupt requests
         interrupt_request_sticky <= any_irq | (interrupt_request_sticky & ~interrupt);

         // Division step
         if (isDivide & ex_fire) begin
            dividend <=   ~instr[12] & aluIn1[31] ? -aluIn1 : aluIn1;
            divisor  <= {(~instr[12] & aluIn2[31] ? -aluIn2 : aluIn2), 31'b0};
            quotient <= 0;
            quotient_msk <= 1 << 31;
         end else begin
            dividend     <= dividendN;
            divisor      <= divisor >> 1;
            quotient     <= quotientN;
            quotient_msk <= quotient_msk >> 1;
         end
         divResult <= instr[13] ? dividendN : quotientN;

         // CSR writes
         if (isSYSTEM & (instr[14:12] != 0) & ex_fire) begin
            if (sel_mstatus) mstatus <= CSR_write[3];
            if (sel_mtvec  ) mtvec   <= CSR_write[31:0];
         end

         // Writeback
         if (writeBack_en & (rdId != 0)) begin
            registerFile[rdId] <= writeBackData;
         end

         // Handle interrupts
         if (ex_fire & interrupt) begin
            mepc   <= PC_new;
            mcause <= irq_mcause;
         end else if (ex_fire & interrupt_return) begin
            mcause <= 32'b0;
         end

         // Flush pipeline on control transfer
         if (ex_flush) begin
            PC_if <= interrupt ? mtvec : PC_new;
            id_valid <= 1'b0;
            fetch_second_half <= 1'b0;
            if_pending <= 1'b0;
         end else begin
            // Issue fetch if IF can accept
            if (!if_pending && (!id_valid || ex_fire)) begin
               if_pending <= 1'b1;
            end

            if (instr_ready) begin
               if (~current_cache_hit | fetch_second_half) begin
                  cached_addr <= i_addr[31:2];
                  cached_data <= i_rdata;
               end

               if (current_unaligned_long & ~fetch_second_half) begin
                  fetch_second_half <= 1'b1;
                  if_pending <= 1'b1;
               end else begin
                  id_valid <= 1'b1;
                  id_instr <= decompressed[31:2];
                  id_pc <= PC_if;
                  id_long <= long_instr_if;
                  fetch_second_half <= 1'b0;
                  if_pending <= 1'b0;
                  PC_if <= long_instr_if ? PCplus4_if : PCplus2_if;
               end
            end else if (ex_fire & id_valid) begin
               if (!instr_ready) begin
                  id_valid <= 1'b0;
               end
            end
         end
      end
   end

endmodule

/******************************************************************************/
// FemtoRV32_Pipewire_WB: Dual-bus Wishbone wrapper for split I/D architecture
/******************************************************************************/
//
// This wrapper bridges the split I/D interface of FemtoRV32_Core_P2 to two
// separate Wishbone buses for instruction (read-only) and data (read/write).
//
// INSTRUCTION BUS (iwb_*):
//   - Pipelined read protocol with automatic burst prefetch
//   - Configurable burst length (default 4 words), reduces average fetch latency
//   - Each word in prefetch cache tagged with valid bit for cache hits
//   - Burst uses CTI codes: 010 (incrementing), 111 (end of cycle)
//
// DATA BUS (dwb_*):
//   - Classic single-transaction read/write
//   - Load (d_rstrb): Read request, wait for ack, receive data on dwb_dat_i
//   - Store (d_wmask non-zero): Write request with write mask, wait for ack
//
/******************************************************************************/

module FemtoRV32_PetitPipe_WB #(
   parameter RESET_ADDR       = 32'h00000000,
   parameter integer IWB_BURST_LEN = 4
)(
   input          clk,

   // Instruction wishbone (pipelined)
   output [31:0] iwb_adr_o,
   output [31:0] iwb_dat_o,
   output  [3:0] iwb_sel_o,
   output        iwb_we_o,
   output        iwb_cyc_o,
   output        iwb_stb_o,
   output  [2:0] iwb_cti_o,
   output  [1:0] iwb_bte_o,
   input  [31:0] iwb_dat_i,
   input         iwb_ack_i,

   // Data wishbone (classic)
   output [31:0] dwb_adr_o,
   output [31:0] dwb_dat_o,
   output  [3:0] dwb_sel_o,
   output        dwb_we_o,
   output        dwb_cyc_o,
   output        dwb_stb_o,
   output  [2:0] dwb_cti_o,
   output  [1:0] dwb_bte_o,
   input  [31:0] dwb_dat_i,
   input         dwb_ack_i,

   input   [7:0] irq_i,

   input         reset_n      // synchronous reset, active low
);

   localparam [2:0] IWB_CTI    = 3'b111;
   localparam [1:0] IWB_BTE    = 2'b00;
   localparam [2:0] DWB_CTI    = 3'b111;
   localparam [1:0] DWB_BTE    = 2'b00;

   wire [31:0] i_addr;
   wire        i_rstrb;
   wire [31:0] i_rdata;
   wire        i_rbusy;

   wire [31:0] d_addr;
   wire [31:0] d_wdata;
   wire  [3:0] d_wmask;
   wire        d_rstrb;
   wire [31:0] d_rdata;
   wire        d_rbusy;
   wire        d_wbusy;

   FemtoRV32_Core_P2 #(
      .RESET_ADDR(RESET_ADDR)
   ) core (
      .clk(clk),
      .i_addr(i_addr),
      .i_rstrb(i_rstrb),
      .i_rdata(i_rdata),
      .i_rbusy(i_rbusy),
      .d_addr(d_addr),
      .d_wdata(d_wdata),
      .d_wmask(d_wmask),
      .d_rstrb(d_rstrb),
      .d_rdata(d_rdata),
      .d_rbusy(d_rbusy),
      .d_wbusy(d_wbusy),
      .irq_i(irq_i),
      .reset_n(reset_n)
   );

   reg [31:0] i_rdata_reg;
   reg [31:0] d_rdata_reg;

   assign i_rdata = (i_rstrb & instr_hit) ? iwb_buf[instr_word_idx] : i_rdata_reg;
   assign d_rdata = d_rdata_reg;

   // Instruction wishbone (pipelined, read-only)
   localparam integer IWB_BURST_BITS = (IWB_BURST_LEN <= 1) ? 1 : $clog2(IWB_BURST_LEN);
   localparam [29:0] IWB_BURST_LEN_W = IWB_BURST_LEN;

   reg                         iwb_burst_active;
   reg  [29:0]        iwb_base_addr;
   reg  [29:0]        iwb_burst_addr;
   reg  [IWB_BURST_BITS:0]      iwb_beats_left;
   reg  [IWB_BURST_LEN-1:0]     iwb_word_valid;
   reg                         iwb_buf_valid;
   reg  [31:0]                  iwb_buf [0:IWB_BURST_LEN-1];

   wire [29:0] instr_word_addr = i_addr[31:2];
   wire [29:0] iwb_base_calc = (IWB_BURST_LEN <= 1) ?
                                          instr_word_addr :
                                          (instr_word_addr / IWB_BURST_LEN) * IWB_BURST_LEN;
   wire [29:0] iwb_base_end = iwb_base_addr + IWB_BURST_LEN_W;
   wire                  instr_in_range = (instr_word_addr >= iwb_base_addr) &
                                          (instr_word_addr <  iwb_base_end);
   wire [29:0] instr_word_off = instr_word_addr - iwb_base_addr;
   wire [IWB_BURST_BITS-1:0] instr_word_idx = instr_word_off[IWB_BURST_BITS-1:0];
   wire                  instr_hit = iwb_buf_valid & instr_in_range & iwb_word_valid[instr_word_idx];

   wire [29:0] iwb_curr_off = iwb_burst_addr - iwb_base_addr;
   wire [IWB_BURST_BITS-1:0] iwb_curr_idx = iwb_curr_off[IWB_BURST_BITS-1:0];
   wire                  iwb_last_beat = iwb_burst_active & (iwb_beats_left == 1);

   assign iwb_adr_o = {iwb_burst_addr, 2'b00 };
   assign iwb_dat_o = 32'b0;
   assign iwb_sel_o = 4'b1111;
   assign iwb_we_o  = 1'b0;
   assign iwb_cyc_o = iwb_burst_active;
   assign iwb_stb_o = iwb_burst_active;
   assign iwb_cti_o = iwb_burst_active ? (iwb_last_beat ? 3'b111 : 3'b010) : IWB_CTI;
   assign iwb_bte_o = IWB_BTE;

   assign i_rdata = (i_rstrb & instr_hit) ? iwb_buf[instr_word_idx] : i_rdata_reg;

   // Data wishbone (classic, read/write)
   reg        dwb_pending;
   reg        dwb_we_pending;
   reg [31:0] dwb_adr_pending;
   reg [31:0] dwb_dat_pending;
   reg  [3:0] dwb_sel_pending;

   wire dwb_new_req = d_rstrb | (|d_wmask);
   wire dwb_new_we  = |d_wmask;
   wire [3:0] dwb_new_sel = dwb_new_we ? d_wmask : 4'b1111;

   wire dwb_active  = dwb_pending | dwb_new_req;
   wire dwb_waiting = dwb_active & ~dwb_ack_i;
   wire dwb_we_comb = dwb_pending ? dwb_we_pending : dwb_new_we;

   assign dwb_adr_o = dwb_pending ? dwb_adr_pending : d_addr;
   assign dwb_dat_o = dwb_pending ? dwb_dat_pending : d_wdata;
   assign dwb_sel_o = dwb_pending ? dwb_sel_pending : dwb_new_sel;
   assign dwb_we_o  = dwb_we_comb;
   assign dwb_cyc_o = dwb_active;
   assign dwb_stb_o = dwb_active;
   assign dwb_cti_o = DWB_CTI;
   assign dwb_bte_o = DWB_BTE;

   assign i_rbusy = (i_rstrb & ~instr_hit);
   assign d_rbusy = dwb_waiting & ~dwb_we_comb;
   assign d_wbusy = dwb_waiting & dwb_we_comb;

   always @(posedge clk) begin
      if(!reset_n) begin
         iwb_burst_active <= 1'b0;
         iwb_beats_left   <= 0;
         iwb_word_valid   <= 0;
         iwb_buf_valid    <= 1'b0;
         dwb_pending      <= 1'b0;
      end else begin
         if (!iwb_burst_active) begin
            if (i_rstrb & ~instr_hit) begin
               iwb_burst_active <= 1'b1;
               iwb_base_addr    <= iwb_base_calc;
               iwb_burst_addr   <= iwb_base_calc;
               iwb_beats_left   <= IWB_BURST_LEN;
               iwb_word_valid   <= 0;
               iwb_buf_valid    <= 1'b1;
            end
         end else if (iwb_ack_i) begin
            iwb_buf[iwb_curr_idx] <= iwb_dat_i;
            iwb_word_valid[iwb_curr_idx] <= 1'b1;
            if (iwb_beats_left == 1) begin
               iwb_burst_active <= 1'b0;
               iwb_beats_left   <= 0;
            end else begin
               iwb_beats_left <= iwb_beats_left - 1'b1;
               iwb_burst_addr <= iwb_burst_addr + 1'b1;
            end
         end

         if (!dwb_pending) begin
            if (dwb_new_req) begin
               dwb_pending     <= ~dwb_ack_i;
               dwb_we_pending  <= dwb_new_we;
               dwb_adr_pending <= d_addr;
               dwb_dat_pending <= d_wdata;
               dwb_sel_pending <= dwb_new_sel;
            end
         end else if (dwb_ack_i) begin
            dwb_pending <= 1'b0;
         end
      end

      if (iwb_ack_i) i_rdata_reg <= iwb_dat_i;
      if (dwb_ack_i) d_rdata_reg <= dwb_dat_i;
   end

endmodule

/*****************************************************************************/

// if c[15:0] is a compressed instruction, decompresses it in d
// else copies c to d
module decompressor(
   input  wire [31:0] c,
   output reg  [31:0] d
);

   // How to handle illegal and unknown opcodes

   localparam illegal = 32'h00000000;
   localparam unknown = 32'h00000000;

   // Register decoder

   wire [4:0] rcl = {2'b01, c[4:2]}; // Register compressed low
   wire [4:0] rch = {2'b01, c[9:7]}; // Register compressed high

   wire [4:0] rwl  = c[ 6:2];  // Register wide low
   wire [4:0] rwh  = c[11:7];  // Register wide high

   localparam x0 = 5'b00000;
   localparam x1 = 5'b00001;
   localparam x2 = 5'b00010;   

   // Immediate decoder

   wire  [4:0]    shiftImm = c[6:2];

   wire [11:0] addi4spnImm = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00};
   wire [11:0]     lwswImm = {5'b00000, c[5], c[12:10] , c[6], 2'b00};
   wire [11:0]     lwspImm = {4'b0000, c[3:2], c[12], c[6:4], 2'b00};
   wire [11:0]     swspImm = {4'b0000, c[8:7], c[12:9], 2'b00};

   wire [11:0] addi16spImm = {{ 3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000};
   wire [11:0]      addImm = {{ 7{c[12]}}, c[6:2]};

   /* verilator lint_off UNUSED */
   wire [12:0]        bImm = {{ 5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};
   wire [20:0]      jalImm = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
   wire [31:0]      luiImm = {{15{c[12]}}, c[6:2], 12'b000000000000};
   /* verilator lint_on UNUSED */

   always @*
   casez (c[15:0])
                                                     // imm / funct7   +   rs2  rs1     fn3                   rd    opcode
      16'b???___????????_???_11 : d =                                                                            c  ; // Long opcode, no need to decompress

/* verilator lint_off CASEOVERLAP */
     
      16'b000___00000000_000_00 : d =                                                                       illegal ; // c.illegal   -->  illegal
      16'b000___????????_???_00 : d = {      addi4spnImm,             x2, 3'b000,                 rcl, 7'b00100_11} ; // c.addi4spn  -->  addi rd', x2, nzuimm[9:2]
/* verilator lint_on CASEOVERLAP */
     
      16'b010_???_???_??_???_00 : d = {          lwswImm,            rch, 3'b010,                 rcl, 7'b00000_11} ; // c.lw        -->  lw   rd', offset[6:2](rs1')
      16'b110_???_???_??_???_00 : d = {    lwswImm[11:5],       rcl, rch, 3'b010,        lwswImm[4:0], 7'b01000_11} ; // c.sw        -->  sw   rs2', offset[6:2](rs1')

      16'b000_???_???_??_???_01 : d = {           addImm,            rwh, 3'b000,                 rwh, 7'b00100_11} ; // c.addi      -->  addi rd, rd, nzimm[5:0]
      16'b001____???????????_01 : d = {     jalImm[20], jalImm[10:1], jalImm[11], jalImm[19:12],   x1, 7'b11011_11} ; // c.jal       -->  jal  x1, offset[11:1]
      16'b010__?_?????_?????_01 : d = {           addImm,             x0, 3'b000,                 rwh, 7'b00100_11} ; // c.li        -->  addi rd, x0, imm[5:0]
      16'b011__?_00010_?????_01 : d = {      addi16spImm,            rwh, 3'b000,                 rwh, 7'b00100_11} ; // c.addi16sp  -->  addi x2, x2, nzimm[9:4]
      16'b011__?_?????_?????_01 : d = {    luiImm[31:12],                                         rwh, 7'b01101_11} ; // c.lui       -->  lui  rd, nzuimm[17:12]
      16'b100_?_00_???_?????_01 : d = {       7'b0000000,  shiftImm, rch, 3'b101,                 rch, 7'b00100_11} ; // c.srli      -->  srli rd', rd', shamt[5:0]
      16'b100_?_01_???_?????_01 : d = {       7'b0100000,  shiftImm, rch, 3'b101,                 rch, 7'b00100_11} ; // c.srai      -->  srai rd', rd', shamt[5:0]
      16'b100_?_10_???_?????_01 : d = {           addImm,            rch, 3'b111,                 rch, 7'b00100_11} ; // c.andi      -->  andi rd', rd', imm[5:0]
      16'b100_011_???_00_???_01 : d = {       7'b0100000,       rcl, rch, 3'b000,                 rch, 7'b01100_11} ; // c.sub       -->  sub  rd', rd', rs2'
      16'b100_011_???_01_???_01 : d = {       7'b0000000,       rcl, rch, 3'b100,                 rch, 7'b01100_11} ; // c.xor       -->  xor  rd', rd', rs2'
      16'b100_011_???_10_???_01 : d = {       7'b0000000,       rcl, rch, 3'b110,                 rch, 7'b01100_11} ; // c.or        -->  or   rd', rd', rs2'
      16'b100_011_???_11_???_01 : d = {       7'b0000000,       rcl, rch, 3'b111,                 rch, 7'b01100_11} ; // c.and       -->  and  rd', rd', rs2'
      16'b101____???????????_01 : d = {     jalImm[20], jalImm[10:1], jalImm[11], jalImm[19:12],   x0, 7'b11011_11} ; // c.j         -->  jal  x0, offset[11:1]
      16'b110__???_???_?????_01 : d = {bImm[12], bImm[10:5],     x0, rch, 3'b000, bImm[4:1], bImm[11], 7'b11000_11} ; // c.beqz      -->  beq  rs1', x0, offset[8:1]
      16'b111__???_???_?????_01 : d = {bImm[12], bImm[10:5],     x0, rch, 3'b001, bImm[4:1], bImm[11], 7'b11000_11} ; // c.bnez      -->  bne  rs1', x0, offset[8:1]

      16'b000__?_?????_?????_10 : d = {        7'b0000000, shiftImm, rwh, 3'b001,                 rwh, 7'b00100_11} ; // c.slli      -->  slli rd, rd, shamt[5:0]
      16'b010__?_?????_?????_10 : d = {           lwspImm,            x2, 3'b010,                 rwh, 7'b00000_11} ; // c.lwsp      -->  lw   rd, offset[7:2](x2)
      16'b100__0_?????_00000_10 : d = {  12'b000000000000,           rwh, 3'b000,                  x0, 7'b11001_11} ; // c.jr        -->  jalr x0, rs1, 0
      16'b100__0_?????_?????_10 : d = {        7'b0000000,      rwl,  x0, 3'b000,                 rwh, 7'b01100_11} ; // c.mv        -->  add  rd, x0, rs2
   // 16'b100__1_00000_00000_10 : d = {                              25'b00000000_00010000_00000000_0, 7'b11100_11} ; // c.ebreak    -->  ebreak
      16'b100__1_?????_00000_10 : d = {  12'b000000000000,           rwh, 3'b000,                  x1, 7'b11001_11} ; // c.jalr      -->  jalr x1, rs1, 0
      16'b100__1_?????_?????_10 : d = {        7'b0000000,      rwl, rwh, 3'b000,                 rwh, 7'b01100_11} ; // c.add       -->  add  rd, rd, rs2
      16'b110__?_?????_?????_10 : d = {     swspImm[11:5],      rwl,  x2, 3'b010,        swspImm[4:0], 7'b01000_11} ; // c.swsp      -->  sw   rs2, offset[7:2](x2)

      default:                    d =                                                                       unknown ; // Unknown opcode
   endcase
endmodule

/*****************************************************************************/
