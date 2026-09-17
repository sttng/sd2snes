# sd2snes_st0011 — dedicated ST011 core

uPD96050 core for **ST011 only** (Hayazashi Nidan Morita Shougi).
Targets **mk2 (Spartan-3 XC3S400)** and **mk3 (Cyclone IV EP4CE15)** from one
source tree.

**Status: working on mk2 and mk3.** The game plays through the move/capture
sequence that previously froze. Both targets use identical parameters.

## ST010 is not supported

ST010 stays on `sd2snes_dsp`, which is untouched by this work. `smc.c`
selects the core: ST010 keeps `fpga_conf = FPGA_DSP`, ST011 gets
`FPGA_ST0011`. The two chips are separated by core, not by featurebit —
there is no free bit (see `fpga_spi.h`), so this core still keys its bus
decode and external-fetch enable off `FEAT_ST0010`, which here means
"uPD96050 present". `load_dspx()` loads a different firmware geometry and
byte order for each chip, so an ST010 cart on this core would get the wrong
image.

## How it works

### Program fetch (`upd77c25_extpgm.v`)

The ST011 program is 16384 24-bit words, too large for on-chip memory. The
MCU downloads it (`PGM_WR`, `$E9`) into the board's Bus 2 SRAM while the DSP
is held in reset. Each fetch is served from the fastest source that has it:

```
loop buffer   8 recent words, flip-flops, zero latency
cache         4096 entries, direct-mapped block RAM, prewarmed with words
              0..4095 after the download; a hit costs no stall cycles
Bus 2 SRAM    ~31 cycles per word (3 bytes, 45 ns part)
```

### Why speed matters: DMA transfers

The game polls SR for commands, but moves bulk data through DR by **DMA**
with no handshake: a byte lands every ~370 ns whether or not the DSP has
consumed the previous one. The transfer loops (words 197–200 inbound,
243–247 outbound) take 4 instructions per byte. A byte that is overwritten
before it is read is lost, the loop counter never reaches zero, and the DSP
waits forever.

At 96 MHz a cached instruction takes 6 cycles (62.5 ns), about 6 per byte
slot. An SRAM fetch takes a whole slot, so the transfer code must never
miss. Four mechanisms ensure that:

- **`SKIP_ALU2`, `PC_LOOKAHEAD`** — 6 cycles per instruction; the next PC is
  looked up in the cache one cycle early.
- **Prewarm** — words 0..4095 are cached before the game first uses the
  DSP, so the first transfer is not cold.
- **Cache pinning** (`PIN_WORDS = 256`) — words above 4095 may not overwrite
  cache slots 0–255. Every word executed during a DMA transfer is in that
  range (0–2, 31, 197–200, 243–247). Without pinning, a routine at words
  12485–12490 evicts slots 197–202 by aliasing, the next inbound transfer
  misses on its first pass and drops a byte: this was the "freeze on
  capturing a piece".
- **Loop buffer** — tight loops outside the cache (high addresses, or
  aliasing onto pinned slots) run at full speed after their first iteration.

## Removed relative to `sd2snes_dsp`

| Removed | Saved | Notes |
|---|---|---|
| MSU-1 (`msu.v`, `msu_databuf`) | 8 RAMB16 / 16 M9K | outputs tied off in `main.v`; shared `msu_*` nets and `mcu_cmd.v` registers left in, pruned by synthesis |
| MSU-1 audio DAC (`dac.v`, `dac_buf`) | 1 RAMB16 / 2 M9K | DAC pins driven to silent idle, `DAC_STATUS` tied low |
| On-chip program ROM (`upd77c25_pgmrom`) | 4 RAMB16 / 6 M9K | never read; see reset ordering below |
| Savestate context capture (`ctx.v`) | logic | PSRAM arbiter ports tied off |
| Savestate scan port | logic | tied off in `main.v` (`ss_window_en = ss_halt = 0`), not deleted: the `ss_*` signals feed the data RAM write path, and constant folding removes the overlay without touching it |
| ChipScope | — | removed from the `.xise` only; files remain in `ip/mk2/` for `MK2_DEBUG` builds |

