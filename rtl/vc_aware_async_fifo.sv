// =============================================================================
// Module    : vc_aware_async_fifo
// Description: Top-level wrapper for the Distributed Credit Loop CDC
//              architecture.  Instantiates one vc_async_fifo_ctrl per
//              virtual channel and one shared vc_async_fifo_mem, then
//              arbitrates the read-side output with a round-robin scheduler.
//
//              Credit Loop #1 — TX ↔ FIFO write side
//                wr_credit_grant[vc] pulses once per flit consumed on the
//                read side of VC vc, returning that credit to the TX.
//
//              Credit Loop #2 — FIFO read side ↔ Receiver
//                rd_valid[vc] is asserted only when the FIFO has data for
//                VC vc AND rd_ready[vc] is high (receiver has a credit).
//
// Parameters:
//   NUM_VC      : Number of virtual channels (default 4, must be power-of-2).
//   FIFO_DEPTH  : Entries per VC (default 8, must be power-of-2, min 2).
//   DATA_WIDTH  : Flit data width in bits (default 32).
//   ADDR_WIDTH  : $clog2(FIFO_DEPTH).
//
// Author    : <placeholder>
// Date      : 2026-03-23
// Standard  : IEEE 1800-2017 SystemVerilog
// =============================================================================

`timescale 1ns/1ps

module vc_aware_async_fifo #(
    parameter int NUM_VC     = 4,   // Must be a power of 2
    parameter int FIFO_DEPTH = 8,   // Must be a power of 2 (≥ 2)
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = $clog2(FIFO_DEPTH)
) (
    // -------------------------------------------------------------------------
    // Write side — transmitter clock domain
    // -------------------------------------------------------------------------
    input  logic                          wr_clk,
    input  logic                          wr_rst_n,        // Active-low reset
    input  logic [NUM_VC-1:0]             wr_valid,        // Per-VC write valid
    input  logic [$clog2(NUM_VC)-1:0]     wr_vc_id,        // VC ID of incoming flit
    input  logic [DATA_WIDTH-1:0]         wr_data,         // Flit payload
    output logic [NUM_VC-1:0]             wr_credit_grant, // Per-VC credit → TX
    output logic [NUM_VC-1:0]             wr_ready,        // Per-VC FIFO not-full

    // -------------------------------------------------------------------------
    // Read side — receiver clock domain
    // -------------------------------------------------------------------------
    input  logic                          rd_clk,
    input  logic                          rd_rst_n,        // Active-low reset
    input  logic [NUM_VC-1:0]             rd_ready,        // Per-VC receiver ready
    output logic [NUM_VC-1:0]             rd_valid,        // Per-VC read valid
    output logic [$clog2(NUM_VC)-1:0]     rd_vc_id,        // VC ID of outgoing flit
    output logic [DATA_WIDTH-1:0]         rd_data          // Flit payload
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int VC_WIDTH = $clog2(NUM_VC);

    // =========================================================================
    // Per-VC signals from/to vc_async_fifo_ctrl instances
    // =========================================================================
    logic [NUM_VC-1:0]         vc_wr_full;
    logic [NUM_VC-1:0]         vc_wr_credit_grant;
    logic [ADDR_WIDTH-1:0]     vc_wr_addr [NUM_VC-1:0];

    logic [NUM_VC-1:0]         vc_rd_empty;
    logic [ADDR_WIDTH-1:0]     vc_rd_addr [NUM_VC-1:0];

    // =========================================================================
    // Per-VC vc_async_fifo_ctrl instantiations (one per virtual channel)
    // =========================================================================
    generate
        genvar vc;
        for (vc = 0; vc < NUM_VC; vc = vc + 1) begin : gen_ctrl
            vc_async_fifo_ctrl #(
                .FIFO_DEPTH (FIFO_DEPTH),
                .ADDR_WIDTH (ADDR_WIDTH)
            ) u_ctrl (
                // Write side
                .wr_clk          (wr_clk),
                .wr_rst_n        (wr_rst_n),
                // Write enable: TX must assert wr_valid[vc] with wr_vc_id == vc
                .wr_en           (wr_valid[vc] && (wr_vc_id == vc)),
                .wr_full         (vc_wr_full[vc]),
                .wr_credit_grant (vc_wr_credit_grant[vc]),
                .wr_addr         (vc_wr_addr[vc]),

                // Read side
                .rd_clk          (rd_clk),
                .rd_rst_n        (rd_rst_n),
                // rd_en = rd_valid[vc]: advance pointer when flit is delivered
                .rd_en           (rd_valid[vc]),
                .rd_empty        (vc_rd_empty[vc]),
                .rd_addr         (vc_rd_addr[vc])
            );
        end
    endgenerate

    // =========================================================================
    // Write-side status outputs (wr_clk domain)
    // =========================================================================
    assign wr_credit_grant = vc_wr_credit_grant;
    assign wr_ready        = ~vc_wr_full;

    // =========================================================================
    // Round-robin read arbiter — rd_clk domain
    //
    // Selects one eligible VC per cycle from the set of VCs that are both
    // non-empty AND have rd_ready asserted (receiver credit available).
    // The winner's address drives the shared memory read port.
    // rd_valid is asserted for exactly that one VC (one-hot).
    //
    // NOTE: pointer wrap uses VC_WIDTH-bit truncation and assumes NUM_VC is
    //       a power of 2 so that natural binary overflow = modulo NUM_VC.
    // =========================================================================

    // Round-robin priority pointer (rd_clk domain)
    logic [VC_WIDTH-1:0] rr_ptr;

    // VCs eligible for a read this cycle: non-empty AND receiver ready
    logic [NUM_VC-1:0] rd_eligible;
    assign rd_eligible = ~vc_rd_empty & rd_ready;

    // Winning VC and its validity flag
    logic [VC_WIDTH-1:0] rd_winner;
    logic                rd_winner_valid;

    // Priority walk: starting from rr_ptr, find first eligible VC.
    // check_vc is computed inline to avoid variable-lifetime issues.
    always_comb begin : rr_arb
        rd_winner       = rr_ptr; // default (no grant)
        rd_winner_valid = 1'b0;
        for (int i = 0; i < NUM_VC; i = i + 1) begin
            if (!rd_winner_valid && rd_eligible[VC_WIDTH'(rr_ptr + i)]) begin
                rd_winner       = VC_WIDTH'(rr_ptr + i);
                rd_winner_valid = 1'b1;
            end
        end
    end

    // Advance the round-robin pointer after each successful grant
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rr_ptr <= '0;
        else if (rd_winner_valid)
            rr_ptr <= VC_WIDTH'(rd_winner + 1'b1);
    end

    // =========================================================================
    // Address / flag muxes
    //
    // Icarus Verilog does not reliably resolve variable-indexed unpacked-array
    // slices inside module port connections.  Explicit combinational muxes here
    // ensure correct selection in both simulation and synthesis.
    // =========================================================================

    // Write-side: select the write address and full flag for the active VC
    logic [ADDR_WIDTH-1:0] sel_wr_addr;
    logic                  sel_wr_full;

    always_comb begin : wr_mux
        sel_wr_addr = '0;
        sel_wr_full = 1'b0;
        for (int i = 0; i < NUM_VC; i = i + 1) begin
            if (wr_vc_id == i) begin
                sel_wr_addr = vc_wr_addr[i];
                sel_wr_full = vc_wr_full[i];
            end
        end
    end

    // Read-side: select the read address for the winning VC
    logic [ADDR_WIDTH-1:0] sel_rd_addr;

    always_comb begin : rd_mux
        sel_rd_addr = '0;
        for (int i = 0; i < NUM_VC; i = i + 1) begin
            if (rd_winner == i) sel_rd_addr = vc_rd_addr[i];
        end
    end

    // =========================================================================
    // Shared memory — combinational read driven by winning VC's read address
    // =========================================================================
    vc_async_fifo_mem #(
        .NUM_VC     (NUM_VC),
        .FIFO_DEPTH (FIFO_DEPTH),
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .VC_WIDTH   (VC_WIDTH)
    ) u_mem (
        // Write port (wr_clk domain)
        .wr_clk   (wr_clk),
        .wr_en    (wr_valid[wr_vc_id] && !sel_wr_full),
        .wr_vc_id (wr_vc_id),
        .wr_addr  (sel_wr_addr),
        .wr_data  (wr_data),

        // Read port (combinational, driven by winning VC)
        .rd_vc_id (rd_winner),
        .rd_addr  (sel_rd_addr),
        .rd_data  (rd_data)
    );

    // =========================================================================
    // rd_valid output — one-hot, asserted for the winning VC only.
    // By construction, rd_valid[vc] == 1 implies rd_ready[vc] == 1
    // (rd_eligible gates on rd_ready), satisfying Credit Loop #2.
    // =========================================================================
    always_comb begin : gen_rd_valid
        rd_valid = '0;
        if (rd_winner_valid)
            rd_valid[rd_winner] = 1'b1;
    end

    // VC ID of the outgoing flit
    assign rd_vc_id = rd_winner_valid ? rd_winner : '0;

endmodule
