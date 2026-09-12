# AXI4-Lite Register IP

A small AXI4-Lite slave IP written in Verilog for learning and practicing AXI protocol design, RTL architecture, and verification.

The design implements a simple memory-mapped register bank with read/write registers, read-only registers, byte-write support through `WSTRB`, AXI response generation, and independent handling of the AXI write address and write data channels.

## Project Goals

This project is intended to practice:

- AXI4-Lite VALID/READY handshaking
- Independent AW and W channel handling
- Write transaction buffering and commit logic
- Memory-mapped register design
- `WSTRB` byte-enable handling
- `BRESP` and `RRESP` generation
- Read and write backpressure handling
- Cocotb-based functional verification
- Verification with `cocotbext-axi`
- Verilator simulation

## Register Map

| Address | Register | Access | Description |
|---:|---|:---:|---|
| `0x00` | CONTROL | RW | General control register |
| `0x04` | STATUS | RO | Status register |
| `0x08` | DATA_A | RW | Input data register A |
| `0x0C` | DATA_B | RW | Input data register B |
| `0x10` | RESULT | RO | `DATA_A + DATA_B` |

Invalid reads and writes return `SLVERR`.

## AXI4-Lite Architecture

The write path treats the AXI write-address and write-data channels independently.

```text
AWVALID/AWREADY
       |
       v
  Capture address
       |
       +------------------+
                          |
WVALID/WREADY             |
       |                  |
       v                  |
 Capture data/WSTRB       |
       |                  |
       +--------+---------+
                |
                v
       AW available && W available
                |
                v
           Write commit
                |
        +-------+-------+
        |               |
        v               v
 Register decode      BRESP
        |               |
        v               v
 Register update     BVALID
```

The read path accepts a read address, decodes the register map, captures `RDATA` and `RRESP`, and holds the response until the AXI read handshake completes.

```text
ARVALID && ARREADY
        |
        v
   Address decode
        |
   +----+----+
   |         |
   v         v
 RDATA      RRESP
   |         |
   +----+----+
        |
        v
 Capture response
        |
        v
     RVALID
        |
        v
RVALID && RREADY
```

## Write Channel Behavior

The design supports:

- AW and W arriving in the same cycle
- AW arriving before W
- W arriving before AW
- B-channel backpressure
- Partial register writes using `WSTRB`

A write transaction is committed only after both address and data are available.

## WSTRB Support

For a 32-bit AXI data bus, `WSTRB` has four bits.

| WSTRB | Byte Updated |
|:---:|---|
| `0001` | `[7:0]` |
| `0010` | `[15:8]` |
| `0100` | `[23:16]` |
| `1000` | `[31:24]` |
| `1111` | Full 32-bit word |

Example:

```text
Old value : 0x11223344
New value : 0xAABBCCDD
WSTRB     : 0b0010

Result    : 0x1122CC44
```

## AXI Responses

The current implementation uses:

```text
OKAY   = 2'b00
SLVERR = 2'b10
```

Writable registers return `OKAY`.

Writes to read-only or invalid addresses return `SLVERR`.

Valid register reads return `OKAY`.

Invalid reads return `SLVERR`.

## Project Structure

```text
01_axil_register/
├── docs/
│   └── docs.drawio
├── rtl/
│   ├── aw_guide.v
│   ├── axil_register.v
│   └── example.v
├── sim/
│   └── Makefile
└── tb/
    └── test_axil_register.py
```

### Directory Description

- `rtl/` - Verilog RTL source files
- `tb/` - Cocotb verification code
- `sim/` - Simulation Makefile and build configuration
- `docs/` - Architecture diagrams and design notes

## Verification

The testbench uses:

- Cocotb
- cocotbext-axi
- Verilator

The current directed regression contains 11 tests.

| Test | Purpose |
|---|---|
| Reset | Check reset behavior |
| DATA_A write/read | Basic AXI-Lite transaction |
| Register map | Verify CONTROL and DATA_B |
| RESULT | Verify `DATA_A + DATA_B` |
| WSTRB | Verify partial byte writes |
| Invalid write | Verify `SLVERR` |
| Invalid read | Verify `SLVERR` |
| AW before W | Verify independent AXI channels |
| W before AW | Verify independent AXI channels |
| BREADY backpressure | Verify B-channel response holding |
| RREADY backpressure | Verify R-channel response holding |

Current regression result:

```text
TESTS=11
PASS=11
FAIL=0
SKIP=0
```

## Running the Simulation

### Requirements

- Python 3
- cocotb
- cocotbext-axi
- Verilator
- GNU Make

Example Python environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install cocotb cocotbext-axi
```

Verify Verilator:

```bash
verilator --version
```

Run the regression:

```bash
cd sim
make clean
make
```

## Generated Files

Simulation-generated files should not be committed to Git.

```text
sim_build/
results.xml
__pycache__/
*.pyc
*.vcd
*.fst
```

These are excluded through `.gitignore`.

## Design Status

```text
AXI4-Lite Write Path       : PASS
AXI4-Lite Read Path        : PASS
WSTRB Support              : PASS
Invalid Address Response   : PASS
AW/W Independent Arrival   : PASS
B Channel Backpressure     : PASS
R Channel Backpressure     : PASS
Directed Cocotb Regression : 11/11 PASS
```

This project is a learning-oriented implementation and has not yet been formally proven to cover every possible AXI protocol timing sequence.

## Possible Next Steps

- Randomized AXI transactions
- Randomized channel backpressure
- Reset during active transactions
- Protocol assertions
- Formal verification
- Parameterized `DATA_WIDTH`
- AXI4-Lite peripheral examples
- AXI4-Stream IP
- AXI4 full-memory slave
- AXI master / DMA design

## Coding Style

```text
r_* : registered signals
w_* : combinational wires / events
c_* : constants
```

External AXI ports keep standard `s_axil_*` naming.

## References

1. Arm, **AMBA AXI and ACE Protocol Specification (IHI 0022)**  
   https://developer.arm.com/documentation/ihi0022/latest/

2. cocotb Documentation  
   https://docs.cocotb.org/

3. cocotbext-axi by Alex Forencich  
   https://github.com/alexforencich/cocotbext-axi

4. Verilator Documentation  
   https://verilator.org/guide/latest/

5. Nandland, **Coding Style Guidelines for VHDL and Verilog**  
   https://nandland.com/coding-style-guidelines-for-vhdl-verilog/

## License

Choose a license before publishing the repository. MIT is a common choice for small open-source RTL learning projects.
