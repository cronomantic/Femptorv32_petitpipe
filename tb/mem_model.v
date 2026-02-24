// SPDX-License-Identifier: BSD-3-Clause
// Synchronous memory model with memory-mapped I/O for simulation.
//
// Address map
// -----------
//   0x00000000 – 0x0007FFFF  : RAM (512 KB, word-addressed internally)
//   0x10000000                : Exit register
//                               Write 1  → test PASSED
//                               Write N≠1 → test FAILED with error code N
//   0x10000004                : UART TX simulation
//                               Write any value → prints low byte as ASCII
//
// Read latency: 1 clock cycle (rready asserts the cycle after ren).

`timescale 1ns/1ps
`default_nettype none

module mem_model #(
    parameter MEM_WORDS = 131072  // 512 KB / 4 bytes per word
) (
    input  wire        clk,

    // Processor interface
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [ 3:0] wmask,
    input  wire        wen,
    input  wire        ren,
    output reg  [31:0] rdata,
    output reg         rready,

    // Exit status – sampled by tb_top each cycle
    output reg         exit_valid,
    output reg  [31:0] exit_code
);

    // -----------------------------------------------------------------------
    // Memory array
    // -----------------------------------------------------------------------
    reg [31:0] ram [0:MEM_WORDS-1];

    // -----------------------------------------------------------------------
    // MMIO constants
    // -----------------------------------------------------------------------
    localparam [31:0] EXIT_ADDR = 32'h1000_0000;
    localparam [31:0] UART_ADDR = 32'h1000_0004;
    localparam [31:0] RAM_END   = MEM_WORDS * 4;  // exclusive upper byte address

    // -----------------------------------------------------------------------
    // Read port (synchronous, 1-cycle latency)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        rready <= 1'b0;
        rdata  <= 32'bx;

        if (ren && (addr < RAM_END)) begin
            rdata  <= ram[addr[31:2]];
            rready <= 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Write port + MMIO handling
    // -----------------------------------------------------------------------
    initial begin
        exit_valid = 1'b0;
        exit_code  = 32'b0;
    end

    always @(posedge clk) begin
        exit_valid <= 1'b0;

        if (wen) begin
            if (addr < RAM_END) begin
                // RAM write with byte enables
                if (wmask[0]) ram[addr[31:2]][ 7: 0] <= wdata[ 7: 0];
                if (wmask[1]) ram[addr[31:2]][15: 8] <= wdata[15: 8];
                if (wmask[2]) ram[addr[31:2]][23:16] <= wdata[23:16];
                if (wmask[3]) ram[addr[31:2]][31:24] <= wdata[31:24];
            end else if (addr == EXIT_ADDR) begin
                // Pass/fail signalling
                exit_code  <= wdata;
                exit_valid <= 1'b1;
            end else if (addr == UART_ADDR) begin
                // UART character output
                $write("%c", wdata[7:0]);
            end
        end
    end

endmodule

`default_nettype wire