This core cannot fold back into `sd2snes_dsp`: it only fits mk2 without MSU-1.

**Reset ordering (why no program ROM is safe).** `mcu_cmd.v` powers up with
`dspx_reset_out = 1` and `main.v` wires `.RST(~dspx_reset)`, so the DSP stays
in reset until after the feature write and firmware load. The cold-start
gates in `upd77c25.v` also require `ext_pgm_en & ext_pgm_ready`, so if that
ordering ever changes the core stalls at pc=0 instead of executing garbage.

## Block RAM (mk2, XC3S400, 16 RAMB16)

```
cache_data_lo    4096 x 18    4
cache_data_hi    4096 x  9    2
upd77c25_datram  2048 x 16    2
upd77c25_datrom  2048 x 16    2
snescmd_buf      1024 x  8    1
                             11
```

The last mk2 build reported 13 of 16 RAMB16 and 80% slice occupancy, with
TS_CLK21 met. `CACHE_BITS = 13` would need 12 RAMB16 for the cache alone and
does not fit mk2; it is kept at 12 on mk3 too so both targets behave
identically.

## Configuration

```
upd77c25.v         SKIP_ALU2=1  PC_LOOKAHEAD=1  PREWARM_ENABLE=1
                   LOOPBUF_ENTRIES=8  READ_VERIFY=0
                   stack 16 entries, regs_sp 4 bits
upd77c25_extpgm.v  CACHE_BITS=12  PIN_WORDS=256  PGM_IN_PSRAM=0
mcu/smc.c          ST0011_WAITSTATES 0
```

- `READ_VERIFY=1` doubles the cost of a miss (31 → 60.5 cycles); keep 0.
- `PGM_IN_PSRAM=1` selects an unfinished PSRAM fetch path that fails its
  own testbench; keep 0.
- Raise `PIN_WORDS` only if some firmware's real-time code sits above 255.

## Building

### mk2 (ISE)

- **Regenerate the CoreGen IP.** The `.ngc` netlists are not shipped. `make`
  regenerates them from the `.xco` files (rule in `common.mk`); the ISE GUI
  does not, and `ngdbuild` then fails with `NgdBuild:604 ... could not be
  resolved`. From the GUI, first run
  `coregen -p ip/mk2 -b ip/mk2/<core>.xco -r` for `snescmd_buf`,
  `upd77c25_datram` and `upd77c25_datrom`.
- The data RAM/ROM `.xco` files are sized for the uPD96050: `datram`
  2048 x 16 (port B 4096 x 8), `datrom` 2048 x 16.
- `main.ucf`: the Bus 2 SRAM pins (`RAM_ADDR`, `RAM_DATA`, `RAM_OE`,
  `RAM_WE`) are enabled; upstream `sd2snes_dsp` ships them commented out.
- Map option "Map Slice Logic into Unused Block RAMs" (`-bp`) is off, so
  ISE does not spend block RAMs to save a few LUTs. The `.xise` value must
  be `non-default` to take effect; check `-bp` is absent from the command
  line in `main_map.mrp`. Cover mode stays `Area`.
- ISE requires declaration before use; Icarus does not. If XST reports
  "illegal redeclaration", a signal is used above its declaration.

Two changes exist purely for mk2 timing and are behaviour-neutral:
`stack_top` is a registered copy of `stack[regs_sp-1]`, and the SRAM byte
address (`pc_r * 3`) is registered with `pc_r`.

### mk3 (Quartus)

The Altera `altsyncram` parameters are already correct; no regeneration
needed.

## Verification

### Reference model and trace replay

