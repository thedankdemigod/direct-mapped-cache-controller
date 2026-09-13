# Set-Associative Cache Controller (Verilog)

A synthesizable RTL implementation of a set-associative cache controller, built as a hands-on architecture project in Vivado.

## Status

🚧 In development — currently at the FSM/datapath design stage, transitioning from architecture theory to RTL.

## Design Overview

- **Associativity:** Set-associative (N-way, configurable)
- **Write policy:** Write-through, no-write-allocate (initial target — avoids dirty-bit tracking and flush-on-evict FSM complexity)
- **Replacement policy:** LRU / pseudo-LRU (TBD based on associativity)
- **Address decomposition:** Tag / Index / Offset, derived from block-number framing (index = block number mod #sets, tag = block number / #sets)

## Repository Structure

```
.
├── rtl/    # Synthesizable Verilog source (cache controller, datapath, arrays)
├── tb/     # Testbenches
├── sim/    # Simulation scripts / waveform configs (Vivado xsim artifacts are gitignored)
├── docs/   # Design notes, FSM diagrams, block diagrams
├── README.md
└── .gitignore
```

## Roadmap

- [x] Cache architecture theory (hierarchy, AMAT, tag/index/offset, write policies, LRU vs pseudo-LRU)
- [ ] FSM state diagram (states, transitions, Moore/Mealy encoding)
- [ ] Memory-side handshake protocol (req/ack or ready/valid, CPU stall on miss)
- [ ] Tag/data array port structure and word-width organization
- [ ] Byte-enable / write-mask logic
- [ ] LRU bit encoding and update logic
- [ ] Reset/initialization sequencing
- [ ] RTL implementation (write-through, no-write-allocate)
- [ ] Testbench and functional verification
- [ ] (Stretch) Write-back + write-allocate variant with dirty bits

## Tools

- Xilinx Vivado (simulation + synthesis)

## Notes

Design decisions and theory walkthroughs are logged in `docs/` as the project progresses.
