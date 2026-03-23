// =============================================================================
// File       : iclink_master.sv
// Project    : XEFI — ICLink Master RTL
// Version    : 0.4
// Description: Intel Chassis Link (ICLink) Master module.
//
//   Implements all five ICLink channel types as defined in ICLink Spec v0.4:
//     • REQ    — Request channel  (TX: Requester → Completer)
//     • DAT    — Data channel     (TX outbound and RX inbound, bi-directional)
//     • REQDAT — Request+Data     (TX: Requester → Completer)
//     • RSP    — Response channel (RX: Completer → Requester)
//     • SNP    — Snoop channel    (RX: Completer → Requester)
//
//   Key features:
//     • Credit-based flow control with per-channel/per-VC counters (Section 8)
//     • Virtual Channel (VC) support with shared credit pool (Section 9)
//     • Interface Activation/Deactivation FSM: STOP → ACTIVATE → RUN →
//       DEACTIVATE → STOP using IFACTIVE_REQ / IFACTIVE_ACK (Section 12)
//     • Async-assert / sync-deassert reset (Section 13)
//     • Fully parameterizable: HEADER_WIDTH, PAYLOAD_WIDTH, NUM_VC,
//       CREDITS_PER_VC, CREDIT_WIDTH
//
//   Signal naming follows the ICLink spec exactly:
//     TX channels : tx_req_*, tx_dat_*, tx_reqdat_*
//     RX channels : rx_rsp_*, rx_snp_*, rx_dat_*
//     Flow control: *_valid, *_credit, *_sop, *_eop
//     Route info  : *_header
//     Payload     : *_payload
//     Interface   : IFACTIVE_REQ, IFACTIVE_ACK
// =============================================================================

