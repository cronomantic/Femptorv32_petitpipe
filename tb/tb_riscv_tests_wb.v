`timescale 1ns/1ps
`default_nettype none

// Wishbone testbench for official riscv-tests suite
// - Loads a Verilog hex image at base address 0x0000_0000
// - Uses tohost write to signal PASS/FAIL
// - Optionally dumps signature region to a file

module tb_riscv_tests_wb;
   localparam MEM_WORDS = 262144; // 1 MB (word-addressed)
   localparam IWB_BURST_LEN = 4;
   localparam [31:0] TOHOST_ADDR = 32'h00001000;
   localparam [31:0] FROMHOST_ADDR = 32'h00001008;

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

   FemtoRV32_PetitPipe_WB #(
      .RESET_ADDR(32'h00000000),
      .IWB_BURST_LEN(IWB_BURST_LEN)
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

   initial begin
      clk = 1'b0;
      forever #5 clk = ~clk;
   end

   integer i;
   initial begin
      reset_n = 1'b0;
      irq_lines = 8'b0;
      cycle_count = 0;

      for (i = 0; i < MEM_WORDS; i = i + 1) begin
         mem[i] = 32'b0;
      end

      if (!$value$plusargs("hex_file=%s", hex_file)) begin
         $display("[TB ERROR] No hex file specified. Use +hex_file=<path>");
         $finish(2);
      end
      if (!$value$plusargs("signature_file=%s", signature_file)) begin
         signature_file = "signature.out";
      end
      if (!$value$plusargs("sig_start=%h", sig_start)) begin
         sig_start = 32'h0;
      end
      if (!$value$plusargs("sig_end=%h", sig_end)) begin
         sig_end = 32'h0;
      end
      if (!$value$plusargs("max_cycles=%d", max_cycles)) begin
         max_cycles = 2000000;
      end

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

   task dump_signature;
      integer fd;
      reg [31:0] addr;
      begin : dump_signature
         if (sig_start == 32'h0 || sig_end == 32'h0 || sig_end <= sig_start) begin
            $display("[TB] Signature range not provided; skipping dump.");
            disable dump_signature;
         end
         fd = $fopen(signature_file, "w");
         if (fd == 0) begin
            $display("[TB ERROR] Unable to open signature file: %0s", signature_file);
            disable dump_signature;
         end
         for (addr = sig_start; addr < sig_end; addr = addr + 4) begin
            if (addr[31:2] < MEM_WORDS) begin
               $fdisplay(fd, "%08x", mem[addr[31:2]]);
            end else begin
               $fdisplay(fd, "%08x", 32'h00000000);
            end
         end
         $fclose(fd);
      end
   endtask

   wire [31:0] i_index = iwb_adr_o[31:2];
   wire [31:0] d_index = dwb_adr_o[31:2];

   always @(posedge clk) begin
      if (!reset_n) begin
         iwb_ack_i <= 1'b0;
         dwb_ack_i <= 1'b0;
         iwb_dat_i <= 32'b0;
         dwb_dat_i <= 32'b0;
      end else begin
         // Instruction Wishbone (pipelined)
         iwb_ack_i <= iwb_cyc_o & iwb_stb_o;
         if (iwb_cyc_o & iwb_stb_o) begin
            if (i_index < MEM_WORDS) begin
               iwb_dat_i <= mem[i_index];
            end else begin
               iwb_dat_i <= 32'h00000013; // NOP
            end
         end

         // Data Wishbone (classic)
         dwb_ack_i <= dwb_cyc_o & dwb_stb_o;
         if (dwb_cyc_o & dwb_stb_o) begin
            if (dwb_we_o) begin
               if (dwb_adr_o == TOHOST_ADDR) begin
                  $display("[TB] tohost write: 0x%08x", dwb_dat_o);
                  dump_signature();
                  if (dwb_dat_o == 32'h00000001) begin
                     $display("[TB PASS] riscv-tests tohost signaled pass");
                     $finish(0);
                  end else begin
                     $display("[TB FAIL] riscv-tests tohost signaled fail: 0x%08x", dwb_dat_o);
                     $finish(1);
                  end
               end else if (dwb_adr_o == FROMHOST_ADDR) begin
                  // Ignore fromhost writes
               end else if (d_index < MEM_WORDS) begin
                  if (dwb_sel_o[0]) mem[d_index][7:0]   <= dwb_dat_o[7:0];
                  if (dwb_sel_o[1]) mem[d_index][15:8]  <= dwb_dat_o[15:8];
                  if (dwb_sel_o[2]) mem[d_index][23:16] <= dwb_dat_o[23:16];
                  if (dwb_sel_o[3]) mem[d_index][31:24] <= dwb_dat_o[31:24];
               end
            end else begin
               if (d_index < MEM_WORDS) begin
                  dwb_dat_i <= mem[d_index];
               end else begin
                  dwb_dat_i <= 32'h00000000;
               end
            end
         end
      end
   end

endmodule

`default_nettype wire
