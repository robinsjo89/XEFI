# ICLink Specification
**Version:** 0.4  
**Project:** Intel Chassis  
**Date:** 2026-03-18

---

## Index

- [0. Terminology](#0-terminology)
- [1. Glossary](#1-glossary)
- [2. Introduction](#2-introduction)
- [3. ICLink](#3-iclink)
- [4. Flits](#4-flits)
- [5. ICLink Channel](#5-iclink-channel)
- [6. Channel Classification](#6-channel-classification)
  - [6.1 Request Channel](#61-request-channel)
  - [6.2 Data Channel](#62-data-channel)
  - [6.3 Request with Data Channel](#63-request-with-data-channel)
  - [6.4 Response Channel](#64-response-channel)
  - [6.5 Snoop Channel](#65-snoop-channel)
  - [6.6 Inter-Channel Dependencies](#66-inter-channel-dependencies)
- [7. ICLink Interface & Port](#7-iclink-interface--port)
- [8. ICLink Flow Control](#8-iclink-flow-control)
- [9. Virtual Channels & Shared Credits](#9-virtual-channels--shared-credits)
- [10. Credit Management for Link Width Asymmetry](#10-credit-management-for-link-width-asymmetry)
- [11. Quality of Service (QoS)](#11-quality-of-service-qos)
- [12. Interface Activation & Deactivation](#12-interface-activation--deactivation)
- [13. Reset, Clocking & CDC](#13-reset-clocking--cdc)

---

## 0. Terminology

ICLink follows the communication hierarchy defined by *Dally & Towles – Principles and Practices of Interconnection Networks*.

```
Protocol Layer               -> Transaction
Protocol Layer (per-channel) -> Message
-----------------------------------------
ICLink
Network Layer                -> Packet
Link Layer                   -> Flit
-----------------------------------------
Physical Layer               -> Phit
```

ICLink spans the Network and Link layers, handling routing, SOP/EOP framing, and credit-based flow control.

### Definitions

| Term | Definition |
|------|------------|
| **Transaction** | A complete protocol-level operation (Read, Write, Atomic). Tracked by `TXN_ID`. Managed above ICLink. |
| **Message** | A discrete transfer within a transaction, mapped to one logical ICLink channel. |
| **Packet** | The routable unit marked by SOP/EOP. Contains routing and VC information. |
| **Flit** | Flow-control digit. One flit consumes one credit. Smallest transferable unit. |
| **Phit** | Physical transfer per cycle. On-die, phit equals flit. |

---

## 1. Glossary

| Acronym | Meaning |
|---------|---------|
| AXI | Advanced eXtensible Interface |
| CHI | Coherent Hub Interface |
| ICF | Intel Chassis Fabric |
| ICLink | Intel Chassis Link |
| QoS | Quality of Service |
| VC | Virtual Channel |
| TXN_ID | Transaction Identifier |
| SOP | Start Of Packet |
| EOP | End Of Packet |

---

## 2. Introduction

The Intel Chassis Link (ICLink) is the link layer of the Intel Chassis Fabric (ICF), bridging high-level protocols (AXI, CHI, XEFI) with physical interconnect routing fabrics.

### Responsibilities

| Layer | Responsibilities |
|-------|-----------------|
| **Protocol Bridge** | Converts transactions to ICLink packets; Maintains protocol ordering; Optional QoS, RAS, telemetry |
| **ICLink Layer** | Flit management; Credit-based flow control; Virtual channel multiplexing; Error detection |
| **Routers** | Routing; VC arbitration; Priority scheduling |

---

## 3. ICLink

ICLink is a flow-controlled point-to-point link between transmitter and receiver nodes.

- **Outbound link**: TX to RX — data flows from the Master (Requester) to the Completer
- **Inbound link**: RX from TX — responses, snoop requests, and read data flow back to the Master

Each direction is an independent set of channels with independent credit management.

---

## 4. Flits

A **flit** (flow-control digit) is the smallest transferable unit on the ICLink.

- Packets consist of one or more flits
- Each flit transmission consumes exactly **one credit**
- The sender must hold a valid credit before transmitting a flit
- On-die implementations: phit size equals flit size (one flit per cycle)

---

## 5. ICLink Channel

A channel is a logical partition of the physical link. Each channel has its own independent credit pool and flow control state.

### Signal Categories

| Category | Signals | Description |
|----------|---------|-------------|
| **Flow Control** | `valid`, `credit`, `sop`, `eop` | Controls flit transmission and framing |
| **Route Info** | `header` | Contains routing destination and VC identifier |
| **Payload** | `payload` | Application data carried in the flit |

### Signal Details

- `valid` — Asserted for exactly one cycle per flit; indicates flit is present and the credit has been consumed
- `sop` (Start Of Packet) — Asserted on the first flit of a packet; packet may span multiple flits
- `eop` (End Of Packet) — Asserted on the last flit of a packet; single-flit packets have both SOP and EOP set
- `credit` — Credit return signal; each cycle this is non-zero, the sender's credit counter increases
- `header` — Contains VC ID, channel type, and destination routing information
- `payload` — Raw data/command content; width is parameterizable

---

## 6. Channel Classification

ICLink defines five logical channel types:

| Channel | Direction | Description |
|---------|-----------|-------------|
| **Request (REQ)** | Requester → Completer | Read/Write command flits |
| **Data (DAT)** | Bi-directional | Read return data (Completer → Requester) and write data (Requester → Completer) |
| **Request+Data (REQDAT)** | Requester → Completer | Combined write command + write data in a single channel |
| **Response (RSP)** | Completer → Requester | No-payload acknowledgement/completion signals |
| **Snoop (SNP)** | Completer → Requester | Coherency traffic generated by the completer |

### 6.1 Request Channel

The **REQ** channel carries read and write command flits from the Requester to the Completer. Each command is a separate packet (SOP=EOP=1 for single-flit commands, or multi-flit for large requests).

**Signal prefix**: `tx_req_*` (TX from master), `rx_req_credit` (credit return to master)

### 6.2 Data Channel

The **DAT** channel is bi-directional and carries data payloads:

- **Outbound** (Requester → Completer): Write data accompanying a separate REQ command
- **Inbound** (Completer → Requester): Read data returned in response to a prior REQ

**Signal prefix**: `tx_dat_*` (outbound), `rx_dat_*` (inbound), `rx_dat_credit` / `tx_dat_credit`

### 6.3 Request with Data Channel

The **REQDAT** channel combines the write command and write data into a single channel, reducing round-trip latency for write transactions.

**Signal prefix**: `tx_reqdat_*`, `rx_reqdat_credit`

### 6.4 Response Channel

The **RSP** channel carries acknowledgement and completion responses from Completer to Requester. RSP flits have no meaningful payload (payload field is reserved and should be zero).

**Signal prefix**: `rx_rsp_*`, `tx_rsp_credit`

### 6.5 Snoop Channel

The **SNP** channel carries coherency traffic from the Completer (acting as a home node) back to the Requester. Snoop requests require the Requester to inspect or invalidate cached data.

**Signal prefix**: `rx_snp_*`, `tx_snp_credit`

### 6.6 Inter-Channel Dependencies

Protocol-level ordering rules (e.g., CHI ordering) are enforced above ICLink. ICLink itself provides only channel-level ordering (flits within a channel are delivered in order). No ordering guarantees exist between different channels.

---

## 7. ICLink Interface & Port

An **Interface** consists of one or more co-located channels sharing clock, reset, and activation handshake signals.

A **Port** is the complete set of TX and RX interfaces between two nodes:

- **TX Interface**: All outbound channels (REQ, DAT-TX, REQDAT)
- **RX Interface**: All inbound channels (RSP, SNP, DAT-RX)
- **Port** = TX Interface + RX Interface + Activation signals

---

## 8. ICLink Flow Control

ICLink uses **credit-based flow control** to prevent buffer overflow without requiring backpressure signals.

### Rules

1. **One credit = one flit**: The sender must possess a valid credit before transmitting any flit
2. **No credit loops**: Credit return signals must not create combinational feedback paths to `valid` outputs
3. **Forward progress**: The credit scheme must guarantee that all channels can make progress simultaneously — no deadlock
4. **Credit initialization**: Credits are allocated at reset; initial count = `NUM_VC × CREDITS_PER_VC` per channel

### Credit Counter Operation

```
On reset        : credit_count = TOTAL_CREDITS
On flit send    : credit_count = credit_count - 1
On credit return: credit_count = credit_count + returned_credits
Stall condition : credit_count == 0  (no transmission allowed)
```

### Implementation Notes

- Credit return is **registered** (one cycle delayed) to break combinational loops
- The sender may combine a send and a return in the same cycle (net change = return_count - 1)
- Credit counters are saturating: they cannot exceed `TOTAL_CREDITS` or go below 0

---

## 9. Virtual Channels & Shared Credits

### Purpose

Virtual Channels (VCs) allow multiple independent logical streams to share the same physical wires without head-of-line blocking.

### Shared Credit Pool

All VCs within a channel share a single credit pool:

- **Total credits** = `NUM_VC × CREDITS_PER_VC`
- **Per-VC minimum guarantee**: Each VC is guaranteed at least `CREDITS_PER_VC` credits when the pool is fully replenished
- VC ID is encoded in the `header` field (lower `$clog2(NUM_VC)` bits)

### QoS Integration

Higher-priority VCs may be allocated additional credits or given scheduling priority by the arbitration logic above ICLink (Section 11).

---

## 10. Credit Management for Link Width Asymmetry

When the TX and RX link widths differ (e.g., 256-bit TX vs 128-bit RX), the credit accounting must be adjusted to reflect the actual number of flits transferred per physical cycle.

Slot-aware credit management synchronizes asymmetric-width interfaces using proportional credit accounting. This ensures the receiver's buffer is never overrun even when the transmitter can send more data per cycle.

---

## 11. Quality of Service (QoS)

Traffic classes are mapped to Virtual Channels. The scheduler above ICLink assigns priority levels to VCs:

- Higher-priority VCs are serviced first during arbitration
- QoS policies do not affect the credit-based flow control rules
- Priority information may be encoded in the `header` field

---

## 12. Interface Activation & Deactivation

The ICLink interface activation/deactivation protocol uses a **two-signal handshake**:

| Signal | Driver | Description |
|--------|--------|-------------|
| `IFACTIVE_REQ` | Master (Requester) | Assert to request interface activation; de-assert to initiate deactivation |
| `IFACTIVE_ACK` | Slave (remote peer) | Assert to acknowledge activation; de-assert to confirm deactivation |

### State Machine

```
         app_activate=1                IFACTIVE_ACK=1
STOP ─────────────────────> ACTIVATE ──────────────────> RUN
 ^                                                         |
 │              !IFACTIVE_ACK &&                           │ app_activate=0
 │              credits_drained                            v
 └───────────────────────────────────── DEACTIVATE <───────┘
```

| State | `IFACTIVE_REQ` | `IFACTIVE_ACK` | Description |
|-------|---------------|---------------|-------------|
| **STOP** | 0 | 0 | Interface quiescent; clocks may be gated |
| **ACTIVATE** | 1 | 0 | Master requested activation; waiting for remote ACK |
| **RUN** | 1 | 1 | Interface fully operational; flits may flow |
| **DEACTIVATE** | 0 | 1→0 | Draining; waiting for credits and remote ACK de-assertion |

### Deactivation Constraint

The interface may only return to **STOP** when **all** TX credit counters equal `TOTAL_CREDITS`. This guarantees that all in-flight flits have been received and acknowledged before the interface powers down.

---

## 13. Reset, Clocking & CDC

### Reset

- Reset polarity: **active-low** (`rst_n`)
- Reset style: **asynchronous assert, synchronous deassert**
  - The reset de-assertion must be synchronized to the local clock domain
  - This prevents metastability on reset-release paths

### Clocking

ICLink supports multiple clocking configurations:

| Mode | Description |
|------|-------------|
| **Synchronous** | TX and RX share the same clock domain |
| **Asynchronous** | TX and RX run on independent clocks (requires async FIFO) |
| **Source-synchronous** | Data is accompanied by a forwarded clock |

### Clock Domain Crossing (CDC)

When TX and RX are in different clock domains:

- Control signals must pass through 2-flop synchronizers
- Data paths use FIFO-based handshake or gray-code pointers
- Credit signals are treated as control signals and require synchronization

---

*End of ICLink Specification v0.4*
