import cocotb

from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, with_timeout

from cocotbext.axi import (
    AxiLiteBus,
    AxiLiteMaster,
    AxiResp,
)


# ============================================================
# Register Map
# ============================================================

ADDR_CONTROL = 0x00
ADDR_STATUS  = 0x04
ADDR_DATA_A  = 0x08
ADDR_DATA_B  = 0x0C
ADDR_RESULT  = 0x10

ADDR_INVALID = 0x20


# ============================================================
# Helper Functions
# ============================================================

def to_u32(value):
    """
    Convert integer to 4-byte little-endian data.
    """
    return int(value & 0xFFFFFFFF).to_bytes(
        4,
        byteorder="little"
    )


def from_u32(data):
    """
    Convert little-endian byte data to integer.
    """
    return int.from_bytes(
        data,
        byteorder="little"
    )


def pause_for_cycles(cycles):
    """
    Pause an AXI channel for a fixed number of clock cycles,
    then release it permanently.

    True  = paused
    False = running
    """

    for _ in range(cycles):
        yield True

    while True:
        yield False


async def wait_until_high(signal, clock, max_cycles=100):
    """
    Wait until a signal becomes logic 1.
    """

    for _ in range(max_cycles):

        await RisingEdge(clock)
        await ReadOnly()

        if int(signal.value) == 1:
            return

    raise AssertionError(
        f"Timeout waiting for {signal._name} to become HIGH"
    )


# ============================================================
# Testbench
# ============================================================

class TB:

    def __init__(self, dut):

        self.dut = dut

        # ----------------------------------------------------
        # Clock
        # ----------------------------------------------------

        cocotb.start_soon(
            Clock(
                dut.aclk,
                10,
                unit="ns"
            ).start()
        )

        # ----------------------------------------------------
        # AXI4-Lite Master
        # ----------------------------------------------------

        self.axi = AxiLiteMaster(
            AxiLiteBus.from_prefix(
                dut,
                "s_axil"
            ),
            dut.aclk,
            dut.aresetn,
            reset_active_level=False
        )


    async def reset(self):

        # Active-low reset
        self.dut.aresetn.value = 0

        for _ in range(5):
            await RisingEdge(self.dut.aclk)

        self.dut.aresetn.value = 1

        for _ in range(5):
            await RisingEdge(self.dut.aclk)


# ============================================================
# TEST 1
#
# Reset
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_reset(dut):

    tb = TB(dut)

    await tb.reset()

    # No pending AXI responses after reset
    assert int(dut.s_axil_bvalid.value) == 0, \
        "BVALID should be 0 after reset"

    assert int(dut.s_axil_rvalid.value) == 0, \
        "RVALID should be 0 after reset"

    # Slave should be ready for a new transaction
    assert int(dut.s_axil_awready.value) == 1, \
        "AWREADY should be 1 after reset"

    assert int(dut.s_axil_wready.value) == 1, \
        "WREADY should be 1 after reset"

    assert int(dut.s_axil_arready.value) == 1, \
        "ARREADY should be 1 after reset"

    dut._log.info(
        "TEST 1 PASS: Reset"
    )


# ============================================================
# TEST 2
#
# Basic DATA_A Write / Read
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_write_read_data_a(dut):

    tb = TB(dut)

    await tb.reset()

    test_value = 0x12345678

    # --------------------------------------------------------
    # WRITE DATA_A
    # --------------------------------------------------------

    write_resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_A,
            to_u32(test_value)
        ),
        5,
        "us"
    )

    assert write_resp.resp == AxiResp.OKAY, \
        f"DATA_A write response = {write_resp.resp}, expected OKAY"

    # --------------------------------------------------------
    # READ DATA_A
    # --------------------------------------------------------

    read_resp = await with_timeout(
        tb.axi.read(
            ADDR_DATA_A,
            4
        ),
        5,
        "us"
    )

    read_value = from_u32(
        read_resp.data
    )

    assert read_resp.resp == AxiResp.OKAY, \
        f"DATA_A read response = {read_resp.resp}, expected OKAY"

    assert read_value == test_value, \
        (
            f"DATA_A mismatch: "
            f"expected 0x{test_value:08X}, "
            f"got 0x{read_value:08X}"
        )

    dut._log.info(
        "TEST 2 PASS: DATA_A Write/Read"
    )


