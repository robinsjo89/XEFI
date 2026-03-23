// =============================================================================
// File       : iclink_pkg.sv
// Project    : XEFI — ICLink Master RTL
// Version    : 0.4
// Description: Shared package for the Intel Chassis Link (ICLink) design.
//              Contains enumerations, typedefs, structs, and default parameter
//              values used by iclink_master.sv and the accompanying testbench.
//
//              Based on: ICLink Specification v0.4 (Intel Chassis Project)
// =============================================================================

`ifndef ICLINK_PKG_SV
`define ICLINK_PKG_SV

package iclink_pkg;

  // ---------------------------------------------------------------------------
  // Default design-wide parameters  (Section 3, Section 8, Section 9)
  // These can be overridden at module instantiation using parameter overrides.
  // ---------------------------------------------------------------------------

  // Width of routing/VC header field (bits)
  parameter int HEADER_WIDTH    = 32;

  // Width of the flit payload field (bits)
  parameter int PAYLOAD_WIDTH   = 128;

  // Width of credit counters (bits); must satisfy 2^CREDIT_WIDTH > NUM_VC*CREDITS_PER_VC
  // Default: 8 bits → supports up to 255 total credits (handles NUM_VC=4, CREDITS_PER_VC=8 → 32)
  parameter int CREDIT_WIDTH    = 8;

  // Number of Virtual Channels supported per logical channel  (Section 9)
  parameter int NUM_VC          = 4;

  // Initial credit count granted to each VC at reset  (Section 8)
  parameter int CREDITS_PER_VC  = 8;

  // ---------------------------------------------------------------------------
  // Channel type enumeration  (Section 6)
  // Identifies the five logical ICLink channel types.
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    CH_REQ    = 3'b000,  // Request channel  — Read/Write commands (Requester → Completer)
    CH_DAT    = 3'b001,  // Data channel     — Read/Write data    (Bi-directional)
    CH_REQDAT = 3'b010,  // Req+Data channel — Combined write cmd+data (Requester → Completer)
    CH_RSP    = 3'b011,  // Response channel — No-payload responses (Completer → Requester)
    CH_SNP    = 3'b100   // Snoop channel    — Coherency traffic   (Completer → Requester)
  } ch_type_e;

  // ---------------------------------------------------------------------------
  // Interface activation state machine states  (Section 12)
  // Two-signal handshake: IFACTIVE_REQ / IFACTIVE_ACK
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IF_STOP       = 2'b00,  // STOP       — Interface inactive; clocks may be gated
    IF_ACTIVATE   = 2'b01,  // ACTIVATE   — Waiting for remote ACK to enter RUN
    IF_RUN        = 2'b10,  // RUN        — Interface fully operational
    IF_DEACTIVATE = 2'b11   // DEACTIVATE — Draining credits before returning to STOP
  } if_state_e;

  // ---------------------------------------------------------------------------
  // Flit header struct  (Section 5 — Route Info signals)
  // Carries routing information and VC identifier per flit.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [1:0]  vc_id;      // Virtual Channel identifier  (Section 9)
    logic [2:0]  ch_type;    // Channel type (ch_type_e cast to logic)
    logic [26:0] route_info; // Destination routing bits — implementation-defined
                              // Total: 32 bits == HEADER_WIDTH default
  } flit_header_t;

  // ---------------------------------------------------------------------------
  // Flit payload struct  (Section 5 — Payload signals)
  // Contains the raw data or command payload for one flit.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [127:0] data; // Payload data — 128 bits == PAYLOAD_WIDTH default
  } flit_payload_t;

  // ---------------------------------------------------------------------------
  // Per-channel credit pool descriptor
  // Tracks outstanding credits available for a single logical channel / VC.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [CREDIT_WIDTH-1:0] count; // Current available credit count
  } credit_pool_t;

endpackage : iclink_pkg

`endif // ICLINK_PKG_SV
