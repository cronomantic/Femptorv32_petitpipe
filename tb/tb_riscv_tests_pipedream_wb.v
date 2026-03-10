`timescale 1ns/1ps
`default_nettype none

// Wishbone testbench for official riscv-tests suite – FemtoRV32_Pipedream_WB
// - Loads a Verilog hex image at base address 0x0000_0000
// - Uses tohost write to signal PASS/FAIL

module tb_riscv_tests_pipedream_wb;
   localparam MEM_WORDS      = 262144; // 1 MB (word-addressed)
   localparam [31:0] EXIT_ADDR     = 32'h10000000; // matches test_macros.h EXIT_ADDR

   reg clk;
   reg reset_n;
   reg [7:0] irq_lines;

   reg [31:0] mem [0:MEM_WORDS-1];

   reg [8*256-1:0] hex_file;
   reg [8*256-1:0] signature_file;
   reg [31:0] sig_start;
   reg [31:0] sig_end;
   integer max_cycles;
   integer cycle_count;

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

   FemtoRV32_Pipedream_WB #(
      .RESET_ADDR(32'h00000000)
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

   initial begin
      clk = 1'b0;
      forever #5 clk = ~clk;
   end

   integer i;
   initial begin
      reset_n     = 1'b0;
      irq_lines   = 8'b0;
      cycle_count = 0;

      for (i = 0; i < MEM_WORDS; i = i + 1)
         mem[i] = 32'b0;

      if (!$value$plusargs("hex_file=%s", hex_file)) begin
         $display("[TB ERROR] No hex file specified. Use +hex_file=<path>");
         $finish(2);
      end
      if (!$value$plusargs("signature_file=%s", signature_file))
         signature_file = "signature.out";
      if (!$value$plusargs("sig_start=%h", sig_start))
         sig_start = 32'h0;
      if (!$value$plusargs("sig_end=%h", sig_end))
         sig_end = 32'h0;
      if (!$value$plusargs("max_cycles=%d", max_cycles))
         max_cycles = 5000000;

      $readmemh(hex_file, mem);

      repeat (5) @(posedge clk);
      reset_n = 1'b1;
   end

   always @(posedge clk) begin
      if (reset_n) begin
         cycle_count <= cycle_count + 1;
         if (cycle_count >= max_cycles) begin
            $display("[TB TIMEOUT] Test did not complete within %0d cycles.", max_cycles);
            $finish(2);
         end
      end
   end

   wire [31:0] wb_index = wb_adr_o[31:2];

   always @(posedge clk) begin
      if (!reset_n) begin
         wb_ack_i <= 1'b0;
         wb_dat_i <= 32'b0;
      end else begin
         // Single Wishbone bus: classic, zero wait states
         wb_ack_i <= wb_cyc_o & wb_stb_o;
         if (wb_cyc_o & wb_stb_o) begin
            if (wb_we_o) begin
               if (wb_adr_o == EXIT_ADDR) begin
                  if (wb_dat_o == 32'h00000001) begin
                     $display("[TB PASS] Test passed in %0d cycles.", cycle_count);
                     $finish(0);
                  end else begin
                     $display("[TB FAIL] Test failed with error code %0d after %0d cycles.",
                              wb_dat_o, cycle_count);
                     $finish(1);
                  end
               end else if (wb_index < MEM_WORDS) begin
                  if (wb_sel_o[0]) mem[wb_index][ 7: 0] <= wb_dat_o[ 7: 0];
                  if (wb_sel_o[1]) mem[wb_index][15: 8] <= wb_dat_o[15: 8];
                  if (wb_sel_o[2]) mem[wb_index][23:16] <= wb_dat_o[23:16];
                  if (wb_sel_o[3]) mem[wb_index][31:24] <= wb_dat_o[31:24];
               end
            end else begin
               if (wb_index < MEM_WORDS)
                  wb_dat_i <= mem[wb_index];
               else
                  wb_dat_i <= 32'h00000013; // NOP
            end
         end
      end
   end

endmodule

`default_nettype wire
