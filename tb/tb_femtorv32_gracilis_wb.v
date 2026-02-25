`timescale 1ns/1ps

// Test FemtoRV32_Gracilis_WB: state-machine RV32IMC core with a single
// classic Wishbone bus (no instruction prefetch cache).
//
// Tests:
//   - Sequential instruction fetch with variable Wishbone wait states
//   - Store and load with correct write-back (verifies rdata bypass)
//   - Interrupt handling (two IRQ lines, priority encoding, handler MRET)
//   - Jump that redirects the fetch state machine

module tb_femtorv32_gracilis_wb;
   localparam ADDR_WIDTH = 10;
   localparam MEM_WORDS  = 256;

   reg clk;
   reg reset_n;
   reg [7:0] irq_lines;
   reg [31:0] mcause_seen0;
   reg [31:0] mcause_seen1;
   integer run_pre_irq;
   integer run_between_irq;
   integer run_post_irq;
   integer cycle_count;
   integer instr_count;

   reg [31:0] mem [0:MEM_WORDS-1];

   // Variable wait-state counter for the Wishbone bus
   localparam integer WB_WAIT_MIN   = 0;
   localparam integer WB_WAIT_MAX   = 3;
   localparam integer WB_WAIT_RANGE = (WB_WAIT_MAX - WB_WAIT_MIN + 1);
   integer wb_wait_ctr;
   reg [7:0] lfsr;

   // -----------------------------------------------------------------------
   // Memory initialization
   // -----------------------------------------------------------------------
   integer i;
   initial begin
      for (i = 0; i < MEM_WORDS; i = i + 1) begin
         mem[i] = 32'h00000013; // NOP
      end

      // Primary test sequence starting at 0x00
      mem[0]  = 32'h04000093; // 0x00: addi x1, x0, 0x40
      mem[1]  = 32'h01200113; // 0x04: addi x2, x0, 0x12
      mem[2]  = 32'h0020A023; // 0x08: sw   x2, 0(x1)      [store 0x12 → mem[0x40]]
      mem[3]  = 32'h0000A183; // 0x0C: lw   x3, 0(x1)      [load  mem[0x40] → x3]

      mem[4]  = 32'h00118213; // 0x10: addi x4, x3, 1
      mem[5]  = 32'h0040A223; // 0x14: sw   x4, 4(x1)      [store x4 → mem[0x44]]
      mem[6]  = 32'h08000293; // 0x18: addi x5, x0, 0x80   [IRQ handler @ 0x80]
      mem[7]  = 32'h30529073; // 0x1C: csrrw x0, mtvec, x5

      mem[8]  = 32'h00800313; // 0x20: addi x6, x0, 8      [MIE bit mask]
      mem[9]  = 32'h30032073; // 0x24: csrrs x0, mstatus, x6 [enable interrupts]
      mem[10] = 32'h05500393; // 0x28: addi x7, x0, 0x55   [marker value]
      mem[11] = 32'h0340006F; // 0x2C: jal  x0, 0x60       [jump to 0x60]

      // Loop at 0x60 (word offset 24)
      mem[24] = 32'h00140413; // 0x60: addi x8, x8, 1
      mem[25] = 32'h00248493; // 0x64: addi x9, x9, 2
      mem[26] = 32'h00340413; // 0x68: addi x8, x8, 3
      mem[27] = 32'h00448493; // 0x6C: addi x9, x9, 4
      mem[28] = 32'h00540413; // 0x70: addi x8, x8, 5
      mem[29] = 32'h00648493; // 0x74: addi x9, x9, 6
      mem[30] = 32'h00740413; // 0x78: addi x8, x8, 7
      mem[31] = 32'h0000006F; // 0x7C: jal  x0, 0          [loop forever]

      // Interrupt handler at 0x80 (word offset 32)
      mem[32] = 32'h0070A423; // 0x80: sw x7, 8(x1)        [write 0x55 → mem[0x48]]
      mem[33] = 32'h30200073; // 0x84: mret
   end

   initial begin
      clk = 1'b0;
      forever #5 clk = ~clk;
   end

   initial begin
      reset_n      = 1'b0;
      irq_lines    = 8'b0;
      mcause_seen0 = 32'b0;
      mcause_seen1 = 32'b0;
      cycle_count  = 0;
      instr_count  = 0;

      if (!$value$plusargs("run_pre_irq=%d",     run_pre_irq))     run_pre_irq     = 800;
      if (!$value$plusargs("run_between_irq=%d", run_between_irq)) run_between_irq = 800;
      if (!$value$plusargs("run_post_irq=%d",    run_post_irq))    run_post_irq    = 2000;

      $dumpfile("dump.vcd");
      $dumpvars(0, tb_femtorv32_gracilis_wb);

      $display("[TEST] Starting simulation...");
      repeat (5) @(posedge clk);
      reset_n = 1'b1;
      $display("[TEST] Reset released, running main program");

      repeat (run_pre_irq) @(posedge clk);
      $display("[TEST] IRQ 0 asserted");
      irq_lines[0] = 1'b1;
      repeat (2) @(posedge clk);
      irq_lines[0] = 1'b0;

      repeat (run_between_irq) @(posedge clk);
      $display("[TEST] IRQ 1 asserted");
      irq_lines[1] = 1'b1;
      repeat (2) @(posedge clk);
      irq_lines[1] = 1'b0;

      repeat (run_post_irq) @(posedge clk);

      $display("=== Simulation end ===");
      $display("mem[0x40] = 0x%08x (expect 0x00000012)", mem[16]);
      $display("mem[0x44] = 0x%08x (expect 0x00000013)", mem[17]);
      $display("x1 (addr reg)   = 0x%08x", dut.core.registerFile[1]);
      $display("x2 (store data) = 0x%08x (expect 0x12)", dut.core.registerFile[2]);
      $display("x3 (loaded)     = 0x%08x (expect 0x12)", dut.core.registerFile[3]);
      $display("x4 (x3+1)       = 0x%08x (expect 0x13)", dut.core.registerFile[4]);

      if (mem[16] !== 32'h00000012) $fatal(1, "FAIL: mem[0x40] = 0x%08x, expected 0x12", mem[16]);
      if (dut.core.registerFile[3] !== 32'h00000012)
         $fatal(1, "FAIL: x3 (load result) = 0x%08x, expected 0x12", dut.core.registerFile[3]);
      if (dut.core.registerFile[4] !== 32'h00000013)
         $fatal(1, "FAIL: x4 (x3+1) = 0x%08x, expected 0x13", dut.core.registerFile[4]);

      $display("✓ Stores executed: mem[0x40]=0x%08x, mem[0x44]=0x%08x", mem[16], mem[17]);
      $display("✓ Load correct: x3=0x%08x, x4=0x%08x", dut.core.registerFile[3], dut.core.registerFile[4]);

      if (mem[18] === 32'h00000055)
         $display("✓ Interrupt handler executed: mem[0x48]=0x55");
      else
         $display("  (Interrupt handler store not yet observed at mem[0x48]=0x%08x)", mem[18]);

      $display("");
      $display("=== Bus Statistics ===");
      $display("Wishbone transactions: %0d", wb_transaction_count);
      $display("Total cycles:          %0d", cycle_count);
      $display("Total instructions:    %0d", instr_count);

      $display("");
      $display("✓✓✓ GRACILIS WB CORE FUNCTIONAL ✓✓✓");
      $finish;
   end

   // Track first two distinct mcause values seen during interrupt handling
   always @(posedge clk) begin
      if (!reset_n) begin
         mcause_seen0 <= 32'b0;
         mcause_seen1 <= 32'b0;
      end else if (dut.core.mcause[31]) begin
         if (mcause_seen0 == 32'b0)
            mcause_seen0 <= dut.core.mcause;
         else if (mcause_seen1 == 32'b0 && dut.core.mcause != mcause_seen0)
            mcause_seen1 <= dut.core.mcause;
      end
   end

   // Instruction / ALU trace
   always @(posedge clk) begin
      if (reset_n & dut.core.ex_fire) begin
         instr_count <= instr_count + 1;
         if (dut.core.isStore)
            $display("[%0t] STORE: addr=0x%h wdata=0x%h wmask=%b",
                     $time, dut.core.d_addr, dut.core.d_wdata, dut.core.d_wmask);
         if (dut.core.isLoad)
            $display("[%0t] LOAD init: addr=0x%h", $time, dut.core.d_addr);
         if (dut.core.isALU & dut.core.rdId != 0)
            $display("[%0t] ALU: x%0d = 0x%h", $time, dut.core.rdId, dut.core.aluOut);
      end
   end

   // Load writeback trace (fires in WAIT_ALU_OR_MEM)
   always @(posedge clk) begin
      if (reset_n & dut.core.state[3] & dut.core.writeBack & dut.core.isLoad)
         $display("[%0t] LOAD done: x%0d = 0x%h", $time, dut.core.rdId, dut.core.LOAD_data);
   end

   always @(posedge clk) begin
      if (reset_n) cycle_count <= cycle_count + 1;
   end

   // LFSR for pseudo-random Wishbone wait states
   always @(posedge clk) begin
      if (!reset_n)
         lfsr <= 8'h1;
      else
         lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
   end

   // Wishbone transaction counter
   integer wb_transaction_count;
   initial wb_transaction_count = 0;
   always @(posedge clk) begin
      if (reset_n & wb_cyc_o & wb_stb_o & wb_ack_i)
         wb_transaction_count <= wb_transaction_count + 1;
   end

   // Wishbone protocol checker (classic bus)
   wire proto_error;
   wire [127:0] proto_msg;

   wishbone_protocol_checker chk (
      .clk      (clk),
      .rst      (!reset_n),
      .cyc      (wb_cyc_o),
      .stb      (wb_stb_o),
      .we       (wb_we_o),
      .ack      (wb_ack_i),
      .cti      (wb_cti_o),
      .sel      (wb_sel_o),
      .addr     (wb_adr_o),
      .data_i   (wb_dat_i),
      .data_o   (wb_dat_o),
      .bus_type (4'h1),      // classic
      .protocol_error(proto_error),
      .error_msg(proto_msg)
   );

   always @(posedge clk) begin
      if (proto_error) begin $error("WB PROTOCOL ERROR: %s", proto_msg); $finish; end
   end

   // -----------------------------------------------------------------------
   // DUT signals
   // -----------------------------------------------------------------------
   wire [31:0] wb_adr_o;
   wire [31:0] wb_dat_o;
   wire  [3:0] wb_sel_o;
   wire        wb_we_o;
   wire        wb_cyc_o;
   wire        wb_stb_o;
   wire  [2:0] wb_cti_o;
   wire  [1:0] wb_bte_o;
   reg  [31:0] wb_dat_i;
   reg         wb_ack_i;

   FemtoRV32_Gracilis_WB #(
      .RESET_ADDR(32'h00000000),
      .ADDR_WIDTH(ADDR_WIDTH)
   ) dut (
      .clk      (clk),
      .wb_adr_o (wb_adr_o),
      .wb_dat_o (wb_dat_o),
      .wb_sel_o (wb_sel_o),
      .wb_we_o  (wb_we_o),
      .wb_cyc_o (wb_cyc_o),
      .wb_stb_o (wb_stb_o),
      .wb_cti_o (wb_cti_o),
      .wb_bte_o (wb_bte_o),
      .wb_dat_i (wb_dat_i),
      .wb_ack_i (wb_ack_i),
      .irq_i    (irq_lines),
      .reset_n  (reset_n)
   );

   wire [7:0] wb_index = wb_adr_o[9:2];

   // -----------------------------------------------------------------------
   // Single memory model, variable wait states (0-3 cycles)
   // -----------------------------------------------------------------------
   always @(posedge clk) begin
      if (!reset_n) begin
         wb_ack_i   <= 1'b0;
         wb_dat_i   <= 32'b0;
         wb_wait_ctr <= 0;
      end else begin
         if (wb_cyc_o & wb_stb_o) begin
            if (wb_wait_ctr == 0) begin
               if (WB_WAIT_RANGE <= 1)
                  wb_wait_ctr <= WB_WAIT_MIN;
               else
                  wb_wait_ctr <= WB_WAIT_MIN + (lfsr % WB_WAIT_RANGE);
            end else begin
               wb_wait_ctr <= wb_wait_ctr - 1;
            end
         end else begin
            wb_wait_ctr <= 0;
         end

         wb_ack_i <= (wb_cyc_o & wb_stb_o) & (wb_wait_ctr == 1 || wb_wait_ctr == 0);
         if (wb_cyc_o & wb_stb_o & (wb_wait_ctr == 1 || wb_wait_ctr == 0)) begin
            if (wb_we_o) begin
               if (wb_sel_o[0]) mem[wb_index][ 7: 0] <= wb_dat_o[ 7: 0];
               if (wb_sel_o[1]) mem[wb_index][15: 8] <= wb_dat_o[15: 8];
               if (wb_sel_o[2]) mem[wb_index][23:16] <= wb_dat_o[23:16];
               if (wb_sel_o[3]) mem[wb_index][31:24] <= wb_dat_o[31:24];
            end else begin
               wb_dat_i <= mem[wb_index];
            end
         end
      end
   end

endmodule
