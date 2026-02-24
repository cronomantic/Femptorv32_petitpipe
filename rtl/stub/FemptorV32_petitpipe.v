// SPDX-License-Identifier: BSD-3-Clause
// Stub wrapper for FemptorV32_petitpipe (unified memory interface)
//
// This stub provides a minimal instantiation for testbench syntax checking
// before the real RTL is available. It matches the interface expected by
// tb/tb_top.v but performs no actual computation.

`timescale 1ns/1ps
`default_nettype none

module FemptorV32_petitpipe (
    input  wire        clk,
    input  wire        rstn,

    // Unified memory bus
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [ 3:0] mem_wmask,
    output wire        mem_wen,
    output wire        mem_ren,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rready
);

    // Stub: all outputs driven to zero for syntax checking only
    assign mem_addr  = 32'b0;
    assign mem_wdata = 32'b0;
    assign mem_wmask =  4'b0;
    assign mem_wen   =  1'b0;
    assign mem_ren   =  1'b0;

endmodule

`default_nettype wire

