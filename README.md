# Cache Controller

A Verilog/SystemVerilog implementation of a direct-mapped cache controller, built and verified in simulation (Vivado/xsim), with an emphasis on a rigorous, self-checking testbench over architectural complexity.

## Project Status

🚧 In development — Stage 1 (architecture & specification) complete. See `docs/architecture.md` for the full frozen spec.

## Specification

| Parameter | Value |
|---|---:|
| Address width | 8 bits |
| Main memory | 256 bytes |
| Cache organization | Direct-mapped |
| Cache lines | 8 |
| Block size | 4 bytes |
| Cache capacity | 32 bytes |
| Data width | 8 bits |
| Operations | Read and Write |
| Write policy | Write-through |
| Allocation policy | Write-allocate |

## Address Format

| Field | Bits |
|---|---:|
| Tag | 3 |
| Index | 3 |
| Offset | 2 |

## Architecture Highlights

- CPU interface: simple `req`/`ready`/`valid` handshake, one outstanding transaction at a time, no request queue or cancellation.
- Memory interface: byte-at-a-time, with continuous-request bursts for 4-byte line fills (no idle gap between bytes in a fetch).
- Memory model: variable random latency (2–8 cycles) per byte transaction, to verify the controller genuinely waits on completion rather than assuming a fixed delay.
- Miss handling: block-aligned fetch into a temporary buffer, single atomic commit to the cache array (never a partially-filled valid line).
- Write-miss: fetch → merge CPU write into the buffer → atomic commit → write-through the modified byte to memory.
- Full synchronous reset (valid/tag/data arrays and FSM state all cleared in one cycle).

Full details, worked examples, and cycle-by-cycle timing diagrams: [`docs/architecture.md`](docs/architecture.md).

## Planned Work

- [x] Define interfaces (CPU ↔ cache, cache ↔ memory)
- [x] Finalize architecture / timing specification
- [ ] Design controller FSM
- [ ] Implement memory model
- [ ] Implement cache storage
- [ ] Implement controller
- [ ] Build testbench
- [ ] Verify functionality
- [ ] Synthesize RTL
- [ ] Document results

## Repository Structure

```
rtl/    - synthesizable RTL
tb/     - testbenches
sim/    - simulation scripts/outputs
docs/   - architecture spec and design notes
```

## Tools

- Vivado / xsim for simulation
- No FPGA hardware or synthesis-to-board required — this project is simulation-only