# ============================================================
# TEST 3
#
# DATA_B + CONTROL Register
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_register_map(dut):

    tb = TB(dut)

    await tb.reset()

    ctrl_value   = 0x00000005
    data_b_value = 0xCAFEBABE

    # --------------------------------------------------------
    # CONTROL
    # --------------------------------------------------------

    write_resp = await with_timeout(
        tb.axi.write(
            ADDR_CONTROL,
            to_u32(ctrl_value)
        ),
        5,
        "us"
    )

    assert write_resp.resp == AxiResp.OKAY

    read_resp = await with_timeout(
        tb.axi.read(
            ADDR_CONTROL,
            4
        ),
        5,
        "us"
    )

    assert read_resp.resp == AxiResp.OKAY

    assert from_u32(read_resp.data) == ctrl_value, \
        "CONTROL register mismatch"

    # --------------------------------------------------------
    # DATA_B
    # --------------------------------------------------------

    write_resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_B,
            to_u32(data_b_value)
        ),
        5,
        "us"
    )

    assert write_resp.resp == AxiResp.OKAY

    read_resp = await with_timeout(
        tb.axi.read(
            ADDR_DATA_B,
            4
        ),
        5,
        "us"
    )

    assert read_resp.resp == AxiResp.OKAY

    assert from_u32(read_resp.data) == data_b_value, \
        "DATA_B register mismatch"

    dut._log.info(
        "TEST 3 PASS: CONTROL and DATA_B"
    )


# ============================================================
# TEST 4
#
# RESULT = DATA_A + DATA_B
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_result_register(dut):

    tb = TB(dut)

    await tb.reset()

    data_a = 10
    data_b = 20

    # --------------------------------------------------------
    # Write operands
    # --------------------------------------------------------

    resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_A,
            to_u32(data_a)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_B,
            to_u32(data_b)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    # --------------------------------------------------------
    # Read RESULT
    # --------------------------------------------------------

    read_resp = await with_timeout(
        tb.axi.read(
            ADDR_RESULT,
            4
        ),
        5,
        "us"
    )

    result = from_u32(
        read_resp.data
    )

    expected = (
        data_a + data_b
    ) & 0xFFFFFFFF

    assert read_resp.resp == AxiResp.OKAY

    assert result == expected, \
        (
            f"RESULT mismatch: "
            f"expected {expected}, "
            f"got {result}"
        )

    dut._log.info(
        "TEST 4 PASS: RESULT = DATA_A + DATA_B"
    )


# ============================================================
# TEST 5
#
# WSTRB Partial Write
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_wstrb_partial_write(dut):

    tb = TB(dut)

    await tb.reset()

    # Initial value
    #
    # DATA_A =
    #
    # Byte3 Byte2 Byte1 Byte0
    #
    #  11    22    33    44
    #
    initial_value = 0x11223344

    resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_A,
            to_u32(initial_value)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    # --------------------------------------------------------
    # Partial write
    #
    # Write only ONE BYTE at address 0x08.
    #
    # cocotbext-axi will generate approximately:
    #
    # WDATA = 0x000000AA
    # WSTRB = 4'b0001
    #
    # Expected:
    #
    # OLD = 11 22 33 44
    # NEW = xx xx xx AA
    #
    # RESULT = 11 22 33 AA
    # --------------------------------------------------------

    resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_A,
            bytes([0xAA])
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    read_resp = await with_timeout(
        tb.axi.read(
            ADDR_DATA_A,
            4
        ),
        5,
        "us"
    )

    read_value = from_u32(
        read_resp.data
    )

    expected = 0x112233AA

    assert read_value == expected, \
        (
            f"WSTRB failed: "
            f"expected 0x{expected:08X}, "
            f"got 0x{read_value:08X}"
        )

    dut._log.info(
        "TEST 5 PASS: WSTRB partial write"
    )