`tools/iss.c` is an instruction-level uPD96050 model. Against the full
MesenCE gameplay trace (136.6 M DSP instructions) it matches every register
and flag with zero mismatches. Both replay harnesses drive the real RTL
(`upd77c25` + `upd77c25_extpgm`, including download, prewarm, cache, pinning
and loop buffer) from that trace:

- **`sim/replay_tb.v`** — the core pauses between instructions while host
  events are applied. Checks logic only. All 8,084,029 trace records:
  0 divergences.
- **`sim/replay_timed_tb.v`** — free-running; DMA bytes arrive at the real
  cadence, CPU-paced events wait for the core. Reports any DR overrun
  immediately. Without cache pinning it fails at record 3,283,498 (the
  capture freeze); with pinning, records 0–4,100,000 pass. With
  `HOST_SCALE=0.5` it reports overruns from the first transfer, confirming
  it detects them.

Pipeline (from `sd2snes_st0011/`):

```
tools/run_replay.sh st011.rom <trace>.tar.bz2 [timed|paused]
```

It builds `tools/trace_filter.c` (22.5 GB trace → ~100 MB, ~5 min), runs the
ISS to produce `stim.txt` / `recs.txt` / `evs.txt`, then simulates. Icarus
runs ~5,000 records/s: the first half of the trace takes ~50 min, all of it
~100 min.

Firmware conventions (`tools/rom2hex.py`): program words are little-endian
per 24-bit word (`f[3w+2]<<16 | f[3w+1]<<8 | f[3w]`; word 2 must be
`0x97C008`); data ROM starts at file offset `0xC000`, 2048 x 16-bit, loaded
in file order (the core applies its own byte swap).

Trace line state is *before* the instruction executes. The flag string is
`C Z V(ov0) V(ov1) N(s0) N(s1)`, uppercase = set.

### Unit testbenches

```
extpgm_tb.v          fetch unit: cache, prewarm, write hazards
st011_rate_tb.v      throughput against a fixed 372 ns DR cadence
call_ret_tb.v        CALL/RET through the registered stack top
flags_tb.v           OV1/S1 rule (mirrors the rule; does not instantiate the core)
miss_latency_tb.v    cost of one external fetch (module name: miss_tb)
ip_stubs.v           behavioural M9K (mk3) -- simulation only
ip_stubs_mk2.v       behavioural RAMB16 (mk2) -- simulation only
ip_stubs_replay.v    as ip_stubs.v, but datram port B writes land
                     (ip_stubs.v ignores them); used by the replay benches
```

```
iverilog -g2005 -DMK3 -I. -o x -s <tb> sim/<tb>.v upd77c25.v upd77c25_extpgm.v sim/ip_stubs.v && vvp x
```

## uPD96050 behaviour (verified against the trace)

- **OV1/S1:** `if(!ov1) s1 = s0;` before the per-ALU switch (logical and
  shift ops included), then for arithmetic
  `ov1 = (ov0 & ov1) ? (s0 == s1) : (ov0 | ov1)`. Same in ares, Mesen-S and
  MesenCE.
- **Carry-in** for SBB, ADC and SHL1 comes from the *other* accumulator's
  flags.
- **JMPSO** jumps to SO; ST011's command dispatch loads SO from a data ROM
  table (`SOL <- RO`) and jumps through it (word 19).
- **Stack** is 16 entries (ares); Mesen-S uses 8. Deeper than the chip is
  harmless.
- **8-bit DR writes** preserve the high byte; ST011 mixes 8-bit and 16-bit
  transfers.

### Not exercised by the trace (latent, low priority)

- `regs_m` takes `{mul_result[31], mul_result[29:15]}`; the reference takes
  bits 30:15. They differ only for K = L = −32768.
- SBB/ADC carry-out uses plain `r > q` / `r < q`, which is wrong when the
  carry-in makes `r == q`.
- A host DR access has priority over the DSP's own RQM/DR update in the
  same clock cycle.