`include "iclink_pkg.sv"

module iclink_master
  import iclink_pkg::*;
#(
  // Width of routing/VC header in bits (Section 5)
  parameter int HEADER_WIDTH   = iclink_pkg::HEADER_WIDTH,
  // Width of the flit payload in bits (Section 4)
  parameter int PAYLOAD_WIDTH  = iclink_pkg::PAYLOAD_WIDTH,
  // Width of each credit counter — supports up to 2^CREDIT_WIDTH credits (Section 8)
  parameter int CREDIT_WIDTH   = iclink_pkg::CREDIT_WIDTH,
  // Number of Virtual Channels per logical channel (Section 9)
  parameter int NUM_VC         = iclink_pkg::NUM_VC,
  // Initial credits allocated to each VC at reset (Section 8)
  parameter int CREDITS_PER_VC = iclink_pkg::CREDITS_PER_VC
) (
  // ===========================================================================
  // Global signals  (Section 13 — Reset, Clocking & CDC)
  // ===========================================================================
  input  logic clk,    // System clock — all synchronous logic is clocked here
  input  logic rst_n,  // Active-low reset: async assert, sync deassert

  // ===========================================================================
  // Interface Activation / Deactivation handshake  (Section 12)
  //   IFACTIVE_REQ : Master requests interface activation/deactivation
  //   IFACTIVE_ACK : Slave acknowledges the request
  //   Two-signal handshake moves the interface through:
  //     STOP → ACTIVATE → RUN → DEACTIVATE → STOP
  // ===========================================================================
  output logic IFACTIVE_REQ, // Master drives: '1' = request to enter RUN state
  input  logic IFACTIVE_ACK, // Slave  drives: '1' = transition acknowledged

  // ===========================================================================
  // REQ Channel — Request  (Section 6.1)
  //   Direction: Requester (this master) → Completer
  //   Purpose  : Carries Read/Write command flits
  // ===========================================================================

  // TX — Outbound REQ flits sent by this master
  output logic                     tx_req_valid,    // '1' when a valid REQ flit is present on the bus
  output logic                     tx_req_sop,      // Start-Of-Packet marker — first flit of a REQ packet
  output logic                     tx_req_eop,      // End-Of-Packet marker   — last  flit of a REQ packet
  output logic [HEADER_WIDTH-1:0]  tx_req_header,   // Routing + VC header for the REQ flit  (Section 5)
  output logic [PAYLOAD_WIDTH-1:0] tx_req_payload,  // Command payload of the REQ flit

  // RX — Credit return from the downstream REQ receiver  (Section 8)
  input  logic [CREDIT_WIDTH-1:0]  rx_req_credit,   // Credits returned by the completer for REQ channel

  // ===========================================================================
  // DAT Channel — Data  (Section 6.2)
  //   Direction: Bi-directional (TX for outbound write data; RX for read data)
  // ===========================================================================

  // TX — Outbound DAT flits (write data from master)
  output logic                     tx_dat_valid,    // '1' when a valid outbound DAT flit is present
  output logic                     tx_dat_sop,      // SOP marker for outbound DAT packet
  output logic                     tx_dat_eop,      // EOP marker for outbound DAT packet
  output logic [HEADER_WIDTH-1:0]  tx_dat_header,   // Header for outbound DAT flit
  output logic [PAYLOAD_WIDTH-1:0] tx_dat_payload,  // Write-data payload of outbound DAT flit

  // RX — Inbound DAT flits (read data returning to master)
  input  logic                     rx_dat_valid,    // '1' when a valid inbound DAT flit arrives
  input  logic                     rx_dat_sop,      // SOP marker for inbound DAT packet
  input  logic                     rx_dat_eop,      // EOP marker for inbound DAT packet
  input  logic [HEADER_WIDTH-1:0]  rx_dat_header,   // Header of inbound DAT flit
  input  logic [PAYLOAD_WIDTH-1:0] rx_dat_payload,  // Read-data payload of inbound DAT flit

  // Credit exchange for DAT channel
  input  logic [CREDIT_WIDTH-1:0]  rx_dat_credit,   // Credits returned by receiver for outbound DAT
  output logic [CREDIT_WIDTH-1:0]  tx_dat_credit,   // Credits returned by this master to inbound DAT sender

  // ===========================================================================
  // REQDAT Channel — Request+Data  (Section 6.3)
  //   Direction: Requester (this master) → Completer
  //   Purpose  : Combined write command + data in a single channel
  // ===========================================================================

  // TX — Outbound REQDAT flits
  output logic                     tx_reqdat_valid,   // '1' when a valid REQDAT flit is on the bus
  output logic                     tx_reqdat_sop,     // SOP marker for REQDAT packet
  output logic                     tx_reqdat_eop,     // EOP marker for REQDAT packet
  output logic [HEADER_WIDTH-1:0]  tx_reqdat_header,  // Header for REQDAT flit
  output logic [PAYLOAD_WIDTH-1:0] tx_reqdat_payload, // Combined cmd+data payload for REQDAT flit

  // RX — Credit return from downstream REQDAT receiver
  input  logic [CREDIT_WIDTH-1:0]  rx_reqdat_credit,  // Credits returned by completer for REQDAT channel

  // ===========================================================================
  // RSP Channel — Response  (Section 6.4)
  //   Direction: Completer → Requester (this master receives responses)
  //   Purpose  : No-payload acknowledgement/completion flits
  // ===========================================================================

  // RX — Inbound RSP flits arriving at this master
  input  logic                     rx_rsp_valid,    // '1' when a valid RSP flit arrives
  input  logic                     rx_rsp_sop,      // SOP marker for inbound RSP packet
  input  logic                     rx_rsp_eop,      // EOP marker for inbound RSP packet
  input  logic [HEADER_WIDTH-1:0]  rx_rsp_header,   // Header of inbound RSP flit
  input  logic [PAYLOAD_WIDTH-1:0] rx_rsp_payload,  // Payload field (spec: RSP is no-payload; reserved)

  // TX — Credit return this master sends back to the RSP sender  (Section 8)
  output logic [CREDIT_WIDTH-1:0]  tx_rsp_credit,   // Credits returned to the RSP channel sender

  // ===========================================================================
  // SNP Channel — Snoop  (Section 6.5)
  //   Direction: Completer → Requester (this master receives snoop requests)
  //   Purpose  : Coherency traffic generated by the completer
  // ===========================================================================

  // RX — Inbound SNP flits
  input  logic                     rx_snp_valid,    // '1' when a valid SNP flit arrives
  input  logic                     rx_snp_sop,      // SOP marker for inbound SNP packet
  input  logic                     rx_snp_eop,      // EOP marker for inbound SNP packet
  input  logic [HEADER_WIDTH-1:0]  rx_snp_header,   // Header of inbound SNP flit
  input  logic [PAYLOAD_WIDTH-1:0] rx_snp_payload,  // Payload of inbound SNP flit

  // TX — Credit return this master sends back to the SNP sender
  output logic [CREDIT_WIDTH-1:0]  tx_snp_credit,   // Credits returned to the SNP channel sender

  // ===========================================================================
  // Application-side (upper-layer) transmit request ports
  //   These allow the layer above ICLink to inject flits into TX channels.
  // ===========================================================================

  // REQ send request
  input  logic                     app_req_valid,    // Upper layer asserts to request REQ flit send
  input  logic                     app_req_sop,      // SOP indicator provided by upper layer
  input  logic                     app_req_eop,      // EOP indicator provided by upper layer
  input  logic [HEADER_WIDTH-1:0]  app_req_header,   // Header provided by upper layer for REQ
  input  logic [PAYLOAD_WIDTH-1:0] app_req_payload,  // Payload provided by upper layer for REQ
  output logic                     app_req_ready,    // Master asserts when credits available to send REQ

  // DAT (TX) send request
  input  logic                     app_dat_valid,    // Upper layer asserts to request DAT flit send
  input  logic                     app_dat_sop,
  input  logic                     app_dat_eop,
  input  logic [HEADER_WIDTH-1:0]  app_dat_header,
  input  logic [PAYLOAD_WIDTH-1:0] app_dat_payload,
  output logic                     app_dat_ready,    // Master asserts when credits available to send DAT

  // REQDAT send request
  input  logic                     app_reqdat_valid,  // Upper layer asserts to request REQDAT flit send
  input  logic                     app_reqdat_sop,
  input  logic                     app_reqdat_eop,
  input  logic [HEADER_WIDTH-1:0]  app_reqdat_header,
  input  logic [PAYLOAD_WIDTH-1:0] app_reqdat_payload,
  output logic                     app_reqdat_ready,  // Master asserts when credits available to send REQDAT

  // ===========================================================================
  // Application-side receive indication ports
  //   Passes inbound flits (RSP, SNP, DAT-RX) up to the upper layer.
  // ===========================================================================
  output logic                     app_rsp_valid,    // Inbound RSP flit forwarded to upper layer
  output logic                     app_rsp_sop,
  output logic                     app_rsp_eop,
  output logic [HEADER_WIDTH-1:0]  app_rsp_header,
  output logic [PAYLOAD_WIDTH-1:0] app_rsp_payload,

  output logic                     app_snp_valid,    // Inbound SNP flit forwarded to upper layer
  output logic                     app_snp_sop,
  output logic                     app_snp_eop,
  output logic [HEADER_WIDTH-1:0]  app_snp_header,
  output logic [PAYLOAD_WIDTH-1:0] app_snp_payload,

  output logic                     app_rxdat_valid,  // Inbound DAT flit forwarded to upper layer
  output logic                     app_rxdat_sop,
  output logic                     app_rxdat_eop,
  output logic [HEADER_WIDTH-1:0]  app_rxdat_header,
  output logic [PAYLOAD_WIDTH-1:0] app_rxdat_payload,

  // ===========================================================================
  // Interface activation control (driven by application / power manager)
  // ===========================================================================
  input  logic                     app_activate    // Assert to request interface activation (STOP→RUN)
                                                   // De-assert to request graceful deactivation (RUN→STOP)
);

  // ===========================================================================
  // Local type / parameter aliases
  // ===========================================================================

  // Total credits initialised per channel = NUM_VC × CREDITS_PER_VC
  localparam int TOTAL_CREDITS = NUM_VC * CREDITS_PER_VC;

  // ===========================================================================
  // Interface Activation FSM  (Section 12)
  // ---------------------------------------------------------------------------
  //   STOP       : Interface quiescent; IFACTIVE_REQ = 0
  //   ACTIVATE   : Master has raised IFACTIVE_REQ; waiting for IFACTIVE_ACK = 1
  //   RUN        : Both REQ and ACK = 1; traffic flows normally
  //   DEACTIVATE : Master de-asserted IFACTIVE_REQ; draining; waits for ACK = 0
  //                All credit counters must equal TOTAL_CREDITS before transition
  //                back to STOP (ensures all in-flight flits are complete).
  // ===========================================================================

  if_state_e if_state_q, if_state_d; // Current / next state

  // Registered IFACTIVE_REQ output (no combinational paths to outputs)
  logic ifactive_req_q;

  // Forward declarations for drain signals (driven in credit counter blocks)
  logic credit_drained_req;
  logic credit_drained_dat;
  logic credit_drained_reqdat;

  // Credit-drain check: interface may only enter STOP when all TX credit pools
  // are fully replenished (i.e., no flits outstanding).  (Section 12)
  logic credits_drained;
  // Combined drain: all TX channels fully replenished
  assign credits_drained = credit_drained_req & credit_drained_dat & credit_drained_reqdat;

  // FSM next-state logic
  always_comb begin : proc_if_fsm_ns
    if_state_d    = if_state_q;
    case (if_state_q)

      IF_STOP : begin
        // Transition to ACTIVATE when application requests activation
        if (app_activate)
          if_state_d = IF_ACTIVATE;
      end

      IF_ACTIVATE : begin
        // Stay in ACTIVATE until remote side acknowledges with IFACTIVE_ACK
        if (IFACTIVE_ACK)
          if_state_d = IF_RUN;
        // If activation is cancelled before ACK, return to STOP
        if (!app_activate)
          if_state_d = IF_STOP;
      end

      IF_RUN : begin
        // Transition to DEACTIVATE when application withdraws activation request
        if (!app_activate)
          if_state_d = IF_DEACTIVATE;
      end

      IF_DEACTIVATE : begin
        // Return to STOP only when remote de-asserts ACK AND all credits drained
        if (!IFACTIVE_ACK && credits_drained)
          if_state_d = IF_STOP;
      end

      default : if_state_d = IF_STOP;
    endcase
  end

  // FSM state register — async assert, sync deassert reset  (Section 13)
  always_ff @(posedge clk or negedge rst_n) begin : proc_if_fsm_ff
    if (!rst_n) begin
      if_state_q    <= IF_STOP;
      ifactive_req_q <= 1'b0;
    end else begin
      if_state_q    <= if_state_d;
      // IFACTIVE_REQ is high while requesting activation or while running
      ifactive_req_q <= (if_state_d == IF_ACTIVATE) || (if_state_d == IF_RUN);
    end
  end

  // Drive registered IFACTIVE_REQ to output (no combinational path — Section 8)
  assign IFACTIVE_REQ = ifactive_req_q;

  // Convenience: interface is in the RUN state
  logic if_running;
  assign if_running = (if_state_q == IF_RUN);

  // ===========================================================================
  // REQ Channel TX — Credit counter  (Section 8)
  // ---------------------------------------------------------------------------
  //   • Initialised to TOTAL_CREDITS at reset.
  //   • Decremented by 1 each cycle a flit is transmitted (tx_req_valid = 1).
  //   • Incremented by rx_req_credit each cycle credits are returned.
  //   • Transmission is gated (app_req_ready = 0) when counter == 0.
  //   • No combinational feedback from credit to valid (Section 8 requirement).
  // ===========================================================================

  logic [CREDIT_WIDTH-1:0] req_credit_q; // Outstanding credits for REQ channel

  always_ff @(posedge clk or negedge rst_n) begin : proc_req_credit
    if (!rst_n) begin
      req_credit_q <= CREDIT_WIDTH'(TOTAL_CREDITS);
    end else begin
      // Atomic: decrement on send, add returned credits in same cycle
      unique case ({tx_req_valid, |rx_req_credit})
        2'b10 : req_credit_q <= req_credit_q - 1'b1;           // Send only
        2'b01 : req_credit_q <= req_credit_q + rx_req_credit;  // Return only
        2'b11 : req_credit_q <= req_credit_q - 1'b1 + rx_req_credit; // Both
        default: ;                                               // No change
      endcase
    end
  end

  // Drain indicator: all REQ credits returned (no flits in flight)
  assign credit_drained_req = (req_credit_q == CREDIT_WIDTH'(TOTAL_CREDITS));

  // Ready to accept a new REQ flit from application
  assign app_req_ready = if_running && (req_credit_q > '0);

  // ===========================================================================
  // REQ Channel TX — Output datapath
  // ---------------------------------------------------------------------------
  //   Registered outputs avoid glitches on the link and break any combinational
  //   loop between credit and valid (Section 8).
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : proc_req_tx
    if (!rst_n) begin
      tx_req_valid   <= 1'b0;
      tx_req_sop     <= 1'b0;
      tx_req_eop     <= 1'b0;
      tx_req_header  <= '0;
      tx_req_payload <= '0;
    end else if (app_req_ready && app_req_valid) begin
      // Forward flit from application to link when credits are available
      tx_req_valid   <= 1'b1;
      tx_req_sop     <= app_req_sop;
      tx_req_eop     <= app_req_eop;
      tx_req_header  <= app_req_header;
      tx_req_payload <= app_req_payload;
    end else begin
      tx_req_valid   <= 1'b0;
      tx_req_sop     <= 1'b0;
      tx_req_eop     <= 1'b0;
      tx_req_header  <= '0;
      tx_req_payload <= '0;
    end
  end

  // ===========================================================================
  // DAT Channel TX — Credit counter  (Section 8)
  // ===========================================================================

  logic [CREDIT_WIDTH-1:0] dat_tx_credit_q; // Outstanding credits for outbound DAT

  always_ff @(posedge clk or negedge rst_n) begin : proc_dat_tx_credit
    if (!rst_n) begin
      dat_tx_credit_q <= CREDIT_WIDTH'(TOTAL_CREDITS);
    end else begin
      unique case ({tx_dat_valid, |rx_dat_credit})
        2'b10 : dat_tx_credit_q <= dat_tx_credit_q - 1'b1;
        2'b01 : dat_tx_credit_q <= dat_tx_credit_q + rx_dat_credit;
        2'b11 : dat_tx_credit_q <= dat_tx_credit_q - 1'b1 + rx_dat_credit;
        default: ;
      endcase
    end
  end

  assign credit_drained_dat = (dat_tx_credit_q == CREDIT_WIDTH'(TOTAL_CREDITS));
  assign app_dat_ready       = if_running && (dat_tx_credit_q > '0);

  // ===========================================================================
  // DAT Channel TX — Output datapath
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : proc_dat_tx
    if (!rst_n) begin
      tx_dat_valid   <= 1'b0;
      tx_dat_sop     <= 1'b0;
      tx_dat_eop     <= 1'b0;
      tx_dat_header  <= '0;
      tx_dat_payload <= '0;
    end else if (app_dat_ready && app_dat_valid) begin
      tx_dat_valid   <= 1'b1;
      tx_dat_sop     <= app_dat_sop;
      tx_dat_eop     <= app_dat_eop;
      tx_dat_header  <= app_dat_header;
      tx_dat_payload <= app_dat_payload;
    end else begin
      tx_dat_valid   <= 1'b0;
      tx_dat_sop     <= 1'b0;
      tx_dat_eop     <= 1'b0;
      tx_dat_header  <= '0;
      tx_dat_payload <= '0;
    end
  end

  // ===========================================================================
  // DAT Channel RX — Credit return  (Section 8)
  // ---------------------------------------------------------------------------
  //   The master must return credits to the inbound DAT sender to allow
  //   continued transmission.  Credit is returned one cycle after a flit is
  //   accepted (registered to avoid combinational credit loops — Section 8).
  // ===========================================================================

  logic [CREDIT_WIDTH-1:0] dat_rx_credit_ret_q; // Pending credits to return

  always_ff @(posedge clk or negedge rst_n) begin : proc_dat_rx_credit_ret
    if (!rst_n) begin
      dat_rx_credit_ret_q <= '0;
    end else begin
      // Return one credit for each inbound DAT flit received
      if (rx_dat_valid)
        dat_rx_credit_ret_q <= 1'b1;
      else
        dat_rx_credit_ret_q <= '0;
    end
  end

  assign tx_dat_credit = dat_rx_credit_ret_q; // Registered credit return

  // Forward inbound DAT flits to the application layer
  always_ff @(posedge clk or negedge rst_n) begin : proc_rxdat_fwd
    if (!rst_n) begin
      app_rxdat_valid   <= 1'b0;
      app_rxdat_sop     <= 1'b0;
      app_rxdat_eop     <= 1'b0;
      app_rxdat_header  <= '0;
      app_rxdat_payload <= '0;
    end else begin
      app_rxdat_valid   <= rx_dat_valid;
      app_rxdat_sop     <= rx_dat_sop;
      app_rxdat_eop     <= rx_dat_eop;
      app_rxdat_header  <= rx_dat_header;
      app_rxdat_payload <= rx_dat_payload;
    end
  end

  // ===========================================================================
  // REQDAT Channel TX — Credit counter  (Section 8)
  // ===========================================================================

  logic [CREDIT_WIDTH-1:0] reqdat_credit_q;

  always_ff @(posedge clk or negedge rst_n) begin : proc_reqdat_credit
    if (!rst_n) begin
      reqdat_credit_q <= CREDIT_WIDTH'(TOTAL_CREDITS);
    end else begin
      unique case ({tx_reqdat_valid, |rx_reqdat_credit})
        2'b10 : reqdat_credit_q <= reqdat_credit_q - 1'b1;
        2'b01 : reqdat_credit_q <= reqdat_credit_q + rx_reqdat_credit;
        2'b11 : reqdat_credit_q <= reqdat_credit_q - 1'b1 + rx_reqdat_credit;
        default: ;
      endcase
    end
  end

  assign credit_drained_reqdat = (reqdat_credit_q == CREDIT_WIDTH'(TOTAL_CREDITS));
  assign app_reqdat_ready       = if_running && (reqdat_credit_q > '0);

  // ===========================================================================
  // REQDAT Channel TX — Output datapath
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : proc_reqdat_tx
    if (!rst_n) begin
      tx_reqdat_valid   <= 1'b0;
      tx_reqdat_sop     <= 1'b0;
      tx_reqdat_eop     <= 1'b0;
      tx_reqdat_header  <= '0;
      tx_reqdat_payload <= '0;
    end else if (app_reqdat_ready && app_reqdat_valid) begin
      tx_reqdat_valid   <= 1'b1;
      tx_reqdat_sop     <= app_reqdat_sop;
      tx_reqdat_eop     <= app_reqdat_eop;
      tx_reqdat_header  <= app_reqdat_header;
      tx_reqdat_payload <= app_reqdat_payload;
    end else begin
      tx_reqdat_valid   <= 1'b0;
      tx_reqdat_sop     <= 1'b0;
      tx_reqdat_eop     <= 1'b0;
      tx_reqdat_header  <= '0;
      tx_reqdat_payload <= '0;
    end
  end

  // ===========================================================================
  // RSP Channel RX — Credit return  (Section 8)
  // ---------------------------------------------------------------------------
  //   Master receives RSP flits and must return credits back to the RSP sender.
  //   Credit is registered to prevent combinational credit loops.
  // ===========================================================================

  logic [CREDIT_WIDTH-1:0] rsp_credit_ret_q;

  always_ff @(posedge clk or negedge rst_n) begin : proc_rsp_credit_ret
    if (!rst_n) begin
      rsp_credit_ret_q <= '0;
    end else begin
      rsp_credit_ret_q <= rx_rsp_valid ? CREDIT_WIDTH'(1) : '0;
    end
  end

  assign tx_rsp_credit = rsp_credit_ret_q;

  // Forward inbound RSP flits to application layer
  always_ff @(posedge clk or negedge rst_n) begin : proc_rsp_fwd
    if (!rst_n) begin
      app_rsp_valid   <= 1'b0;
      app_rsp_sop     <= 1'b0;
      app_rsp_eop     <= 1'b0;
      app_rsp_header  <= '0;
      app_rsp_payload <= '0;
    end else begin
      app_rsp_valid   <= rx_rsp_valid;
      app_rsp_sop     <= rx_rsp_sop;
      app_rsp_eop     <= rx_rsp_eop;
      app_rsp_header  <= rx_rsp_header;
      app_rsp_payload <= rx_rsp_payload;
    end
  end

  // ===========================================================================
  // SNP Channel RX — Credit return  (Section 8)
  // ---------------------------------------------------------------------------
  //   Master receives SNP flits and returns credits to the SNP sender.
  // ===========================================================================

  logic [CREDIT_WIDTH-1:0] snp_credit_ret_q;

  always_ff @(posedge clk or negedge rst_n) begin : proc_snp_credit_ret
    if (!rst_n) begin
      snp_credit_ret_q <= '0;
    end else begin
      snp_credit_ret_q <= rx_snp_valid ? CREDIT_WIDTH'(1) : '0;
    end
  end

  assign tx_snp_credit = snp_credit_ret_q;

  // Forward inbound SNP flits to application layer
  always_ff @(posedge clk or negedge rst_n) begin : proc_snp_fwd
    if (!rst_n) begin
      app_snp_valid   <= 1'b0;
      app_snp_sop     <= 1'b0;
      app_snp_eop     <= 1'b0;
      app_snp_header  <= '0;
      app_snp_payload <= '0;
    end else begin
      app_snp_valid   <= rx_snp_valid;
      app_snp_sop     <= rx_snp_sop;
      app_snp_eop     <= rx_snp_eop;
      app_snp_header  <= rx_snp_header;
      app_snp_payload <= rx_snp_payload;
    end
  end

  // ===========================================================================
  // Virtual Channel (VC) shared credit pool  (Section 9)
  // ---------------------------------------------------------------------------
  //   All TX channels share a pool of NUM_VC × CREDITS_PER_VC credits.
  //   Per-VC minimum guarantees are enforced by initializing each VC slot with
  //   CREDITS_PER_VC credits.  The VC ID is encoded in the header (bits [1:0]
  //   of tx_req_header / tx_dat_header / tx_reqdat_header).
  //
  //   This block tracks how many credits each VC has consumed so that the
  //   scheduler above can enforce QoS / priority policies (Section 11).
  //
  //   NOTE: The per-channel credit counters (req_credit_q, dat_tx_credit_q,
  //         reqdat_credit_q) govern actual forward-progress guarantees.  The
  //         VC pool below provides additional visibility for QoS accounting.
  //
  //   Race-condition avoidance: all channel contributions to the same VC are
  //   accumulated into a signed net-delta first, then applied as one atomic
  //   read-modify-write per VC per clock cycle. This prevents lost updates when
  //   multiple channels target the same VC simultaneously.
  // ===========================================================================

  // Per-VC consumed-credit counters (one entry per VC)
  logic [CREDIT_WIDTH-1:0] vc_credits_used_q [NUM_VC];

  // Extract VC ID from the header field being transmitted
  logic [$clog2(NUM_VC)-1:0] req_vc_id, dat_vc_id, reqdat_vc_id;
  assign req_vc_id    = app_req_header[$clog2(NUM_VC)-1:0];
  assign dat_vc_id    = app_dat_header[$clog2(NUM_VC)-1:0];
  assign reqdat_vc_id = app_reqdat_header[$clog2(NUM_VC)-1:0];

  // Signed net-delta accumulators: one per VC, computed combinatorially.
  // Using signed arithmetic wider than CREDIT_WIDTH to handle all combinations.
  logic signed [CREDIT_WIDTH:0] vc_delta [NUM_VC]; // +1 bit for sign

  always_comb begin : proc_vc_delta
    // Initialise all deltas to zero
    for (int v = 0; v < NUM_VC; v++)
      vc_delta[v] = '0;

    // REQ channel: +1 on send, -credit on return
    if (tx_req_valid)
      vc_delta[req_vc_id] = vc_delta[req_vc_id] + (CREDIT_WIDTH+1)'(1);
    if (|rx_req_credit)
      vc_delta[req_vc_id] = vc_delta[req_vc_id] - (CREDIT_WIDTH+1)'(rx_req_credit);

    // DAT TX channel: +1 on send, -credit on return
    if (tx_dat_valid)
      vc_delta[dat_vc_id] = vc_delta[dat_vc_id] + (CREDIT_WIDTH+1)'(1);
    if (|rx_dat_credit)
      vc_delta[dat_vc_id] = vc_delta[dat_vc_id] - (CREDIT_WIDTH+1)'(rx_dat_credit);

    // REQDAT channel: +1 on send, -credit on return
    if (tx_reqdat_valid)
      vc_delta[reqdat_vc_id] = vc_delta[reqdat_vc_id] + (CREDIT_WIDTH+1)'(1);
    if (|rx_reqdat_credit)
      vc_delta[reqdat_vc_id] = vc_delta[reqdat_vc_id] - (CREDIT_WIDTH+1)'(rx_reqdat_credit);
  end

  always_ff @(posedge clk or negedge rst_n) begin : proc_vc_accounting
    if (!rst_n) begin
      for (int v = 0; v < NUM_VC; v++)
        vc_credits_used_q[v] <= '0;
    end else begin
      // Apply the pre-computed atomic delta for each VC in a single write
      for (int v = 0; v < NUM_VC; v++) begin
        if (vc_delta[v] != '0)
          vc_credits_used_q[v] <= CREDIT_WIDTH'(
            $signed({1'b0, vc_credits_used_q[v]}) + vc_delta[v]);
      end
    end
  end

  // ===========================================================================
  // Formal/debug assertions (synthesizable only when ASSERTIONS_ON is defined)
  // ===========================================================================

`ifdef ASSERTIONS_ON
  // Credit counter must never go negative (underflow guard)
  property req_credit_no_underflow;
    @(posedge clk) disable iff (!rst_n)
    tx_req_valid |-> (req_credit_q > '0);
  endproperty
  assert property (req_credit_no_underflow)
    else $error("ICLink: REQ credit underflow — attempted send with zero credits");

  property dat_credit_no_underflow;
    @(posedge clk) disable iff (!rst_n)
    tx_dat_valid |-> (dat_tx_credit_q > '0);
  endproperty
  assert property (dat_credit_no_underflow)
    else $error("ICLink: DAT credit underflow — attempted send with zero credits");

  property reqdat_credit_no_underflow;
    @(posedge clk) disable iff (!rst_n)
    tx_reqdat_valid |-> (reqdat_credit_q > '0);
  endproperty
  assert property (reqdat_credit_no_underflow)
    else $error("ICLink: REQDAT credit underflow — attempted send with zero credits");

  // TX signals must be 0 when interface is not in RUN state
  property tx_gated_when_not_run;
    @(posedge clk) disable iff (!rst_n)
    (!if_running) |-> (!tx_req_valid && !tx_dat_valid && !tx_reqdat_valid);
  endproperty
  assert property (tx_gated_when_not_run)
    else $error("ICLink: TX activity detected while interface is not in RUN state");
`endif

endmodule : iclink_master
