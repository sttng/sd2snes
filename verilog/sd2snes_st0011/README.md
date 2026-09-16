# sd2snes_st0011 — dedicated ST011 core

uPD96050 core for **ST011 only** (Hayazashi Nidan Morita Shougi 2).
Targets **mk2 (Spartan-3 XC3S400)** and **mk3 (Cyclone IV EP4CE15)**.

**ST010 is not supported by this core and must not be routed to it.**
ST010 stays on `sd2snes_dsp`, which is untouched by any of this work.
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

## What was removed, and why it matters

**MSU-1.** 8 BRAM on mk2, 16 M9K on mk3. No ST011 cart uses it.
`msu.v` and `msu_databuf` are gone; the `msu_*` nets, `address.v`'s
`msu_enable` decode and `mcu_cmd.v`'s MSU registers are deliberately left
in place — they are shared modules, the MCU never sets `FEAT_MSU1` here,
and synthesis prunes the unreachable logic. The three signals the module
used to drive are tied off in `main.v`.

**`upd77c25_pgmrom` was removed and then put back.** The reasoning for
removing it was that this core fetches its 16384-word program externally
and never reads the on-chip 2048-word ROM. True once `ext_pgm_en` is high
-- but with the ROM gone there is no opcode source at all while that bit
is low, which includes the window between FPGA configuration and the MCU's
feature write. It is back, and `opcode_w` is the original
`ext_pgm_en ? ext_pgm_dout : pgm_doutb` mux again.

Dropping MSU-1 alone is enough to fit the mk2.

## mk2 budget (XC3S400 — 16 RAMB16 of 18 Kbit)

```
cache_data_lo    4096 x 18    4
cache_data_hi    4096 x  9    2
upd77c25_datram  2048 x 16    2
upd77c25_datrom  2048 x 16    2
upd77c25_pgmrom  2048 x 24    3
dac_buf          2048 x  8    1
snescmd_buf      1024 x  8    1
                             15 of 16
```

One spare -- tight. `dac_buf` is the next candidate if more is needed (see
below); removing it would give three. Note this only works at `CACHE_BITS = 12`: at 8192 entries the
cache alone is 12 BRAM and the total is 18, over the device. mk3 comes to
roughly 29 of 56.

`dac_buf` is a further 1 BRAM that is also dead without MSU-1 audio —
removing `dac.v` is available if the margin is ever needed, but it touches
pin wiring in `main.v`, so it is left in.

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
still reports 6.01 cycles/instruction with 64/64 bytes consumed. mk2 has
not been elaborated because the vendor IP wrappers are stale as described
above; that is the first thing to resolve.

## Simulation

`sim/` holds `extpgm_tb.v`, `st011_rate_tb.v`, `miss_latency_tb.v` and
`ip_stubs.v` (behavioural memories — simulation only, do not add to the
project). See `docs/STATUS.md` in the working package for what each proves.

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


## MSU-1 audio DAC removed

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


## On-chip program ROM removed

`upd77c25_pgmrom` is gone from both targets: 4 RAMB16 on mk2, 6 M9K on mk3.
It holds 2048 words for DSP1-4; this core's program is 16384 words and always
arrives through the external fetch path, so it was never read.

This was removed once before and put back, on the theory that it left no
opcode source while `ext_pgm_en` is low. That turned out to be wrong -- the
failure at the time was a firmware endianness mix-up, and the window does not
exist: `mcu_cmd.v` powers up with `dspx_reset_out = 1`, `main.v` wires
`.RST(~dspx_reset)`, and the MCU only releases reset after the feature write
and the firmware load.

Because that safety depends on reset ORDERING rather than on anything local,
the cold-start gates in `upd77c25.v` were tightened at the same time. They
now require `ext_pgm_en & ext_pgm_ready` instead of treating "external fetch
disabled" as "ready to run". If the reset ordering is ever changed, the core
stalls at pc=0 rather than executing whatever `ext_pgm_dout` happens to hold.
Verified in simulation: with `ext_pgm_en` tied low and the core out of reset,
pc stays at 0 for 2000 clocks.

## Call stack: 16 entries (a reduction to 8 was tried and REVERTED)

`stack` was 16 entries with a 4-bit `regs_sp`. The uPD96050's call stack is
8 deep; 16 was arbitrary on my part and cost a 16-entry x 14-bit mux on
every read -- `pc_next` selects from it combinationally for RT, and
`regs_sp<0>` was the endpoint of the worst-failing CLK21 path on the mk2
XC3S400 (-9.855 ns against a 10.412 ns budget).

REVERTED. Mesen-S uses `_stackSize = 8` for ST010/ST011, but ares allocates
16 for every uPD7725/uPD96050 revision, so the two references disagree on
this. The error is asymmetric: a stack DEEPER than hardware is harmless,
while one SHALLOWER silently corrupts return addresses on deep nesting --
which would present as "works for a while, then dies on a specific call
chain". Back to 16 entries / 4-bit `regs_sp`, and the savestate scan window
back to 0x34-0x53.

The timing margin the reduction was bought for is no longer needed: mk2
meets TS_CLK21 at 80% slice occupancy after the savestate and ctx removals.

