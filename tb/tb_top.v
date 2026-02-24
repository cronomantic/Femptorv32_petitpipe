// SPDX-License-Identifier: BSD-3-Clause
// Top-level testbench for FemptorV32_petitpipe
//
// Usage (iverilog / vvp):
//   iverilog -g2012 -I tb -o build/sim/tb_top \
//       tb/tb_top.v tb/mem_model.v rtl/FemptorV32_petitpipe.v
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
    parameter MEM_WORDS   = 131072; // 512 KB (word-addressed)

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
    // Processor <-> memory wires
    // -----------------------------------------------------------------------
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wmask;
    wire        mem_wen;
    wire        mem_ren;
    wire [31:0] mem_rdata;
    wire        mem_rready;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // NOTE: Replace this with the real module once RTL is available.
    // -----------------------------------------------------------------------
    FemptorV32_petitpipe dut (
        .clk       (clk),
        .rstn      (rstn),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wmask (mem_wmask),
        .mem_wen   (mem_wen),
        .mem_ren   (mem_ren),
        .mem_rdata (mem_rdata),
        .mem_rready(mem_rready)
    );

    // -----------------------------------------------------------------------
    // Memory model instantiation
    // -----------------------------------------------------------------------
    mem_model #(
        .MEM_WORDS(MEM_WORDS)
    ) u_mem (
        .clk      (clk),
        .addr     (mem_addr),
        .wdata    (mem_wdata),
        .wmask    (mem_wmask),
        .wen      (mem_wen),
        .ren      (mem_ren),
        .rdata    (mem_rdata),
        .rready   (mem_rready)
    );

    // -----------------------------------------------------------------------
    // Hex-file loader
    // -----------------------------------------------------------------------
    reg [8*256-1:0] hex_file;

    initial begin
        if (!$value$plusargs("hex_file=%s", hex_file)) begin
            $display("[TB ERROR] No hex file specified. Use +hex_file=<path>");
            $finish;
        end
        $readmemh(hex_file, u_mem.ram);
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
    // Exit detection – mem_model signals exit_code via a shared reg
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (u_mem.exit_valid) begin
            if (u_mem.exit_code == 32'd1) begin
                $display("[TB PASS] Test passed in %0d cycles.", cycle_cnt);
                $finish(0);
            end else begin
                $display("[TB FAIL] Test failed with error code %0d after %0d cycles.",
                         u_mem.exit_code, cycle_cnt);
                $finish(1);
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
