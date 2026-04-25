# SPC7110 Port: Technical Notes

This document records the non-obvious decisions made during the port
of the MiSTer SPC7110 core into the SD2SNES/FXPak Pro firmware. It
exists for anyone reading the code who wonders why a particular
choice was made. None of these are speculative; each was discovered
by debugging real test ROMs on real hardware.

## Target hardware

  - Cyclone IV EP4CE15F17C8 FPGA, 96 MHz system clock
  - 70 ns asynchronous PSRAM holding ROM data and BSRAM
  - LPC1756 MCU on the FXPak Pro Mk.III board

The MiSTer SPC7110 core was originally designed for a ~21 MHz
internal clock. Running it at 96 MHz on the Cyclone IV requires
careful attention to clock-enable gating; see "DEC clock enable"
below.

## The +1 bank shift on DROM addresses is correct

`SPC7110Map.vhd` adds 1 to the bank portion of all DROM
(decompression ROM, banks 0x40 onwards) addresses before they reach
the wrapper. This looked wrong on first inspection and was the
subject of multiple debugging passes. It is correct.

The shift exists because the SPC7110 mapping presents DROM starting
at SNES bank 0x40, but the ROM file's DROM region begins at offset
0x100000 within the file (which the wrapper sees as PSRAM bank 1).
The +1 compensates. Do not "fix" it.

## BSRAM must initialise to 0xFF, not 0x00

`spc7110_bsram_init.mif` initialises the BSRAM block to all 0xFF
bytes. This matches the behaviour of a factory-fresh cartridge
(uninitialised SRAM after long power-off reads as 0xFF on the
SPC7110). Initialising to 0x00 causes the SPC7110 self-check program
to fail on the S-RAM tests because the test relies on detecting an
"empty" cartridge state.

## Warm reset detection via reset vector fetch

The SD2SNES board does not route a dedicated reset wire from the
SNES to the FPGA's coprocessor logic. To detect a warm reset
(user pressing the SNES reset button), the wrapper watches for a
read at `$00:FFFC` (the 6502 reset vector). This is the first thing
the CPU does after reset, and it's idempotent enough to use as a
reliable trigger.

In `main.v`:

```
wire snes_reset_vector_fetch = ~SNES_READ & (SNES_ADDR == 24'h00FFFC);
reg [2:0] spc_rst_shift;
// ... shift register extends the single-cycle pulse over several cycles ...
wire spc_warm_reset = (spc_rst_shift != 3'b000);
wire spc7110_rst_n = ~(SNES_DEADr | spc_warm_reset);
```

The single-cycle reset-vector fetch sets `spc_rst_shift` to all-ones,
which then counts down. `spc_warm_reset` stays asserted for the full
count, holding the SPC7110 core in reset long enough for the core's
internal state to clear.

## Step 17: MCU bus contention during DROM transactions