An attempt to measure the firmware's true maximum call depth from the
gameplay trace was inconclusive -- naive CALL/RET counting does not balance
(the firmware appears to leave subroutines via JMPSO), giving an absurd
depth. If someone wants to settle it properly, that measurement needs to
follow the stack pointer rather than count mnemonics.

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
Their `.ngc` netlists were never generated because nothing needs them, but
the `.xise` still listed both `.xco` files as project sources, so ISE tried
to resolve the netlists at every process that walks the source list:

```
WARNING:ProjectMgmt - File .../ip/mk2/chipscope_ila.ngc is missing.
```

Harmless, but repeated dozens of times and it buries real warnings. Both
cores are now out of the `.xise`. The files are still in `ip/mk2/`, so a
MK2_DEBUG build just needs them added back as CoreGen sources and generated.

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

## Savestate context capture (ctx.v) removed

`ctx.v` snoops the SNES bus continuously to capture CPU/PPU state for
savestates. This core never takes savestates -- `savestate.c` gates
`dsp_ok` on `fpga_conf == FPGA_DSP` and this loads as `FPGA_ST0011` -- so it
was live logic that could never be reached, in a design at 89% slice
occupancy with TS_CLK21 unmet.

Unlike the scan port there is no enable to tie off: ctx.v has no such input.
It is removed outright and its outputs tied to constants in `main.v`. Its
three `OE_*_ENABLE` outputs were connected nowhere else, so the only real
consumers were the PSRAM arbiter ports (`CTX_WRQ` / `CTX_ADDR` / `CTX_DOUT`
/ `CTX_WORD`), now constant. `CTX_RDY` is an arbiter output that simply goes
unread.

Removed from VSRC, main.qsf and the .xise as well as the file itself.

## Loop buffer

`upd77c25_extpgm.v` now holds an 8-entry fully-associative buffer of
recently-fetched words, in flip-flops (no block RAM). It is checked in
parallel with the cache and hits with zero latency.

The direct-mapped cache is prewarmed over words 0..(2^CACHE_BITS-1) only;
anything above that both misses and evicts a prewarmed entry through index
aliasing. Growing the cache does not fit -- 8192 entries needs 12 RAMB16 on
mk2 against the 6 in use. But the requirement is not "hold the program", it
is "hold the transfer loop during a transfer": of the 382 real-time windows
in the reference trace, 380 execute exactly four consecutive words.

Sized 8, not 16: it is a combinational compare feeding `ready`, and mk2 only
just closed timing. `LOOPBUF_ENTRIES` is a parameter on `upd77c25` (0
disables) if the fitter turns out to have room, or if it costs too much.

VERIFIED: the mechanism works -- probed over a run, 62,774 hit cycles across
10,463 instruction fetches with entries correctly populated.
NOT VERIFIED: that it fixes anything. The rate testbench's program is six
words at low addresses, so its cache never thrashes and the buffer has
nothing to contribute there. Demonstrating the benefit needs a test whose
hot loop sits above the prewarm range.

## (RESOLVED) write-invalidate bug -- kept for the record

The issue described below is FIXED. `lb_wr` is a one-shot raised by
lb_insert and consumed by the generate block next cycle, so it must be
cleared unconditionally every cycle. Its default assignment had been placed
next to `psram_rrq <= 1'b0`, which sits inside the `PGM_IN_PSRAM` branch and
therefore never executes on the Bus 2 SRAM path this design uses. `lb_wr`
latched high for the whole firmware-write sequence, and the stale pre-write
word was re-inserted the moment `wr_busy` dropped. The default now lives on
the SRAM path. extpgm_tb passes in full.

### original description

`extpgm_tb` had TWO FAILING CASES with the loop buffer enabled: after a
firmware write to an address, a refetch of that address can return the
stale pre-write word. A stale entry survives the write-invalidate and the
buffer serves it instead of the fresh word. Bypassing the buffer in the
`dout`/`ready` path makes every test pass, so the fault is in the buffer's
invalidate logic, not elsewhere.

Why it may not bite in practice: PGM_WR only occurs during firmware
download, and mcu_cmd.v holds the DSP in reset (dspx_reset_out = 1 at
power-up, released only after load_dspx), so the core is not fetching while
writes happen. That is REASONING, NOT VERIFICATION -- treat it as a risk,
not a clearance.

To disable the buffer and get a build that passes everything, set
`LOOPBUF_ENTRIES = 0`... no: that leaves `reg [-1:0]` and is malformed.
Instead bypass it in the two places it is read:

    assign ready = ~enable | (((pc_last_done == pc) | cache_hit_now)
                              & ~wr_busy & ~prewarm_active);
    assign dout  = (pc_last_done == pc) ? dout_r : cache_rdata;

That reproduces the previous package's behaviour exactly.


## Why the loop buffer is the right fix (measured)

From a full 56.5 GB / 1.449 billion instruction gameplay trace:

```
real-time windows                            128,988
  executing above word 4095                        0
distinct words per window       4: 128,932    7: 56
minimum host-access gap                            8 instructions
high-address execution (word > 4095)      19,795,689
  landing on cache entries 0-1023 (the hot region)  7,513,442  (38%)
```

