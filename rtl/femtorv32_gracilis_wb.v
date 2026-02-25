/******************************************************************************/
// FemtoRV32 Gracilis Wishbone
//
// Based on FemtoRV32 "Gracilis" by Bruno Levy, Matthias Koch, 2020-2021
// (https://github.com/BrunoLevy/learn-fpga)
//
// Adaptations:
//   - Single Wishbone master bus (classic protocol, shared instruction+data;
//     gracilis has no prefetch cache — each word is fetched individually, and
//     the state machine never issues instruction fetch and data access together)
//   - 8 independent IRQ lines with priority encoder (irq_i[0] = highest)
//   - Full 32-bit mcause register matching RISC-V privileged spec:
//       bit 31 = interrupt flag, bits [3:0] = IRQ index
//   - Synchronous active-low reset (reset_n)
//
// Instruction Set: RV32IMC + CSR + MRET
//
// Parameters:
//   RESET_ADDR: Initial program counter (default 0x00000000)
//
// Interfaces:
//   wb_*:       single classic Wishbone master (instruction fetch + data r/w)
//   irq_i[7:0]: 8 interrupt request lines
//
// Bruno Levy, Matthias Koch, 2020-2021 (original Gracilis)
// Wishbone + 8-IRQ adaptation: see femtorv32_petitpipe.v
/******************************************************************************/

// Firmware generation flags for this processor
`define NRV_ARCH     "rv32imac"
`define NRV_ABI      "ilp32"
`define NRV_OPTIMIZE "-O3"
`define NRV_INTERRUPTS

/******************************************************************************/
// FemtoRV32_Gracilis_Core: state-machine RV32IMC core with split I/D buses
// and 8-level IRQ priority (privileged-spec mcause encoding).
//
// State machine (4 states):
//   FETCH_INSTR       → assert i_rstrb, advance to WAIT_INSTR
//   WAIT_INSTR        → wait for ~i_rbusy, decode instruction, go to EXECUTE
//                       (may re-enter FETCH_INSTR for unaligned RVC second half)
//   EXECUTE           → execute instruction; load/store/divide go to
//                       WAIT_ALU_OR_MEM, otherwise go to FETCH_INSTR
//   WAIT_ALU_OR_MEM   → wait for ~aluBusy & ~d_rbusy & ~d_wbusy, write back
//                       load result, then go to FETCH_INSTR
//
// Note: gracilis has no instruction prefetch cache.  Each instruction word
// is fetched via a single classic Wishbone transaction.  The 2-word
// instruction register (cached_addr/cached_data) is only used to reassemble
// 32-bit RVC instructions that straddle a 32-bit word boundary.
/******************************************************************************/

