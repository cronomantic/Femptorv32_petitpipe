// SPDX-License-Identifier: BSD-3-Clause
// Stub for FemtoRV32_PetitPipe_WB (Wishbone interface)
//
// Provides a minimal no-op instantiation for testbench syntax checking
// (make tb-check) before the real RTL is available. All outputs are
// driven to zero; no computation is performed.

`timescale 1ns/1ps
`default_nettype none

module FemtoRV32_PetitPipe_WB #(
    parameter [31:0] RESET_ADDR       = 32'h00000000,
    parameter integer IWB_BURST_LEN   = 4
) (
    input  wire        clk,
    input  wire        reset_n,

    // Instruction Wishbone master (pipelined burst, read-only)
    output wire [31:0] iwb_adr_o,
    output wire [31:0] iwb_dat_o,
    output wire  [3:0] iwb_sel_o,
    output wire        iwb_we_o,
    output wire        iwb_cyc_o,
    output wire        iwb_stb_o,
    output wire  [2:0] iwb_cti_o,
    output wire  [1:0] iwb_bte_o,
    input  wire [31:0] iwb_dat_i,
    input  wire        iwb_ack_i,

    // Data Wishbone master (classic)
    output wire [31:0] dwb_adr_o,
    output wire [31:0] dwb_dat_o,
    output wire  [3:0] dwb_sel_o,
    output wire        dwb_we_o,
    output wire        dwb_cyc_o,
    output wire        dwb_stb_o,
    output wire  [2:0] dwb_cti_o,
    output wire  [1:0] dwb_bte_o,
    input  wire [31:0] dwb_dat_i,
    input  wire        dwb_ack_i,

    // Interrupts
    input  wire  [7:0] irq_i
);

    // Stub: all outputs driven to zero for syntax checking only
    assign iwb_adr_o = 32'b0;
    assign iwb_dat_o = 32'b0;
    assign iwb_sel_o =  4'b0;
    assign iwb_we_o  =  1'b0;
    assign iwb_cyc_o =  1'b0;
    assign iwb_stb_o =  1'b0;
    assign iwb_cti_o =  3'b0;
    assign iwb_bte_o =  2'b0;

    assign dwb_adr_o = 32'b0;
    assign dwb_dat_o = 32'b0;
    assign dwb_sel_o =  4'b0;
    assign dwb_we_o  =  1'b0;
    assign dwb_cyc_o =  1'b0;
    assign dwb_stb_o =  1'b0;
    assign dwb_cti_o =  3'b0;
    assign dwb_bte_o =  2'b0;

endmodule

`default_nettype wire

