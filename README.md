# XEFI — ICLink Master RTL

Intel Chassis Link (ICLink) Master RTL and comprehensive testbench, based on the
**ICLink v0.4 Specification** (Intel Chassis Project).

ICLink is the link layer of the Intel Chassis Fabric (ICF), bridging high-level
protocols (AXI, CHI, XEFI) with physical interconnect routing fabrics.  It spans
the Network and Link layers, handling routing, SOP/EOP framing, and credit-based
flow control.

---

## Repository Structure

```
XEFI/
├── rtl/
│   ├── iclink_pkg.sv        — Shared package: enums, structs, default parameters
│   └── iclink_master.sv     — ICLink Master RTL module
├── tb/
│   └── iclink_master_tb.sv  — Comprehensive SystemVerilog testbench (10 tests)
├── doc/
│   └── ICLink_v0.4.md       — Full ICLink v0.4 specification document
└── README.md                — This file
```

---

## Architecture Overview

### ICLink Hierarchy

```
Protocol Layer (Transaction)
        │
  ┌─────┴──────┐
  │  ICLink    │   ← This design
  │  Master    │
  │            │
  │  Network   │  Routing, VC multiplexing
  │  Link      │  Flit management, credit flow control
  └─────┬──────┘
        │
Physical Layer (Phit)
```

### Five Channel Types

| Channel | Signal Prefix | Direction | Purpose |
|---------|--------------|-----------|---------|
| **REQ** | `tx_req_*` | Master → Completer | Read/Write commands |
| **DAT** | `tx_dat_*` / `rx_dat_*` | Bi-directional | Read/Write data |
| **REQDAT** | `tx_reqdat_*` | Master → Completer | Combined write cmd+data |
| **RSP** | `rx_rsp_*` | Completer → Master | No-payload responses |
| **SNP** | `rx_snp_*` | Completer → Master | Coherency traffic |

### Key Design Features

| Feature | Description |
|---------|-------------|
| **Credit-based flow control** | Per-channel credit counters; stall when count=0; no combinational loops |
| **Virtual Channels** | Parameterizable `NUM_VC` VCs per channel; shared credit pool |
| **Interface FSM** | STOP → ACTIVATE → RUN → DEACTIVATE → STOP with `IFACTIVE_REQ`/`IFACTIVE_ACK` |
| **Reset** | Async assert, sync deassert (`rst_n`) |
| **Parameterizable** | `HEADER_WIDTH`, `PAYLOAD_WIDTH`, `CREDIT_WIDTH`, `NUM_VC`, `CREDITS_PER_VC` |

---

## Signal Naming Convention

All signals follow the ICLink specification naming exactly:

| Category | Pattern | Examples |
|----------|---------|---------|
| TX flow control | `tx_{ch}_valid`, `tx_{ch}_sop`, `tx_{ch}_eop` | `tx_req_valid`, `tx_dat_sop` |
| TX route info | `tx_{ch}_header` | `tx_req_header`, `tx_reqdat_header` |
| TX payload | `tx_{ch}_payload` | `tx_dat_payload` |
| RX credit return (TX→remote) | `tx_{ch}_credit` | `tx_dat_credit`, `tx_rsp_credit`, `tx_snp_credit` |
| RX flow control | `rx_{ch}_valid`, `rx_{ch}_sop`, `rx_{ch}_eop` | `rx_rsp_valid`, `rx_dat_valid` |
| RX route info | `rx_{ch}_header` | `rx_rsp_header` |
| RX payload | `rx_{ch}_payload` | `rx_snp_payload` |
| RX credit return (remote→TX) | `rx_{ch}_credit` | `rx_req_credit`, `rx_dat_credit` |
| Interface activation | `IFACTIVE_REQ`, `IFACTIVE_ACK` | |
| Reset | `rst_n` | Active-low, async assert / sync deassert |
| Clock | `clk` | |

---

## Module Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `HEADER_WIDTH` | 32 | Width of routing/VC header field (bits) |
| `PAYLOAD_WIDTH` | 128 | Width of flit payload field (bits) |
| `CREDIT_WIDTH` | 8 | Width of credit counters (bits); max credits = 2^CREDIT_WIDTH |
| `NUM_VC` | 4 | Number of Virtual Channels per logical channel |
| `CREDITS_PER_VC` | 8 | Initial credits per VC at reset (total = NUM_VC × CREDITS_PER_VC) |

---

## Simulation — How to Run

### Prerequisites

Any IEEE 1800-2017 compliant SystemVerilog simulator. Examples:

- [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog` + `vvp`) — free
- Synopsys VCS, Cadence Xcelium, Mentor Questa — commercial

### Using Icarus Verilog

```bash
# Create waveform output directory
mkdir -p vcd

# Compile (icarus supports SV with -g2012)
iverilog -g2012 -I rtl \
    rtl/iclink_pkg.sv \
    rtl/iclink_master.sv \
    tb/iclink_master_tb.sv \
    -o sim/iclink_master_tb

# Run simulation
vvp sim/iclink_master_tb

# View waveform (optional)
gtkwave vcd/iclink_master_tb.vcd
```

### Using VCS (Synopsys)

```bash
vcs -sverilog +incdir+rtl \
    rtl/iclink_pkg.sv \
    rtl/iclink_master.sv \
    tb/iclink_master_tb.sv \
    -o simv
./simv
```

### Expected Output

```
--- T01: Interface Activation ---
[PASS] T01 Interface Activation

--- T02: REQ Channel TX & Credit Decrement ---
[PASS] T02 REQ TX flit visibility
...

==========================================================
ICLink Master Testbench Summary
  PASS: 14
  FAIL: 0
  OVERALL RESULT: ** PASS **
==========================================================
```

---

## Testbench Test Coverage

| Test | Description |
|------|-------------|
| T01 | Interface activation: STOP → ACTIVATE → RUN handshake |
| T02 | REQ channel flit TX and credit decrement |
| T03 | REQ credit stall (credits=0) and resume (credit return) |
| T04 | DAT channel TX (outbound) and RX (inbound) with credit return |
| T05 | REQDAT channel TX |
| T06 | RSP channel RX and credit return to sender |
| T07 | SNP channel RX and credit return to sender |
| T08 | Multi-flit SOP/EOP framing validation (3-flit packet) |
| T09 | Virtual Channel multiplexing (all NUM_VC VCs exercised) |
| T10 | Interface deactivation: RUN → DEACTIVATE → STOP after credit drain |

---

## Specification Reference

See [`doc/ICLink_v0.4.md`](doc/ICLink_v0.4.md) for the complete ICLink v0.4 specification.
