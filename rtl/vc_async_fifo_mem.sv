// =============================================================================
// Module    : vc_async_fifo_mem
// Description: Dual-port register-based memory for the VC-aware async FIFO.
//              Each virtual channel owns a dedicated, non-overlapping bank
//              addressed by the concatenation {vc_id, ptr}.
//
//              Write port : synchronous (wr_clk domain).
//              Read  port : asynchronous (combinational) — data is available
//                           in the same cycle as a stable read address is
//                           presented, matching the top-level round-robin
//                           arbiter flow.
//
// Parameters:
//   NUM_VC      : Number of virtual channels.
//   FIFO_DEPTH  : Entries per VC (must be a power of 2).
//   DATA_WIDTH  : Flit data width in bits.
//   ADDR_WIDTH  : $clog2(FIFO_DEPTH).
//   VC_WIDTH    : $clog2(NUM_VC).
//
// Author    : <placeholder>
// Date      : 2026-03-23
// Standard  : IEEE 1800-2017 SystemVerilog
// =============================================================================

`timescale 1ns/1ps

module vc_async_fifo_mem #(
    parameter int NUM_VC     = 4,
    parameter int FIFO_DEPTH = 8,
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = $clog2(FIFO_DEPTH),
    parameter int VC_WIDTH   = $clog2(NUM_VC)
) (
    // -------------------------------------------------------------------------
    // Write port — wr_clk domain
    // -------------------------------------------------------------------------
    input  logic                   wr_clk,
    input  logic                   wr_en,    // Write strobe
    input  logic [VC_WIDTH-1:0]    wr_vc_id, // Which VC is writing
    input  logic [ADDR_WIDTH-1:0]  wr_addr,  // Write pointer (LSBs)
    input  logic [DATA_WIDTH-1:0]  wr_data,  // Flit payload

    // -------------------------------------------------------------------------
    // Read port — asynchronous (combinational output)
    // -------------------------------------------------------------------------
    input  logic [VC_WIDTH-1:0]    rd_vc_id, // Which VC is reading
    input  logic [ADDR_WIDTH-1:0]  rd_addr,  // Read pointer (LSBs)
    output logic [DATA_WIDTH-1:0]  rd_data   // Flit payload (combinational)
);

    // =========================================================================
    // Memory array
    //
    // Total entries = NUM_VC * FIFO_DEPTH; each VC occupies a contiguous bank.
    // Full address = {vc_id, ptr} for both read and write ports.
    // =========================================================================
    localparam int MEM_DEPTH = NUM_VC * FIFO_DEPTH;

    logic [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    // =========================================================================
    // Synchronous write — wr_clk domain
    // =========================================================================
    always_ff @(posedge wr_clk) begin
        if (wr_en)
            // {vc_id, addr} forms the full bank-offset memory address
            mem[{wr_vc_id, wr_addr}] <= wr_data;
    end

    // =========================================================================
    // Asynchronous (combinational) read
    // =========================================================================
    assign rd_data = mem[{rd_vc_id, rd_addr}];

endmodule
