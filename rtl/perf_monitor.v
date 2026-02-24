/**
 * Performance Monitor for FemtoRV32 Instruction Cache
 * 
 * Tracks:
 * - Cycle counter
 * - Cache line fill events
 * - Instruction bus transactions
 * - Data bus transactions
 * - Stall cycle breakdown
 * 
 * Usage: Instantiate in testbench alongside FemtoRV32_PetitPipe_WB
 */

module perf_monitor (
    input clk,
    input rst,
    
    // Instruction Wishbone interface (pipelined)
    input         iwb_stb,
    input         iwb_ack,
    input         iwb_cyc,
    input  [2:0]  iwb_cti,  // CTI codes: 010=continue burst, 111=end burst
    
    // Data Wishbone interface (classic)
    input         dwb_stb,
    input         dwb_ack,
    
    // Core internal signals (if accessible)
    input         core_stall,
    input  [31:0] core_pc,
    
    // Statistics output (for $display in testbench)
    output reg [63:0] cycle_count,
    output reg [31:0] icache_line_fills,
    output reg [31:0] icache_beats_count,
    output reg [31:0] dbus_transactions,
    output reg [31:0] stall_cycles,
    output reg [31:0] burst_fills_completed
);

    // Cycle counter
    always @(posedge clk) begin
        if (rst)
            cycle_count <= 64'h0;
        else
            cycle_count <= cycle_count + 64'h1;
    end
    
    // Track cache line fill sequences
    // A fill starts with iwb_stb=1 and CTI=010 (continue), ends when CTI=111 (end)
    reg in_burst;
    reg [1:0] burst_word_count;
    
    always @(posedge clk) begin
        if (rst) begin
            in_burst <= 1'b0;
            burst_word_count <= 2'h0;
        end else if (iwb_stb && iwb_ack) begin
            // New bus cycle acknowledged
            if (iwb_cti == 3'b010) begin
                // Continue burst - start or continue
                if (!in_burst) begin
                    in_burst <= 1'b1;
                    burst_word_count <= 2'h1;
                end else begin
                    burst_word_count <= burst_word_count + 2'h1;
                end
            end else if (iwb_cti == 3'b111) begin
                // End burst
                in_burst <= 1'b0;
                burst_word_count <= 2'h0;
            end
        end
    end
    
    // Track line fill completion (assume 4-word bursts)
    always @(posedge clk) begin
        if (rst) begin
            icache_line_fills <= 32'h0;
            burst_fills_completed <= 32'h0;
        end else if (iwb_stb && iwb_ack && iwb_cti == 3'b111) begin
            // CTI=111 signals end of burst -> one cache line filled
            icache_line_fills <= icache_line_fills + 32'h1;
            burst_fills_completed <= burst_fills_completed + 32'h1;
        end
    end
    
    // Count total instruction bus beats (every ack on I-bus)
    always @(posedge clk) begin
        if (rst)
            icache_beats_count <= 32'h0;
        else if (iwb_stb && iwb_ack)
            icache_beats_count <= icache_beats_count + 32'h1;
    end
    
    // Count data bus transactions (all acks on D-bus)
    always @(posedge clk) begin
        if (rst)
            dbus_transactions <= 32'h0;
        else if (dwb_stb && dwb_ack)
            dbus_transactions <= dbus_transactions + 32'h1;
    end
    
    // Track stall cycles (core dependency)
    always @(posedge clk) begin
        if (rst)
            stall_cycles <= 32'h0;
        else if (core_stall)
            stall_cycles <= stall_cycles + 32'h1;
    end
    
    // Dump statistics at end of test
    always @(posedge clk) begin
        if (cycle_count == 64'h0)
            // End simulation checkpoint: print all counters
            $display("[PERF_MON] Ready for statistics dump");
    end

endmodule

// Helper module for SoC integration: cycle counter in CSR
module csr_cycle_counter (
    input         clk,
    input         rst,
    
    // CSR interface
    input  [11:0] addr,
    input  [31:0] din,
    input         we,
    output reg [31:0] dout,
    
    output reg [63:0] cycles
);
    
    always @(posedge clk) begin
        if (rst)
            cycles <= 64'h0;
        else
            cycles <= cycles + 64'h1;
    end
    
    always @(*) begin
        dout = 32'h0;
        case (addr)
            12'hC00: dout = cycles[31:0];      // mcycles (lower)
            12'hC80: dout = cycles[63:32];     // mcyclesh (upper)
            default: dout = 32'h0;
        endcase
    end

endmodule
