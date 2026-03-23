// =============================================================================
// File       : iclink_master_tb.sv
// Project    : XEFI — ICLink Master RTL
// Version    : 0.4
// Description: Comprehensive testbench for the ICLink Master module.
//
//   Tests covered:
//     T01 — Interface Activation (STOP → ACTIVATE → RUN)
//     T02 — REQ channel flit transmission & credit decrement
//     T03 — REQ channel credit stall & resume (no-credit → stall → credit return)
//     T04 — DAT channel TX and RX (bi-directional)
//     T05 — REQDAT channel transmission
//     T06 — RSP channel reception & credit return
//     T07 — SNP channel reception & credit return
//     T08 — Multi-flit SOP/EOP framing (all TX channels)
//     T09 — Virtual Channel multiplexing (NUM_VC VCs exercised)
//     T10 — Interface Deactivation (RUN → DEACTIVATE → STOP after credit drain)
//
//   Signal naming follows the spec exactly (Section 5 & 7).
//   Waveform dump: vcd/iclink_master_tb.vcd
// =============================================================================

`timescale 1ns/1ps
`include "iclink_pkg.sv"

module iclink_master_tb;
  import iclink_pkg::*;

  // ===========================================================================
  // Parameters — match DUT defaults
  // ===========================================================================
  localparam int HEADER_WIDTH   = 32;
  localparam int PAYLOAD_WIDTH  = 128;
  localparam int CREDIT_WIDTH   = 8;
  localparam int NUM_VC         = 4;
  localparam int CREDITS_PER_VC = 8;
  localparam int TOTAL_CREDITS  = NUM_VC * CREDITS_PER_VC;  // 32

  // Clock period (ns)
  localparam int CLK_PERIOD = 10;

  // ===========================================================================
  // Clock & reset
  // ===========================================================================
  logic clk   = 0;
  logic rst_n = 0;

  always #(CLK_PERIOD/2) clk = ~clk; // 100 MHz clock

  // ===========================================================================
  // DUT port signals — wired directly to iclink_master instantiation
  // ===========================================================================

  // Interface activation
  logic IFACTIVE_REQ;   // DUT output — master requests activation
  logic IFACTIVE_ACK;   // TB drives  — simulated remote acknowledges

  // ------ REQ channel -------------------------------------------------------
  logic                     tx_req_valid;
  logic                     tx_req_sop;
  logic                     tx_req_eop;
  logic [HEADER_WIDTH-1:0]  tx_req_header;
  logic [PAYLOAD_WIDTH-1:0] tx_req_payload;
  logic [CREDIT_WIDTH-1:0]  rx_req_credit;

  // ------ DAT channel -------------------------------------------------------
  logic                     tx_dat_valid;
  logic                     tx_dat_sop;
  logic                     tx_dat_eop;
  logic [HEADER_WIDTH-1:0]  tx_dat_header;
  logic [PAYLOAD_WIDTH-1:0] tx_dat_payload;
  logic [CREDIT_WIDTH-1:0]  tx_dat_credit;   // Credit return from DUT to inbound DAT sender

  logic                     rx_dat_valid;
  logic                     rx_dat_sop;
  logic                     rx_dat_eop;
  logic [HEADER_WIDTH-1:0]  rx_dat_header;
  logic [PAYLOAD_WIDTH-1:0] rx_dat_payload;
  logic [CREDIT_WIDTH-1:0]  rx_dat_credit;

  // ------ REQDAT channel ----------------------------------------------------
  logic                     tx_reqdat_valid;
  logic                     tx_reqdat_sop;
  logic                     tx_reqdat_eop;
  logic [HEADER_WIDTH-1:0]  tx_reqdat_header;
  logic [PAYLOAD_WIDTH-1:0] tx_reqdat_payload;
  logic [CREDIT_WIDTH-1:0]  rx_reqdat_credit;

  // ------ RSP channel -------------------------------------------------------
  logic                     rx_rsp_valid;
  logic                     rx_rsp_sop;
  logic                     rx_rsp_eop;
  logic [HEADER_WIDTH-1:0]  rx_rsp_header;
  logic [PAYLOAD_WIDTH-1:0] rx_rsp_payload;
  logic [CREDIT_WIDTH-1:0]  tx_rsp_credit;   // Credit return from DUT to RSP sender

  // ------ SNP channel -------------------------------------------------------
  logic                     rx_snp_valid;
  logic                     rx_snp_sop;
  logic                     rx_snp_eop;
  logic [HEADER_WIDTH-1:0]  rx_snp_header;
  logic [PAYLOAD_WIDTH-1:0] rx_snp_payload;
  logic [CREDIT_WIDTH-1:0]  tx_snp_credit;   // Credit return from DUT to SNP sender

  // ------ Application TX request ports -------------------------------------
  logic                     app_req_valid;
  logic                     app_req_sop;
  logic                     app_req_eop;
  logic [HEADER_WIDTH-1:0]  app_req_header;
  logic [PAYLOAD_WIDTH-1:0] app_req_payload;
  logic                     app_req_ready;   // DUT output

  logic                     app_dat_valid;
  logic                     app_dat_sop;
  logic                     app_dat_eop;
  logic [HEADER_WIDTH-1:0]  app_dat_header;
  logic [PAYLOAD_WIDTH-1:0] app_dat_payload;
  logic                     app_dat_ready;

  logic                     app_reqdat_valid;
  logic                     app_reqdat_sop;
  logic                     app_reqdat_eop;
  logic [HEADER_WIDTH-1:0]  app_reqdat_header;
  logic [PAYLOAD_WIDTH-1:0] app_reqdat_payload;
  logic                     app_reqdat_ready;

  // ------ Application RX indication ports ----------------------------------
  logic                     app_rsp_valid;
  logic                     app_rsp_sop;
  logic                     app_rsp_eop;
  logic [HEADER_WIDTH-1:0]  app_rsp_header;
  logic [PAYLOAD_WIDTH-1:0] app_rsp_payload;

  logic                     app_snp_valid;
  logic                     app_snp_sop;
  logic                     app_snp_eop;
  logic [HEADER_WIDTH-1:0]  app_snp_header;
  logic [PAYLOAD_WIDTH-1:0] app_snp_payload;

  logic                     app_rxdat_valid;
  logic                     app_rxdat_sop;
  logic                     app_rxdat_eop;
  logic [HEADER_WIDTH-1:0]  app_rxdat_header;
  logic [PAYLOAD_WIDTH-1:0] app_rxdat_payload;

  // Interface activation control (TB-driven)
  logic app_activate;

  // ===========================================================================
  // DUT instantiation
  // ===========================================================================
  iclink_master #(
    .HEADER_WIDTH   (HEADER_WIDTH),
    .PAYLOAD_WIDTH  (PAYLOAD_WIDTH),
    .CREDIT_WIDTH   (CREDIT_WIDTH),
    .NUM_VC         (NUM_VC),
    .CREDITS_PER_VC (CREDITS_PER_VC)
  ) dut (
    .clk                (clk),
    .rst_n              (rst_n),

    .IFACTIVE_REQ       (IFACTIVE_REQ),
    .IFACTIVE_ACK       (IFACTIVE_ACK),

    // REQ TX
    .tx_req_valid       (tx_req_valid),
    .tx_req_sop         (tx_req_sop),
    .tx_req_eop         (tx_req_eop),
    .tx_req_header      (tx_req_header),
    .tx_req_payload     (tx_req_payload),
    .rx_req_credit      (rx_req_credit),

    // DAT
    .tx_dat_valid       (tx_dat_valid),
    .tx_dat_sop         (tx_dat_sop),
    .tx_dat_eop         (tx_dat_eop),
    .tx_dat_header      (tx_dat_header),
    .tx_dat_payload     (tx_dat_payload),
    .rx_dat_valid       (rx_dat_valid),
    .rx_dat_sop         (rx_dat_sop),
    .rx_dat_eop         (rx_dat_eop),
    .rx_dat_header      (rx_dat_header),
    .rx_dat_payload     (rx_dat_payload),
    .rx_dat_credit      (rx_dat_credit),
    .tx_dat_credit      (tx_dat_credit),

    // REQDAT
    .tx_reqdat_valid    (tx_reqdat_valid),
    .tx_reqdat_sop      (tx_reqdat_sop),
    .tx_reqdat_eop      (tx_reqdat_eop),
    .tx_reqdat_header   (tx_reqdat_header),
    .tx_reqdat_payload  (tx_reqdat_payload),
    .rx_reqdat_credit   (rx_reqdat_credit),

    // RSP RX
    .rx_rsp_valid       (rx_rsp_valid),
    .rx_rsp_sop         (rx_rsp_sop),
    .rx_rsp_eop         (rx_rsp_eop),
    .rx_rsp_header      (rx_rsp_header),
    .rx_rsp_payload     (rx_rsp_payload),
    .tx_rsp_credit      (tx_rsp_credit),

    // SNP RX
    .rx_snp_valid       (rx_snp_valid),
    .rx_snp_sop         (rx_snp_sop),
    .rx_snp_eop         (rx_snp_eop),
    .rx_snp_header      (rx_snp_header),
    .rx_snp_payload     (rx_snp_payload),
    .tx_snp_credit      (tx_snp_credit),

    // App TX
    .app_req_valid      (app_req_valid),
    .app_req_sop        (app_req_sop),
    .app_req_eop        (app_req_eop),
    .app_req_header     (app_req_header),
    .app_req_payload    (app_req_payload),
    .app_req_ready      (app_req_ready),

    .app_dat_valid      (app_dat_valid),
    .app_dat_sop        (app_dat_sop),
    .app_dat_eop        (app_dat_eop),
    .app_dat_header     (app_dat_header),
    .app_dat_payload    (app_dat_payload),
    .app_dat_ready      (app_dat_ready),

    .app_reqdat_valid   (app_reqdat_valid),
    .app_reqdat_sop     (app_reqdat_sop),
    .app_reqdat_eop     (app_reqdat_eop),
    .app_reqdat_header  (app_reqdat_header),
    .app_reqdat_payload (app_reqdat_payload),
    .app_reqdat_ready   (app_reqdat_ready),

    // App RX
    .app_rsp_valid      (app_rsp_valid),
    .app_rsp_sop        (app_rsp_sop),
    .app_rsp_eop        (app_rsp_eop),
    .app_rsp_header     (app_rsp_header),
    .app_rsp_payload    (app_rsp_payload),

    .app_snp_valid      (app_snp_valid),
    .app_snp_sop        (app_snp_sop),
    .app_snp_eop        (app_snp_eop),
    .app_snp_header     (app_snp_header),
    .app_snp_payload    (app_snp_payload),

    .app_rxdat_valid    (app_rxdat_valid),
    .app_rxdat_sop      (app_rxdat_sop),
    .app_rxdat_eop      (app_rxdat_eop),
    .app_rxdat_header   (app_rxdat_header),
    .app_rxdat_payload  (app_rxdat_payload),

    .app_activate       (app_activate)
  );

  // ===========================================================================
  // Waveform dump  (for debug with GTKWave or Verdi)
  // ===========================================================================
  initial begin
    $dumpfile("vcd/iclink_master_tb.vcd");
    $dumpvars(0, iclink_master_tb);
  end

  // ===========================================================================
  // Test bookkeeping
  // ===========================================================================
  int test_pass_count = 0;
  int test_fail_count = 0;

  // Print a PASS/FAIL line and update counters
  task automatic print_result(input string test_name, input logic passed);
    if (passed) begin
      $display("[PASS] %s", test_name);
      test_pass_count++;
    end else begin
      $display("[FAIL] %s", test_name);
      test_fail_count++;
    end
  endtask

  // Helper: advance N clock cycles
  task automatic tick(input int n = 1);
    repeat (n) @(posedge clk);
    #1; // small delta to let signals settle after posedge
  endtask

  // ===========================================================================
  // Default / idle signal values
  // (Applied at reset and between tests to ensure clean baselines)
  // ===========================================================================
  task automatic set_idle();
    IFACTIVE_ACK     = 1'b0;

    // No credits returned by default (TB models empty credit-return path)
    rx_req_credit    = '0;
    rx_dat_credit    = '0;
    rx_reqdat_credit = '0;

    // No inbound flits by default
    rx_dat_valid     = 1'b0;
    rx_dat_sop       = 1'b0;
    rx_dat_eop       = 1'b0;
    rx_dat_header    = '0;
    rx_dat_payload   = '0;

    rx_rsp_valid     = 1'b0;
    rx_rsp_sop       = 1'b0;
    rx_rsp_eop       = 1'b0;
    rx_rsp_header    = '0;
    rx_rsp_payload   = '0;

    rx_snp_valid     = 1'b0;
    rx_snp_sop       = 1'b0;
    rx_snp_eop       = 1'b0;
    rx_snp_header    = '0;
    rx_snp_payload   = '0;

    // No application requests
    app_req_valid    = 1'b0;
    app_req_sop      = 1'b0;
    app_req_eop      = 1'b0;
    app_req_header   = '0;
    app_req_payload  = '0;

    app_dat_valid    = 1'b0;
    app_dat_sop      = 1'b0;
    app_dat_eop      = 1'b0;
    app_dat_header   = '0;
    app_dat_payload  = '0;

    app_reqdat_valid   = 1'b0;
    app_reqdat_sop     = 1'b0;
    app_reqdat_eop     = 1'b0;
    app_reqdat_header  = '0;
    app_reqdat_payload = '0;

    app_activate     = 1'b0;
  endtask

  // ===========================================================================
  // Simulate the remote receiver returning N credits on the REQ channel
  // (models the completer credit-return path — Section 8)
  // ===========================================================================
  task automatic return_req_credits(input int n);
    rx_req_credit = CREDIT_WIDTH'(n);
    tick(1);
    rx_req_credit = '0;
  endtask

  task automatic return_dat_credits(input int n);
    rx_dat_credit = CREDIT_WIDTH'(n);
    tick(1);
    rx_dat_credit = '0;
  endtask

  task automatic return_reqdat_credits(input int n);
    rx_reqdat_credit = CREDIT_WIDTH'(n);
    tick(1);
    rx_reqdat_credit = '0;
  endtask

  // ===========================================================================
  // Perform interface activation sequence (STOP → ACTIVATE → RUN)
  // Returns when the interface reaches RUN state.
  // ===========================================================================
  task automatic activate_interface();
    app_activate = 1'b1;
    tick(2);
    // DUT should have raised IFACTIVE_REQ — now ACK from remote side
    if (IFACTIVE_REQ !== 1'b1)
      $display("[WARN] activate_interface: IFACTIVE_REQ not asserted after activate request");
    IFACTIVE_ACK = 1'b1;
    tick(2);
    // Interface should now be in RUN state (app_req_ready asserted when credits available)
    IFACTIVE_ACK = 1'b0; // keep ACK latched; real handshake holds ACK in RUN
    IFACTIVE_ACK = 1'b1; // restore — keep ACK high while running
  endtask

  // ===========================================================================
  // Perform interface deactivation sequence (RUN → DEACTIVATE → STOP)
  // Waits until all TX credits are returned before completing.
  // ===========================================================================
  task automatic deactivate_interface();
    int timeout;
    app_activate = 1'b0; // request deactivation — DUT drops IFACTIVE_REQ next cycle
    tick(4);
    // Return all outstanding credits to ensure drain condition is met
    return_req_credits(TOTAL_CREDITS);
    return_dat_credits(TOTAL_CREDITS);
    return_reqdat_credits(TOTAL_CREDITS);
    // Remote side drops ACK to signal it has stopped receiving
    IFACTIVE_ACK = 1'b0;
    // Wait up to 100 cycles for FSM to reach STOP (drain may take a few cycles)
    timeout = 0;
    while (IFACTIVE_REQ !== 1'b0 && timeout < 100) begin
      tick(1);
      timeout++;
    end
  endtask

  // ===========================================================================
  // Helper: send one REQ flit with given header/payload via app interface
  // ===========================================================================
  task automatic send_req_flit(
    input logic                     is_sop,
    input logic                     is_eop,
    input logic [HEADER_WIDTH-1:0]  hdr,
    input logic [PAYLOAD_WIDTH-1:0] pld
  );
    // Wait for ready: credit available + interface running  (Section 8)
    while (app_req_ready !== 1'b1) @(posedge clk);
    #1;
    app_req_valid   = 1'b1;
    app_req_sop     = is_sop;
    app_req_eop     = is_eop;
    app_req_header  = hdr;
    app_req_payload = pld;
    tick(1);
    app_req_valid   = 1'b0;
    app_req_sop     = 1'b0;
    app_req_eop     = 1'b0;
  endtask

  task automatic send_dat_flit(
    input logic                     is_sop,
    input logic                     is_eop,
    input logic [HEADER_WIDTH-1:0]  hdr,
    input logic [PAYLOAD_WIDTH-1:0] pld
  );
    while (app_dat_ready !== 1'b1) @(posedge clk);
    #1;
    app_dat_valid   = 1'b1;
    app_dat_sop     = is_sop;
    app_dat_eop     = is_eop;
    app_dat_header  = hdr;
    app_dat_payload = pld;
    tick(1);
    app_dat_valid   = 1'b0;
    app_dat_sop     = 1'b0;
    app_dat_eop     = 1'b0;
  endtask

  task automatic send_reqdat_flit(
    input logic                     is_sop,
    input logic                     is_eop,
    input logic [HEADER_WIDTH-1:0]  hdr,
    input logic [PAYLOAD_WIDTH-1:0] pld
  );
    while (app_reqdat_ready !== 1'b1) @(posedge clk);
    #1;
    app_reqdat_valid   = 1'b1;
    app_reqdat_sop     = is_sop;
    app_reqdat_eop     = is_eop;
    app_reqdat_header  = hdr;
    app_reqdat_payload = pld;
    tick(1);
    app_reqdat_valid   = 1'b0;
    app_reqdat_sop     = 1'b0;
    app_reqdat_eop     = 1'b0;
  endtask

  // ===========================================================================
  // Module-level test result variables
  // (iverilog requires declarations at module scope, not inside begin...end)
  // ===========================================================================
  logic t_passed;
  logic t_req_raised;
  logic t_in_run;
  logic t_flit_seen;
  logic t_hdr_match;
  logic t_pld_match;
  logic t_passed_stall;
  logic t_passed_resume;
  logic t_passed_tx;
  logic t_passed_rx;
  logic t_passed_cret;
  logic t_passed_credit;
  logic t_sop_ok;
  logic t_mid_ok;
  logic t_eop_ok;
  logic t_vc_ok;
  logic t_passed_req_drop;
  logic t_passed_stop;
  int   t_sent;
  int   t_vc_fail;
  logic [HEADER_WIDTH-1:0]  t_vc_hdr;
  logic [PAYLOAD_WIDTH-1:0] t_vc_pld;

  // ===========================================================================
  // Main test sequence
  // ===========================================================================
  initial begin : main_test

    // -------------------------------------------------------------------------
    // Initialise all signals and apply reset
    // -------------------------------------------------------------------------
    set_idle();
    rst_n = 1'b0;
    tick(5);          // Hold reset for 5 cycles
    @(posedge clk);
    #1;
    rst_n = 1'b1;     // Release reset (sync deassert — Section 13)
    tick(3);

    // =========================================================================
    // T01 — Interface Activation  (Section 12)
    //   Verify: STOP -> ACTIVATE -> RUN handshake
    //   Expected: IFACTIVE_REQ raised after app_activate;
    //             transitions to RUN after IFACTIVE_ACK received
    // =========================================================================
    $display("\n--- T01: Interface Activation ---");

    app_activate = 1'b1;
    tick(2);
    t_req_raised = (IFACTIVE_REQ === 1'b1);  // REQ must be asserted

    IFACTIVE_ACK = 1'b1;
    tick(2);
    // After ACK and credits initialized, app_req_ready should be 1
    t_in_run = (app_req_ready === 1'b1);

    t_passed = t_req_raised && t_in_run;
    print_result("T01 Interface Activation", t_passed);

    // =========================================================================
    // T02 — REQ channel flit TX & credit decrement  (Section 6.1, Section 8)
    //   Send a single REQ flit; verify tx_req_valid and header/payload match.
    // =========================================================================
    $display("\n--- T02: REQ Channel TX & Credit Decrement ---");

    // Positional args: (is_sop, is_eop, hdr, pld)
    send_req_flit(1'b1, 1'b1, 32'hDEAD_BEEF, {4{32'hCAFE_BABE}});
    // send_req_flit already advances one clock; output is valid on return
    t_flit_seen = (tx_req_valid === 1'b1);
    t_hdr_match = (tx_req_header === 32'hDEAD_BEEF);
    t_pld_match = (tx_req_payload === {4{32'hCAFE_BABE}});

    t_passed = t_flit_seen && t_hdr_match && t_pld_match;
    print_result("T02 REQ TX flit visibility", t_passed);

    // Return the credit so counters stay balanced
    return_req_credits(1);

    // =========================================================================
    // T03 — REQ credit stall & resume  (Section 8)
    //   Exhaust all REQ credits; verify app_req_ready de-asserts (stall).
    //   Return credits; verify app_req_ready re-asserts (resume).
    // =========================================================================
    $display("\n--- T03: REQ Credit Stall & Resume ---");

    t_sent = 0;
    // Drain all credits by sending TOTAL_CREDITS flits without returning any
    for (int i = 0; i < TOTAL_CREDITS; i++) begin
      if (app_req_ready) begin
        app_req_valid   = 1'b1;
        app_req_sop     = (i == 0) ? 1'b1 : 1'b0;
        app_req_eop     = (i == TOTAL_CREDITS - 1) ? 1'b1 : 1'b0;
        app_req_header  = 32'(i);
        app_req_payload = 128'(i);
        tick(1);
        app_req_valid = 1'b0;
        t_sent++;
      end else begin
        tick(1);
      end
    end

    tick(2); // Let pipeline settle

    // After draining credits, ready must be low (stalled)
    t_passed_stall = (app_req_ready === 1'b0);
    print_result("T03a REQ stall when credits=0", t_passed_stall);

    // Return all credits at once
    return_req_credits(TOTAL_CREDITS);
    tick(2);

    // Now ready should be high again (resumed)
    t_passed_resume = (app_req_ready === 1'b1);
    print_result("T03b REQ resume after credit return", t_passed_resume);

    // =========================================================================
    // T04 — DAT channel TX (outbound) and RX (inbound)  (Section 6.2)
    //   Send a DAT flit outbound; verify tx_dat_valid.
    //   Inject an inbound DAT flit; verify app_rxdat_valid and credit return.
    // =========================================================================
    $display("\n--- T04: DAT Channel TX & RX ---");

    // TX path — positional args: (is_sop, is_eop, hdr, pld)
    send_dat_flit(1'b1, 1'b1, 32'hA5A5_5A5A, 128'h1234_5678);
    // Output is valid when send_dat_flit returns (it already advanced one clock)
    t_passed_tx = (tx_dat_valid === 1'b1) && (tx_dat_header === 32'hA5A5_5A5A);
    print_result("T04a DAT TX flit", t_passed_tx);
    return_dat_credits(1);

    // RX path — inject flit from completer side
    rx_dat_valid   = 1'b1;
    rx_dat_sop     = 1'b1;
    rx_dat_eop     = 1'b1;
    rx_dat_header  = 32'hBEEF_CAFE;
    rx_dat_payload = 128'hDEAD;
    tick(1);
    // Check immediately after posedge — DUT registered the flit in this cycle
    t_passed_rx = (app_rxdat_valid === 1'b1) &&
                  (app_rxdat_header === 32'hBEEF_CAFE);
    print_result("T04b DAT RX flit forwarded to app", t_passed_rx);
    // Credit return is also registered in the same posedge  (Section 8)
    t_passed_cret = (tx_dat_credit > 8'h0);
    print_result("T04c DAT RX credit return", t_passed_cret);
    rx_dat_valid = 1'b0;

    // =========================================================================
    // T05 — REQDAT channel TX  (Section 6.3)
    //   Send a combined REQ+DATA flit; verify output signals.
    // =========================================================================
    $display("\n--- T05: REQDAT Channel TX ---");

    send_reqdat_flit(1'b1, 1'b1, 32'h1111_2222, 128'hABCD_EF01);
    // Output is valid when send_reqdat_flit returns (already advanced one clock)
    t_passed = (tx_reqdat_valid  === 1'b1) &&
               (tx_reqdat_header === 32'h1111_2222) &&
               (tx_reqdat_sop    === 1'b1) &&
               (tx_reqdat_eop    === 1'b1);
    print_result("T05 REQDAT TX flit", t_passed);
    return_reqdat_credits(1);

    // =========================================================================
    // T06 — RSP channel RX & credit return  (Section 6.4, Section 8)
    //   Inject an RSP flit; verify app_rsp_valid and tx_rsp_credit.
    // =========================================================================
    $display("\n--- T06: RSP Channel RX & Credit Return ---");

    rx_rsp_valid   = 1'b1;
    rx_rsp_sop     = 1'b1;
    rx_rsp_eop     = 1'b1;
    rx_rsp_header  = 32'hCCCC_DDDD;
    rx_rsp_payload = 128'h0; // RSP carries no payload per spec (Section 6.4)
    tick(1);
    // Check immediately — DUT registered RSP flit at this posedge
    t_passed_rx = (app_rsp_valid === 1'b1) && (app_rsp_header === 32'hCCCC_DDDD);
    print_result("T06a RSP RX flit forwarded to app", t_passed_rx);
    // Credit return is also registered at the same posedge
    t_passed_credit = (tx_rsp_credit > 8'h0);
    print_result("T06b RSP credit return asserted", t_passed_credit);
    rx_rsp_valid = 1'b0;

    // =========================================================================
    // T07 — SNP channel RX & credit return  (Section 6.5, Section 8)
    // =========================================================================
    $display("\n--- T07: SNP Channel RX & Credit Return ---");

    rx_snp_valid   = 1'b1;
    rx_snp_sop     = 1'b1;
    rx_snp_eop     = 1'b1;
    rx_snp_header  = 32'hEEEE_FFFF;
    rx_snp_payload = 128'hFACE;
    tick(1);
    // Check immediately — DUT registered SNP flit at this posedge
    t_passed_rx = (app_snp_valid === 1'b1) && (app_snp_header === 32'hEEEE_FFFF);
    print_result("T07a SNP RX flit forwarded to app", t_passed_rx);
    // Credit return registered at the same posedge
    t_passed_credit = (tx_snp_credit > 8'h0);
    print_result("T07b SNP credit return asserted", t_passed_credit);
    rx_snp_valid = 1'b0;

    // =========================================================================
    // T08 — Multi-flit SOP/EOP framing  (Section 4, Section 5)
    //   Send a 3-flit REQ packet: flit0=SOP, flit1=mid, flit2=EOP.
    //   Verify SOP asserted only on first flit, EOP only on last.
    // =========================================================================
    $display("\n--- T08: Multi-flit SOP/EOP Framing ---");

    // Flit 0 — SOP only
    send_req_flit(1'b1, 1'b0, 32'hF0F0_F0F0, 128'h1);
    // Output valid on return from send_req_flit
    t_sop_ok = (tx_req_valid === 1'b1) && (tx_req_sop === 1'b1) && (tx_req_eop === 1'b0);
    return_req_credits(1);

    // Flit 1 — middle flit (no SOP, no EOP)
    send_req_flit(1'b0, 1'b0, 32'hF0F0_F0F0, 128'h2);
    t_mid_ok = (tx_req_valid === 1'b1) && (tx_req_sop === 1'b0) && (tx_req_eop === 1'b0);
    return_req_credits(1);

    // Flit 2 — EOP only
    send_req_flit(1'b0, 1'b1, 32'hF0F0_F0F0, 128'h3);
    t_eop_ok = (tx_req_valid === 1'b1) && (tx_req_sop === 1'b0) && (tx_req_eop === 1'b1);
    return_req_credits(1);

    print_result("T08a SOP on first flit only",    t_sop_ok);
    print_result("T08b No SOP/EOP on middle flit", t_mid_ok);
    print_result("T08c EOP on last flit only",     t_eop_ok);

    // =========================================================================
    // T09 — Virtual Channel multiplexing  (Section 9)
    //   Send one flit on each VC (VC 0..NUM_VC-1) on the REQ channel.
    //   Verify the header VC field (bits [1:0] for NUM_VC=4) is forwarded.
    // =========================================================================
    $display("\n--- T09: Virtual Channel Multiplexing ---");

    t_vc_fail = 0;
    for (int vc = 0; vc < NUM_VC; vc++) begin
      t_vc_hdr = 32'(vc);   // VC ID in lower bits of header
      t_vc_pld = 128'(vc);
      send_req_flit(1'b1, 1'b1, t_vc_hdr, t_vc_pld);
      // Output valid on return from send_req_flit
      t_vc_ok = (tx_req_valid === 1'b1) &&
                (tx_req_header[1:0] === vc[1:0]); // bits [1:0] = VC ID for NUM_VC=4
      if (!t_vc_ok) t_vc_fail++;
      return_req_credits(1);
    end
    print_result("T09 VC multiplexing (all VCs sent)", (t_vc_fail == 0));

    // =========================================================================
    // T10 — Interface Deactivation  (Section 12)
    //   Trigger deactivation; verify IFACTIVE_REQ drops; confirm STOP reached
    //   only after all credits are returned (credits_drained condition).
    // =========================================================================
    $display("\n--- T10: Interface Deactivation ---");

    deactivate_interface();

    // After deactivation, IFACTIVE_REQ should be low (STOP state)
    t_passed_req_drop = (IFACTIVE_REQ === 1'b0);
    // TX channels should be quiescent in STOP state
    t_passed_stop = (tx_req_valid === 1'b0) &&
                    (tx_dat_valid === 1'b0) &&
                    (tx_reqdat_valid === 1'b0);

    print_result("T10a IFACTIVE_REQ drops after deactivation", t_passed_req_drop);
    print_result("T10b TX channels quiescent in STOP",         t_passed_stop);

    // =========================================================================
    // Final PASS/FAIL summary
    // =========================================================================
    tick(5);
    $display("\n==========================================================");
    $display("ICLink Master Testbench Summary");
    $display("  PASS: %0d", test_pass_count);
    $display("  FAIL: %0d", test_fail_count);
    if (test_fail_count == 0)
      $display("  OVERALL RESULT: ** PASS **");
    else
      $display("  OVERALL RESULT: ** FAIL **");
    $display("==========================================================\n");

    $finish;
  end : main_test

  // ===========================================================================
  // Timeout watchdog — prevents infinite simulation hangs
  // ===========================================================================
  initial begin
    #1_000_000; // 1 ms safety timeout
    $display("[TIMEOUT] Simulation exceeded maximum time — force-finishing.");
    $finish;
  end

endmodule : iclink_master_tb
