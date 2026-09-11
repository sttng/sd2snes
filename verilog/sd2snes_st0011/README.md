# sd2snes_st0011 — dedicated ST011 core

uPD96050 core for **ST011 only** (Hayazashi Nidan Morita Shougi 2).
Targets **mk2 (Spartan-3 XC3S400)** and **mk3 (Cyclone IV EP4CE15)**.

Needs 


| SHA256 Hash     | MD5 Hash | Rom file |
| -------- | ------- |----|
| 8B2B3F3F3E6E29F4D21D8BC736B400BC988B7D2214EBEE15643F01C1FEE2F364  | 5C209CE0283632B6574AD835BF862BEE    | st011.rom | 


**ST010 is not supported by this core and must not be routed to it.**
ST010 stays on `sd2snes_dsp`, which is untouched.
`smc.c` selects between them: ST010 keeps `fpga_conf = FPGA_DSP`, ST011
gets `FPGA_ST0011`. The two chips are separated by CORE, not by featurebit
— there is no free bit to split them with (see the note in `fpga_spi.h`),
so this core still keys its bus decode and external-fetch enable off
`FEAT_ST0010`, which means "uPD96050 present" rather than "this is an
ST010". Do not read that bit name as ST010 support.

The two are not interchangeable even though both are uPD96050:
`load_dspx()` loads a different firmware geometry for each, and the ST010
and ST011 firmware images are distributed in different byte orders (see
`PGM_BYTE_SWAP` in `upd77c25_extpgm.v`). Pointing an ST010 cart at this
core would load the wrong image at the wrong size.

Derived from `sd2snes_dsp` with the working ST011 fixes, minus two things
that this cart type never uses.

## What was removed


### MSU-1 audio DAC removed

**MSU-1.** 8 BRAM on mk2, 16 M9K on mk3. No ST011 cart uses it.
`msu.v` and `msu_databuf` are gone; the `msu_*` nets, `address.v`'s
`msu_enable` decode and `mcu_cmd.v`'s MSU registers are deliberately left
in place — they are shared modules, the MCU never sets `FEAT_MSU1` here,
and synthesis prunes the unreachable logic. The three signals the module
used to drive are tied off in `main.v`.

`dac.v` and `dac_buf` are gone from both mk2 and mk3. The buffer's only
source is MSU-1 audio, which this core does not have, so it was dead weight:
1 BRAM on mk2, 2 M9K on mk3. On mk2 that is the difference between 16 of 16
and 15 of 16.

`DAC_MCLK`, `DAC_LRCK` and `DAC_SDOUT` are driven to a defined idle in
`main.v` rather than left floating, so the external DAC sees a static silent
input instead of an undriven bus. `DAC_STATUS` -- one bit, per mcu_cmd.v's
port -- is tied low; it used to be driven by the dac module.

`mcu_cmd.v`'s DAC registers are deliberately left in place. It is a shared
module, the MCU never drives audio on this core, and synthesis prunes the
unreachable logic. Only the module and its buffer are removed.

mk3 total is now roughly 21 of 56.

## Before you build

**The mk2 CoreGen IP must be regenerated.** `ip/mk2/upd77c25_datram.xco`
and `upd77c25_datrom.xco` have had their depths edited from 1024/1536 to
2048 — the uPD96050 has 2 KB of data RAM and 2 KB of data ROM where the
uPD77C25 has far less. The `.xco` is the CoreGen *input*; the matching
`.v` wrapper is generated output and still describes the old geometry.
Open both in CORE Generator and regenerate before the mk2 build will be
correct. Check the `_b` port geometry too: `datram`'s B side is the SNES's
byte-wide window and wants 4096 x 8.

**mk3 IP is already correct** — the Altera `altsyncram` parameters are
plain text and were updated in the working build.

The design elaborates clean on mk3 under Icarus, and the ST011 rate test
still reports 6.01 cycles/instruction with 64/64 bytes consumed.

## Configuration

`upd77c25.v` parameters: `READ_VERIFY=0`, `PREWARM_ENABLE=1`,
`SKIP_ALU2=1`, `PC_LOOKAHEAD=1`. `ST0011_WAITSTATES` is 0 in `mcu/smc.c`.
Do not raise any of them without reading the throughput note in
`upd77c25.v` first.

