/******************************************************************************/
// FemtoRV32 Pipedream
//
// Based on FemtoRV32_Gracilis_WB (femtorv32_gracilis_wb.v)
//
// Key optimization over Gracilis:
//   During EXECUTE of any non-memory / non-divide / non-interrupt instruction
//   the instruction bus is asserted for PC_new in the *same* cycle.  This
//   allows the state machine to jump directly from EXECUTE to WAIT_INSTR,
//   skipping the FETCH_INSTR state and saving one bus-turn-around cycle per
//   non-memory instruction.
//
//   Steady-state throughput for sequential ALU code:
//     Gracilis  : FETCH → WAIT → EXECUTE  = 3 cycles / instruction
//     Pipedream : EXECUTE → WAIT_INSTR    = 2 cycles / instruction (after warmup)
//
//   Memory (load/store) and divide instructions fall back to the same
//   WAIT_ALU_OR_MEM → FETCH_INSTR path as Gracilis; no bus conflicts arise
//   because exec_prefetch and d_active are mutually exclusive.
//
// Instruction Set: RV32IMC + CSR + MRET
//
// Parameters:
//   RESET_ADDR: Initial program counter (default 0x00000000)
//
// Interfaces (FemtoRV32_Pipedream_WB):
//   wb_*:       single classic Wishbone master (instruction fetch + data r/w)
//   irq_i[7:0]: 8 interrupt request lines
//
// Bruno Levy, Matthias Koch, 2020-2021 (original Gracilis)
// Wishbone + 8-IRQ adaptation: see femtorv32_gracilis_wb.v
// Exec-prefetch optimization: see problem statement (Pipedream)
/******************************************************************************/

// Firmware generation flags for this processor
`define NRV_ARCH     "rv32imac"
`define NRV_ABI      "ilp32"
`define NRV_OPTIMIZE "-O3"
`define NRV_INTERRUPTS

/******************************************************************************/
// FemtoRV32_Pipedream_Core: single-bus RV32IMC core with exec-time prefetch
//
// State machine (4 states, same encoding as Gracilis):
//   FETCH_INSTR       → assert i_rstrb, advance to WAIT_INSTR
//   WAIT_INSTR        → wait for ~i_rbusy, decode, go to EXECUTE
//                       (may re-enter FETCH_INSTR for unaligned RVC second half)
//   EXECUTE           → execute; if exec_prefetch (non-mem/div, no IRQ):
//                         assert i_rstrb for PC_new → go to WAIT_INSTR (skip FETCH)
//                       else: go to WAIT_ALU_OR_MEM or FETCH_INSTR
//   WAIT_ALU_OR_MEM   → wait for ~aluBusy & ~d_rbusy & ~d_wbusy, then FETCH_INSTR
/******************************************************************************/

