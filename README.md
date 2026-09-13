# Cache Controller

A Verilog/SystemVerilog implementation of a direct-mapped cache controller.

## Project Status

🚧 In development

## Initial Specifications

- Address width: 8 bits
- Main memory: 256 bytes
- Cache organization: Direct-mapped
- Cache lines: 8
- Block size: 4 bytes
- Cache capacity: 32 bytes
- Data width: 8 bits
- Operations: Read and Write
- Write policy: Write-through
- Allocation policy: Write-allocate

## Address Format

| Field  | Bits |
|--------|------|
| Tag    | 3    |
| Index  | 3    |
| Offset | 2    |

## Planned Work

- [ ] Define interfaces
- [ ] Design controller FSM
- [ ] Implement memory
- [ ] Implement cache
- [ ] Implement controller
- [ ] Build testbench
- [ ] Verify functionality
- [ ] Synthesize RTL
- [ ] Document results