The transfer loops never leave the prewarmed region -- so the buffer is NOT
about covering high addresses, which was the original (wrong) justification.
Its value is EVICTION IMMUNITY. Rarely-executed high code aliases onto the
hot entries and evicts them:

```
evictions of entries 242-247 (outbound loop w243-246) : 75,560
evictions of entries   0-  3 (idle / command entry)   : 64,306
evictions of entries 196-200 (inbound loop w197-200)  :    216
   words 12484-12488 alias exactly onto entries 196-200
```

A command runs high code -> the transfer loop's cache entries are evicted ->
the next transfer enters cold -> each refetch costs 31 cycles inside a 372ns
byte slot -> a byte is dropped -> the loop counter never reaches zero ->
freeze. Rare, because eviction and transfer have to coincide.

Once the loop's words are in the buffer they stay: inserts only happen on
demand fetches, and a resident loop stops generating them. That is immunity
from exactly this mechanism.

CACHE_BITS stays 12 on BOTH targets, deliberately, to keep mk2 and mk3
identical. CACHE_BITS=13 would cut hot-region evictions from 7.5M to 1.87M
but only fits mk3, and divergence is not worth that here now that the buffer
addresses the mechanism directly.

## OV1 / S1 semantics corrected (confirmed against three emulators)

STATUS: FIXED. ares, Mesen-S and MesenCE all implement the same rule and
this core now matches it.

The core previously implemented nocash's earlier description of the uPD7725 overflow
flags -- "S1 = sign on overflow, OV1 = toggle on overflow" -- which the
NESdev uPD7725 overflow thread establishes is wrong, and which nocash
himself conceded there. The correct rule is AWJ's truth table, which higan
and MAME converged on:

    if(!ov1) s1 = s0;                          // BEFORE ov1 is recalculated
    ov1 = (ov0 & ov1) ? (s0 == s1) : (ov0 | ov1);

CONFIRMED against both emulator sources, not just the forum thread:

  ares  component/processor/upd96050/instructions.cpp, execOP():
      flag.s0 = r & 0x8000;
      if(!flag.ov1) flag.s1 = flag.s0;
      ...
      flag.ov1 = flag.ov0 & flag.ov1 ? flag.s0 == flag.s1
                                     : flag.ov0 | flag.ov1;

  Mesen-S  Core/NecDsp.cpp, RunApuOp():
      flags.Sign0 = (result & 0x8000) >> 15;
      if(!flags.Overflow1) { flags.Sign1 = flags.Sign0; }
      ...
      if(flags.Overflow0 && flags.Overflow1) {
        flags.Overflow1 = flags.Sign0 == flags.Sign1;
      } else { flags.Overflow1 |= flags.Overflow0; }

In both, the S1 guard sits BEFORE the per-ALU switch, so it applies to the
logical/shift ops as well -- which is the third correction made here.

Three differences from what was implemented:

  * S1 updates when the OLD OV1 is clear, regardless of whether OV0 is set.
    Previously it updated only on overflow.
  * Two overflows in the SAME direction must leave OV1 SET. A plain toggle
    clears it. This is the case the thread singles out -- the chip has to
    distinguish same-direction from opposite-direction overflows to report
    the right state after three operations.
  * Logical/shift ops must also respect the `if(!ov1)` guard on S1. S1 is
    "direction of last overflow" and has to survive ops that cannot
    overflow; it was being overwritten unconditionally.

Why this matters here: S1 is read by JSA0 / JSB0 / JNSB0, which the ST011
firmware executes ~167,000 times in the full gameplay trace, essentially all
of it in the high-address code that runs during move processing. A wrong S1
sends those branches the wrong way in rarely-exercised code -- which matches
a freeze that appears after a few moves rather than immediately, and that no
testbench here would have caught.

`sim/flags_tb.v` covers it: same-direction overflows, opposite-direction,
three in a row, non-overflowing ops preserving S1, S1 tracking sign while
OV1 is clear, plus 2000 randomised steps against the reference.


### A wrong revert, recorded

This fix was briefly reverted because a scan of the MesenCE trace appeared
to show a plain toggle (1,887 of 1,888 disputed cases). That scan was wrong.
MesenCE's own source has the same rule as ares and Mesen-S:

```
Core/SNES/Coprocessors/DSP/NecDsp.cpp
  347  if(!flags.Overflow1) { flags.Sign1 = flags.Sign0; }
  373  if(flags.Overflow0 && flags.Overflow1) {
  374      flags.Overflow1 = flags.Sign0 == flags.Sign1;
  376  } else { flags.Overflow1 |= flags.Overflow0; }
```

and its trace flag string is C Z V(ov0) V(ov1) N(s0) N(s1)
(NecDspTraceLogger.cpp:53) -- exactly the layout the scan assumed, so layout
was not the error. The cause of the bad scan result was never identified.

Lesson: the scan inferred op type and accumulator select from trace text
rather than decoding opcodes. A correct version must decode each PC's opcode
from st011.rom and filter to ALU 4-9. Source beats inference.
