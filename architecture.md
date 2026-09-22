# Cache Controller v1 — Architecture

This is the frozen architecture-level spec for v1. It stays at the architecture/spec level — no FSM states, no RTL yet. Those come next.

## 1. System overview

```text
                    CPU
                     |
                     | CPU interface
                     v
        +---------------------------+
        |     CACHE CONTROLLER      |
        |                           |
        |  Request / FSM / Control  |
        |                           |
        |     +---------------+     |
        |     | Cache Storage |     |
        |     +---------------+     |
        |                           |
        |     +---------------+     |
        |     | Temp Buffer   |     |
        |     +---------------+     |
        +-------------+-------------+
                      |
                      | Byte-at-a-time
                      | Memory interface
                      v
               +-------------+
               | Main Memory |
               |   256 x 8   |
               +-------------+
```

## 2. Cache configuration

| Parameter | Value |
|---|---:|
| Address width | 8 bits |
| Main memory | 256 bytes |
| Organization | Direct-mapped |
| Number of cache lines | 8 |
| Block size | 4 bytes |
| Cache data capacity | 32 bytes |
| Data granularity | 1 byte / 8 bits |
| Tag | 3 bits |
| Index | 3 bits |
| Offset | 2 bits |
| Write policy | Write-through |
| Allocation | Write-allocate |

Address breakdown:

```text
 7       5 4       2 1       0
+---------+---------+---------+
|   TAG   |  INDEX  | OFFSET  |
+---------+---------+---------+
   3 bits    3 bits    2 bits
```

Cache line:

```text
+-------+------+-------------------+
| Valid | Tag  |     Data[0:3]     |
+-------+------+-------------------+
   1       3          4 x 8 bits
```

8 lines = 8 sets (direct-mapped: one line per set, no ways).

## 3. CPU interface

**CPU → Cache**

```text
cpu_req
cpu_addr[7:0]
cpu_read
cpu_write
cpu_wdata[7:0]
```

**Cache → CPU**

```text
cache_ready
cache_valid
cache_rdata[7:0]
```

**Protocol**

A request is accepted when `cpu_req && cache_ready`. Once `cpu_req` is asserted, the CPU holds `cpu_req` / `cpu_addr` / `cpu_read` / `cpu_write` / `cpu_wdata` stable until acceptance — no changing the request mid-wait.

Only one CPU transaction can be outstanding at a time. No request queue, no request IDs, no cancellation.

If `cpu_read` and `cpu_write` are ever asserted together, this is resolved by a hardware priority rule rather than left undefined or assumed away by the testbench.

## 4. Cache ready / completion

```text
cache_ready = (FSM state == IDLE)
```

`cache_valid` pulses for one cycle to indicate the accepted transaction has completed.

Read: `cache_valid = 1`, `cache_rdata` = returned byte.
Write: `cache_valid = 1`, `cache_rdata` ignored.

Hit/miss is never exposed to the CPU — only the completion latency differs. Back-to-back requests are allowed with no mandatory idle gap between them.

## 5. Read hit

```text
CPU request
     |
Extract TAG / INDEX / OFFSET
     |
Select cache[index]
     |
valid == 1 ?
     |
Compare stored tag with CPU tag
     |
      HIT
       |
Select data[offset]
       |
cache_rdata
       |
cache_valid
```

Worked example — `address = 0x34` (`0011_0100`):

```text
TAG    = 001
INDEX  = 101
OFFSET = 00
```

The offset selects byte 0 of the selected cache line.

## 6. Read miss

**Step 1 — block base.** Clear the offset bits: `block_base = cpu_addr & 8'b1111_1100`.

Example: `cpu_addr = 0x36` -> `block_base = 0x34` -> fetch `0x34, 0x35, 0x36, 0x37`.

**Step 2 — fetch**, one byte at a time, as a single continuous burst (see §10 for exact burst timing):

```text
READ 0x34 -> temp_buffer[0]
READ 0x35 -> temp_buffer[1]
READ 0x36 -> temp_buffer[2]
READ 0x37 -> temp_buffer[3]
```

**Step 3 — atomic cache commit.** Only once all four bytes have arrived:

```text
cache[index].data[0..3] <= temp_buffer[0..3]
cache[index].tag        <= cpu_tag
cache[index].valid      <= 1
```

One cache-line commit, not four independent writes.

