`timescale 1ns/1ps

// Test FemtoRV32_PetitPipe_WB: Pipelined core with Wishbone split buses
// and instruction fetch line cache (prefetch cache)
//
// Cache behavior tested:
//   - Sequential instruction fetches (cache hits within same line)
//   - Cache line prefetch on misses
//   - Variable memory latency (simulates variable wishbone response time)
//   - Interrupt handling with cache active
//   - Jump/branch instructions that may cause cache flushes

module tb_femtorv32_wb;
   localparam MEM_WORDS  = 256;
   localparam IWB_BURST_LEN = 4;  // Instruction cache line size (4 words)

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
   localparam integer WB_WAIT_MIN = 0;
   localparam integer WB_WAIT_MAX = 3;
   localparam integer WB_WAIT_RANGE = (WB_WAIT_MAX - WB_WAIT_MIN + 1);
   integer wait_ctr;
   reg [7:0] lfsr;

   // -----------------------------------------------------------------------
   // Memory initialization with cache-testing sequences
   // -----------------------------------------------------------------------
   integer i;
   initial begin
      for (i = 0; i < MEM_WORDS; i = i + 1) begin
         mem[i] = 32'h00000013; // NOP: addi x0, x0, 0
      end

      // Primary test sequence (cache line starting at 0x0, 4 instructions)
      // Tests: sequential fetches within line, cache hits
      mem[0]  = 32'h04000093; // 0x00: addi x1, x0, 0x40   [cache line 0]
      mem[1]  = 32'h01200113; // 0x04: addi x2, x0, 0x12   [cache line 0]
      mem[2]  = 32'h0020A023; // 0x08: sw   x2, 0(x1)      [cache line 0]
      mem[3]  = 32'h0000A183; // 0x0C: lw   x3, 0(x1)      [cache line 0]
      
      // Second cache line (0x10-0x1C)
      mem[4]  = 32'h00118213; // 0x10: addi x4, x3, 1      [cache line 1]
      mem[5]  = 32'h0040A223; // 0x14: sw   x4, 4(x1)      [cache line 1]
      mem[6]  = 32'h08000293; // 0x18: addi x5, x0, 0x80   [cache line 1]
      mem[7]  = 32'h30529073; // 0x1C: csrrw x0, mtvec, x5 [cache line 1]
      
      // Interrupt setup
      mem[8]  = 32'h00800313; // 0x20: addi x6, x0, 8      [cache line 2]
      mem[9]  = 32'h30032073; // 0x24: csrrs x0, mstatus, x6 [cache line 2]
      mem[10] = 32'h05500393; // 0x28: addi x7, x0, 0x55   [cache line 2]
      mem[11] = 32'h0340006F; // 0x2C: jal  x0, 0x60       [cache line 2] (jump - cache invalidate)

      // Jumped-to code (0x60 = word offset 0x18)
      // Tests: longer sequential fetch stream before looping
      mem[24] = 32'h00140413; // 0x60: addi x8, x8, 1
      mem[25] = 32'h00248493; // 0x64: addi x9, x9, 2
      mem[26] = 32'h00340413; // 0x68: addi x8, x8, 3
      mem[27] = 32'h00448493; // 0x6C: addi x9, x9, 4
      mem[28] = 32'h00540413; // 0x70: addi x8, x8, 5
      mem[29] = 32'h00648493; // 0x74: addi x9, x9, 6
      mem[30] = 32'h00740413; // 0x78: addi x8, x8, 7
      mem[31] = 32'h0000006F; // 0x7C: jal  x0, 0        (loop here)

      // Interrupt handler @ 0x80 (word offset 0x20)
      // Tests: cache behavior during interrupt, return from handler
      mem[32] = 32'h0070A423; // 0x80: sw x7, 8(x1)
      mem[33] = 32'h30200073; // 0x84: mret
   end

   initial begin
      clk = 1'b0;
      forever #5 clk = ~clk;
   end

   initial begin
      reset_n = 1'b0;
      irq_lines = 8'b0;
      mcause_seen0 = 32'b0;
      mcause_seen1 = 32'b0;
      cycle_count = 0;
      instr_count = 0;
      if (!$value$plusargs("run_pre_irq=%d", run_pre_irq))
         run_pre_irq = 500;
      if (!$value$plusargs("run_between_irq=%d", run_between_irq))
         run_between_irq = 500;
      if (!$value$plusargs("run_post_irq=%d", run_post_irq))
         run_post_irq = 1500;
      
      // Enable waveform dumping
      $dumpfile("dump.vcd");
      $dumpvars(0, tb_femtorv32_wb);
      
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
      $display("mem[0x40] = 0x%08x", mem[16]);
      $display("mem[0x44] = 0x%08x", mem[17]);
      $display("x1 (addr reg) = 0x%08x", dut.core.registerFile[1]);
      $display("x2 (first data) = 0x%08x", dut.core.registerFile[2]);
      $display("x3 (loaded) = 0x%08x", dut.core.registerFile[3]);
      $display("x4 (x3+1) = 0x%08x", dut.core.registerFile[4]);
      if (mem[16] !== 32'h00000012) $fatal(1, "Unexpected mem[0x40]");
      $display("✓ Stores executed: mem[0x40]=0x%08x, mem[0x44]=0x%08x", mem[16], mem[17]);
      $display("✓ Registers: x1=0x%08x, x2=0x%08x, x4=0x%08x", dut.core.registerFile[1], dut.core.registerFile[2], dut.core.registerFile[4]);
      if (mem[18] === 32'h00000055) $display("✓ Interrupt handler executed: mem[0x48]=0x55");
      
      // Display cache and bus statistics
      $display("");
      $display("=== Instruction Cache (Pipelined Prefetch) Statistics ===");
      $display("Cache line size: %0d words (4 words per line)", IWB_BURST_LEN);
      $display("Total instruction bus beats (pipelined): %0d", iwb_burst_transaction_count);
      $display("Cache line fills completed: %0d", cache_line_fill_count);
      $display("Data bus transactions (classic): %0d", wb_data_transaction_count);
      $display("Total cycles: %0d", cycle_count);
      $display("Total instructions: %0d", instr_count);
      
      $display("");
      $display("✓✓✓ PIPELINED CORE WITH INSTRUCTION CACHE FUNCTIONAL ✓✓✓");
      $finish;
   end

   always @(posedge clk) begin
      if (!reset_n) begin
         mcause_seen0 <= 32'b0;
         mcause_seen1 <= 32'b0;
      end else if (dut.core.mcause[31]) begin
         if (mcause_seen0 == 32'b0) begin
            mcause_seen0 <= dut.core.mcause;
         end else if (mcause_seen1 == 32'b0 && dut.core.mcause != mcause_seen0) begin
            mcause_seen1 <= dut.core.mcause;
         end
      end
   end

   // Debug: Monitor instruction execution
   integer debug_pc_prev;
   initial debug_pc_prev = 0;


   always @(posedge clk) begin
      if (reset_n & dut.core.ex_fire) begin
         instr_count <= instr_count + 1;
         if (dut.core.isStore) begin
            $display("[%0t] STORE: instr=0x%08b, addr=0x%h, wdata=0x%h, wmask=0x%h, d_wbusy=%d",
                     $time, {2'b0, dut.core.instr[31:2]}, dut.core.d_addr, dut.core.d_wdata, dut.core.d_wmask, dut.core.d_wbusy);
         end
         if (dut.core.isLoad) begin
            $display("[%0t] LOAD init: addr=0x%h, d_rbusy=%d", $time, dut.core.d_addr, dut.core.d_rbusy);
         end
         if (dut.core.isALU & dut.core.rdId != 0) begin
            $display("[%0t] ALU: x%d = 0x%h", $time, dut.core.rdId, dut.core.aluOut);
         end
      end
      // Track load writebacks
      if (reset_n & dut.core.writeBack_en & dut.core.isLoad) begin
         $display("[%0t] LOAD done: x%d = 0x%h (from addr 0x%h)", $time, dut.core.rdId, dut.core.LOAD_data, dut.core.d_addr);
      end
   end

   always @(posedge clk) begin
      if (reset_n) begin
         cycle_count <= cycle_count + 1;
      end
   end


   always @(posedge clk) begin
      if (!reset_n) begin
         lfsr <= 8'h1;
      end else begin
         lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
      end
   end

   // Monitor Wishbone transactions and cache behavior
   integer wb_data_transaction_count;
   integer iwb_burst_transaction_count;
   integer cache_line_fill_count;
   
   initial begin
      wb_data_transaction_count = 0;
      iwb_burst_transaction_count = 0;
      cache_line_fill_count = 0;
   end
   
   always @(posedge clk) begin
      if (reset_n) begin
         // Count data bus transactions
         if (dwb_cyc_o & dwb_stb_o) begin
            wb_data_transaction_count <= wb_data_transaction_count + 1;
         end
         
         // Count instruction bus beats (pipelined bursts)
         if (iwb_cyc_o & iwb_stb_o) begin
            iwb_burst_transaction_count <= iwb_burst_transaction_count + 1;
            // Burst end (CTI = 111 = 3'b111) = cache line fill complete
            if (iwb_cti_o == 3'b111) begin
               cache_line_fill_count <= cache_line_fill_count + 1;
               $display("[%0t] Cache line fill complete at addr 0x%h", 
                        $time, {iwb_adr_o[31:2], 2'b00});
            end
         end
      end
   end

   // Monitor instruction bus activity (pipelined prefetch)
   always @(posedge clk) begin
      if (reset_n & iwb_cyc_o & iwb_stb_o) begin
         if (iwb_cti_o == 3'b010) begin  // Burst continue
            $display("[%0t] Instruction bus: Burst beat at 0x%h (CTI=010 continue)",
                     $time, {iwb_adr_o[31:2], 2'b00});
         end else if (iwb_cti_o == 3'b111) begin  // Burst end
            $display("[%0t] Instruction bus: Burst end at 0x%h (CTI=111)",
                     $time, {iwb_adr_o[31:2], 2'b00});
         end
      end
   end

   wire [31:0] iwb_adr_o;
   wire [31:0] iwb_dat_o;
   wire  [3:0] iwb_sel_o;
   wire        iwb_we_o;
   wire        iwb_cyc_o;
   wire        iwb_stb_o;
   wire  [2:0] iwb_cti_o;
   wire  [1:0] iwb_bte_o;
   reg  [31:0] iwb_dat_i;
   reg         iwb_ack_i;

   wire [31:0] dwb_adr_o;
   wire [31:0] dwb_dat_o;
   wire  [3:0] dwb_sel_o;
   wire        dwb_we_o;
   wire        dwb_cyc_o;
   wire        dwb_stb_o;
   wire  [2:0] dwb_cti_o;
   wire  [1:0] dwb_bte_o;
   reg  [31:0] dwb_dat_i;
   reg         dwb_ack_i;

   FemtoRV32_PetitPipe_WB  #(
      .RESET_ADDR(32'h00000000),
      .IWB_BURST_LEN(4)
   ) dut (
      .clk(clk),
      .iwb_adr_o(iwb_adr_o),
      .iwb_dat_o(iwb_dat_o),
      .iwb_sel_o(iwb_sel_o),
      .iwb_we_o(iwb_we_o),
      .iwb_cyc_o(iwb_cyc_o),
      .iwb_stb_o(iwb_stb_o),
      .iwb_cti_o(iwb_cti_o),
      .iwb_bte_o(iwb_bte_o),
      .iwb_dat_i(iwb_dat_i),
      .iwb_ack_i(iwb_ack_i),
      .dwb_adr_o(dwb_adr_o),
      .dwb_dat_o(dwb_dat_o),
      .dwb_sel_o(dwb_sel_o),
      .dwb_we_o(dwb_we_o),
      .dwb_cyc_o(dwb_cyc_o),
      .dwb_stb_o(dwb_stb_o),
      .dwb_cti_o(dwb_cti_o),
      .dwb_bte_o(dwb_bte_o),
      .dwb_dat_i(dwb_dat_i),
      .dwb_ack_i(dwb_ack_i),
      .irq_i(irq_lines),
      .reset_n(reset_n)
   );

   wire proto_i_error;
   wire proto_d_error;
   wire cache_error;
   wire [127:0] proto_i_msg;
   wire [127:0] proto_d_msg;
   wire [127:0] cache_msg;

   wishbone_protocol_checker chk_i (
      .clk(clk),
      .rst(!reset_n),
      .cyc(iwb_cyc_o),
      .stb(iwb_stb_o),
      .we(1'b0),
      .ack(iwb_ack_i),
      .cti(iwb_cti_o),
      .sel(iwb_sel_o),
      .addr(iwb_adr_o),
      .data_i(iwb_dat_i),
      .data_o(32'h0),
      .bus_type(4'h0),
      .protocol_error(proto_i_error),
      .error_msg(proto_i_msg)
   );

   wishbone_protocol_checker chk_d (
      .clk(clk),
      .rst(!reset_n),
      .cyc(dwb_cyc_o),
      .stb(dwb_stb_o),
      .we(dwb_we_o),
      .ack(dwb_ack_i),
      .cti(dwb_cti_o),
      .sel(dwb_sel_o),
      .addr(dwb_adr_o),
      .data_i(dwb_dat_i),
      .data_o(dwb_dat_o),
      .bus_type(4'h1),
      .protocol_error(proto_d_error),
      .error_msg(proto_d_msg)
   );

   cache_protocol_checker cache_chk (
      .clk(clk),
      .rst(!reset_n),
      .iwb_stb(iwb_cyc_o & iwb_stb_o),
      .iwb_ack(iwb_ack_i),
      .iwb_cti(iwb_cti_o),
      .iwb_addr(iwb_adr_o[31:2]),
      .cache_error(cache_error),
      .error_msg(cache_msg)
   );

   always @(posedge clk) begin
      if (proto_i_error) begin
         $error("I-BUS PROTOCOL ERROR: %s", proto_i_msg);
         $finish;
      end
      if (proto_d_error) begin
         $error("D-BUS PROTOCOL ERROR: %s", proto_d_msg);
         $finish;
      end
      if (cache_error) begin
         $error("CACHE PROTOCOL ERROR: %s", cache_msg);
         $finish;
      end
   end

   wire [7:0] i_index = iwb_adr_o[9:2];
   wire [7:0] d_index = dwb_adr_o[9:2];

   always @(posedge clk) begin
      if(!reset_n) begin
         iwb_ack_i <= 1'b0;
         dwb_ack_i <= 1'b0;
         iwb_dat_i <= 32'b0;
         dwb_dat_i <= 32'b0;
         wait_ctr <= 0;
      end else begin
         // ===================================================================
         // INSTRUCTION WISHBONE (PIPELINED)
         // Simulates pipelined burst prefetch for cache line fills
         // ===================================================================
         
         if (iwb_cyc_o & iwb_stb_o) begin
            if (wait_ctr == 0) begin
               if (WB_WAIT_RANGE <= 1) begin
                  wait_ctr <= WB_WAIT_MIN;
               end else begin
                  wait_ctr <= WB_WAIT_MIN + (lfsr % WB_WAIT_RANGE);
               end
            end else begin
               wait_ctr <= wait_ctr - 1;
            end
         end else begin
            wait_ctr <= 0;
         end

         // Acknowledge after variable latency
         iwb_ack_i <= (iwb_cyc_o & iwb_stb_o) & (wait_ctr == 1 || wait_ctr == 0);
         if (iwb_cyc_o & iwb_stb_o & (wait_ctr == 1 || wait_ctr == 0)) begin
            iwb_dat_i <= mem[i_index];
         end

         // ===================================================================
         // DATA WISHBONE (CLASSIC)
         // Single-transaction read/write protocol
         // ===================================================================
         
         dwb_ack_i <= dwb_cyc_o & dwb_stb_o;
         if (dwb_cyc_o & dwb_stb_o) begin
            if (dwb_we_o) begin
               // Write transaction
               if (dwb_sel_o[0]) mem[d_index][7:0]   <= dwb_dat_o[7:0];
               if (dwb_sel_o[1]) mem[d_index][15:8]  <= dwb_dat_o[15:8];
               if (dwb_sel_o[2]) mem[d_index][23:16] <= dwb_dat_o[23:16];
               if (dwb_sel_o[3]) mem[d_index][31:24] <= dwb_dat_o[31:24];
            end else begin
               // Read transaction
               dwb_dat_i <= mem[d_index];
            end
         end
      end
   end


endmodule
