`timescale 1ns/1ps
`default_nettype none

// Performance comparison: FemtoRV32_PetitPipe_WB vs FemtoRV32_Gracilis_WB
//
// Both processors run the same test program simultaneously from separate but
// identically initialised memory arrays (zero-latency Wishbone, 1 cycle ack).
// Each processor is watched for an EXIT_ADDR (0x10000000) write: that write
// carries the test exit code (1 = PASS, other = FAIL) and its arrival cycle
// is recorded.  When both finish, a comparison table is printed.
//
// Usage:
//   build/sim/tb_perf_compare +hex_file=<path> [+max_cycles=N] [+test_name=<s>]
//
// Architectural differences under test:
//   PetitPipe : 2-stage pipeline, dual Wishbone buses, 4-word burst I-cache
//   Gracilis  : 4-state machine, single Wishbone bus, one-word fetch (no cache)

module tb_perf_compare;
   localparam MEM_WORDS     = 131072; // 512 KB word-addressed (matches tb_top.v)
   localparam IWB_BURST_LEN = 4;
   localparam [31:0] EXIT_ADDR = 32'h10000000;

   reg clk;
   reg reset_n;

   // -------------------------------------------------------------------------
   // Memories: two separate arrays, both loaded with the same program.
   // Programs may write to data memory, so isolation prevents cross-talk.
   // -------------------------------------------------------------------------
   reg [31:0] pp_mem [0:MEM_WORDS-1];  // PetitPipe memory
   reg [31:0] gr_mem [0:MEM_WORDS-1];  // Gracilis memory

   // -------------------------------------------------------------------------
   // Completion tracking
   // -------------------------------------------------------------------------
   integer     pp_cycles;
   integer     gr_cycles;
   integer     pp_exit_cycle;
   integer     gr_exit_cycle;
   reg [31:0]  pp_exit_code;
   reg [31:0]  gr_exit_code;
   reg         pp_done;
   reg         gr_done;

   integer       max_cycles;
   reg [8*256-1:0] hex_file;
   reg [8*64-1:0]  test_name;

   // -------------------------------------------------------------------------
   // PetitPipe Wishbone signals
   // -------------------------------------------------------------------------
   wire [31:0] pp_iwb_adr_o, pp_iwb_dat_o;
   wire  [3:0] pp_iwb_sel_o;
   wire        pp_iwb_we_o, pp_iwb_cyc_o, pp_iwb_stb_o;
   wire  [2:0] pp_iwb_cti_o;
   wire  [1:0] pp_iwb_bte_o;
   wire [31:0] pp_iwb_dat_i;  // driven combinatorially (see I-bus model below)
   reg         pp_iwb_ack_i;

   wire [31:0] pp_dwb_adr_o, pp_dwb_dat_o;
   wire  [3:0] pp_dwb_sel_o;
   wire        pp_dwb_we_o, pp_dwb_cyc_o, pp_dwb_stb_o;
   wire  [2:0] pp_dwb_cti_o;
   wire  [1:0] pp_dwb_bte_o;
   reg  [31:0] pp_dwb_dat_i;
   reg         pp_dwb_ack_i;

   // -------------------------------------------------------------------------
   // Gracilis Wishbone signals (single bus)
   // -------------------------------------------------------------------------
   wire [31:0] gr_wb_adr_o, gr_wb_dat_o;
   wire  [3:0] gr_wb_sel_o;
   wire        gr_wb_we_o, gr_wb_cyc_o, gr_wb_stb_o;
   wire  [2:0] gr_wb_cti_o;
   wire  [1:0] gr_wb_bte_o;
   reg  [31:0] gr_wb_dat_i;
   reg         gr_wb_ack_i;

   // -------------------------------------------------------------------------
   // DUTs
   // -------------------------------------------------------------------------
   FemtoRV32_PetitPipe_WB #(
      .RESET_ADDR   (32'h00000000),
      .IWB_BURST_LEN(IWB_BURST_LEN)
   ) pp_dut (
      .clk       (clk),
      .iwb_adr_o (pp_iwb_adr_o), .iwb_dat_o (pp_iwb_dat_o),
      .iwb_sel_o (pp_iwb_sel_o), .iwb_we_o  (pp_iwb_we_o),
      .iwb_cyc_o (pp_iwb_cyc_o), .iwb_stb_o (pp_iwb_stb_o),
      .iwb_cti_o (pp_iwb_cti_o), .iwb_bte_o (pp_iwb_bte_o),
      .iwb_dat_i (pp_iwb_dat_i), .iwb_ack_i (pp_iwb_ack_i),
      .dwb_adr_o (pp_dwb_adr_o), .dwb_dat_o (pp_dwb_dat_o),
      .dwb_sel_o (pp_dwb_sel_o), .dwb_we_o  (pp_dwb_we_o),
      .dwb_cyc_o (pp_dwb_cyc_o), .dwb_stb_o (pp_dwb_stb_o),
      .dwb_cti_o (pp_dwb_cti_o), .dwb_bte_o (pp_dwb_bte_o),
      .dwb_dat_i (pp_dwb_dat_i), .dwb_ack_i (pp_dwb_ack_i),
      .irq_i     (8'b0),
      .reset_n   (reset_n)
   );

   FemtoRV32_Gracilis_WB #(
      .RESET_ADDR(32'h00000000)
   ) gr_dut (
      .clk      (clk),
      .wb_adr_o (gr_wb_adr_o), .wb_dat_o (gr_wb_dat_o),
      .wb_sel_o (gr_wb_sel_o), .wb_we_o  (gr_wb_we_o),
      .wb_cyc_o (gr_wb_cyc_o), .wb_stb_o (gr_wb_stb_o),
      .wb_cti_o (gr_wb_cti_o), .wb_bte_o (gr_wb_bte_o),
      .wb_dat_i (gr_wb_dat_i), .wb_ack_i (gr_wb_ack_i),
      .irq_i    (8'b0),
      .reset_n  (reset_n)
   );

   // -------------------------------------------------------------------------
   // Clock
   // -------------------------------------------------------------------------
   initial clk = 1'b0;
   always  #5  clk = ~clk;

   // -------------------------------------------------------------------------
   // Initialisation
   // -------------------------------------------------------------------------
   integer i;
   initial begin
      reset_n       = 1'b0;
      pp_done       = 1'b0;
      gr_done       = 1'b0;
      pp_cycles     = 0;
      gr_cycles     = 0;
      pp_exit_cycle = 0;
      gr_exit_cycle = 0;
      pp_exit_code  = 32'hFFFFFFFF;
      gr_exit_code  = 32'hFFFFFFFF;

      for (i = 0; i < MEM_WORDS; i = i + 1) begin
         pp_mem[i] = 32'h00000013; // NOP
         gr_mem[i] = 32'h00000013;
      end

      if (!$value$plusargs("hex_file=%s", hex_file)) begin
         $display("[PERF ERROR] No hex file specified.  Use +hex_file=<path>");
         $finish(2);
      end
      if (!$value$plusargs("max_cycles=%d", max_cycles))
         max_cycles = 200000;
      if (!$value$plusargs("test_name=%s", test_name))
         test_name = hex_file;

      $readmemh(hex_file, pp_mem);
      $readmemh(hex_file, gr_mem);

      repeat (5) @(posedge clk);
      reset_n = 1'b1;
   end

   // -------------------------------------------------------------------------
   // Per-processor cycle counters + timeout
   // -------------------------------------------------------------------------
   always @(posedge clk) begin
      if (reset_n) begin
         if (!pp_done) begin
            pp_cycles <= pp_cycles + 1;
            if (pp_cycles >= max_cycles) begin
               $display("[PERF] PetitPipe timed out after %0d cycles", max_cycles);
               pp_exit_cycle <= pp_cycles;
               pp_done       <= 1'b1;
            end
         end
         if (!gr_done) begin
            gr_cycles <= gr_cycles + 1;
            if (gr_cycles >= max_cycles) begin
               $display("[PERF] Gracilis timed out after %0d cycles", max_cycles);
               gr_exit_cycle <= gr_cycles;
               gr_done       <= 1'b1;
            end
         end
      end
   end

   // -------------------------------------------------------------------------
   // Print results once both have finished
   // -------------------------------------------------------------------------
   always @(posedge clk) begin
      if (pp_done && gr_done) begin
         $display("");
         $display("+------------------------------------------------------------------+");
         $display("|           Performance Comparison                                 |");
         $display("+------------------------------------------------------------------+");
         $display("|  PetitPipe: 2-stage pipeline, 4-word burst I-cache               |");
         $display("|  Gracilis:  4-state machine,  single-word fetch (no cache)       |");
         $display("+--------------------+------------+------------+-------------------+");
         $display("| Processor          | Cycles     | Exit code  | Status            |");
         $display("+--------------------+------------+------------+-------------------+");
         $display("| PetitPipe          | %-10d | %-10d | %-17s |",
                  pp_exit_cycle, pp_exit_code,
                  (pp_exit_code == 1) ? "PASS" : "FAIL");
         $display("| Gracilis           | %-10d | %-10d | %-17s |",
                  gr_exit_cycle, gr_exit_code,
                  (gr_exit_code == 1) ? "PASS" : "FAIL");
         $display("+--------------------+------------+-------------------------------+");
         if (gr_exit_cycle > 0 && pp_exit_cycle > 0) begin
            $display("| Gracilis / PetitPipe speedup ratio: %6.3fx                       |",
                     $itor(gr_exit_cycle) / $itor(pp_exit_cycle));
            $display("|  (>1.0 means PetitPipe finished in fewer cycles)                |");
         end
         $display("+------------------------------------------------------------------+");
         $display("");

         if (pp_exit_code == 1 && gr_exit_code == 1) begin
            $display("[PERF] Both processors PASSED  (%0s)", test_name);
            $finish(0);
         end else begin
            $display("[PERF FAIL] pp_exit=%0d  gr_exit=%0d  (%0s)",
                     pp_exit_code, gr_exit_code, test_name);
            $finish(1);
         end
      end
   end

   // -------------------------------------------------------------------------
   // PetitPipe I-bus: pipelined, 1-cycle registered ack.
   //
   // Data must be combinatorial (wire) so it always reflects the current
   // burst address at the moment ack fires.  If data were registered one
   // cycle behind the address, the burst wrapper would advance burst_addr
   // on each ack and store each word into the wrong cache-buffer slot
   // (slot N would receive word N-1), corrupting the entire cache line.
   // -------------------------------------------------------------------------
   wire [31:0] pp_i_idx = pp_iwb_adr_o[31:2];
   // Combinatorial data: always valid for the current burst address.
   assign pp_iwb_dat_i = (pp_i_idx < MEM_WORDS) ? pp_mem[pp_i_idx] : 32'h00000013;
   always @(posedge clk) begin
      if (!reset_n)
         pp_iwb_ack_i <= 1'b0;
      else
         pp_iwb_ack_i <= pp_iwb_cyc_o & pp_iwb_stb_o;
   end

   // -------------------------------------------------------------------------
   // PetitPipe D-bus: classic, zero-latency, EXIT_ADDR detection
   // -------------------------------------------------------------------------
   wire [31:0] pp_d_idx = pp_dwb_adr_o[31:2];
   always @(posedge clk) begin
      if (!reset_n) begin
         pp_dwb_ack_i <= 1'b0;
         pp_dwb_dat_i <= 32'b0;
      end else begin
         pp_dwb_ack_i <= pp_dwb_cyc_o & pp_dwb_stb_o;
         if (pp_dwb_cyc_o & pp_dwb_stb_o) begin
            if (pp_dwb_we_o) begin
               if (pp_dwb_adr_o == EXIT_ADDR) begin
                  if (!pp_done) begin
                     pp_exit_code  <= pp_dwb_dat_o;
                     pp_exit_cycle <= pp_cycles;
                     pp_done       <= 1'b1;
                  end
               end else if (pp_d_idx < MEM_WORDS) begin
                  if (pp_dwb_sel_o[0]) pp_mem[pp_d_idx][ 7: 0] <= pp_dwb_dat_o[ 7: 0];
                  if (pp_dwb_sel_o[1]) pp_mem[pp_d_idx][15: 8] <= pp_dwb_dat_o[15: 8];
                  if (pp_dwb_sel_o[2]) pp_mem[pp_d_idx][23:16] <= pp_dwb_dat_o[23:16];
                  if (pp_dwb_sel_o[3]) pp_mem[pp_d_idx][31:24] <= pp_dwb_dat_o[31:24];
               end
            end else begin
               if (pp_d_idx < MEM_WORDS)
                  pp_dwb_dat_i <= pp_mem[pp_d_idx];
            end
         end
      end
   end

   // -------------------------------------------------------------------------
   // Gracilis single-bus: classic, zero-latency, EXIT_ADDR detection
   // -------------------------------------------------------------------------
   wire [31:0] gr_idx = gr_wb_adr_o[31:2];
   always @(posedge clk) begin
      if (!reset_n) begin
         gr_wb_ack_i <= 1'b0;
         gr_wb_dat_i <= 32'b0;
      end else begin
         gr_wb_ack_i <= gr_wb_cyc_o & gr_wb_stb_o;
         if (gr_wb_cyc_o & gr_wb_stb_o) begin
            if (gr_wb_we_o) begin
               if (gr_wb_adr_o == EXIT_ADDR) begin
                  if (!gr_done) begin
                     gr_exit_code  <= gr_wb_dat_o;
                     gr_exit_cycle <= gr_cycles;
                     gr_done       <= 1'b1;
                  end
               end else if (gr_idx < MEM_WORDS) begin
                  if (gr_wb_sel_o[0]) gr_mem[gr_idx][ 7: 0] <= gr_wb_dat_o[ 7: 0];
                  if (gr_wb_sel_o[1]) gr_mem[gr_idx][15: 8] <= gr_wb_dat_o[15: 8];
                  if (gr_wb_sel_o[2]) gr_mem[gr_idx][23:16] <= gr_wb_dat_o[23:16];
                  if (gr_wb_sel_o[3]) gr_mem[gr_idx][31:24] <= gr_wb_dat_o[31:24];
               end
            end else begin
               if (gr_idx < MEM_WORDS)
                  gr_wb_dat_i <= gr_mem[gr_idx];
               else
                  gr_wb_dat_i <= 32'h00000013; // NOP
            end
         end
      end
   end

endmodule

`default_nettype wire