module FemtoRV32_Pipedream_Core (
   input          clk,

   // Instruction bus (classic single-word read)
   output [31:0]  i_addr,
   output         i_rstrb,
   input  [31:0]  i_rdata,
   input          i_rbusy,

   // Data bus (classic read/write)
   output [31:0]  d_addr,
   output [31:0]  d_wdata,
   output  [3:0]  d_wmask,
   output         d_rstrb,
   input  [31:0]  d_rdata,
   input          d_rbusy,
   input          d_wbusy,

   // Interrupt lines: irq_i[0] = highest priority, irq_i[7] = lowest
   input   [7:0]  irq_i,

   input          reset_n   // synchronous reset, active low
);

   parameter RESET_ADDR = 32'h00000000;

   /***************************************************************************/
   // State machine
   /***************************************************************************/

   localparam FETCH_INSTR_bit     = 0;
   localparam WAIT_INSTR_bit      = 1;
   localparam EXECUTE_bit         = 2;
   localparam WAIT_ALU_OR_MEM_bit = 3;
   localparam NB_STATES           = 4;

   localparam FETCH_INSTR     = 1 << FETCH_INSTR_bit;
   localparam WAIT_INSTR      = 1 << WAIT_INSTR_bit;
   localparam EXECUTE         = 1 << EXECUTE_bit;
   localparam WAIT_ALU_OR_MEM = 1 << WAIT_ALU_OR_MEM_bit;

   (* onehot *)
   reg [NB_STATES-1:0] state;

   /***************************************************************************/
   // Instruction decoding
   /***************************************************************************/

   wire [4:0] rdId = instr[11:7];

   (* onehot *)
   wire [7:0] funct3Is = 8'b00000001 << instr[14:12];

   wire [31:0] Uimm = {    instr[31],   instr[30:12], {12{1'b0}}};
   wire [31:0] Iimm = {{21{instr[31]}}, instr[30:20]};
   /* verilator lint_off UNUSED */
   wire [31:0] Simm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
   wire [31:0] Bimm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
   wire [31:0] Jimm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
   /* verilator lint_on UNUSED */

   wire isLoad    = (instr[6:2] == 5'b00000);
   wire isALUimm  = (instr[6:2] == 5'b00100);
   wire isAUIPC   = (instr[6:2] == 5'b00101);
   wire isStore   = (instr[6:2] == 5'b01000);
   wire isALUreg  = (instr[6:2] == 5'b01100);
   wire isLUI     = (instr[6:2] == 5'b01101);
   wire isBranch  = (instr[6:2] == 5'b11000);
   wire isJALR    = (instr[6:2] == 5'b11001);
   wire isJAL     = (instr[6:2] == 5'b11011);
   wire isSYSTEM  = (instr[6:2] == 5'b11100);

   wire isALU = isALUimm | isALUreg;

   /***************************************************************************/
   // Register file
   /***************************************************************************/

   reg [31:0] rs1;
   reg [31:0] rs2;
   reg [31:0] registerFile [31:0];

   integer _i_pd;
   initial begin
      for (_i_pd = 0; _i_pd < 32; _i_pd = _i_pd + 1)
         registerFile[_i_pd] = 0;
   end

   always @(posedge clk) begin
      if (writeBack)
         if (rdId != 0)
            registerFile[rdId] <= writeBackData;
   end

   /***************************************************************************/
   // ALU
   /***************************************************************************/

   wire [31:0] aluIn1 = rs1;
   wire [31:0] aluIn2 = isALUreg | isBranch ? rs2 : Iimm;

   // aluWr pulses in EXECUTE to start a division
   wire aluWr = state[EXECUTE_bit] & isALU;

   wire [31:0] aluPlus  = aluIn1 + aluIn2;
   wire [32:0] aluMinus = {1'b1, ~aluIn2} + {1'b0, aluIn1} + 33'b1;
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

   wire funcM    = instr[25];
   wire isDivide = isALUreg & funcM & instr[14];
   wire aluBusy  = |quotient_msk;

   wire isMULH   = funct3Is[1];
   wire isMULHSU = funct3Is[2];

   wire sign1 = aluIn1[31] &  isMULH;
   wire sign2 = aluIn2[31] & (isMULH | isMULHSU);

   wire signed [32:0] signed1  = {sign1, aluIn1};
   wire signed [32:0] signed2  = {sign2, aluIn2};
   wire signed [63:0] multiply = signed1 * signed2;

   wire [31:0] aluOut_base =
     (funct3Is[0] ? instr[30] & instr[5] ? aluMinus[31:0] : aluPlus : 32'b0) |
     (funct3Is[1] ? leftshift                                        : 32'b0) |
     (funct3Is[2] ? {31'b0, LT}                                      : 32'b0) |
     (funct3Is[3] ? {31'b0, LTU}                                     : 32'b0) |
     (funct3Is[4] ? aluIn1 ^ aluIn2                                  : 32'b0) |
     (funct3Is[5] ? shifter                                          : 32'b0) |
     (funct3Is[6] ? aluIn1 | aluIn2                                  : 32'b0) |
     (funct3Is[7] ? aluIn1 & aluIn2                                  : 32'b0);

   wire [31:0] aluOut_muldiv =
     (  funct3Is[0]   ? multiply[31: 0] : 32'b0) |
     ( |funct3Is[3:1] ? multiply[63:32] : 32'b0) |
     (  instr[14]     ? div_sign ? -divResult : divResult : 32'b0);

   wire [31:0] aluOut = isALUreg & funcM ? aluOut_muldiv : aluOut_base;

   // Division
   reg [31:0] dividend;
   reg [62:0] divisor;
   reg [31:0] quotient;
   reg [31:0] quotient_msk;

   wire divstep_do = (divisor <= {31'b0, dividend});
   wire [31:0] dividendN   = divstep_do ? dividend - divisor[31:0] : dividend;
   wire [31:0] quotientN   = divstep_do ? quotient | quotient_msk  : quotient;

   wire div_sign = ~instr[12] & (instr[13] ? aluIn1[31] :
                                           (aluIn1[31] != aluIn2[31]) & |aluIn2);
   reg [31:0] divResult;

   /***************************************************************************/
   // Branch predicate
   /***************************************************************************/

   wire predicate =
        funct3Is[0] &  EQ  |
        funct3Is[1] & !EQ  |
        funct3Is[4] &  LT  |
        funct3Is[5] & !LT  |
        funct3Is[6] &  LTU |
        funct3Is[7] & !LTU;

   /***************************************************************************/
   // Program counter and address computation
   /***************************************************************************/

   reg  [31:0] PC;
   reg  [31:2]           instr;
   reg                   long_instr;

   wire [31:0] PCplus2 = PC + 2;
   wire [31:0] PCplus4 = PC + 4;
   wire [31:0] PCinc   = long_instr ? PCplus4 : PCplus2;

   wire [31:0] PCplusImm = PC + ( instr[3] ? Jimm[31:0] :
                                            instr[4] ? Uimm[31:0] :
                                                       Bimm[31:0] );

   wire [31:0] loadstore_addr = rs1[31:0] +
                   (instr[5] ? Simm[31:0] : Iimm[31:0]);

   wire [31:0] PC_new =
           isJALR                         ? {aluPlus[31:1], 1'b0} :
           isJAL | (isBranch & predicate) ? PCplusImm :
           interrupt_return               ? mepc :
                                            PCinc;

   /***************************************************************************/
   // Instruction bus: exec-time prefetch
   //
   // exec_prefetch fires in EXECUTE when the bus is free (non-memory,
   // non-divide, no interrupt taken).  The address is PC_new — the
   // combinatorially computed next-instruction address.  The state machine
   // then transitions directly to WAIT_INSTR, skipping FETCH_INSTR.
   //
   // When exec_prefetch=0 the bus is either idle (normal FETCH_INSTR path)
   // or used for a data transaction (needToWait=1); bus conflicts cannot occur.
   /***************************************************************************/

   wire exec_prefetch = state[EXECUTE_bit] & ~needToWait & ~interrupt;

   /* verilator lint_off WIDTH */
   assign i_addr  = exec_prefetch        ? {PC_new[31:2], 2'b00}
                  : fetch_second_half    ? {PCplus4[31:2], 2'b00}
                  :                       {PC[31:2], 2'b00};
   assign d_addr  = loadstore_addr;
   /* verilator lint_on WIDTH */

   // i_rstrb is asserted in FETCH_INSTR, WAIT_INSTR, and during exec_prefetch
   assign i_rstrb = state[FETCH_INSTR_bit] | state[WAIT_INSTR_bit] | exec_prefetch;

   /***************************************************************************/
   // Load/Store
   /***************************************************************************/

   wire mem_byteAccess     = instr[13:12] == 2'b00;
   wire mem_halfwordAccess = instr[13:12] == 2'b01;

   wire [15:0] LOAD_halfword =
               loadstore_addr[1] ? d_rdata[31:16] : d_rdata[15:0];

   wire  [7:0] LOAD_byte =
               loadstore_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];

   wire LOAD_sign =
        !instr[14] & (mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);

   wire [31:0] LOAD_data =
         mem_byteAccess     ? {{24{LOAD_sign}},     LOAD_byte} :
         mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                              d_rdata;

   wire [3:0] STORE_wmask =
              mem_byteAccess ?
                    (loadstore_addr[1] ?
                          (loadstore_addr[0] ? 4'b1000 : 4'b0100) :
                          (loadstore_addr[0] ? 4'b0010 : 4'b0001)
                    ) :
              mem_halfwordAccess ?
                    (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
              4'b1111;

   assign d_wdata[ 7: 0] = rs2[7:0];
   assign d_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0]  : rs2[15: 8];
   assign d_wdata[23:16] = loadstore_addr[1] ? rs2[7:0]  : rs2[23:16];
   assign d_wdata[31:24] = loadstore_addr[0] ? rs2[7:0]  :
                           loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

   assign d_rstrb = state[EXECUTE_bit] & isLoad;
   assign d_wmask = {4{state[EXECUTE_bit] & isStore}} & STORE_wmask;

   /***************************************************************************/
   // Unaligned-fetch / RVC boundary register
   /***************************************************************************/

   reg [31:2] cached_addr;
   reg           [31:0] cached_data;
   reg                  fetch_second_half;

   wire current_cache_hit = cached_addr == PC[31:2];

   wire [31:0] cached_mem   = current_cache_hit ? cached_data : i_rdata;
   wire [31:0] decomp_input = PC[1] ? {i_rdata[15:0], cached_mem[31:16]}
                                    : cached_mem;
   wire [31:0] decompressed;

   decompressor_pipedream _decomp (.c(decomp_input), .d(decompressed));

   wire current_unaligned_long = &cached_mem[17:16] & PC[1];

   /***************************************************************************/
   // CSR registers and interrupt logic
   /***************************************************************************/

   reg  [31:0] mepc;
   reg  [31:0] mtvec;
   reg                   mstatus; // global interrupt enable (MIE = bit 3)
   reg  [31:0]           mcause;  // bit 31 = interrupt, [3:0] = IRQ index
   reg  [63:0]           cycles;

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
     (sel_cyclesh ? cycles[63:32]          : 32'b0);
   /* verilator lint_on WIDTH */

   wire [31:0] CSR_modifier = instr[14] ? {27'd0, instr[19:15]} : rs1;

   wire [31:0] CSR_write = (instr[13:12] == 2'b10) ? CSR_modifier | CSR_read  :
                           (instr[13:12] == 2'b11) ? ~CSR_modifier & CSR_read :
                                                      CSR_modifier;

   wire interrupt_return = isSYSTEM & funct3Is[0];

   // 8-level priority encoder: irq_i[0] = highest priority (cause 0)
   wire any_irq = |irq_i;
   reg  interrupt_request_sticky;

   /* verilator lint_off WIDTH */
   wire [7:0] irq_prio =
      irq_i[0] ? 8'd1 :
      irq_i[1] ? 8'd2 :
      irq_i[2] ? 8'd3 :
      irq_i[3] ? 8'd4 :
      irq_i[4] ? 8'd5 :
      irq_i[5] ? 8'd6 :
      irq_i[6] ? 8'd7 :
      irq_i[7] ? 8'd8 : 8'd0;

   wire [31:0] irq_cause  = {28'b0, (irq_prio == 0 ? 4'd0 : irq_prio[3:0] - 4'd1)};
   /* verilator lint_on WIDTH */
   wire [31:0] irq_mcause = 32'h80000000 | irq_cause;

   wire mcause_lock = |mcause;
   wire interrupt   = interrupt_request_sticky & mstatus & ~mcause_lock;

   // Accepted when the state machine acts on the interrupt in EXECUTE
   wire interrupt_accepted = interrupt & state[EXECUTE_bit];

   /***************************************************************************/
   // Write-back
   /***************************************************************************/

   wire writeBack = ~(isBranch | isStore) &
                    (state[EXECUTE_bit] | state[WAIT_ALU_OR_MEM_bit]);

   /* verilator lint_off WIDTH */
   wire [31:0] writeBackData =
      (isSYSTEM          ? CSR_read  : 32'b0) |
      (isLUI             ? Uimm      : 32'b0) |
      (isALU             ? aluOut    : 32'b0) |
      (isAUIPC           ? PCplusImm : 32'b0) |
      (isJALR | isJAL    ? PCinc     : 32'b0) |
      (isLoad            ? LOAD_data : 32'b0);
   /* verilator lint_on WIDTH */

   wire needToWait = isLoad | isStore | isDivide;

   /***************************************************************************/
   // Main clocked state machine
   /***************************************************************************/

   always @(posedge clk) begin
      if (!reset_n) begin
         state                    <= WAIT_ALU_OR_MEM; // → FETCH_INSTR on first cycle
         PC                       <= RESET_ADDR[31:0];
         mcause                   <= 32'b0;
         mstatus                  <= 1'b0;
         mtvec                    <= 0;
         mepc                     <= 0;
         cached_addr              <= {30{1'b1}}; // invalid address
         fetch_second_half        <= 1'b0;
         interrupt_request_sticky <= 1'b0;
         dividend                 <= 0;
         divisor                  <= 0;
         quotient                 <= 0;
         quotient_msk             <= 0;
         divResult                <= 0;
      end else begin
         // Track sticky interrupt requests
         interrupt_request_sticky <=
            any_irq | (interrupt_request_sticky & ~interrupt_accepted);

         // Division step (iterates every cycle while aluBusy)
         if (isDivide & aluWr) begin
            dividend     <= ~instr[12] & aluIn1[31] ? -aluIn1 : aluIn1;
            divisor      <= {(~instr[12] & aluIn2[31] ? -aluIn2 : aluIn2), 31'b0};
            quotient     <= 0;
            quotient_msk <= 1 << 31;
         end else begin
            dividend     <= dividendN;
            divisor      <= divisor >> 1;
            quotient     <= quotientN;
            quotient_msk <= quotient_msk >> 1;
         end
         divResult <= instr[13] ? dividendN : quotientN;

         // CSR writes (EXECUTE state only)
         if (isSYSTEM & (instr[14:12] != 0) & state[EXECUTE_bit]) begin
            if (sel_mstatus) mstatus <= CSR_write[3];
            if (sel_mtvec  ) mtvec   <= CSR_write[31:0];
         end

         (* parallel_case *)
         case (1'b1)

            state[WAIT_INSTR_bit]: begin
               if (!i_rbusy) begin
                  // Save fetched word for unaligned-RVC reassembly
                  if (~current_cache_hit | fetch_second_half) begin
                     cached_addr <= i_addr[31:2];
                     cached_data <= i_rdata;
                  end

                  // Read register file and latch decoded instruction
                  rs1        <= registerFile[decompressed[19:15]];
                  rs2        <= registerFile[decompressed[24:20]];
                  instr      <= decompressed[31:2];
                  long_instr <= &decomp_input[1:0];

                  // Unaligned 32-bit instruction spanning two words:
                  // first half is in cached_data, re-fetch for second half
                  if (current_unaligned_long & ~fetch_second_half) begin
                     fetch_second_half <= 1'b1;
                     state             <= FETCH_INSTR;
                  end else begin
                     fetch_second_half <= 1'b0;
                     state             <= EXECUTE;
                  end
               end
            end

            state[EXECUTE_bit]: begin
               if (interrupt) begin
                  // Take interrupt: redirect to mtvec, save PC, record cause
                  PC     <= mtvec;
                  mepc   <= PC_new;
                  mcause <= irq_mcause;
                  // No exec_prefetch on interrupt: fall back to FETCH_INSTR
                  state  <= needToWait ? WAIT_ALU_OR_MEM : FETCH_INSTR;
               end else begin
                  PC <= PC_new;
                  if (interrupt_return) mcause <= 32'b0;
                  if (needToWait) begin
                     state <= WAIT_ALU_OR_MEM;
                  end else begin
                     // KEY OPTIMIZATION: exec_prefetch asserted — i_rstrb is
                     // already driving PC_new onto the bus this cycle, so we
                     // skip FETCH_INSTR and go directly to WAIT_INSTR.
                     state <= WAIT_INSTR;
                  end
               end
            end

            state[WAIT_ALU_OR_MEM_bit]: begin
               if (!aluBusy & !d_rbusy & !d_wbusy) begin
                  state <= FETCH_INSTR;
               end
            end

            default: begin // FETCH_INSTR
               state <= WAIT_INSTR;
            end

         endcase
      end
   end

endmodule

/******************************************************************************/
// FemtoRV32_Pipedream_WB: single classic-Wishbone wrapper
//
// Identical in structure to FemtoRV32_Gracilis_WB: a single bus is shared
// between instruction fetches and data accesses.  No arbitration is needed
// because the Pipedream core guarantees mutual exclusion:
//   exec_prefetch=1  →  i_rstrb=1, d_rstrb=0, d_wmask=0
//   needToWait=1     →  i_rstrb=0 (no exec_prefetch), d_rstrb or d_wmask set
//   FETCH/WAIT_INSTR →  i_rstrb=1, d_rstrb=0, d_wmask=0
//   WAIT_ALU_OR_MEM  →  i_rstrb=0, d_pending may hold a pending data tx
/******************************************************************************/

module FemtoRV32_Pipedream_WB #(
   parameter RESET_ADDR = 32'h00000000
)(
   input          clk,

   // Single Wishbone master bus (classic, shared instruction+data, no burst)
   output [31:0]  wb_adr_o,
   output [31:0]  wb_dat_o,
   output  [3:0]  wb_sel_o,
   output         wb_we_o,
   output         wb_cyc_o,
   output         wb_stb_o,
   output  [2:0]  wb_cti_o,
   output  [1:0]  wb_bte_o,
   input  [31:0]  wb_dat_i,
   input          wb_ack_i,

   input   [7:0]  irq_i,

   input          reset_n
);

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

   FemtoRV32_Pipedream_Core #(
      .RESET_ADDR(RESET_ADDR)
   ) core (
      .clk      (clk),
      .i_addr   (i_addr),
      .i_rstrb  (i_rstrb),
      .i_rdata  (i_rdata),
      .i_rbusy  (i_rbusy),
      .d_addr   (d_addr),
      .d_wdata  (d_wdata),
      .d_wmask  (d_wmask),
      .d_rstrb  (d_rstrb),
      .d_rdata  (d_rdata),
      .d_rbusy  (d_rbusy),
      .d_wbusy  (d_wbusy),
      .irq_i    (irq_i),
      .reset_n  (reset_n)
   );

   // -------------------------------------------------------------------------
   // Data-side pending register
   // -------------------------------------------------------------------------

   reg        d_pending;
   reg        d_we_pending;
   reg [31:0] d_adr_pending;
   reg [31:0] d_dat_pending;
   reg  [3:0] d_sel_pending;

   wire d_new_req = d_rstrb | (|d_wmask);
   wire d_new_we  = |d_wmask;
   wire [3:0] d_new_sel = d_new_we ? d_wmask : 4'b1111;

   wire d_active  = d_pending | d_new_req;
   wire d_waiting = d_active & ~wb_ack_i;
   wire d_we_comb = d_pending ? d_we_pending : d_new_we;

   // -------------------------------------------------------------------------
   // Single-bus mux — i_rstrb and d_active are mutually exclusive
   // -------------------------------------------------------------------------

   assign wb_cyc_o = i_rstrb | d_active;
   assign wb_stb_o = i_rstrb | d_active;
   assign wb_adr_o = i_rstrb ? i_addr                                      :
                               (d_pending ? d_adr_pending : d_addr);
   assign wb_dat_o = i_rstrb ? 32'b0                                       :
                               (d_pending ? d_dat_pending : d_wdata);
   assign wb_sel_o = i_rstrb ? 4'b1111                                     :
                               (d_pending ? d_sel_pending : d_new_sel);
   assign wb_we_o  = ~i_rstrb & d_we_comb;
   assign wb_cti_o = 3'b111; // classic (end of cycle)
   assign wb_bte_o = 2'b00;

   // -------------------------------------------------------------------------
   // Read-data bypass
   // -------------------------------------------------------------------------

   reg [31:0] rdata_reg;

   assign i_rdata = wb_ack_i ? wb_dat_i : rdata_reg;
   assign i_rbusy = i_rstrb & ~wb_ack_i;

   assign d_rdata = wb_ack_i ? wb_dat_i : rdata_reg;
   assign d_rbusy = d_waiting & ~d_we_comb;
   assign d_wbusy = d_waiting &  d_we_comb;

   always @(posedge clk) begin
      if (!reset_n) begin
         d_pending <= 1'b0;
      end else begin
         if (!d_pending) begin
            if (d_new_req) begin
               d_pending     <= ~wb_ack_i;
               d_we_pending  <= d_new_we;
               d_adr_pending <= d_addr;
               d_dat_pending <= d_wdata;
               d_sel_pending <= d_new_sel;
            end
         end else if (wb_ack_i) begin
            d_pending <= 1'b0;
         end
      end

      if (wb_ack_i) rdata_reg <= wb_dat_i;
   end

endmodule

/******************************************************************************/
// decompressor_pipedream: RVC (16-bit) → RV32I (32-bit) decompressor
//
// Renamed from decompressor_gracilis to avoid a duplicate-module conflict
// when all RTL files in rtl/ are compiled together.
/******************************************************************************/

// if c[15:0] is a compressed instruction, decompresses it in d
// else copies c to d
module decompressor_pipedream (
   input  wire [31:0] c,
   output reg  [31:0] d
);

   localparam illegal = 32'h00000000;
   localparam unknown = 32'h00000000;

   wire [4:0] rcl = {2'b01, c[4:2]};
   wire [4:0] rch = {2'b01, c[9:7]};
   wire [4:0] rwl  = c[ 6:2];
   wire [4:0] rwh  = c[11:7];

   localparam x0 = 5'b00000;
   localparam x1 = 5'b00001;
   localparam x2 = 5'b00010;

   always @(*) begin
      casez (c[15:0])
        // Quadrant 0
        16'b000_???_???_??_???_00: begin // C.ADDI4SPN
           d = (c[12:5] == 0) ? illegal : {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b00,
                                            x2, 3'b000, rcl, 7'b0010011};
        end
        16'b010_???_???_??_???_00: begin // C.LW
           d = {5'b0, c[5], c[12:10], c[6], 2'b00, rcl, 3'b010, rch, 7'b0000011};
        end
        16'b110_???_???_??_???_00: begin // C.SW
           d = {5'b0, c[5], c[12], rcl, rch, 3'b010, c[11:10], c[6], 2'b00, 7'b0100011};
        end
        // Quadrant 1
        16'b000_?????_?????_01: begin // C.NOP / C.ADDI
           d = {{6{c[12]}}, c[12], c[6:2], rwh, 3'b000, rwh, 7'b0010011};
        end
        16'b001_?????_?????_01: begin // C.JAL
           d = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], {9{c[12]}},
                4'b0000, x1, 7'b1101111};
        end
        16'b010_?????_?????_01: begin // C.LI
           d = {{6{c[12]}}, c[12], c[6:2], x0, 3'b000, rwh, 7'b0010011};
        end
        16'b011_00010_?????_01: begin // C.ADDI16SP
           d = (c[12:2] == 0) ? illegal :
               {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000, x2, 3'b000, x2, 7'b0010011};
        end
        16'b011_?????_?????_01: begin // C.LUI
           d = (rwh == x2 || {c[12], c[6:2]} == 0) ? illegal :
               {{14{c[12]}}, c[12], c[6:2], rwh, 7'b0110111};
        end
        16'b100_?0_00_???_???_01: begin // C.SRLI
           d = {7'b0000000, c[6:2], rch, 3'b101, rch, 7'b0010011};
        end
        16'b100_?1_00_???_???_01: begin // C.SRAI
           d = {7'b0100000, c[6:2], rch, 3'b101, rch, 7'b0010011};
        end
        16'b100_??_01_???_???_01: begin // C.ANDI
           d = {{6{c[12]}}, c[12], c[6:2], rch, 3'b111, rch, 7'b0010011};
        end
        16'b100_0_11_???_00_???_01: begin // C.SUB
           d = {7'b0100000, rcl, rch, 3'b000, rch, 7'b0110011};
        end
        16'b100_0_11_???_01_???_01: begin // C.XOR
           d = {7'b0000000, rcl, rch, 3'b100, rch, 7'b0110011};
        end
        16'b100_0_11_???_10_???_01: begin // C.OR
           d = {7'b0000000, rcl, rch, 3'b110, rch, 7'b0110011};
        end
        16'b100_0_11_???_11_???_01: begin // C.AND
           d = {7'b0000000, rcl, rch, 3'b111, rch, 7'b0110011};
        end
        16'b101_?????_?????_01: begin // C.J
           d = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], {9{c[12]}},
                4'b0000, x0, 7'b1101111};
        end
        16'b110_???_???_??_???_01: begin // C.BEQZ
           d = {{3{c[12]}}, c[12], c[6:5], c[2], 3'b000, rch, x0,
                3'b000, c[11:10], c[4:3], c[12], 7'b1100011};
        end
        16'b111_???_???_??_???_01: begin // C.BNEZ
           d = {{3{c[12]}}, c[12], c[6:5], c[2], 3'b000, rch, x0,
                3'b001, c[11:10], c[4:3], c[12], 7'b1100011};
        end
        // Quadrant 2
        16'b000_?????_?????_10: begin // C.SLLI
           d = {7'b0000000, c[6:2], rwh, 3'b001, rwh, 7'b0010011};
        end
        16'b010_?????_?????_10: begin // C.LWSP
           d = (rwh == x0) ? illegal :
               {4'b0000, c[3:2], c[12], c[6:4], 2'b00, x2, 3'b010, rwh, 7'b0000011};
        end
        16'b100_0_?????_00000_10: begin // C.JR
           d = (rwh == x0) ? illegal : {12'b0, rwh, 3'b000, x0, 7'b1100111};
        end
        16'b100_0_?????_?????_10: begin // C.MV
           d = (rwh == x0) ? illegal : {7'b0, rwl, x0, 3'b000, rwh, 7'b0110011};
        end
        16'b100_1_00000_00000_10: begin // C.EBREAK
           d = 32'h00100073;
        end
        16'b100_1_?????_00000_10: begin // C.JALR
           d = {12'b0, rwh, 3'b000, x1, 7'b1100111};
        end
        16'b100_1_?????_?????_10: begin // C.ADD
           d = {7'b0, rwl, rwh, 3'b000, rwh, 7'b0110011};
        end
        16'b110_?????_?????_10: begin // C.SWSP
           d = {4'b0000, c[8:7], c[12], rwl, x2, 3'b010, c[11:9], 2'b00, 7'b0100011};
        end
        default: begin
           d = (c[1:0] == 2'b11) ? c : unknown;
        end
      endcase
   end
endmodule
