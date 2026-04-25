# sd2snes-spc7110

A fork of [ikari\_01's sd2snes firmware](https://github.com/mrehkopf/sd2snes)
that adds SPC7110 coprocessor support, ported from the
[MiSTer SNES core](https://github.com/MiSTer-devel/SNES_MiSTer) by srg320.

The SPC7110 is used by only three commercially released games:

* Tengai Makyou Zero (JP retail; English fan translation; Shounen Jump magazine variant)
* Super Power League 4
* Momotarou Dentetsu Happy

These games have not previously been playable on real SNES hardware
via SD2SNES.

## Status

**Not maintained.** This is the state of my work as of April 2026.
I am not accepting issues, pull requests, or bug reports. Fork freely
as a base for your own work.

## What works

* All five test ROMs boot to gameplay with correct graphics
* SPC7110 self-check program (V2.2 \& V3.0) passes MODE 1 and MODE 2
* SaveRAM persists correctly across power cycles
* RTC4513 functional in Tengai Makyou Zero ROMs
* QUsb2Snes / SNI reset functional
* Tested stable for multi-hour gameplay sessions on real hardware

## What does not work

* **FXPak Pro STM32 variant**: graphical glitching reported by testers.
Cause unknown. The base firmware build for this board is supported
(`make CONFIG=config-mk3-stm32`) but the SPC7110 core triggers
issues that do not occur on LPC1756.
* **Original SD2SNES (Spartan-3A FPGA)**: not attempted. The SPC7110
core's BRAM and LE footprint may not fit. Sacrificing MSU1 support
would likely be the first step toward making it fit.

## Tested hardware

* FXPak Pro Mk.III with LPC1756 MCU (board reports "sd2snes Mk.III"
over UART)

I do not have access to the FXPak Pro STM32 variant or the original
SD2SNES, which is why those targets are unverified.

## Building

Two binaries need to be built before the firmware build will succeed:
`utils/bin2c` (top-level utils folder) and `src/utils/genhdr` and
`src/utils/lpcchksum` (separate utils folder under src). The build
references them via different relative paths.

From a Linux or WSL shell:

```
cd utils
make bin2c
cd ../src/utils
make
cd ..
make CONFIG=config-mk3
```

`make CONFIG=config-mk3` produces `firmware.im3` for LPC1756 boards.
`make CONFIG=config-mk3-stm32` produces `firmware.stm` for STM32
boards (build succeeds; runtime has issues, see above).

The FPGA bitfile lives at `verilog/sd2snes\_spc7110/`. Open
`sd2snes\_spc7110.qpf` in Quartus Prime Lite 17.0.2 and run a full
compilation. Convert the resulting `output\_files/main.rbf` to
`fpga\_spc7110.bi3` using the `rle` tool from this repository's
`utils/` folder.

Copy `firmware.im3` (or `.stm`) and `fpga\_spc7110.bi3` to the
SD card at `/sd2snes/`.

## Project layout

The SPC7110 core is contained in `verilog/sd2snes\_spc7110/`. It is a
parallel implementation alongside the existing cores
(`sd2snes\_base`, `sd2snes\_sa1`, `sd2snes\_sdd1`, etc.). The SDD1
implementation served as the architectural template.

Firmware-side changes vs. stock sd2snes are limited to two files:

* `src/smc.c`: SPC7110 cart detection at carttype 0xf5 / 0xf9
* `src/fpga.h`: bitfile path constant for the SPC7110 core

See `PORTING\_NOTES.md` for technical details on the non-obvious
decisions made during the port.

## Credits

* **ikari\_01 (mrehkopf)**: original sd2snes firmware and FPGA
framework. This work is a fork of that repository.
* **srg320**: the MiSTer SPC7110 VHDL implementation, from which
the core RTL (`SPC7110.vhd`, `SPC7110\_DEC.vhd`,
`SPC7110\_DEC\_PKG.vhd`, `SPC7110\_FIFO.vhd`, `SPC7110\_MULDIV.vhd`,
`SPC7110Map.vhd`, `RTC4513.vhd`) is derived.
* The MiSTer SNES core team for the surrounding infrastructure
and reference behaviour.

## License

The original sd2snes is released under the GNU General Public License
v2 or later. The MiSTer SPC7110 RTL is derived work under the GPL.
This fork is released under GPLv3 or later, the more restrictive of
the two upstream licenses, to ensure compatibility with both lineages.

See `LICENSE` for full terms.

