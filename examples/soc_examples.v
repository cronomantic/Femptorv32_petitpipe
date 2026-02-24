/**
 * Example SoC Memory Controller for FemtoRV32 PetitPipe
 * 
 * Implements a dual-port memory with Wishbone interface to:
 * - Instruction bus (iwb_*): Pipelined (supports burst with CTI)
 * - Data bus (dwb_*): Classic single-transaction
 * 
 * Features:
 * - Configurable memory size
 * - Separate I/D address spaces (split memory SoC)
 * - Variable wait-state simulation (realistic latency)
 * - Write-through (no cache coherency issues)
 */

module soc_dual_port_controller #(
    parameter ADDR_WIDTH = 16,          // 64KB each (I and D memory)
    parameter word_addr_width = ADDR_WIDTH - 2,  // Word-addressed
    parameter INIT_FILE = "",           // Optional: initial program
    parameter LATENCY = 1               // Wait-states before ACK
) (
    input clk,
    input rst,
    
    // Instruction Wishbone (pipelined)
    input         iwb_cyc,
    input         iwb_stb,
    input  [word_addr_width-1:0] iwb_adr,
    input  [2:0]  iwb_cti,              // Burst indicator
    output        iwb_ack,
    output [31:0] iwb_dat_o,
    
    // Data Wishbone (classic)
    input         dwb_cyc,
    input         dwb_stb,
    input         dwb_we,
    input  [3:0]  dwb_sel,
    input  [word_addr_width-1:0] dwb_adr,
    input  [31:0] dwb_dat_i,
    output        dwb_ack,
    output [31:0] dwb_dat_o,
    
    // Debug port (optional read-only access for simulation)
    input  [word_addr_width-1:0] dbg_adr,
    output [31:0] dbg_dat_o
);
    
    // Dual-port memory arrays
    reg [31:0] imem [0:(1<<word_addr_width)-1];  // Instruction memory
    reg [31:0] dmem [0:(1<<word_addr_width)-1];  // Data memory
    
    // Pipeline stages for pipelined I-bus (Wishbone B4)
    reg [word_addr_width-1:0] iwb_adr_q;
    reg iwb_burst_q;
    reg [2:0] iwb_cti_q;
    reg [$clog2(LATENCY)-1:0] iwb_wait_q;
    
    // Classic D-bus pipeline
    reg [word_addr_width-1:0] dwb_adr_q;
    reg dwb_we_q;
    reg [3:0] dwb_sel_q;
    reg [31:0] dwb_dat_q;
    reg [$clog2(LATENCY)-1:0] dwb_wait_q;
    
    // Instruction memory output
    assign iwb_dat_o = imem[iwb_adr_q];
    
    // Data memory output
    assign dwb_dat_o = dmem[dwb_adr_q];
    
    // Debug read (non-blocking)
    assign dbg_dat_o = dmem[dbg_adr];
    
    // Pipelined instruction bus (Wishbone B4)
    // ACK is generated based on configurable latency
    always @(posedge clk) begin
        if (rst) begin
            iwb_adr_q <= {word_addr_width{1'b0}};
            iwb_cti_q <= 3'b000;
            iwb_wait_q <= {$clog2(LATENCY){1'b0}};
        end else if (iwb_cyc && iwb_stb) begin
            // Capture address and burst info
            iwb_adr_q <= iwb_adr;
            iwb_cti_q <= iwb_cti;
            iwb_wait_q <= iwb_wait_q + 1'b1;
        end
    end
    
    // Instruction ACK generation (pipelined: 1 cycle latency by default)
    assign iwb_ack = iwb_cyc && iwb_stb && (iwb_wait_q >= (LATENCY - 1));
    
    // Classic data bus (Wishbone B4)
    always @(posedge clk) begin
        if (rst) begin
            dwb_adr_q <= {word_addr_width{1'b0}};
            dwb_we_q <= 1'b0;
            dwb_sel_q <= 4'b0000;
            dwb_dat_q <= 32'h0;
            dwb_wait_q <= {$clog2(LATENCY){1'b0}};
        end else if (dwb_cyc && dwb_stb) begin
            // Capture transaction
            dwb_adr_q <= dwb_adr;
            dwb_we_q <= dwb_we;
            dwb_sel_q <= dwb_sel;
            dwb_dat_q <= dwb_dat_i;
            dwb_wait_q <= dwb_wait_q + 1'b1;
            
            // Write-through memory on ACK
            if (dwb_ack) begin
                if (dwb_we) begin
                    // Byte-selectable write
                    if (dwb_sel[0]) dmem[dwb_adr][7:0]   <= dwb_dat_i[7:0];
                    if (dwb_sel[1]) dmem[dwb_adr][15:8]  <= dwb_dat_i[15:8];
                    if (dwb_sel[2]) dmem[dwb_adr][23:16] <= dwb_dat_i[23:16];
                    if (dwb_sel[3]) dmem[dwb_adr][31:24] <= dwb_dat_i[31:24];
                end
            end
        end
    end
    
    // Data ACK generation (classic: 1 cycle latency)
    assign dwb_ack = dwb_cyc && dwb_stb && (dwb_wait_q >= (LATENCY - 1));
    
    // Initialize from file if provided
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, imem);
    end

endmodule

/**
 * Example Bus Arbiter for Shared Instruction Memory
 * 
 * If instruction and data memories share a single port,
 * this arbiter gives priority to I-bus (prefetch is time-critical).
 * 
 * Priority: I-bus > D-bus
 */

module soc_simple_arbiter #(
    parameter ADDR_WIDTH = 16
) (
    input clk,
    input rst,
    
    // I-bus request (pipelined, prefetch)
    input         iwb_cyc,
    input         iwb_stb,
    input  [ADDR_WIDTH-3:0] iwb_adr,
    input  [2:0]  iwb_cti,
    output        iwb_ack,
    output [31:0] iwb_dat,
    
    // D-bus request (classic, lower priority)
    input         dwb_cyc,
    input         dwb_stb,
    input         dwb_we,
    input  [ADDR_WIDTH-3:0] dwb_adr,
    input  [3:0]  dwb_sel,
    input  [31:0] dwb_wdat,
    output        dwb_ack,
    output [31:0] dwb_rdat,
    
    // Shared memory interface
    output        mem_cyc,
    output        mem_stb,
    output        mem_we,
    output [ADDR_WIDTH-3:0] mem_adr,
    output [3:0]  mem_sel,
    output [31:0] mem_wdat,
    input         mem_ack,
    input  [31:0] mem_rdat
);
    
    // Arbitration: I-bus has strict priority
    wire i_wins = iwb_cyc && iwb_stb;
    wire d_wins = dwb_cyc && dwb_stb && !iwb_cyc;
    
    // Multiplex outputs to memory
    assign mem_cyc  = i_wins ? iwb_cyc  : (d_wins ? dwb_cyc  : 1'b0);
    assign mem_stb  = i_wins ? iwb_stb  : (d_wins ? dwb_stb  : 1'b0);
    assign mem_we   = i_wins ? 1'b0     : (d_wins ? dwb_we   : 1'b0);  // I-bus read-only
    assign mem_adr  = i_wins ? iwb_adr  : (d_wins ? dwb_adr  : {(ADDR_WIDTH-2){1'b0}});
    assign mem_sel  = i_wins ? 4'b1111  : (d_wins ? dwb_sel  : 4'b0000);  // I-bus always full word
    assign mem_wdat = dwb_wdat;
    
    // Feedback: ACK goes to winner
    assign iwb_ack = i_wins && mem_ack;
    assign dwb_ack = d_wins && mem_ack;
    
    // Mux read data
    assign iwb_dat = mem_rdat;
    assign dwb_rdat = mem_rdat;

endmodule

/**
 * Example: Unified SoC Top Level
 * 
 * Integrates FemtoRV32_PetitPipe_WB with dual-port memory controller
 * and optional shared-port memory with arbiter.
 */

module soc_top #(
    parameter IMEM_SIZE = 16'h4000,  // 16KB instruction
    parameter DMEM_SIZE = 16'h2000   // 8KB data
) (
    input clk,
    input rst,
    input [7:0] ext_irq,
    
    // Debug/JTAG interface (optional)
    input  [31:0] dbg_addr,
    output [31:0] dbg_rdata,
    input  [31:0] dbg_wdata,
    input         dbg_we
);
    
    // Core-to-bus wires
    wire [31:0] core_pc;
    wire [31:0] core_ir;
    
    // Instruction bus
    wire         iwb_cyc, iwb_stb;
    wire [31:2]  iwb_adr;
    wire [2:0]   iwb_cti;
    wire         iwb_ack;
    wire [31:0]  iwb_dat;
    
    // Data bus
    wire         dwb_cyc, dwb_stb, dwb_we;
    wire [3:0]   dwb_sel;
    wire [31:2]  dwb_adr;
    wire [31:0]  dwb_wdat, dwb_rdat;
    wire         dwb_ack;
    
    // Interrupt acknowledge
    wire irq_ack;
    reg [7:0] irq_r;
    
    // Clock and reset
    always @(posedge clk or negedge rst) begin
        if (!rst)
            irq_r <= 8'h0;
        else
            irq_r <= ext_irq;
    end
    
    // ===== Core Instance =====
    FemtoRV32_PetitPipe_WB core (
        .clk(clk),
        .reset(!rst),
        
        // Instruction Wishbone
        .iwb_cyc(iwb_cyc),
        .iwb_stb(iwb_stb),
        .iwb_adr(iwb_adr),
        .iwb_cti(iwb_cti),
        .iwb_ack(iwb_ack),
        .iwb_dat_o(iwb_dat),
        
        // Data Wishbone
        .dwb_cyc(dwb_cyc),
        .dwb_stb(dwb_stb),
        .dwb_we(dwb_we),
        .dwb_sel(dwb_sel),
        .dwb_adr(dwb_adr),
        .dwb_dat_i(dwb_rdat),
        .dwb_dat_o(dwb_wdat),
        .dwb_ack(dwb_ack),
        
        // Interrupt
        .irq(irq_r),
        .irq_ack(irq_ack),
        
        // Debug
        .core_pc(core_pc),
        .core_ir(core_ir)
    );
    
    // ===== Memory Controller Instance =====
    soc_dual_port_controller #(
        .ADDR_WIDTH(16),
        .LATENCY(1)
    ) mem_ctrl (
        .clk(clk),
        .rst(rst),
        
        .iwb_cyc(iwb_cyc),
        .iwb_stb(iwb_stb),
        .iwb_adr(iwb_adr[13:0]),
        .iwb_cti(iwb_cti),
        .iwb_ack(iwb_ack),
        .iwb_dat_o(iwb_dat),
        
        .dwb_cyc(dwb_cyc),
        .dwb_stb(dwb_stb),
        .dwb_we(dwb_we),
        .dwb_sel(dwb_sel),
        .dwb_adr(dwb_adr[13:0]),
        .dwb_dat_i(dwb_wdat),
        .dwb_ack(dwb_ack),
        .dwb_dat_o(dwb_rdat),
        
        .dbg_adr(dbg_addr[13:0]),
        .dbg_dat_o(dbg_rdata)
    );

endmodule
