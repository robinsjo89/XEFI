// =============================================================================
// Module    : vc_async_fifo_ctrl
// Description: Per-virtual-channel asynchronous FIFO control logic.
//              Implements Gray-code pointer synchronization with 2-FF CDC
//              synchronizers and write-side credit management for the
//              Distributed Credit Loop CDC architecture.
//
//              Credit Loop #1 (TX → FIFO write side):
//                wr_credit_grant pulses once per flit consumed on the read
//                side, returning that credit to the transmitter.
//              Credit Loop #2 (FIFO read side → Receiver):
//                rd_empty drives rd_valid gating in the top-level wrapper.
//
// Parameters:
//   FIFO_DEPTH  : Number of entries per VC (must be power of 2, min 2).
//   ADDR_WIDTH  : $clog2(FIFO_DEPTH) — address bits for the shared memory.
//
// Author    : <placeholder>
// Date      : 2026-03-23
// Standard  : IEEE 1800-2017 SystemVerilog
// =============================================================================

`timescale 1ns/1ps

module vc_async_fifo_ctrl #(
    parameter int FIFO_DEPTH = 8,              // Must be a power of 2 (≥ 2)
    parameter int ADDR_WIDTH = $clog2(FIFO_DEPTH)
) (
    // -------------------------------------------------------------------------
    // Write side — transmitter clock domain (wr_clk)
    // -------------------------------------------------------------------------
    input  logic                  wr_clk,
    input  logic                  wr_rst_n,        // Active-low synchronous reset
    input  logic                  wr_en,           // Write enable (pre-qualified)
    output logic                  wr_full,         // FIFO full flag (wr_clk domain)
    output logic                  wr_credit_grant, // 1 pulse = 1 credit returned to TX
    output logic [ADDR_WIDTH-1:0] wr_addr,         // Write address to shared memory

    // -------------------------------------------------------------------------
    // Read side — receiver clock domain (rd_clk)
    // -------------------------------------------------------------------------
    input  logic                  rd_clk,
    input  logic                  rd_rst_n,        // Active-low synchronous reset
    input  logic                  rd_en,           // Read enable (pre-qualified)
    output logic                  rd_empty,        // FIFO empty flag (rd_clk domain)
    output logic [ADDR_WIDTH-1:0] rd_addr          // Read address to shared memory
);

    // =========================================================================
    // Local parameters
    // =========================================================================

    // One extra MSB beyond ADDR_WIDTH disambiguates full vs. empty when the
    // lower address bits wrap around to zero.
    localparam int PTR_WIDTH = ADDR_WIDTH + 1;

    // Full-condition XOR mask: top two bits = 1, remaining bits = 0.
    // wr_full when (wr_ptr_gray XOR rd_ptr_gray_sync) == FULL_MASK.
    // Works for any PTR_WIDTH ≥ 2 (i.e., FIFO_DEPTH ≥ 2).
    localparam logic [PTR_WIDTH-1:0] FULL_MASK = PTR_WIDTH'(3 << (PTR_WIDTH - 2));

    // =========================================================================
    // Pointer registers
    // =========================================================================

    logic [PTR_WIDTH-1:0] wr_ptr_bin;  // Binary write pointer  (wr_clk domain)
    logic [PTR_WIDTH-1:0] wr_ptr_gray; // Gray   write pointer  (wr_clk domain)
    logic [PTR_WIDTH-1:0] rd_ptr_bin;  // Binary read  pointer  (rd_clk domain)
    logic [PTR_WIDTH-1:0] rd_ptr_gray; // Gray   read  pointer  (rd_clk domain)

    // =========================================================================
    // 2-FF CDC synchronizers
    //
    // Gray code changes exactly 1 bit per counter increment.  Synchronising a
    // multi-bit Gray bus through a 2-FF chain is safe: any metastable FF can
    // only produce a one-step pointer error which is self-correcting.
    // =========================================================================

    // Write pointer crossing into rd_clk domain
    (* async_reg = "true" *) logic [PTR_WIDTH-1:0] wr_ptr_gray_s1;
    (* async_reg = "true" *) logic [PTR_WIDTH-1:0] wr_ptr_gray_s2;

    // Read pointer crossing into wr_clk domain
    (* async_reg = "true" *) logic [PTR_WIDTH-1:0] rd_ptr_gray_s1;
    (* async_reg = "true" *) logic [PTR_WIDTH-1:0] rd_ptr_gray_s2;

    // =========================================================================
    // Write pointer — wr_clk domain
    // =========================================================================
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= '0;
            wr_ptr_gray <= '0;
        end else if (wr_en && !wr_full) begin
            wr_ptr_bin  <= wr_ptr_bin + 1'b1;
            // Binary → Gray: gray = bin XOR (bin >> 1)
            wr_ptr_gray <= (wr_ptr_bin + 1'b1) ^ ((wr_ptr_bin + 1'b1) >> 1);
        end
    end

    // =========================================================================
    // Read pointer — rd_clk domain
    // =========================================================================
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= '0;
            rd_ptr_gray <= '0;
        end else if (rd_en && !rd_empty) begin
            rd_ptr_bin  <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= (rd_ptr_bin + 1'b1) ^ ((rd_ptr_bin + 1'b1) >> 1);
        end
    end

    // =========================================================================
    // Synchroniser: wr_ptr_gray → rd_clk domain (2 flip-flop stages)
    // =========================================================================
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_s1 <= '0;
            wr_ptr_gray_s2 <= '0;
        end else begin
            wr_ptr_gray_s1 <= wr_ptr_gray;
            wr_ptr_gray_s2 <= wr_ptr_gray_s1;
        end
    end

    // =========================================================================
    // Synchroniser: rd_ptr_gray → wr_clk domain (2 flip-flop stages)
    // =========================================================================
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_s1 <= '0;
            rd_ptr_gray_s2 <= '0;
        end else begin
            rd_ptr_gray_s1 <= rd_ptr_gray;
            rd_ptr_gray_s2 <= rd_ptr_gray_s1;
        end
    end

    // =========================================================================
    // Full flag — wr_clk domain (conservative; uses synchronised rd pointer)
    //
    // Full when wr_ptr_gray XOR rd_ptr_gray_sync equals FULL_MASK, meaning
    // the write pointer has wrapped around exactly once more than the read
    // pointer (top two Gray bits inverted, all lower bits equal).
    // =========================================================================
    assign wr_full = ((wr_ptr_gray ^ rd_ptr_gray_s2) == FULL_MASK);

    // =========================================================================
    // Empty flag — rd_clk domain (conservative; uses synchronised wr pointer)
    //
    // Empty when the read Gray pointer equals the synchronised write Gray
    // pointer — no unread entries remain.
    // =========================================================================
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_s2);

    // =========================================================================
    // Address outputs — lower ADDR_WIDTH bits of binary pointer
    // =========================================================================
    assign wr_addr = wr_ptr_bin[ADDR_WIDTH-1:0];
    assign rd_addr = rd_ptr_bin[ADDR_WIDTH-1:0];

    // =========================================================================
    // Credit management — wr_clk domain
    //
    // The read-side pointer (rd_ptr_gray) is synchronised into the write
    // domain (rd_ptr_gray_s2).  Converting it to binary and differencing
    // against the previously observed value gives the number of flits
    // consumed since the last clock edge — each is a credit to return to TX.
    //
    // A pending-credit counter accumulates newly discovered credits and
    // drains one per wr_clk cycle so wr_credit_grant is always a single-
    // cycle pulse.  This handles cases where rd_clk is faster than wr_clk
    // and the pointer can advance by more than one between wr_clk edges.
    // =========================================================================

    // Gray → Binary conversion function (combinational, ripple XOR chain)
    function automatic [PTR_WIDTH-1:0] gray_to_bin;
        input [PTR_WIDTH-1:0] gray;
        integer i;
        gray_to_bin[PTR_WIDTH-1] = gray[PTR_WIDTH-1];
        for (i = PTR_WIDTH-2; i >= 0; i = i - 1)
            gray_to_bin[i] = gray_to_bin[i+1] ^ gray[i];
    endfunction

    // Synchronised read pointer in binary (wr domain)
    wire [PTR_WIDTH-1:0] rd_ptr_bin_wr;
    assign rd_ptr_bin_wr = gray_to_bin(rd_ptr_gray_s2);

    // Previously observed binary read pointer (registered)
    logic [PTR_WIDTH-1:0] rd_ptr_bin_wr_prev;

    // Number of new credits discovered this wr_clk cycle
    wire [PTR_WIDTH-1:0] new_credits;
    assign new_credits = rd_ptr_bin_wr - rd_ptr_bin_wr_prev;

    // Pending credits waiting to be serialised as single-cycle grant pulses
    logic [PTR_WIDTH-1:0] pending_credits;

    // Issue a credit whenever there are pending credits or new ones arrive
    assign wr_credit_grant = (pending_credits > '0) || (new_credits > '0);

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_bin_wr_prev <= '0;
            pending_credits    <= '0;
        end else begin
            // Latch the current binary read pointer for the next delta
            rd_ptr_bin_wr_prev <= rd_ptr_bin_wr;
            // Accumulate new credits; subtract 1 if granting this cycle
            pending_credits    <= pending_credits + new_credits
                                  - {{(PTR_WIDTH-1){1'b0}}, wr_credit_grant};
        end
    end

endmodule
