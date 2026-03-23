// =============================================================================
// Module    : tb_vc_aware_async_fifo
// Description: Self-checking testbench for vc_aware_async_fifo.
//
//              Covers:
//   TC1  Basic per-VC write and read
//   TC2  Credit Loop #1 — wr_credit_grant count == flits consumed
//   TC3  Credit Loop #2 — rd_valid only when rd_ready asserted
//   TC4  Full condition — wr_ready deasserts; no overflow
//   TC5  Empty condition — rd_valid does not assert on empty FIFO
//   TC6  Multi-VC simultaneous traffic (wr_clk=100 MHz, rd_clk≈133 MHz)
//   TC7  CDC stress — random back-pressure on read side
//
//              Scoreboard: per-VC circular buffer; push on write, pop+compare
//              on read.  Mismatches call $error; fatal conditions call $fatal.
//              Final pass/fail summary printed at end of simulation.
//
// Clocks:
//   wr_clk : 10 ns period (100 MHz)
//   rd_clk : 7.5 ns period (~133 MHz, async / independent)
//
// Author    : <placeholder>
// Date      : 2026-03-23
// Standard  : IEEE 1800-2017 SystemVerilog
// =============================================================================

`timescale 1ns/1ps

module tb_vc_aware_async_fifo;

    // =========================================================================
    // Parameters (must match the DUT defaults)
    // =========================================================================
    localparam int NUM_VC     = 4;
    localparam int FIFO_DEPTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int VC_WIDTH   = $clog2(NUM_VC);
    localparam int ADDR_WIDTH = $clog2(FIFO_DEPTH);

    // =========================================================================
    // Clocks and resets
    // =========================================================================
    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;
    logic wr_rst_n;
    logic rd_rst_n;

    always #5.0   wr_clk = ~wr_clk; // 10 ns  → 100 MHz
    always #3.75  rd_clk = ~rd_clk; // 7.5 ns → ~133 MHz (independent / async)

    // =========================================================================
    // DUT ports
    // =========================================================================
    logic [NUM_VC-1:0]         wr_valid;
    logic [VC_WIDTH-1:0]       wr_vc_id;
    logic [DATA_WIDTH-1:0]     wr_data;
    logic [NUM_VC-1:0]         wr_credit_grant;
    logic [NUM_VC-1:0]         wr_ready;

    logic [NUM_VC-1:0]         rd_ready;
    logic [NUM_VC-1:0]         rd_valid;
    logic [VC_WIDTH-1:0]       rd_vc_id;
    logic [DATA_WIDTH-1:0]     rd_data;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    vc_aware_async_fifo #(
        .NUM_VC     (NUM_VC),
        .FIFO_DEPTH (FIFO_DEPTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .wr_clk          (wr_clk),
        .wr_rst_n        (wr_rst_n),
        .wr_valid        (wr_valid),
        .wr_vc_id        (wr_vc_id),
        .wr_data         (wr_data),
        .wr_credit_grant (wr_credit_grant),
        .wr_ready        (wr_ready),
        .rd_clk          (rd_clk),
        .rd_rst_n        (rd_rst_n),
        .rd_ready        (rd_ready),
        .rd_valid        (rd_valid),
        .rd_vc_id        (rd_vc_id),
        .rd_data         (rd_data)
    );

    // =========================================================================
    // Scoreboard — per-VC circular buffer (avoids SV queue limitations)
    // =========================================================================
    localparam int SB_DEPTH = 256; // max outstanding entries per VC

    logic [DATA_WIDTH-1:0] sb_mem  [NUM_VC][SB_DEPTH];
    int                    sb_wptr [NUM_VC]; // next write slot
    int                    sb_rptr [NUM_VC]; // next read  slot
    int                    sb_cnt  [NUM_VC]; // items in buffer

    // Global counters
    int sb_errors;
    int sb_rd_count;
    int credit_grant_cnt [NUM_VC]; // wr_credit_grant pulses per VC
    int credit_rd_cnt    [NUM_VC]; // read-side flit counts per VC

    // Temporary used inside always block (no 'automatic' allowed in always)
    logic [DATA_WIDTH-1:0] mon_exp_data;

    // =========================================================================
    // Push one entry into the per-VC scoreboard
    // =========================================================================
    task automatic sb_push(input int vc, input logic [DATA_WIDTH-1:0] d);
        if (sb_cnt[vc] >= SB_DEPTH)
            $fatal(1, "[SB] Overflow on VC%0d — increase SB_DEPTH", vc);
        sb_mem[vc][sb_wptr[vc] & (SB_DEPTH-1)] = d;
        sb_wptr[vc] = sb_wptr[vc] + 1;
        sb_cnt[vc]  = sb_cnt[vc]  + 1;
    endtask

    // Pop and compare one entry from the per-VC scoreboard
    task automatic sb_pop_check(input int vc, input logic [DATA_WIDTH-1:0] actual);
        logic [DATA_WIDTH-1:0] expected;
        if (sb_cnt[vc] == 0) begin
            $error("[SB] Unexpected rd_valid[%0d]: scoreboard empty (t=%0t)", vc, $time);
            sb_errors = sb_errors + 1;
        end else begin
            expected  = sb_mem[vc][sb_rptr[vc] & (SB_DEPTH-1)];
            sb_rptr[vc]         = sb_rptr[vc] + 1;
            sb_cnt[vc]          = sb_cnt[vc]  - 1;
            sb_rd_count         = sb_rd_count + 1;
            credit_rd_cnt[vc]   = credit_rd_cnt[vc] + 1;
            if (actual !== expected) begin
                $error("[SB] VC%0d data MISMATCH: got 0x%08X, expected 0x%08X (t=%0t)",
                       vc, actual, expected, $time);
                sb_errors = sb_errors + 1;
            end
        end
    endtask

    // Clear all per-VC scoreboard state and counters
    task automatic sb_clear();
        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            sb_wptr[vc]          = 0;
            sb_rptr[vc]          = 0;
            sb_cnt[vc]           = 0;
            credit_grant_cnt[vc] = 0;
            credit_rd_cnt[vc]    = 0;
        end
        sb_rd_count = 0;
    endtask

    // =========================================================================
    // Read monitor (rd_clk domain)
    //
    // Runs continuously; calls sb_pop_check for every asserted rd_valid bit.
    // Also verifies Credit Loop #2: rd_valid must never assert when rd_ready
    // is deasserted for that VC.
    // =========================================================================
    always @(posedge rd_clk) begin
        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            if (rd_valid[vc]) begin
                // Credit Loop #2 check
                if (!rd_ready[vc]) begin
                    $error("[RD-MON] TC3 FAIL: rd_valid[%0d] asserted but rd_ready[%0d]=0 (t=%0t)",
                           vc, vc, $time);
                    sb_errors = sb_errors + 1;
                end
                sb_pop_check(vc, rd_data);
            end
        end
    end

    // =========================================================================
    // Credit-grant monitor (wr_clk domain)
    // =========================================================================
    always @(posedge wr_clk) begin
        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            if (wr_credit_grant[vc])
                credit_grant_cnt[vc] = credit_grant_cnt[vc] + 1;
        end
    end

    // =========================================================================
    // Helper tasks (all declared automatic — safe for per-call variable scope)
    // =========================================================================

    // Apply reset to both clock domains and settle
    task automatic apply_reset();
        wr_rst_n = 1'b0;
        rd_rst_n = 1'b0;
        wr_valid = '0;
        wr_vc_id = '0;
        wr_data  = '0;
        rd_ready = '0;
        repeat (8) @(posedge wr_clk);
        repeat (8) @(posedge rd_clk);
        @(posedge wr_clk); #1; wr_rst_n = 1'b1;
        @(posedge rd_clk); #1; rd_rst_n = 1'b1;
        repeat (8) @(posedge wr_clk);
        repeat (8) @(posedge rd_clk);
    endtask

    // Write one flit to VC 'vc'; stalls if FIFO is full.
    // Also pushes expected data into the scoreboard.
    // Signals are set #1 after the PREVIOUS posedge so that the CURRENT
    // posedge samples stable values (avoids Icarus initial/always race).
    task automatic write_flit(input int unsigned vc,
                               input logic [DATA_WIDTH-1:0] data);
        while (!wr_ready[vc]) @(posedge wr_clk);
        // Drive #1 after last posedge — safely between clock edges
        #1;
        wr_valid     = '0;
        wr_valid[vc] = 1'b1;
        wr_vc_id     = VC_WIDTH'(vc);
        wr_data      = data;
        sb_push(vc, data);
        @(posedge wr_clk);
        // Deassert #1 after the sampling edge
        #1;
        wr_valid = '0;
        wr_vc_id = '0;
        wr_data  = '0;
    endtask

    // Wait until the scoreboard is empty for every VC set in 'vc_mask'.
    // Times out after 'timeout_cycles' rd_clk edges.
    task automatic wait_drain(input logic [NUM_VC-1:0] vc_mask,
                               input int timeout_cycles = 2000);
        int cnt;
        bit all_empty;
        cnt = 0;
        all_empty = 1'b0;
        while (!all_empty) begin
            @(posedge rd_clk);
            cnt = cnt + 1;
            all_empty = 1'b1;
            for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
                if (vc_mask[vc] && (sb_cnt[vc] > 0))
                    all_empty = 1'b0;
            end
            if (cnt >= timeout_cycles) begin
                $error("[TB] wait_drain timeout after %0d rd_clk cycles", timeout_cycles);
                sb_errors = sb_errors + 1;
                all_empty = 1'b1; // force exit
            end
        end
    endtask

    // Wait N wr_clk cycles
    task automatic wclk_delay(input int n);
        repeat (n) @(posedge wr_clk);
    endtask

    // Wait N rd_clk cycles
    task automatic rclk_delay(input int n);
        repeat (n) @(posedge rd_clk);
    endtask

    // =========================================================================
    // TC1: Basic per-VC write and read
    // =========================================================================
    task automatic run_tc1();
        $display("[TB] ===== TC1: Basic per-VC write & read =====");
        sb_clear();
        rd_ready = '1;
        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            for (int b = 0; b < 4; b = b + 1) begin
                write_flit(vc, DATA_WIDTH'(32'hA000_0000 | (vc << 8) | b));
            end
        end
        wait_drain('1, 2000);
        // Allow CDC pipeline to drain all residual credit grants before the
        // next TC's sb_clear() resets the per-VC credit counters.
        wclk_delay(32);
        $display("[TB] TC1 complete — %0d flits verified, errors=%0d",
                 sb_rd_count, sb_errors);
    endtask

    // =========================================================================
    // TC2: Credit Loop #1 — wr_credit_grant count equals flits consumed
    // =========================================================================
    task automatic run_tc2();
        $display("[TB] ===== TC2: Credit Loop #1 verification =====");
        sb_clear();
        rd_ready = '1;
        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            for (int b = 0; b < 6; b = b + 1) begin
                write_flit(vc, DATA_WIDTH'(32'hB000_0000 | (vc << 8) | b));
            end
        end
        wait_drain('1, 2000);
        // Allow CDC pipeline to flush all pending credit grants
        wclk_delay(32);

        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            if (credit_grant_cnt[vc] !== credit_rd_cnt[vc]) begin
                $error("[TC2] VC%0d credit mismatch: grants=%0d, reads=%0d",
                       vc, credit_grant_cnt[vc], credit_rd_cnt[vc]);
                sb_errors = sb_errors + 1;
            end else begin
                $display("[TC2] VC%0d OK — %0d credits returned",
                         vc, credit_grant_cnt[vc]);
            end
        end
    endtask

    // =========================================================================
    // TC3: Credit Loop #2 — rd_valid must not assert when rd_ready is low.
    // The read monitor detects violations and increments sb_errors.
    // =========================================================================
    task automatic run_tc3();
        $display("[TB] ===== TC3: Credit Loop #2 verification =====");
        sb_clear();
        rd_ready = '0; // block all receiver credits

        // Fill all VCs partway (using same #1-after-edge discipline)
        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            for (int b = 0; b < 3; b = b + 1) begin
                while (!wr_ready[vc]) @(posedge wr_clk);
                #1;
                wr_valid     = '0;
                wr_valid[vc] = 1'b1;
                wr_vc_id     = VC_WIDTH'(vc);
                wr_data      = DATA_WIDTH'(32'hC000_0000 | (vc << 8) | b);
                sb_push(vc, wr_data);
                @(posedge wr_clk);
                #1;
                wr_valid = '0;
            end
        end

        // Hold back-pressure for many rd_clk cycles; monitor catches violations
        rclk_delay(160);

        // Re-enable and drain
        rd_ready = '1;
        wait_drain('1, 2000);
        $display("[TB] TC3 complete — errors=%0d", sb_errors);
    endtask

    // =========================================================================
    // TC4: Full condition — fill VC0; verify wr_ready[0] deasserts, recovers.
    // =========================================================================
    task automatic run_tc4();
        $display("[TB] ===== TC4: Full condition =====");
        sb_clear();
        rd_ready = '0; // block reads so the FIFO fills up

        for (int b = 0; b < FIFO_DEPTH; b = b + 1) begin
            while (!wr_ready[0]) @(posedge wr_clk);
            #1;
            wr_valid    = '0;
            wr_valid[0] = 1'b1;
            wr_vc_id    = '0;
            wr_data     = DATA_WIDTH'(32'hD000_0000 | b);
            sb_push(0, wr_data);
            @(posedge wr_clk);
            #1;
            wr_valid = '0;
        end

        // Allow full flag to propagate through 2-FF CDC synchroniser
        wclk_delay(12);

        if (wr_ready[0]) begin
            $error("[TC4] FAIL: wr_ready[0] still asserted after filling VC0");
            sb_errors = sb_errors + 1;
        end else begin
            $display("[TC4] PASS: wr_ready[0] correctly deasserted");
        end

        // Drain VC0 only and check recovery
        rd_ready = 4'b0001;
        wait_drain(4'b0001, 2000);
        wclk_delay(20);

        if (!wr_ready[0]) begin
            $error("[TC4] FAIL: wr_ready[0] did not recover after draining");
            sb_errors = sb_errors + 1;
        end else begin
            $display("[TC4] PASS: wr_ready[0] recovered after drain");
        end
        rd_ready = '0;
    endtask

    // =========================================================================
    // TC5: Empty condition — rd_valid must not fire when all FIFOs are empty.
    // =========================================================================
    task automatic run_tc5();
        int snap_rd_count;
        $display("[TB] ===== TC5: Empty condition =====");

        // Reset to guarantee empty FIFOs
        apply_reset();
        sb_clear();
        snap_rd_count = sb_rd_count; // capture count before test

        rd_ready = '1; // receiver ready, but FIFOs are empty

        // Observe for 160 rd_clk cycles (any spurious valid caught by monitor)
        rclk_delay(160);

        if (sb_rd_count == snap_rd_count)
            $display("[TC5] PASS: rd_valid never asserted on empty FIFO");
        else begin
            $error("[TC5] FAIL: %0d spurious reads detected", sb_rd_count - snap_rd_count);
            sb_errors = sb_errors + 1;
        end
        rd_ready = '0;
    endtask

    // =========================================================================
    // TC6: Multi-VC simultaneous traffic
    // Interleaved writes to all VCs while the faster rd_clk drains them.
    // =========================================================================
    task automatic run_tc6();
        $display("[TB] ===== TC6: Multi-VC simultaneous traffic =====");
        sb_clear();
        rd_ready = '1;

        // Round-robin write across all VCs — stresses the round-robin arbiter
        for (int round = 0; round < FIFO_DEPTH; round = round + 1) begin
            for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
                write_flit(vc, DATA_WIDTH'(32'hE000_0000 | (vc << 8) | round));
            end
        end

        wait_drain('1, 8000);
        $display("[TB] TC6 complete — %0d flits verified, errors=%0d",
                 sb_rd_count, sb_errors);
    endtask

    // =========================================================================
    // TC7: CDC stress test — random back-pressure on read side
    // =========================================================================
    task automatic run_tc7();
        logic [7:0] lfsr;
        int tc7_writes;
        $display("[TB] ===== TC7: CDC stress test =====");
        sb_clear();
        rd_ready = '1;
        lfsr      = 8'hA5;
        tc7_writes = 0;

        // Interleave writes with pseudo-random back-pressure toggles.
        // Back-pressure is toggled on rd_clk, writes happen on wr_clk.
        for (int round = 0; round < 8; round = round + 1) begin
            for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
                for (int b = 0; b < 4; b = b + 1) begin
                    // Pseudo-random rd_ready toggle (LFSR: x8+x6+x5+x4+1)
                    @(posedge rd_clk);
                    // #1 ensures rd_ready change is past the sampling edge so the
                    // read monitor and rd_valid are consistent when checked.
                    #1;
                    lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
                    rd_ready = {4{1'b1}} & lfsr[NUM_VC-1:0];

                    write_flit(vc, DATA_WIDTH'(32'hF000_0000 |
                                               (round << 12) | (vc << 8) | b));
                    tc7_writes = tc7_writes + 1;
                end
            end
        end

        $display("[TC7] Writer done — %0d flits injected", tc7_writes);

        // Release all back-pressure and drain
        rd_ready = '1;
        wait_drain('1, 8000);
        $display("[TB] TC7 complete — %0d flits verified, errors=%0d",
                 sb_rd_count, sb_errors);
    endtask

    // =========================================================================
    // Initialisation
    // =========================================================================
    initial begin
        sb_errors   = 0;
        sb_rd_count = 0;
        wr_rst_n    = 1'b0;
        rd_rst_n    = 1'b0;
        wr_valid    = '0;
        wr_vc_id    = '0;
        wr_data     = '0;
        rd_ready    = '0;
        for (int vc = 0; vc < NUM_VC; vc = vc + 1) begin
            sb_wptr[vc]          = 0;
            sb_rptr[vc]          = 0;
            sb_cnt[vc]           = 0;
            credit_grant_cnt[vc] = 0;
            credit_rd_cnt[vc]    = 0;
        end
    end

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin : stimulus
        apply_reset();
        $display("[TB] Reset complete at t=%0t", $time);

        run_tc1();
        run_tc2();
        run_tc3();
        run_tc4();
        run_tc5();
        run_tc6();
        run_tc7();

        // Final settle
        wclk_delay(20);
        rclk_delay(20);

        if (sb_errors == 0)
            $display("[TB] *** ALL TESTS PASSED *** (%0d flits verified total)",
                     sb_rd_count);
        else
            $error("[TB] *** %0d ERROR(S) DETECTED ***", sb_errors);

        $finish;
    end

    // =========================================================================
    // Simulation timeout guard
    // =========================================================================
    initial begin
        #2_000_000; // 2 ms
        $fatal(1, "[TB] Simulation timeout — possible hang or deadlock");
    end

endmodule