The biggest single fix in the port. The SD2SNES PSRAM bus is shared
between the SNES (via the SPC7110 core's DROM reads) and the MCU
(for SD card streaming, register access, etc.). The original wrapper
gave MCU accesses priority via a simple `MCU_HIT ?` term in the
PSRAM mux.

This was fine for MODE 1 of the self-check but fatal for the
SPC7110's decompressor, which fires back-to-back DROM reads at high
rate from its FIFO. Even one MCU preemption mid-transaction
corrupts the data the decompressor receives. Across hundreds of
sequential reads, the corruption rate is catastrophic for the
stateful decoder.

The fix has three parts:

  1. **A "DROM window" signal** combining SPC7110_DROM_PENDING
     (raised inside SPC7110Map the moment the core knows it needs
     DROM, even before the bus transaction starts) with the
     SPC7110_ROM_IS_DROM level signal that's high during the
     transaction itself.

  2. **A 16-cycle tail counter** (`spc_busy_tail`) that keeps the
     window asserted for a few cycles after the transaction
     completes, covering the asynchronous PSRAM's hold time.

  3. **PSRAM mux priority inversion**: inside the DROM window, the
     `SPC7110_ROM_IS_DROM ?` cases are placed *above* the
     `MCU_HIT ?` cases in the priority encoder, so SPC7110 wins.
     ROM_BHE/ROM_BLE are forced to 16-bit mode during DROM to
     prevent byte-lane masking from dropping the byte the core
     wants.

The MCU is held off the bus during the entire window. This costs
some SD card streaming throughput but is necessary for graphics
correctness.

## Step 22a: BSRAM must not route through SPC7110Map

The original sd2snes wrapper has `IS_ROM` and `IS_SAVERAM` decode
signals that determine whether a SNES access targets ROM (PSRAM-
backed) or saveram (PSRAM-backed BSRAM region). The SPC7110 core
also has its own internal BSRAM port driven by the
`spc7110_bsram_init.mif` block.

If both paths are enabled simultaneously, saveram writes go to
the SPC7110's internal BRAM port (small, ephemeral) instead of
the wrapper's PSRAM-backed BSRAM (large, persisted to SD card).
Saves don't survive power cycles.

The fix: explicitly exclude `IS_SAVERAM` from `spc7110_rom_active`
so that saveram regions skip the SPC7110 core entirely and route
through the wrapper's standard BSRAM path. The SPC7110's internal
BSRAM port is left wired up but never selected by real accesses.

## Step 40: RD auto-advance must scale with DEC_MODE

The MiSTer SPC7110 VHDL had a hardcoded `+4` increment on the
`RD` (read pointer) auto-advance during decompressor output. This
worked for MODE 11 (4-bpp tile output) but not for MODE 00 (1-bpp,
+1) or MODE 01 (2-bpp, +2). Symptom: SPL4 boot menu rendered with
glitchy team logos because some sprite data is encoded in non-4bpp
modes.

Fix in `SPC7110.vhd`: replace the hardcoded constant with a case
on `DEC_MODE`:

```
case DEC_MODE is
  when "00"   => RD <= RD + 1;
  when "01"   => RD <= RD + 2;
  when others => RD <= RD + 4;  -- "10" and "11"
end case;
```

This is faithful to the real SPC7110's behaviour and fixes SPL4
graphics without breaking TMZ or MDH.

## DEC clock enable cannot be a clock gate

Naively gating `SPC7110_DEC` with a clock-enable signal causes
Quartus to emit warning 14320 and synthesises away the FIFO RAM
inside the decompressor. The synthesiser cannot prove the FIFO is
written-then-read in a stable enough pattern when its clock is
gated.

Workaround: feed `CLK` directly to `SPC7110_DEC` and instead use
edge detectors on FIFO_RD / FIFO_WR to gate the *control logic*
that fires decompressor steps. The RAM stays clocked at full speed;
the FSM advances only when needed.

## MCU bus access strategy

`MCU_HIT` is the wrapper's signal for "MCU wants the PSRAM bus
right now." Outside the DROM window (Step 17), it has full
priority over the SPC7110 core. This matches sd2snes's existing
behaviour for other coprocessors and is necessary so SD card
streaming, save loads, and reset sequences continue to work.

Inside the DROM window, MCU_HIT is blocked until the window
closes. The MCU command processor (`mcu_cmd.v`) does not need to
know about this; it sees normal back-pressure through the
existing handshaking.

## What was investigated and ruled out

  - **ROM_MASK bit-width**: hypothesis that the wrapper computed
    the ROM mask incorrectly for TMZ English (which is on a
    boundary). Counters added during Step 42 instrumentation
    showed zero out-of-range DROM accesses across 25 minutes of
    play. This hypothesis is dead.
  - **MCU firmware mapper_id**: confirmed correct at 5. The
    firmware patch (`smc.c`, `fpga.h`) is minimal and verified.
  - **SignalTap**: not available. The 14-pin header (P401) on the
    FXPak Pro Mk.III is the MCU's JTAG port, not the FPGA's. No
    FPGA JTAG header is externally accessible.

## Debug strategy used during development

In place of SignalTap, the working build used a debug intercept in
the MCU read path that diverted reads from `$F80000-$F8005F` to a
mux of in-FPGA shadow registers. Counters, last-seen-value latches,
and atomic snapshots were exposed through this window and read by
PowerShell scripts over the SNI WebSocket interface.

The shipped fork has all of this removed. There is no record of the
removed code in this repository's history (the strip happened
outside version control). If you want to add similar instrumentation
when investigating a new bug, a reasonable starting point is:

  1. In `main.v`, intercept MCU reads at some unused address range
     (e.g. `$F80000-$F8000F`) and substitute a mux of debug signals
     for `MCU_DINr`.
  2. Wire the signals you want to observe out of the VHDL core via
     additional ports and connect them through `SPC7110Map`.
  3. On the PC side, use `GetAddress` over SNI's WebSocket
     (`ws://localhost:23074`) with `Space=SNES` and
     `offset=$F80000` to read the window.

Watch out for two things: gating `SPC7110_DEC` with a clock enable
will synthesise away its FIFO RAM (Quartus warning 14320), and
multi-byte counters need atomic latching when the MCU reads the low
byte or you will see torn reads when the counters increment fast.

## Files derived from MiSTer

The following files in `verilog/sd2snes_spc7110/` are derived from
the MiSTer SNES core's SPC7110 implementation by srg320, with
modifications as documented above:

  - `SPC7110.vhd`
  - `SPC7110_DEC.vhd`
  - `SPC7110_DEC_PKG.vhd`
  - `SPC7110_FIFO.vhd`
  - `SPC7110_MULDIV.vhd`
  - `SPC7110Map.vhd`
  - `RTC4513.vhd`

`main.v`, `mcu_cmd.v`, `address.v`, and the build infrastructure
are derived from the sd2snes SDD1 core, modified to instantiate
and arbitrate around the SPC7110 core.

## Suggested next steps for anyone forking

  1. Reproduce the build on an LPC1756 board to confirm the fork
     compiles and runs as described.
  2. STM32 variant: instrument the MCU-side UART and SPI paths.
     The base firmware works on STM32, so the issue is likely in
     the SPC7110-specific timing relative to the STM32's bus
     behaviour. The block-on-IRQ UART patch attempted in earlier
     sessions helped but did not resolve.
  3. Original SD2SNES (Spartan-3A): expect to drop MSU1 first,
     then expect timing closure work below 96 MHz, then expect
     `SPC7110_MULDIV.vhd`'s LPM primitives to be the most likely
     vendor-portability hot spot. Reasonable target clock is 84
     to 90 MHz.

Good luck.
