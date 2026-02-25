// SPDX-License-Identifier: BSD-3-Clause
// Top-level testbench for FemtoRV32_PetitPipe_WB
//
// Connects the real Wishbone core to an inline memory model.
// Compatible with the same test programs used by tb_riscv_tests_wb.v.
//
// Usage (iverilog / vvp):
//   iverilog -g2012 -I tb -o build/sim/tb_top \
//       tb/tb_top.v tb/mem_model.v rtl/femtorv32_petitpipe.v \
//       rtl/femtorv32_gracilis_wb.v rtl/perf_monitor.v
//   vvp build/sim/tb_top +hex_file=build/hexes/test_add.hex
//
// Optional plusargs:
//   +hex_file=<path>  – path to the Verilog hex program image (required)
//   +dump_vcd         – enable VCD waveform dump
//   +vcd_file=<path>  – path for VCD output (default: sim.vcd)
//   +max_cycles=<n>   – override simulation timeout (default: 100000)
//
// Exit conventions (written by test programs to EXIT_ADDR = 0x10000000):
//   1          = PASS
//   other      = FAIL (non-zero error code identifies the failing check)

`timescale 1ns/1ps
`default_nettype none

module tb_top;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam MEM_WORDS     = 131072; // 512 KB (word-addressed)
    localparam IWB_BURST_LEN = 4;
    localparam [31:0] EXIT_ADDR = 32'h10000000;

    // -----------------------------------------------------------------------
    // Clock & reset
    // -----------------------------------------------------------------------
    reg clk  = 1'b0;
    reg rstn = 1'b0;

    // 10 ns period (100 MHz)
    always #5 clk = ~clk;

    // Hold reset for 10 rising edges, then deassert
    integer reset_cnt = 0;
    always @(posedge clk) begin
        if (reset_cnt < 10)
            reset_cnt <= reset_cnt + 1;
        else
            rstn <= 1'b1;
    end

    // -----------------------------------------------------------------------
    // Memory array
    // -----------------------------------------------------------------------
    reg [31:0] mem [0:MEM_WORDS-1];

    // -----------------------------------------------------------------------
    // Wishbone signals – I-bus (pipelined burst, read-only)
    // -----------------------------------------------------------------------
    wire [31:0] iwb_adr_o, iwb_dat_o;
    wire  [3:0] iwb_sel_o;
    wire        iwb_we_o, iwb_cyc_o, iwb_stb_o;
    wire  [2:0] iwb_cti_o;
    wire  [1:0] iwb_bte_o;
    wire [31:0] iwb_dat_i;  // combinatorial – see I-bus model below
    reg         iwb_ack_i;

    // -----------------------------------------------------------------------
    // Wishbone signals – D-bus (classic, read/write)
    // -----------------------------------------------------------------------
    wire [31:0] dwb_adr_o, dwb_dat_o;
    wire  [3:0] dwb_sel_o;
    wire        dwb_we_o, dwb_cyc_o, dwb_stb_o;
    wire  [2:0] dwb_cti_o;
    wire  [1:0] dwb_bte_o;
    reg  [31:0] dwb_dat_i;
    reg         dwb_ack_i;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    FemtoRV32_PetitPipe_WB #(
        .RESET_ADDR   (32'h00000000),
        .IWB_BURST_LEN(IWB_BURST_LEN)
    ) dut (
        .clk       (clk),
        .reset_n   (rstn),
        .iwb_adr_o (iwb_adr_o), .iwb_dat_o (iwb_dat_o),
        .iwb_sel_o (iwb_sel_o), .iwb_we_o  (iwb_we_o),
        .iwb_cyc_o (iwb_cyc_o), .iwb_stb_o (iwb_stb_o),
        .iwb_cti_o (iwb_cti_o), .iwb_bte_o (iwb_bte_o),
        .iwb_dat_i (iwb_dat_i), .iwb_ack_i (iwb_ack_i),
        .dwb_adr_o (dwb_adr_o), .dwb_dat_o (dwb_dat_o),
        .dwb_sel_o (dwb_sel_o), .dwb_we_o  (dwb_we_o),
        .dwb_cyc_o (dwb_cyc_o), .dwb_stb_o (dwb_stb_o),
        .dwb_cti_o (dwb_cti_o), .dwb_bte_o (dwb_bte_o),
        .dwb_dat_i (dwb_dat_i), .dwb_ack_i (dwb_ack_i),
        .irq_i     (8'b0)
    );

    // -----------------------------------------------------------------------
    // I-bus memory model: pipelined, zero wait state.
    // Data is combinatorial so it always reflects the current burst address
    // at the moment ack fires, ensuring correct cache-buffer slot filling.
    // -----------------------------------------------------------------------
    wire [31:0] i_idx = iwb_adr_o[31:2];
    assign iwb_dat_i = (i_idx < MEM_WORDS) ? mem[i_idx] : 32'h00000013; // NOP on OOB

    always @(posedge clk) begin
        if (!rstn) iwb_ack_i <= 1'b0;
        else       iwb_ack_i <= iwb_cyc_o & iwb_stb_o;
    end

    // -----------------------------------------------------------------------
    // D-bus memory model: classic, zero wait state, with exit detection.
    // -----------------------------------------------------------------------
    wire [31:0] d_idx = dwb_adr_o[31:2];

    always @(posedge clk) begin
        if (!rstn) begin
            dwb_ack_i <= 1'b0;
            dwb_dat_i <= 32'b0;
        end else begin
            dwb_ack_i <= dwb_cyc_o & dwb_stb_o;
            if (dwb_cyc_o & dwb_stb_o) begin
                if (dwb_we_o) begin
                    if (d_idx < MEM_WORDS) begin
                        if (dwb_sel_o[0]) mem[d_idx][ 7: 0] <= dwb_dat_o[ 7: 0];
                        if (dwb_sel_o[1]) mem[d_idx][15: 8] <= dwb_dat_o[15: 8];
                        if (dwb_sel_o[2]) mem[d_idx][23:16] <= dwb_dat_o[23:16];
                        if (dwb_sel_o[3]) mem[d_idx][31:24] <= dwb_dat_o[31:24];
                    end
                end else begin
                    if (d_idx < MEM_WORDS)
                        dwb_dat_i <= mem[d_idx];
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Exit detection – test programs write 1=PASS or N=FAIL to EXIT_ADDR
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rstn && dwb_cyc_o && dwb_stb_o && dwb_we_o &&
                dwb_adr_o == EXIT_ADDR) begin
            if (dwb_dat_o == 32'd1) begin
                $display("[TB PASS] Test passed in %0d cycles.", cycle_cnt);
                $finish(0);
            end else begin
                $display("[TB FAIL] Test failed with error code %0d after %0d cycles.",
                         dwb_dat_o, cycle_cnt);
                $finish(1);
            end
        end
    end

    // -----------------------------------------------------------------------
    // Hex-file loader
    // -----------------------------------------------------------------------
    reg [8*256-1:0] hex_file;
    integer i;

    initial begin
        if (!$value$plusargs("hex_file=%s", hex_file)) begin
            $display("[TB ERROR] No hex file specified. Use +hex_file=<path>");
            $finish;
        end
        for (i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 32'h00000013; // NOP
        $readmemh(hex_file, mem);
        $display("[TB] Loaded program: %0s", hex_file);
    end

    // -----------------------------------------------------------------------
    // Simulation timeout / pass-fail watchdog
    // -----------------------------------------------------------------------
    integer max_cycles;
    integer cycle_cnt = 0;

    initial begin
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 100000;
    end

    always @(posedge clk) begin
        if (rstn) begin
            cycle_cnt <= cycle_cnt + 1;

            if (cycle_cnt >= max_cycles) begin
                $display("[TB TIMEOUT] Test did not complete within %0d cycles.",
                         max_cycles);
                $finish(2);
            end
        end
    end

    // -----------------------------------------------------------------------
    // Optional VCD dump
    // -----------------------------------------------------------------------
    reg [8*256-1:0] vcd_file;

    initial begin
        if ($test$plusargs("dump_vcd")) begin
            if (!$value$plusargs("vcd_file=%s", vcd_file))
                vcd_file = "sim.vcd";
            $dumpfile(vcd_file);
            $dumpvars(0, tb_top);
            $display("[TB] VCD dump enabled: %0s", vcd_file);
        end
    end

endmodule

`default_nettype wire