module FemtoRV32_Gracilis_Core (
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

   // Convenience signal: high for the single cycle spent in EXECUTE
   wire ex_fire = state[EXECUTE_bit];

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

   integer _i_g;
   initial begin
      for (_i_g = 0; _i_g < 32; _i_g = _i_g + 1)
         registerFile[_i_g] = 0;
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

   /* verilator lint_off WIDTH */
   assign i_addr = fetch_second_half ? {PCplus4[31:2], 2'b00}
                                     : {PC     [31:2], 2'b00};
   assign d_addr = loadstore_addr;
   /* verilator lint_on WIDTH */

   wire [31:0] PC_new =
           isJALR                         ? {aluPlus[31:1], 1'b0} :
           isJAL | (isBranch & predicate) ? PCplusImm :
           interrupt_return               ? mepc :
                                            PCinc;

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

   // Instruction bus: asserted while fetching (FETCH_INSTR and WAIT_INSTR)
   assign i_rstrb = state[FETCH_INSTR_bit] | state[WAIT_INSTR_bit];

   /***************************************************************************/
   // Unaligned-fetch / RVC boundary register
   //
   // cached_addr / cached_data hold the last fetched 32-bit word so that a
   // 32-bit instruction straddling a word boundary can be reassembled without
   // an extra bus transaction.  This is NOT a prefetch cache.
   /***************************************************************************/

   reg [31:2] cached_addr;
   reg           [31:0] cached_data;
   reg                  fetch_second_half;

   wire current_cache_hit = cached_addr == PC[31:2];

   wire [31:0] cached_mem   = current_cache_hit ? cached_data : i_rdata;
   wire [31:0] decomp_input = PC[1] ? {i_rdata[15:0], cached_mem[31:16]}
                                    : cached_mem;
   wire [31:0] decompressed;

   decompressor_gracilis _decomp (.c(decomp_input), .d(decompressed));

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
   //
   // Write-back fires in EXECUTE (ALU/CSR/jump) and again in WAIT_ALU_OR_MEM
   // (load result / divide result).  For loads the second write wins because
   // d_rdata is valid only when d_rbusy = 0 (WAIT_ALU_OR_MEM exit condition).
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
                  state  <= needToWait ? WAIT_ALU_OR_MEM : FETCH_INSTR;
               end else begin
                  PC <= PC_new;
                  if (interrupt_return) mcause <= 32'b0;
                  state <= needToWait ? WAIT_ALU_OR_MEM : FETCH_INSTR;
               end
            end

            state[WAIT_ALU_OR_MEM_bit]: begin
               // d_rdata is presented with the bypass (see wrapper) so the
               // write-back that fires simultaneously with this transition
               // sees the correct loaded value
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
// FemtoRV32_Gracilis_WB: single classic-Wishbone wrapper for FemtoRV32_Gracilis_Core
//
// A single Wishbone master bus is shared between instruction fetches and data
// accesses.  No arbitration logic is needed: the gracilis state machine never
// issues an instruction fetch and a data access at the same time —
//   FETCH_INSTR / WAIT_INSTR  →  only i_rstrb is asserted
//   EXECUTE                   →  only d_rstrb or d_wmask are asserted
//   WAIT_ALU_OR_MEM           →  only data (kept alive by pending register)
// so the mux is purely combinational with no priority resolution required.
//
// Classic Wishbone protocol (CTI = 3'b111, no burst).
//
// Timing note: rdata bypasses its holding register when wb_ack_i is high.
// This ensures the core sees valid read data on the same clock edge that it
// transitions out of WAIT_INSTR / WAIT_ALU_OR_MEM, preserving the original
// gracilis unified-bus memory semantics.
/******************************************************************************/

module FemtoRV32_Gracilis_WB #(
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

   FemtoRV32_Gracilis_Core #(
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
   //
   // In EXECUTE the core asserts d_rstrb / d_wmask for one cycle then moves to
   // WAIT_ALU_OR_MEM where those signals drop to zero.  The pending register
   // keeps the transaction on the bus until wb_ack_i arrives.
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
   // Single-bus mux
   //
   // i_rstrb and d_active are mutually exclusive (guaranteed by the gracilis
   // state machine), so this is a simple non-conflicting mux.
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
   //
   // wb_dat_i is routed to both i_rdata and d_rdata via a bypass that presents
   // the live bus value when wb_ack_i is high.  Since instruction fetch and
   // data access are mutually exclusive only one bypass path is active at a
   // time.
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
// decompressor_gracilis: RVC (16-bit) → RV32I (32-bit) decompressor
//
// Renamed from "decompressor" to avoid a duplicate-module conflict when both
// femtorv32_petitpipe.v and femtorv32_gracilis_wb.v are compiled together.
/******************************************************************************/

// if c[15:0] is a compressed instruction, decompresses it in d
// else copies c to d
module decompressor_gracilis (
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

   wire  [4:0]    shiftImm    = c[6:2];
   wire [11:0] addi4spnImm    = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00};
   wire [11:0]     lwswImm    = {5'b00000, c[5], c[12:10], c[6], 2'b00};
   wire [11:0]     lwspImm    = {4'b0000, c[3:2], c[12], c[6:4], 2'b00};
   wire [11:0]     swspImm    = {4'b0000, c[8:7], c[12:9], 2'b00};
   wire [11:0] addi16spImm    = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000};
   wire [11:0]      addImm    = {{7{c[12]}}, c[6:2]};
   /* verilator lint_off UNUSED */
   wire [12:0]        bImm    = {{5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};
   wire [20:0]      jalImm    = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
   wire [31:0]      luiImm    = {{15{c[12]}}, c[6:2], 12'b000000000000};
   /* verilator lint_on UNUSED */

   always @*
   casez (c[15:0])
                                                      // imm / funct7   +   rs2  rs1     fn3                   rd    opcode
      16'b???___????????_???_11 : d =                                                                            c  ; // Long opcode, pass through

/* verilator lint_off CASEOVERLAP */
      16'b000___00000000_000_00 : d =                                                                       illegal ; // c.illegal
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

      default:                    d =                                                                       unknown ;
   endcase
endmodule

/*****************************************************************************/