---

## mk2 (Spartan-3 XC3S400) build notes

Two things had to change for mk2, beyond what mk3 needed:

**`main.ucf`: the Bus 2 SRAM constraints were commented out.** All 87
`RAM_ADDR` / `RAM_DATA` / `RAM_OE` / `RAM_WE` lines shipped disabled because
upstream `sd2snes_dsp` never used that bus. This core needs it -- the ST011
program is 16384 24-bit words, cannot fit on-chip, and is fetched from that
SRAM through `upd77c25_extpgm`. They are now live (19 address pins, 8 data,
OE, WE).

**`ip/mk2/*.xco` geometry.** The mk2 CoreGen cores were sized for the
uPD77C25, not the uPD96050:

```
                    was            now
upd77c25_datram     1024 x 16      2048 x 16  (port B 4096 x 8)
upd77c25_datrom     1536 x 16      2048 x 16
upd77c25_pgmrom     2048 x 24      2048 x 24  (unchanged)
```

**The `.ngc` netlists are not shipped; they are generated from the `.xco`.**
`common.mk` has the rule:

```
$(XIL_IPCORE_DIR)/%.ngc: $(XIL_IPCORE_DIR)/%.xco | $(XIL_IPCORE_DIR)/coregen.cgc
        coregen -p $(XIL_IPCORE_DIR) -b $< -r
```

so `make` regenerates each core -- including the resized ones -- and
overwrites the `.v` wrappers with the new geometry. Building from the ISE
GUI does NOT run that rule; if you go that route, regenerate the three
cores in CORE Generator first, or `ngdbuild` fails with

```
ERROR:NgdBuild:604 - logical block ... could not be resolved
Symbol 'upd77c25_datram' is not supported in target 'spartan3'
```

which means the netlist is missing, not that anything is wrong with the
design.

### Block RAM budget

```
cache_data_lo    4096 x 18    4
cache_data_hi    4096 x  9    2
upd77c25_datram  2048 x 16    2
upd77c25_datrom  2048 x 16    2
snescmd_buf      1024 x  8    1
                             11 of 16
```

Five spare. `dac_buf` and `upd77c25_pgmrom` have both been removed (see
below). `CACHE_BITS` cannot go below 12 without giving up the prewarm
coverage the ST011 transfer loops depend on.

Note this only fits because MSU-1 is absent (8 BRAM). It will not fold back
into `sd2snes_dsp`.


## Call stack reduced to 8 entries

`stack` was 16 entries with a 4-bit `regs_sp`. The uPD96050's call stack is
8 deep; 16 was arbitrary on my part and cost a 16-entry x 14-bit mux on
every read -- `pc_next` selects from it combinationally for RT, and
`regs_sp<0>` was the endpoint of the worst-failing CLK21 path on the mk2
XC3S400 (-9.855 ns against a 10.412 ns budget).

Now 8 entries, `regs_sp` 3 bits. Firmware that nests calls deeper than 8
would behave differently -- but so would real hardware, which wraps at 8,
so this is closer to the chip rather than further from it.

The savestate scan window moved with it: 0x34-0x53 (16 entries x 2 bytes)
-> 0x34-0x43 (8 x 2). Left at the old size, scan addresses in the upper
half would alias onto entries 0-7 through the now-3-bit index and corrupt
them on a write. This core never takes savestates -- savestate.c gates
dsp_ok on fpga_conf == FPGA_DSP -- but a latent aliasing write is not
worth leaving in.

Note this is one of two levers identified from the mk2 timing report; the
other, removing the savestate scan port entirely, is untouched. See the
timing notes above.

## Savestate scan port disabled

The scan overlay in `upd77c25.v` -- the register window inside
`$68-$6F`, the boundary-gated freeze, the stack/accumulator readout mux --
exists for DSP1-4. ST011 never uses it: `savestate.c` gates `dsp_ok` on
`fpga_conf == FPGA_DSP`, and this core loads as `FPGA_ST0011`.

It was gated on `featurebits[0]` (FEAT_DSPX), a *runtime* signal, so
synthesis could not prune it even though that bit is always 0 here -- the
whole overlay was being built and placed. It was also on the worst-failing
CLK21 path on the mk2 XC3S400:

