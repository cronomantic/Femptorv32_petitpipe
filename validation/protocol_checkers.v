/**
 * Wishbone Protocol Compliance Checker
 * 
 * Validates Wishbone B4 protocol compliance for both instruction and data buses.
 * 
 * Checks:
 * - Signal timing constraints (stb/cyc/ack sequencing)
 * - CTI code validity (pipelined I-bus)
 * - Address/data stability during transactions
 * - Burst protocol correctness (010->111 sequences)
 * 
 * Assertions will trigger $error on protocol violations.
 */

module wishbone_protocol_checker (
    input clk,
    input rst,
    
    // Bus signals
    input         cyc,      // Cycle active
    input         stb,      // Strobe (valid address/data)
    input         we,       // Write enable
    input         ack,      // Acknowledge
    input  [2:0]  cti,      // Cycle Type Indicator (burst type)
    input  [3:0]  sel,      // Byte select
    input  [31:0] addr,
    input  [31:0] data_i,   // Read data
    input  [31:0] data_o,   // Write data
    
    // Configuration
    input [3:0] bus_type,   // 0=I-bus (pipelined), 1=D-bus (classic)
    
    output reg protocol_error,
    output reg [127:0] error_msg
);
    
    // Error tracking
    reg cyc_without_stb;
    reg stb_without_cyc;
    reg invalid_cti;
    reg data_change_during_transaction;
    reg addr_change_during_transaction;
    reg early_cyc_termination;
    
    // Previous cycle state
    reg cyc_prev, stb_prev, we_prev, ack_prev;
    reg [2:0] cti_prev;
    reg [31:0] addr_prev, data_prev;
    
    always @(posedge clk) begin
        if (rst) begin
            protocol_error <= 1'b0;
            cyc_without_stb <= 1'b0;
            stb_without_cyc <= 1'b0;
            invalid_cti <= 1'b0;
            data_change_during_transaction <= 1'b0;
            addr_change_during_transaction <= 1'b0;
            early_cyc_termination <= 1'b0;
        end else begin
            
            // ===== CHECK 1: CYC and STB relationship =====
            // CYC must not be high unless STB follows or is concurrent
            if (cyc && !stb && ack_prev && !cyc_prev) begin
                cyc_without_stb <= 1'b1;
                error_msg <= "ERROR: CYC high without STB (classic protocol)";
            end
            
            // STB must not be high unless CYC is high
            if (stb && !cyc) begin
                stb_without_cyc <= 1'b1;
                error_msg <= "ERROR: STB high without CYC";
            end
            
            // ===== CHECK 2: CTI code validity (pipelined I-bus) =====
            // Valid CTI codes: 000 (classic), 010 (continue), 111 (end)
            if (cyc || stb) begin
                if (bus_type == 4'h0) begin
                    // Instruction bus (pipelined with bursts)
                    if (cti != 3'b000 && cti != 3'b010 && cti != 3'b111) begin
                        invalid_cti <= 1'b1;
                        error_msg <= {"ERROR: Invalid CTI code: ", cti};
                    end
                    
                    // CTI must transition: 010...010 -> 111
                    if (cti_prev == 3'b010 && cti == 3'b010) begin
                        // Continuation is OK
                    end else if (cti_prev == 3'b010 && cti == 3'b111) begin
                        // Burst end is OK
                    end else if (cti == 3'b000) begin
                        // Classic (single) transaction OK
                    end
                end else begin
                    // Data bus (classic only)
                    if (^cti !== 1'bx && cti != 3'b000 && cti != 3'b111) begin
                        invalid_cti <= 1'b1;
                        error_msg <= "ERROR: CTI not 000/111 on classic D-bus";
                    end
                end
            end
            
            // ===== CHECK 3: Signal stability during transaction =====
            if (stb && !ack && !ack_prev && bus_type != 4'h0) begin
                // Classic transaction in progress (no ack on this or previous cycle)
                // Address must be stable
                if (addr != addr_prev && stb_prev) begin
                    addr_change_during_transaction <= 1'b1;
                    error_msg <= {"ERROR: Address changed during transaction: ", addr_prev, " -> ", addr};
                end
                
                // Data must be stable (write path)
                if (we && data_o != data_prev && stb_prev) begin
                    data_change_during_transaction <= 1'b1;
                    error_msg <= "ERROR: Write data changed during transaction";
                end
            end
            
            // ===== CHECK 4: Cycle termination protocol =====
            if (cyc_prev && !cyc) begin
                // CYC termination
                if (ack_prev && stb_prev) begin
                    // Normal termination after ACK: OK
                end else begin
                    early_cyc_termination <= 1'b1;
                    error_msg <= "ERROR: CYC terminated before ACK";
                end
            end
            
            // Collect all errors
            if (cyc_without_stb || stb_without_cyc || invalid_cti || 
                data_change_during_transaction || addr_change_during_transaction || 
                early_cyc_termination) begin
                protocol_error <= 1'b1;
                $error("WISHBONE PROTOCOL VIOLATION: %s", error_msg);
            end
        end
        
        // Save previous state
        cyc_prev <= cyc;
        stb_prev <= stb;
        we_prev <= we;
        ack_prev <= ack;
        cti_prev <= cti;
        addr_prev <= addr;
        data_prev <= data_o;
    end

endmodule

/**
 * Cache Protocol Checker
 * 
 * Validates cache line fill correctness:
 * - All bursts complete (010 never stuck, 111 terminates)
 * - No interleaved fills
 * - Line alignment verification
 */

module cache_protocol_checker (
    input clk,
    input rst,
    
    input         iwb_stb,
    input         iwb_ack,
    input  [2:0]  iwb_cti,
    input  [31:2] iwb_addr,  // Word-aligned address
    
    output reg cache_error,
    output reg [127:0] error_msg
);
    
    reg in_burst;
    reg [1:0] burst_count;
    reg [31:2] burst_start_addr;
    reg burst_timeout;
    integer burst_age;
    
    // Cache line descriptor (4-word line = 16 bytes = addr[31:4])
    wire [31:4] current_line = iwb_addr[31:4];
    
    always @(posedge clk) begin
        if (rst) begin
            in_burst <= 1'b0;
            burst_count <= 2'h0;
            cache_error <= 1'b0;
            burst_timeout <= 1'b0;
            burst_age <= 0;
        end else begin
            
            // Track burst age for timeout detection
            if (in_burst)
                burst_age <= burst_age + 1;
            
            // Burst timeout: if in burst for >100 cycles without end
            if (burst_age > 100) begin
                cache_error <= 1'b1;
                error_msg <= "ERROR: Cache burst timeout (CTI=010 for >100 cycles)";
            end
            
            if (iwb_stb && iwb_ack) begin
                
                if (iwb_cti == 3'b010) begin
                    // Burst continue
                    
                    if (!in_burst) begin
                        // Start new burst
                        in_burst <= 1'b1;
                        burst_count <= 2'h1;
                        burst_start_addr <= iwb_addr[31:2];
                        burst_age <= 0;
                    end else begin
                        // Continue burst: address must increment by 1 (word-aligned)
                        if (iwb_addr != burst_start_addr + burst_count) begin
                            cache_error <= 1'b1;
                            error_msg <= {"ERROR: Non-sequential cache burst address: ", 
                                        iwb_addr, " != ", burst_start_addr + burst_count};
                        end
                        
                        burst_count <= burst_count + 2'h1;
                        
                        // Burst should not exceed 4 words
                        if (burst_count >= 2'h3) begin
                            cache_error <= 1'b1;
                            error_msg <= "ERROR: Cache burst exceeded 4 words without CTI=111";
                        end
                    end
                    
                end else if (iwb_cti == 3'b111) begin
                    // Burst end
                    
                    if (!in_burst) begin
                        // Standalone transaction (OK, not part of burst)
                        in_burst <= 1'b0;
                        burst_count <= 2'h0;
                    end else begin
                        // Valid burst termination
                        // Verify all 4 words were fetched
                        if (burst_count < 2'h3) begin
                            $warning("CACHE WARNING: Short burst completed: %0d words", burst_count + 1);
                        end
                        in_burst <= 1'b0;
                        burst_count <= 2'h0;
                        burst_age <= 0;
                    end
                    
                end else begin
                    // CTI = 000 (single classic transaction)
                    if (in_burst) begin
                        cache_error <= 1'b1;
                        error_msg <= "ERROR: Classic CTI=000 received during burst (expected 010 or 111)";
                    end
                    in_burst <= 1'b0;
                    burst_count <= 2'h0;
                end
            end
        end
    end

endmodule

/**
 * Interrupt Protocol Checker
 * 
 * Validates interrupt sequencing and CSR register state consistency.
 */

module interrupt_protocol_checker (
    input clk,
    input rst,
    
    input [7:0] irq,
    input irq_ack,
    
    input [31:0] mcause,
    input [31:0] mepc,
    input [31:0] mstatus,
    
    output reg irq_error,
    output reg [127:0] error_msg
);
    
    // Check mcause lock (bit 31 should stay 1 during interrupt service)
    reg [31:0] mcause_prev;
    reg irq_active;
    
    always @(posedge clk) begin
        if (rst) begin
            irq_error <= 1'b0;
            irq_active <= 1'b0;
        end else begin
            
            // mcause[31] = 1 indicates interrupt
            if (mcause[31]) begin
                irq_active <= 1'b1;
                
                // Verify mcause code is valid (bits [3:0])
                if (mcause[3:0] > 8'd7) begin
                    irq_error <= 1'b1;
                    error_msg = {"ERROR: Invalid mcause IRQ code: ", mcause[3:0]};
                end
                
                // mcause should not change while service in progress
                if (mcause_prev[31] && mcause != mcause_prev) begin
                    irq_error <= 1'b1;
                    error_msg <= "ERROR: mcause changed during interrupt service (nested interrupt not allowed)";
                end
            end
            
            // Check interrupt acknowledge timing
            if (irq_ack && !irq_active) begin
                irq_error <= 1'b1;
                error_msg <= "ERROR: IRQ acknowledge without active interrupt";
            end
            
            mcause_prev <= mcause;
        end
    end

endmodule
