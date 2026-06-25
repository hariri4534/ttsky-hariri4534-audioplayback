import cocotb
import random
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, ReadOnly
import logging

class QSPIFlash:
    """
    Simulates a QSPI Flash memory (e.g., W25Qxx series) as expected by the EF_QSPI_XIP_CTRL.
    Supports:
    - 0x66/0x99 Reset sequence (1-bit mode)
    - 0xEB Fast Read Quad I/O (1-4-4 mode)
    """
    def __init__(self, dut, memory=None):
        self.dut = dut
        self.line_size = 16
        self.memory = memory if memory is not None else {}
        self.log = logging.getLogger("cocotb.flash")
        self.log.setLevel(logging.INFO)
        
        # Using wires exposed in tb.v for reliable triggering in Icarus
        self.cs_n = dut.qspi_cs_n
        self.sck  = dut.qspi_sck
        self.sd0  = dut.qspi_sd0
        self.sd1  = dut.qspi_sd1
        self.sd2  = dut.qspi_sd2
        self.sd3  = dut.qspi_sd3
        self.douten = dut.qspi_douten
        self.done = dut.done

        self.addr = 0


    async def run(self):
        self.log.info("QSPI Flash simulation started")
        first_loop = True
        while True:
            # 1. Wait for CS# to fall
            await FallingEdge(self.cs_n)
            self.log.info("Flash: CS# Low")
            
            # 2. Capture Command (8 bits on SD0) only during first loop
            if (first_loop):
                cmd = 0
                for i in range(8):
                    await RisingEdge(self.sck)
                    cmd = (cmd << 1) | int(self.sd0.value)
                self.log.info(f"Flash: Command 0x{cmd:02X} received")
            else:
                self.log.info(f"Flash: Skip command loop and go straight to address")

            
            if cmd == 0xEB or not first_loop:  # Fast Read Quad I/O
                # Address (24 bits, 6 cycles, 4 bits per cycle)
                self.addr = 0
                for _ in range(6):
                    await RisingEdge(self.sck)
                    self.addr = (self.addr << 4) | self._get_nibble()
                self.log.info(f"Flash: Address 0x{self.addr:06X} received")
                
                await ClockCycles(self.sck, 6)

                self.log.info(f"Data transmission start...")
                # Data transmission (2 cycles per byte)
                for i in range(self.line_size):
                    byte = self.memory.get(self.addr, 0x00)
                    self.log.info(f"Flash: Byte 0x{byte:06X} received, Addr = {self.addr:06X}")

                    # High nibble
                    await FallingEdge(self.sck)
                    self._set_nibble(byte >> 4)
                    await FallingEdge(self.sck)
                    self._set_nibble(byte & 0x0F)

                    
                    self.addr += 1

                await ReadOnly()
                self.log.info(f"Flash: SPI controller says done = {self.done.value}")
                first_loop = False


            elif cmd == 0x66:
                self.log.info("Flash: Reset Enable received")
            elif cmd == 0x99:
                self.log.info("Flash: Reset command received")
            else:
                self.log.error(f"Flash: Unknown command 0x{cmd:02X}")

            # 3. Wait for CS# to rise
            if self.cs_n.value == 0:
                await RisingEdge(self.cs_n)
            self.log.info("Flash: CS# High")
            self._set_nibble(0, drive=False)

    def _get_nibble(self):
        nibble = 0
        if int(self.sd0.value): nibble |= 0x1
        if int(self.sd1.value): nibble |= 0x2
        if int(self.sd2.value): nibble |= 0x4
        if int(self.sd3.value): nibble |= 0x8
        return nibble

    def _set_nibble(self, nibble, drive=True):
        current = int(self.dut.uio_in.value)
        mask = (1 << 1) | (1 << 2) | (1 << 4) | (1 << 5)
        if not drive:
            self.dut.uio_in.value = current & ~mask
            return
            
        new_bits = 0
        if nibble & 0x1: new_bits |= (1 << 1)
        if nibble & 0x2: new_bits |= (1 << 2)
        if nibble & 0x4: new_bits |= (1 << 4)
        if nibble & 0x8: new_bits |= (1 << 5)
        self.dut.uio_in.value = (current & ~mask) | new_bits


async def assert_gen_read_req_ptr(dut):
    playback = dut.user_project.u_playback
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.rst_n.value == 1 and playback.gen_read_req.value == 1:
            await RisingEdge(dut.clk)
            await ReadOnly()
            assert playback.sample_ptr_q.value == 0, f"after generating read request, sample pointer must reset to 0"


async def assert_gen_read_req_to_rd_o(dut):
    if not hasattr(dut, "user_project") or not hasattr(dut.user_project, "u_playback"):
        dut._log.warning("Internal signal u_playback not found, skipping assertion check")
        return
    playback = dut.user_project.u_playback
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.rst_n.value == 1 and playback.gen_read_req.value == 1:
            await RisingEdge(dut.clk)
            await RisingEdge(dut.clk)
            await ReadOnly()
            if dut.rst_n.value == 1:
                assert playback.rd_o.value == 1, f"Assertion failed: rd_o is {playback.rd_o.value} (expected 1) in the cycle after gen_read_req was high"

async def toggle_speed(dut):
    while True:
        await ClockCycles(dut.clk, 100)
        dut.ui_in.value = random.randint(0,3)
        dut._log.info(f"playback speed changed to {dut.ui_in.value}")

@cocotb.test()
async def test_qspi(dut):
    dut._log.info("Start QSPI Simulation Test")

    # Start assertion checker
    cocotb.start_soon(assert_gen_read_req_to_rd_o(dut))
    cocotb.start_soon(toggle_speed(dut))

    # 50 MHz clock
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())

    # Pre-fill memory with some audio-like pattern (sawtooth)
    mem = {i: (i % 256) for i in range(1,1024)}
    flash = QSPIFlash(dut, mem)
    cocotb.start_soon(flash.run())

    # Initialize inputs
    dut.ena.value = 1
    dut.ui_in.value = 3
    dut._log.info(f"playback speed value is {dut.ui_in.value}")
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    # Reset duration
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    dut._log.info("Reset released")

    # Wait for the initial QSPI Reset sequence (0x66, 0x99) and the first read.
    # EF_QSPI_XIP_CTRL.v has RESET_CYCLES=999, which takes about 2000 clock cycles.
    await ClockCycles(dut.clk, 2500)

    # Check if we are getting data. 
    # The playback_ctrl should be outputting samples to uo_out[7] (via PWM)
    # and we can check the internal signals if needed.
    
    # Let's wait a bit more to see multiple line reads
    await ClockCycles(dut.clk, 100*100)
    
    dut._log.info("Finished QSPI Simulation Test")