**Step 4 — return byte:** `cache_rdata = temp_buffer[cpu_offset]`, then `cache_valid = 1`.

## 7. Write hit

Cache-array update and the write-through push to memory are issued **in the same cycle** (parallel, not sequential):

```text
CPU WRITE (hit)
   |
   |-- cache[index].data[offset] <= cpu_wdata     (same cycle, instant)
   |-- cache_m_req/write issued to memory          (same cycle)
   |
... wait for mem_valid ...
   |
cache_valid = 1
```

The cache-array write completes instantly (internal, no handshake) and is never the bottleneck — the memory write's variable latency is. `cache_valid` fires only once `mem_valid` confirms the memory write has completed; a write is not "done" until both cache and memory are updated. Memory receives only the modified byte, never the whole line.

## 8. Write miss

Locked ordering:

```text
FETCH -> MERGE -> CACHE COMMIT -> MEMORY WRITE -> COMPLETE
```

**Step 1 — fetch** the entire block into `temp_buffer`, identical mechanism to a read miss (same burst, see §10) — the fetch step itself does not distinguish between a read-miss or write-miss caller.

**Step 2 — merge:** `temp_buffer[cpu_offset] = cpu_wdata`.

Example — `address = 0x36`, `wdata = 0xAA`, fetched block `11 22 33 44` -> after merge: `11 22 AA 44`.

**Step 3 — atomic cache commit** of the already-merged line (same mechanism as §6 Step 3) — the cache array is written exactly once, and it's already correct.

**Step 4 — write-through:** send only the modified byte to memory (`address = cpu_addr`, `data = cpu_wdata`). The other three bytes aren't rewritten — memory already has them.

**Step 5 — complete:** `cache_valid = 1` only after the memory write finishes.

```text
CPU write miss
      |
      v
Fetch 4 bytes (burst, §10)
      |
      v
Modify temporary buffer
      |
      v
Commit complete cache line
      |
      v
Write modified byte to memory
      |
      v
cache_valid
```

## 9. Cache <-> memory interface

Byte-at-a-time architecture.

**Cache -> Memory**

```text
cache_m_req
cache_m_read
cache_m_write
cache_m_addr[7:0]
cache_m_wdata[7:0]
```

**Memory -> Cache**

```text
mem_valid
mem_rdata[7:0]
```

Address/control/data are held stable for the duration of a single-byte transaction, per the stability contract used on the CPU side. `cache_m_req` is held high for the full duration of a transaction (not a one-cycle pulse) and drops one cycle after `mem_valid` fires — except during a multi-byte burst, see §10.

`mem_rdata` is valid only in the exact cycle `mem_valid` is high; don't-care otherwise. The cache must register `mem_rdata` into the temp buffer on that exact clock edge — the data is not retained on the wire afterward, only in whatever register the cache captures it into. Symmetrically, memory must commit `cache_m_wdata` into its storage on the exact cycle it raises `mem_valid` for a write.

If `cache_m_read` and `cache_m_write` are ever asserted together, this is resolved by the same hardware priority rule as the CPU side — not assumed away.

No `mem_ready` signal is used in v1. Memory always accepts a request instantly; there is no separate acceptance phase, since memory is a dedicated single-consumer resource with no contention in this design.

## 10. Memory model and burst timing

For verification: 256 x 8-bit memory. Every byte transaction takes a **random, independently-drawn delay between 2 and 8 cycles** (uniform), not a fixed latency. Latency counting begins the cycle *after* `cache_m_req` (or, mid-burst, the changed address) is presented — not the presenting cycle itself.

The cache FSM must wait purely on `mem_valid` with no assumption of a fixed delay; this is a mandatory correctness property, not an optional stress test, since delay genuinely varies transaction to transaction.