# ============================================================
# TEST 6
#
# Invalid Write Address
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_invalid_write(dut):

    tb = TB(dut)

    await tb.reset()

    # --------------------------------------------------------
    # STATUS is Read-Only
    # --------------------------------------------------------

    resp = await with_timeout(
        tb.axi.write(
            ADDR_STATUS,
            to_u32(0x12345678)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.SLVERR, \
        (
            f"Write STATUS should return SLVERR, "
            f"got {resp.resp}"
        )

    # --------------------------------------------------------
    # Completely invalid address
    # --------------------------------------------------------

    resp = await with_timeout(
        tb.axi.write(
            ADDR_INVALID,
            to_u32(0xDEADBEEF)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.SLVERR, \
        (
            f"Invalid write should return SLVERR, "
            f"got {resp.resp}"
        )

    dut._log.info(
        "TEST 6 PASS: Invalid Write -> SLVERR"
    )


# ============================================================
# TEST 7
#
# Invalid Read Address
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_invalid_read(dut):

    tb = TB(dut)

    await tb.reset()

    resp = await with_timeout(
        tb.axi.read(
            ADDR_INVALID,
            4
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.SLVERR, \
        (
            f"Invalid read should return SLVERR, "
            f"got {resp.resp}"
        )

    # Your RTL currently returns zero on invalid read
    read_value = from_u32(
        resp.data
    )

    assert read_value == 0, \
        (
            f"Invalid read data expected 0, "
            f"got 0x{read_value:08X}"
        )

    dut._log.info(
        "TEST 7 PASS: Invalid Read -> SLVERR"
    )


# ============================================================
# TEST 8
#
# AW arrives before W
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_aw_before_w(dut):

    tb = TB(dut)

    await tb.reset()

    test_value = 0xA1B2C3D4

    # --------------------------------------------------------
    # Delay W channel
    #
    # AW should be accepted first and stored in:
    #
    # r_awaddr
    # r_aw_hold
    # --------------------------------------------------------

    tb.axi.write_if.w_channel.set_pause_generator(
        pause_for_cycles(8)
    )

    resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_A,
            to_u32(test_value)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    # Read back
    read_resp = await with_timeout(
        tb.axi.read(
            ADDR_DATA_A,
            4
        ),
        5,
        "us"
    )

    assert from_u32(read_resp.data) == test_value

    dut._log.info(
        "TEST 8 PASS: AW before W"
    )


# ============================================================
# TEST 9
#
# W arrives before AW
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_w_before_aw(dut):

    tb = TB(dut)

    await tb.reset()

    test_value = 0x55AA1234

    # --------------------------------------------------------
    # Delay AW channel
    #
    # W should be accepted first and stored in:
    #
    # r_wdata
    # r_wstrb
    # r_w_hold
    # --------------------------------------------------------

    tb.axi.write_if.aw_channel.set_pause_generator(
        pause_for_cycles(8)
    )

    resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_B,
            to_u32(test_value)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    read_resp = await with_timeout(
        tb.axi.read(
            ADDR_DATA_B,
            4
        ),
        5,
        "us"
    )

    assert from_u32(read_resp.data) == test_value

    dut._log.info(
        "TEST 9 PASS: W before AW"
    )


# ============================================================
# TEST 10
#
# BREADY Backpressure
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_bready_backpressure(dut):

    tb = TB(dut)

    await tb.reset()

    test_value = 0xDEADBEEF

    # --------------------------------------------------------
    # Master refuses B response for 30 cycles
    #
    # DUT must hold:
    #
    # BVALID = 1
    # BRESP stable
    # --------------------------------------------------------

    tb.axi.write_if.b_channel.set_pause_generator(
        pause_for_cycles(30)
    )

    write_task = cocotb.start_soon(
        tb.axi.write(
            ADDR_DATA_A,
            to_u32(test_value)
        )
    )

    # Wait until DUT produces BVALID
    await wait_until_high(
        dut.s_axil_bvalid,
        dut.aclk
    )

    expected_bresp = int(
        dut.s_axil_bresp.value
    )

    # During backpressure BVALID and BRESP must remain stable
    for _ in range(5):

        await RisingEdge(dut.aclk)
        await ReadOnly()

        assert int(dut.s_axil_bvalid.value) == 1, \
            "BVALID dropped before BREADY handshake"

        assert int(dut.s_axil_bresp.value) == expected_bresp, \
            "BRESP changed while BVALID was waiting"

    # Eventually pause generator releases BREADY
    resp = await with_timeout(
        write_task,
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    dut._log.info(
        "TEST 10 PASS: BREADY backpressure"
    )


# ============================================================
# TEST 11
#
# RREADY Backpressure
# ============================================================

@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_rready_backpressure(dut):

    tb = TB(dut)

    await tb.reset()

    test_value = 0x1234ABCD

    # First put known data into DATA_A
    resp = await with_timeout(
        tb.axi.write(
            ADDR_DATA_A,
            to_u32(test_value)
        ),
        5,
        "us"
    )

    assert resp.resp == AxiResp.OKAY

    # --------------------------------------------------------
    # Master refuses R response for 30 cycles
    #
    # DUT must hold:
    #
    # RVALID
    # RDATA
    # RRESP
    # --------------------------------------------------------

    tb.axi.read_if.r_channel.set_pause_generator(
        pause_for_cycles(30)
    )

    read_task = cocotb.start_soon(
        tb.axi.read(
            ADDR_DATA_A,
            4
        )
    )

    await wait_until_high(
        dut.s_axil_rvalid,
        dut.aclk
    )

    expected_rdata = int(
        dut.s_axil_rdata.value
    )

    expected_rresp = int(
        dut.s_axil_rresp.value
    )

    # Check that payload remains stable while stalled
    for _ in range(5):

        await RisingEdge(dut.aclk)
        await ReadOnly()

        assert int(dut.s_axil_rvalid.value) == 1, \
            "RVALID dropped before RREADY handshake"

        assert int(dut.s_axil_rdata.value) == expected_rdata, \
            "RDATA changed while RVALID was waiting"

        assert int(dut.s_axil_rresp.value) == expected_rresp, \
            "RRESP changed while RVALID was waiting"

    read_resp = await with_timeout(
        read_task,
        5,
        "us"
    )

    assert read_resp.resp == AxiResp.OKAY

    read_value = from_u32(
        read_resp.data
    )

    assert read_value == test_value, \
        (
            f"Backpressure read mismatch: "
            f"expected 0x{test_value:08X}, "
            f"got 0x{read_value:08X}"
        )

    dut._log.info(
        "TEST 11 PASS: RREADY backpressure"
    )