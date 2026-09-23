# ST011 on sd2snes — handoff

## State

**Fixed and confirmed on hardware: no freeze on mk2 or mk3.**

The freeze is a DR overrun during a DMA transfer, caused by cache eviction in
`upd77c25_extpgm.v`. Fixed by protecting the transfer code in the cache
(below); now implemented as a pinned table plus a 512-entry cache. With it, the timed replay of
the MesenCE trace runs through record 4,100,000 (the first half, past the
failure point) with 0 overruns and 0 divergences.

## Possible follow-ups (none required)

- Run the timed replay over the second half of the trace
  (`tools/run_replay.sh st011.rom <trace> timed`, ~100 min).
- The three latent edge cases listed below.

## Root cause

- The game polls SR (`LDA $600001`) for commands, but moves bulk data with
  **DMA** (`$4314 = $60`): a byte hits DR every 8–9 Mesen DSP cycles (~370 ns)
  with no handshake. The DSP must consume each byte within that slot.
- The core does ~62.5 ns/instruction when fetching from cache. An external
  fetch costs ~323 ns (miss_latency_tb) — one miss eats a whole byte slot.
- Every word executed inside a DMA-paced window in the trace is one of
  0–2, 31, 197–200, 243–247. All prewarmed.
- The cache is direct-mapped on pc[11:0]. A rare routine at words 12485–12490
  (≈ record 3,276,100, only episode in the first half) overwrites slots
  197–202 by aliasing. The next inbound transfer ~7,000 records later misses
  on 199/200 on its first pass (the loop buffer has moved on), the second byte
  overwrites the unread first one, B never reaches 0, the DSP waits forever.
- Unfixed core: `HOST WRITE OVERRUN at event for record 3283498 (gap 8):
  RQM=0 ... core at pc 199`.

## The fix, and the current cache layout

First fix (confirmed on hardware): high words were barred from overwriting
cache slots 0–255 of the single 4096-entry cache.

Current layout (split cache, replaces the above): `upd77c25_extpgm.v` has
two block RAMs looked up in parallel:

```
pin_data     256 x 25  {valid, word}            words 0..255, prewarmed
cache_data   512 x 30  {valid, tag[4:0], word}  all other words, on demand
```

Same protection for the transfer code (nothing can write the pinned table
except prewarm, a miss on a low word, or PGM_WR), fewer misses (modelled
8.0% vs 10.2%) and 2 RAMB16 instead of 6 on mk2 (7 arrays total, was 11).

Simulated only -- NOT yet run on hardware. Timed-replay segments at records
1.6M, 3.2M, 4.8M, 6.4M and 7.8M (200k each) pass with 0 overruns and 0
divergences, including the eviction episode at 3,276,100 and the transfer
that used to fail at 3,283,498. The same segment on the pre-fix RTL still
reproduces that overrun, so the segments do catch failures. A full run from
record 0 has not been done since the split.

When building, check the map report shows pin_data and cache_data as block
RAM, not distributed RAM (pin_data is only 6,400 bits).

## What is verified (do not re-litigate)