**Single-byte transaction (e.g. write-hit's write-through push):**

```text
cycle:           0      1      2      3
cache_m_req:     1      1      1      0
cache_m_write:   1      1      1      0
cache_m_addr:    0x36   0x36   0x36   --
cache_m_wdata:   0xAA   0xAA   0xAA   --
mem_valid:       0      0      1      0
```
(shown with a delay of 2, for illustration — actual delay is random 2-8)

**Multi-byte burst (4-byte block fill, used identically by read-miss and write-miss fetch):**

`cache_m_req` stays **continuously high for the entire burst**, only dropping after the *last* byte's `mem_valid`. A **change in `cache_m_addr`** — not a `cache_m_req` toggle — signals the start of each new byte-transaction within the burst; memory must detect the address change the cycle after its own `mem_valid` and begin a fresh random-delay countdown for that new address. This gives zero idle cycles between bytes within a burst (Design 2), as opposed to toggling `cache_m_req` per byte, which would force a mandatory 1-cycle gap between every byte (Design 1, rejected).

**Explicit non-retrigger rule:** while `cache_m_req` is high and `cache_m_addr` is unchanged from the previous cycle, memory must treat this as the *same* transaction still in progress — it must not restart its random-delay countdown or reinterpret it as a new request. A new countdown starts only on the specific cycle the address changes (or on the very first cycle of the burst). This matters concretely: in the diagram below, address `34` is held for 3 consecutive cycles before `mem_valid` fires — memory must count through all 3 as one transaction, not three.

**Address-change timing, stated precisely:** if byte K's `mem_valid` fires on cycle N, then byte K+1's address appears on `cache_m_addr` on cycle N+1, and its random-delay countdown begins counting from cycle N+1. The cache's next-address logic must have that address ready to present on cycle N+1 — it cannot be computed reactively after N+1 has already passed.

```text
cycle:          0    1    2    3    4    5    6    7    8    9    10   11   12
cache_m_req:    1    1    1    1    1    1    1    1    1    1    1    1    0
cache_m_addr:   34   34   34   35   35   35   36   36   36   37   37   37   --
mem_valid:      0    0    1    0    0    1    0    0    1    0    0    1    0
mem_rdata:      -    -    D34  -    -    D35  -    -    D36  -    -    D37  -
```
(shown with a delay of 2 per byte, for illustration — actual per-byte delay is random 2-8, independently drawn)

The cache's next-address logic must be ready to present the next byte's address on the cycle immediately following the prior byte's `mem_valid` — this is a real sequencing requirement on the FSM/datapath, not automatic.

## 11. Design invariant

A cache line is never made valid until all four bytes are available and the complete line has been committed in one atomic write. There is no externally visible state where `valid = 1`, `tag = new tag`, but `data` is only partially filled. This holds for both read misses and write misses.

## 12. Reset behavior

Synchronous reset, single cycle. On the reset edge, the following clear/initialize simultaneously:

- All 8 valid bits -> 0
- All 8 tag fields -> 0
- All 8 data lines (32 bytes total) -> 0
- FSM state -> `IDLE`

Tags and data are not functionally required to reset (they're unreachable while valid=0), but are cleared anyway for simulation cleanliness — avoiding X-propagation in waveforms, and allowing simple, complete-state self-checking testbench assertions immediately after reset. The hardware cost of clearing the full arrays is negligible at this scale.

`cache_ready` is correctly high (FSM = IDLE) from the first cycle after reset. The temp buffer is left don't-care at reset, since no transaction can be mid-flight the instant reset ends.

## 13. Transaction summaries

**Read hit:** REQUEST -> LOOKUP -> HIT -> RETURN BYTE -> cache_valid

**Read miss:** REQUEST -> LOOKUP -> MISS -> FETCH 4 BYTES (burst) -> CACHE COMMIT -> RETURN BYTE -> cache_valid

**Write hit:** REQUEST -> LOOKUP -> HIT -> UPDATE CACHE + WRITE MEMORY (parallel) -> cache_valid

**Write miss:** REQUEST -> LOOKUP -> MISS -> FETCH 4 BYTES (burst) -> MERGE CPU WRITE -> CACHE COMMIT -> WRITE MODIFIED BYTE TO MEMORY -> cache_valid

---

The architectural core, in one line: **direct-mapped, 8-line x 4-byte cache, byte-addressable, write-through + write-allocate, byte-at-a-time memory interface with continuous-request bursts for line fills (Design 2), temporary 4-byte miss buffer, atomic line commit, read/write priority rule on both CPU and memory interfaces, variable random memory latency (2-8 cycles per byte), parallel write-hit update, full synchronous reset, and write-miss ordering of FETCH -> MERGE -> CACHE COMMIT -> MEMORY WRITE -> COMPLETE.**

## 14. What's left before this becomes an FSM

- Full cycle-by-cycle timing diagrams have been drawn for the individual transaction types (§6, §7, §8, §10); the FSM stage should now formalize these into actual states and transitions
- FSM structure
- Exact RTL representation of cache storage (register array vs. other structures, port count)
