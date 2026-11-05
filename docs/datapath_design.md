# Cache Controller v1 — Datapath Design

This document specifies the registers, storage arrays, write controls and muxes of the cache controller, and the structure of the RTL and the simulation memory model. Behavior is defined in [`architecture.md`](architecture.md) and the FSM in [`fsm_design.md`](fsm_design.md).

## 1. Registers

| Register | Width | Loaded | Purpose |
|---|---:|---|---|
| `state` | 3 | every edge | FSM state |
| `req_addr` | 8 | `IDLE -> LOOKUP` | retained request address |
| `req_is_write` | 1 | `IDLE -> LOOKUP` | retained operation (write wins if both CPU signals are high; neither means read) |
| `req_wdata` | 8 | `IDLE -> LOOKUP` | retained write data |
| `cnt` | 2 | cleared on `LOOKUP -> FETCH`, incremented on each `mem_valid` in `FETCH` | burst byte index |
| `temp_buffer` | 4 x 8 | one byte per `mem_valid` in `FETCH` | line being assembled |
| `cache_valid_r` | 1 | completion transitions | registered `cache_valid` |
| `cache_rdata_r` | 8 | read completions | registered `cache_rdata` |

Storage cost, for reference:

| Item | Bits |
|---|---:|
| Cache arrays (8 lines x 36 bits) | 288 |
| `temp_buffer` | 32 |
| Request registers | 17 |
| `cnt` | 2 |
| Response registers | 9 |
| `state` | 3 |
| **Total** | **351** |

## 2. Derived fields

Computed combinationally from the retained request:

```text
tag        = req_addr[7:5]
index      = req_addr[4:2]
offset     = req_addr[1:0]
block_base = {req_addr[7:2], 2'b00}
hit        = valid[index] && (tag_array[index] == tag)
```

## 3. Storage arrays

Register arrays, one entry per cache line:

```text
valid[0:7]        1 bit each
tag_array[0:7]    3 bits each
data[0:7][0:3]    4 bytes per line, 8 bits each
```

All three are cleared by the synchronous reset. Reads are combinational from the retained `index`; the `LOOKUP` cycle gives the registered address a full cycle to settle, so the storage could later be BRAM-based without changing the FSM.

## 4. Array write controls

The array has two write modes. Each is driven by one control signal computed outside the array block.

| Signal | Asserted when | Effect |
|---|---|---|
| `array_byte_we` | `state == LOOKUP` and `req_is_write` and `hit` | writes `req_wdata` to `data[index][offset]` only; tag and valid are untouched |
| `array_line_we` | `state == COMMIT` | writes `valid[index] <= 1`, `tag_array[index] <= tag` and `data[index][0..3] <= temp_buffer[0..3]` together |

At most one of the two is asserted in any cycle. The byte write therefore needs byte-enable (write-mask) logic on the data array, while the line write drives all four bytes.

## 5. Muxes

**Capture mux (in `FETCH`, when `mem_valid`):**

```text
temp_buffer[cnt] <= (req_is_write && cnt == offset) ? req_wdata : mem_rdata
```

This performs the write-miss merge. It covers every offset, including offset 3, where the merge and the last capture happen on the same edge.

**Memory address mux:**

| State | `cache_m_addr` |
|---|---|
| `FETCH` | `{req_addr[7:2], cnt}` |
| `WRITE_MEM` | `req_addr` |
| other | don't care |

**Response data source:**

| Transition | `cache_rdata_r` loaded from |
|---|---|
| `LOOKUP -> IDLE` (read hit) | `data[index][offset]` |
| `COMMIT -> IDLE` (read miss) | `temp_buffer[offset]` |

Write completions load `cache_valid_r` only; `cache_rdata` is ignored for writes.

## 6. Reset

Synchronous and single-cycle. It clears `valid`, `tag_array` and `data`, sets `state` to `IDLE`, and clears `cache_valid_r` and `cnt`. The request registers and `temp_buffer` are left don't-care.

## 7. RTL structure

The controller is a single SystemVerilog module, `cache_controller`, in `rtl/`. The file follows this fixed section order:

1. State encoding (`localparam`s)
2. Declarations: `state`, `next_state`, request registers, `cnt`, `temp_buffer`, `cache_valid_r`, `cache_rdata_r`, and the arrays
3. Derived fields: `tag`, `index`, `offset`, `block_base`, `hit`
4. Next-state logic and the control enables (`array_byte_we`, `array_line_we`), all combinational
5. Moore output decode, driven by state only
6. One sequential block for the state register, request registers, `cnt`, `temp_buffer` and the registered response
7. The array block, sequential
8. Simulation-only assertions

Rule: the array block may only reference `array_byte_we`, `array_line_we`, `index`, `offset`, `tag` and the write data. It never references `state`. That keeps the array a self-contained unit, so it can be cut out into its own module later (for example when moving to a 2-way design) with no logic changes.

Ports:

| Group | Signals |
|---|---|
| Clock/reset | `clk`, `rst` (synchronous) |
| CPU -> cache | `cpu_req`, `cpu_addr[7:0]`, `cpu_read`, `cpu_write`, `cpu_wdata[7:0]` |
| Cache -> CPU | `cache_ready`, `cache_valid`, `cache_rdata[7:0]` |
| Cache -> memory | `cache_m_req`, `cache_m_read`, `cache_m_write`, `cache_m_addr[7:0]`, `cache_m_wdata[7:0]` |
| Memory -> cache | `mem_valid`, `mem_rdata[7:0]` |

## 8. Memory model (`main_memory`)

A behavioral, simulation-only module in `tb/`. It is not synthesizable.

- **Ports:** `clk`, `rst`, the `cache_m_*` signals as inputs, `mem_valid` and `mem_rdata` as outputs.
- **Parameters:** minimum delay 2, maximum delay 8, and a random seed so runs can be reproduced.
- **Starting a transaction:** it draws a fresh delay when `cache_m_req` rises, or when `cache_m_addr` changes while `cache_m_req` is high. An unchanged address means the same transaction, so the countdown is not restarted.
- **Completion:** after the delay it pulses `mem_valid` for exactly one cycle. For a read, `mem_rdata` is driven in that cycle. For a write, `cache_m_wdata` is stored into the array in that cycle.
- **Contents:** the testbench preloads memory with known data. Whether the contents survive a reset is a testbench decision, since the cache's reset does not touch main memory.
- **Reset:** it clears the delay countdown together with the cache.
