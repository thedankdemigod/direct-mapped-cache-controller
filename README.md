# Cache Controller

A SystemVerilog implementation of a direct-mapped cache controller, built and verified in simulation (Vivado/xsim), with an emphasis on a rigorous, self-checking testbench over architectural complexity.

## Project Status

🚧 In development — architecture, FSM and datapath design are complete. RTL implementation is next.

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

- CPU interface: a simple `req` / `ready` / `valid` handshake, one outstanding transaction at a time, no request queue or cancellation.
- Registered completion: `cache_valid` appears in the first `IDLE` cycle after the work finishes, so the cache can accept the next request in that same cycle.
- Memory interface: byte-at-a-time, with continuous-request bursts for 4-byte line fills (no idle gap between bytes in a fetch).
- Memory model: variable random latency (2–8 cycles) per byte transaction, to verify the controller genuinely waits on completion rather than assuming a fixed delay.
- Miss handling: block-aligned fetch into a temporary buffer, then a single atomic commit to the cache array (never a partially-filled valid line).
- Write miss: fetch, merge the CPU write into the buffer, atomic commit, then write-through of the modified byte to memory.
- Controller FSM: five states (`IDLE`, `LOOKUP`, `FETCH`, `COMMIT`, `WRITE_MEM`).
- Full synchronous reset (valid, tag and data arrays and the FSM state all cleared in one cycle).

## Documentation

- [`docs/architecture.md`](docs/architecture.md): behavior, interfaces, timing and worked examples
- [`docs/fsm_design.md`](docs/fsm_design.md): states, transitions, per-state outputs and verification targets
- [`docs/datapath_design.md`](docs/datapath_design.md): registers, arrays, write controls, muxes and the memory model

## Planned Work

- [x] Define interfaces (CPU ↔ cache, cache ↔ memory)
- [x] Finalize architecture / timing specification
- [x] Design controller FSM
- [x] Design datapath and storage
- [ ] Implement memory model
- [ ] Implement controller (cache storage included)
- [ ] Build testbench
- [ ] Verify functionality
- [ ] Synthesize RTL
- [ ] Document results

## Repository Structure

```
rtl/    - synthesizable RTL
tb/     - testbenches and the simulation memory model
sim/    - simulation scripts/outputs
docs/   - architecture, FSM and datapath design documents
```

## Tools

- Vivado / xsim for simulation
- No FPGA hardware is required — this project is simulation-only
