// SPDX-License-Identifier: BSD-3-Clause
// Stub implementation of FemptorV32_petitpipe.
//
// This file is used ONLY for testbench syntax checking before the real RTL is
// available.  It matches the interface expected by tb/tb_top.v but performs no
// computation – all outputs are driven to zero.
//
// Expected processor interface:
//   clk        – clock (rising-edge triggered)
//   rstn       – synchronous active-low reset
//   mem_addr   – byte address driven by the processor
//   mem_wdata  – write data driven by the processor
//   mem_wmask  – byte-enable write mask (0000 = read transaction)
//   mem_wen    – write enable
//   mem_ren    – read enable
//   mem_rdata  – read data returned by the memory subsystem
//   mem_rready – read-data valid handshake from the memory subsystem

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

    // Stub: drive all outputs to 0 – no actual pipeline logic yet.
    assign mem_addr  = 32'b0;
    assign mem_wdata = 32'b0;
    assign mem_wmask =  4'b0;
    assign mem_wen   =  1'b0;
    assign mem_ren   =  1'b0;

endmodule

`default_nettype wire