```
SNES_ADDR_4 -> ss_reg_do_cmp_ge0000 -> ss_reg_do_and0000
            -> stack -> regs_sp        -9.855 ns
```

`main.v` now ties `ss_window_en` and `ss_halt` to constants, which lets
constant folding remove the overlay entirely.

**Why tied off rather than deleted.** The `ss_*` signals are interlocked
with the live data-RAM path: `ram_web` and `ram_wea` both reference them,
and that window is the one the SNES actually uses to talk to the DSP.
Cutting the logic out by hand risks changing behaviour there for no gain,
since constant folding produces the same netlist. With `ss_window_en = 0`:
`ss_ctrl` and `ss_regwin` fold to 0, so `ram_web` reduces to
`reg_we_rising & DP_enable`; `ss_halt_eff` folds to 0, so `ss_frozen`
stays 0 and `ram_wea` is unaffected. The data-RAM window is untouched.

## Timing: SRAM address multiply registered

`pc_r_byte0` (= pc_r * 3, the byte address of a 24-bit word) was computed
combinationally and then had +1 / +2 added for the second and third bytes,
putting a 17-bit carry chain between `pc_r` and `RAM_ADDR` in one cycle.
After the scan-port removal this was the worst remaining CLK21 path on mk2,
at -0.287 ns.

`pc_r` is loaded one cycle before `RAM_ADDR` is driven, so the multiply is
now registered alongside every `pc_r` load. No extra cycle, no behavioural
change -- it just moves the arithmetic off the critical tail.


## Map cost model: Area -> Speed

The map report showed the mapper spending block RAMs to absorb LUTs:

```
INFO:MapLib:332 - In total, 16 LUTs were mapped to 3 Block RAMs.
RAMB16 "BRAM_snes_ctx/IS_APU_RAM_r"
RAMB16 "BRAM_snes_dspx/regs_rp_10"
RAMB16 "BRAM_snes_mcu_cmd/MCU_DATA_IN_BUF_0"
```

Three RAMB16s to save sixteen LUTs. On this device that trade is backwards:
after the savestate removal, LUTs are at 74% while block RAM is at 100%, so
those three blocks are the difference between 16/16 and 13/16.

The control for this is NOT the cover mode -- that governs LUT covering, not
block-RAM inference. Switching to `-cm speed` was tried and changed nothing
here except costing 130 slices (86% -> 90%), so the cover mode is back to
`Area`.

The actual option is `Map Slice Logic into Unused Block RAMs`, which appears
on the map command line as `-bp`. It is now `false`, which should return the
3 absorbed blocks and put RAMB16 at 13/16.

Note the `valueState` attribute has to be `non-default` for ISE to honour a
value at all; left at `default` it silently uses its own. The Makefile flow
picks these up automatically -- common.mk derives XILINX_MAP_OPTS from the
.xise via xgenmapcmd.tcl -- so both flows agree. Confirm by checking that
`-bp` is absent from the command line at the top of main_map.mrp.

## ChipScope removed from the project (files kept)

`chipscope_icon` and `chipscope_ila` are only instantiated under
`` `ifdef MK2_DEBUG `` -- on-chip debug logic, not part of a normal build.

## Timing: stack top registered

After the block-RAM absorption was turned off and the cache arrays were free
to move, the worst CLK21 path on mk2 became:

```
Msub__COND_34 (regs_sp-1) -> extpgm/Mram_cache_data_lo3.B    -1.341 ns
stack<2>                  -> extpgm/Mram_cache_data_lo3.B    -0.998 ns
```

PC_LOOKAHEAD publishes `pc_next` straight into the fetch unit's cache
address, so the whole expression -- op decode, cond_true, the `regs_sp-1`
subtract and the 8-entry stack mux -- sat combinationally in front of a
block RAM address pin.

`stack_top` is now a registered copy of `stack[regs_sp-1]`, which takes the
subtract and the mux off that path. Safe because `regs_sp` and `stack` only
change at the STATE_STORE edge and the next STATE_STORE is six cycles later,
so it is always settled before `pc_next` uses it.

`sim/call_ret_tb.v` was added specifically for this: no other testbench
executes RT, and a stale stack top would return to the wrong address
silently. It checks CALL -> RET -> resume at CALL+1, and passes both with
the registered read and with the original combinational one.