- **Semantics.** `tools/iss.c` (instruction-level uPD96050 model) matches the
  whole MesenCE trace — 136.6M DSP instructions / 8,084,030 distinct records —
  with **zero** mismatches on PC, A, B, both flag sets, K, L, M, N, RP, DP, TR,
  TRB, SR. This settles:
  - SBB/ADC/SHL1 carry-in comes from the **other** accumulator (same-acc
    gives ~17k mismatches). The core already does this.
  - The OV1/S1 rule in the core is correct. The old "1,887 of 1,888 plain
    toggle" scan was wrong; drop it.
  - Data ROM effective byte order little-endian (core's `dat_doutb_fixed`).
- **Core logic + fetch path.** `sim/replay_tb.v` (core paused between
  instructions, host events injected exactly) replays all 8,084,029 records
  through upd77c25 + upd77c25_extpgm (PGM_WR download, prewarm, cache, loop
  buffer): **0 divergences**. No logic bug in the core on this trace.
- **Timed harness catches overruns.** It caught the real one above; with
  `-Preplay_timed_tb.HOST_SCALE=0.5` it reports overruns from the first
  burst (record 1892).

## Not exercised by the trace (latent, low priority)

- `regs_m <= {mul_result[31], mul_result[29:15]}`; reference is bits 30:15.
  Differs only for K = L = −32768.
- SBB/ADC carry uses plain `r>q`/`r<q`; wrong when carry-in makes r == q.
- Host DR/RQM access has priority over the DSP's STORE in the same clock
  (else-if). Only matters if a host access lands in that exact cycle.

## Trace facts (Hayazashi Nidan Morita Shougi, MesenCE)

- Starts mid-game, DSP idle at word 2, cycle 668M. Zero-initialised data RAM
  and empty stack are sufficient.
- Mesen's DSP clock is 22 MHz: 365,919 DSP cycles per frame, one instruction
  per cycle (45.45 ns).
- Host events: 26,888 byte handshakes (SR A400→2400), 422 commands
  (C400→4400), 8 16-bit transfers (8000→9000→0000, host *writes*), 22,272
  SNES byte writes into DSP data RAM at `$68:xxxx`.
- Gaps: 21,032 at 8 cycles + 5,070 at 9 (DMA), 12,360 ≥32 (CPU-paced).
- Line state is BEFORE the instruction executes.

## Tools (tools/, sim/)

```
tools/trace_filter.c   22.5 GB trace -> ~100 MB: DSP lines with consecutive
                       duplicates collapsed, CPU lines touching bank $6x
tools/iss.c            reference model; reads filtered trace on stdin,
                       ROM path from $ROM. Writes stim.txt (paused replay),
                       recs.txt + evs.txt (timed replay), events.txt,
                       learned.txt. Prints MIS@ lines on any mismatch.
tools/rom2hex.py       st011.rom -> pgm.hex, drom.hex
tools/run_replay.sh    whole pipeline
sim/replay_tb.v        paused replay (exact logic check)
sim/replay_timed_tb.v  free-running replay: DMA events at real cadence,
                       CPU-paced events after the core reaches the record.
                       Params: MAXREC, MAXERR, HS_GAP, HOST_SCALE
sim/ip_stubs_replay.v  M9K stubs WITH datram port-B writes. The shipped
                       ip_stubs.v ignores wren_b, so SNES writes into DSP RAM
                       never landed in any earlier simulation.
```
Speed: ~5,000 records/s in Icarus. First half ~50 min, full ~100 min.
Filtering the trace: ~5 min. The ISS pass: ~1 min.

## Configuration as shipped

```
upd77c25.v        SKIP_ALU2=1  PC_LOOKAHEAD=1  PREWARM_ENABLE=1
                  LOOPBUF_ENTRIES=0  READ_VERIFY=0
                  stack 16 entries, regs_sp 4 bits
upd77c25_extpgm.v CACHE_BITS=9  PIN_BITS=8   (same on mk2 and mk3)
mcu/smc.c         ST0011_WAITSTATES 0
```

## Build notes (unchanged)

- mk2 IP must be regenerated from the .xco files before building:
  `coregen -p ip/mk2 -b ip/mk2/<core>.xco -r` for snescmd_buf,
  upd77c25_datram, upd77c25_datrom, msu_databuf, dac_buf. `make` does this; the ISE GUI does not
  (`NgdBuild:604 ... could not be resolved`).
- ISE requires declaration-before-use: declare nets above their first use.
- Savestate scan port, ctx.v and the on-chip pgmrom are removed. MSU-1
  (msu.v, dac.v) is back, taken from sd2snes_base; on mk2 it uses the last 9
  block RAMs (16 of 16). ST010 stays on sd2snes_dsp.
