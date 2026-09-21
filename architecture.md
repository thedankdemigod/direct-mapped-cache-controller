# Cache Controller v1 — Architecture

This is the frozen architecture-level spec for v1. It stays at the architecture/spec level — no FSM states, no RTL, no exact timing diagrams yet. Those come next.

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

**Step 1 — block base**

Clear the offset bits: `block_base = cpu_addr & 8'b1111_1100`.

Example: `cpu_addr = 0x36` → `block_base = 0x34` → fetch `0x34, 0x35, 0x36, 0x37`.

**Step 2 — fetch**, one byte at a time:

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

This is one cache-line commit, not four independent writes.

**Step 4 — return byte:** `cache_rdata = temp_buffer[cpu_offset]`, then `cache_valid = 1`.

## 7. Write hit

```text
CPU WRITE
   |
Lookup
   |
 HIT
   |
Update cache byte
   |
Write same byte to main memory
   |
Both complete
   |
cache_valid
```

Memory receives only the modified byte. Exact internal parallel/sequential timing between the cache-array update and the memory write is still an implementation decision (see §13).

## 8. Write miss

Locked ordering:

```text
FETCH -> MERGE -> CACHE COMMIT -> MEMORY WRITE -> COMPLETE
```

**Step 1 — fetch** the entire block into `temp_buffer`, same as a read miss.

**Step 2 — merge:** `temp_buffer[cpu_offset] = cpu_wdata`.

Example — `address = 0x36`, `wdata = 0xAA`, fetched block `11 22 33 44` → after merge: `11 22 AA 44`.

**Step 3 — atomic cache commit** of the already-merged line (same mechanism as §6 Step 3) — the cache array is written exactly once, and it's already correct.

**Step 4 — write-through:** send only the modified byte to memory (`address = cpu_addr`, `data = cpu_wdata`). The other three bytes aren't rewritten — memory already has them.

**Step 5 — complete:** `cache_valid = 1` only after the memory write finishes.

```text
CPU write miss
      |
      v
Fetch 4 bytes
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

## 9. Cache ↔ memory interface

Byte-at-a-time architecture.

**Cache → Memory**

```text
cache_m_req
cache_m_read
cache_m_write
cache_m_addr[7:0]
cache_m_wdata[7:0]
```

**Memory → Cache**

```text
mem_valid
mem_rdata[7:0]
```

Read transaction:

```text
cache_m_req
cache_m_read
cache_m_addr
        |
     MEMORY
        |
mem_valid
mem_rdata
```

Write transaction:

```text
cache_m_req
cache_m_write
cache_m_addr
cache_m_wdata
        |
     MEMORY
        |
mem_valid
```

Address/control/data are held stable for the duration of the transaction, per the same stability contract used on the CPU side.

If `cache_m_read` and `cache_m_write` are ever asserted together, this is resolved by the same hardware priority rule as the CPU side — not assumed away.

Exact request/response cycle timing is intentionally not frozen yet.

## 10. Memory model

For verification: 256 x 8-bit memory with fixed multi-cycle latency. A cache-line fetch is four independent memory transactions:

```text
Transaction 0 -> byte 0
Transaction 1 -> byte 1
Transaction 2 -> byte 2
Transaction 3 -> byte 3
```

The memory latency is a single fixed parameter applied identically to every memory transaction, read or write.

```text
MEM_LATENCY = 3   // default
```

`MEM_LATENCY` is exposed as a parameter so the testbench can sweep different latency values without changing the cache-controller RTL. The controller must therefore wait for `mem_valid` rather than rely on a hardcoded latency.

## 11. Design invariant

A cache line is never made valid until all four bytes are available and the complete line has been committed in one atomic write. There is no externally visible state where `valid = 1`, `tag = new tag`, but `data` is only partially filled. This holds for both read misses and write misses.

## 12. Transaction summaries

**Read hit:** REQUEST → LOOKUP → HIT → RETURN BYTE → cache_valid

**Read miss:** REQUEST → LOOKUP → MISS → FETCH 4 BYTES → CACHE COMMIT → RETURN BYTE → cache_valid

**Write hit:** REQUEST → LOOKUP → HIT → UPDATE CACHE → WRITE MEMORY → cache_valid

**Write miss:** REQUEST → LOOKUP → MISS → FETCH 4 BYTES → MERGE CPU WRITE → CACHE COMMIT → WRITE MODIFIED BYTE TO MEMORY → cache_valid

---

The architectural core, in one line: **direct-mapped, 8-line x 4-byte cache, byte-addressable, write-through + write-allocate, byte-at-a-time memory interface, temporary 4-byte miss buffer, atomic line commit, read/write priority rule on both CPU and memory interfaces, memory requests held until `mem_valid`, parameterized fixed memory latency (`MEM_LATENCY = 3` by default), no `mem_ready`, and write-miss ordering of FETCH → MERGE → CACHE COMMIT → MEMORY WRITE → COMPLETE.**

## 13. What's left before this becomes an FSM

- Exact cycle-by-cycle timing diagrams
- Exact write-through timing for write hit (parallel vs. sequential with the cache-array update)
- Reset behavior
- FSM structure
- Exact RTL representation of cache storage

### Locked memory-interface decisions

- `cache_m_req` is held high for the full memory transaction, from request issue until `mem_valid`.
- `MEM_LATENCY` is a parameter rather than a hardcoded controller assumption.
- Default `MEM_LATENCY = 3`.
- The same fixed latency applies to both read and write transactions.
- The testbench should be able to sweep `MEM_LATENCY` values to verify that the controller depends on `mem_valid` for completion rather than a hardcoded wait count.
- No `mem_ready` signal is used in v1.
- There is no separate memory acceptance phase.
- The original stability contract remains: memory address/control/write-data remain stable until `mem_valid`.

