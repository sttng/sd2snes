// upd77c25_extpgm.v
//
// External program memory controller for ST010/ST011.
//
// The on-chip pgmrom (upd77c25_pgmrom, 2048 x 24-bit) only ever holds
// DSP1-4 firmware -- it's far too small for ST010/ST011, whose real
// firmware can span the full 16384-word address space (confirmed against
// actual game dumps: Hayazashi Nidan Morita Shogi's ST011 program uses
// 16364 of 16384 words). That firmware instead lives in the board's Bus 2
// SRAM (U511, nominally 4Mbit/512KB per the schematic, but the MCU
// firmware's own memtest documents real hardware-measured usable capacity
// as 256KB/0x40000 -- addresses past that read back as noise, not a
// "4Mbit" chip's honest upper half. This design's actual usage (max
// ~49KB) is comfortably under either figure, so it doesn't affect
// correctness here, but comments/docs should cite the real number, not
// the schematic one) -- a separate physical chip from the PSRAM used for
// cart ROM/SaveRAM. Some OTHER cores (sd2snes_gsu, sd2snes_sa1) actively
// drive this same bus for their own working RAM, so "unused" isn't a
// board-wide property -- but it IS unused within sd2snes_dsp specifically
// (confirmed: undriven in this project's main.v before this work), and
// only one core bitstream is ever configured on the FPGA at a time, so a
// DSP-family cart never has the GSU/SA-1 bitstream loaded regardless of
// what those cores do with this bus. No conflict for this design.
//
// Each 24-bit instruction word is stored as 3 consecutive bytes, low byte
// first (matching the firmware dump format used by ares: byte0 =
// bits[7:0], byte1 = bits[15:8], byte2 = bits[23:16]), at byte address
// word_addr*3.
//
// `enable` (=ext_pgm_en) gates the READ (fetch) side only -- when 0
// (DSP1-4), `pc_stale` never fires, so this module never fetches and
// `ready` reflects the last completed operation, harmless since the
// opcode_w mux in upd77c25.v only selects this path when enable=1.
//
// IMPORTANT: this module deliberately has NO dependency on upd77c25's
// core RST, unlike every other part of that module. Confirmed by tracing
// the real MCU firmware (mcu_cmd.v's dspx_reset_out defaults to 1'b1 at
// FPGA-configuration time, so RST=~dspx_reset is asserted from the moment
// the fpga_dsp bitstream loads; deassert_reset() -- the only place that
// clears it -- runs at the very end of load_rom(), well after
// load_dspx()'s firmware download completes) that firmware download
// happens *specifically* while the CPU core is held in reset -- that's
// the documented, intentional design pattern this whole family of cores
// uses (see the NES/Atari "chipfeat must be written before the core
// leaves reset" invariant in memory.c). An earlier version of this module
// gated its write-capture logic behind `if(!RST)`, which meant it faithfully
// obeyed that reset signal by ignoring every single PGM_WR pulse for the
// entire download -- firmware never reached the SRAM at all. The on-chip
// pgmrom never had this problem since its underlying RAM primitive has no
// reset input to begin with; this module needs the same property.
// Power-up defaults come from the initial values below (Verilog `= value`
// declarations), which SRAM-based FPGA configuration applies as part of
// loading the bitstream -- equivalent to a reset for this module's actual
// purposes, since a fresh load_reconfigure_fpga() call (which always runs
// first in load_rom(), switching from whatever core -- typically the
// menu's own fpga_base -- was previously active) precedes every firmware
// download in the normal flow.
//
// Firmware download reuses the *same* PGM_WR/PGM_DI/PGM_WR_ADDR signals
// that already feed the on-chip pgmrom for DSP1-4 (driven by mcu_cmd.v's
// existing $e9 SPI-download command) -- no MCU-firmware changes needed,
// only where the FPGA routes those bytes on arrival.
//
// RAM_OE/RAM_WE are ACTIVE-LOW (confirmed from the MCU firmware's own
// fault-classification code, which refers to them as "CE#/OE#/WE#" --
// standard notation for active-low control signals on an async SRAM part;
// there's no separate CE pin exposed to the FPGA at all, so it's presumably
// tied active on the board since this bus has only one chip on it).
// Asserted = 0, idle/inactive = 1.
//
// Each byte access spends one cycle with the address presented and both
// control lines still deasserted (basic address-setup margin before OE/WE
// assert -- real async SRAM parts generally want this) before actually
// asserting OE or WE for HOLD_CYCLES.
//
// NOTE: HOLD_CYCLES below is a conservative default sized to safely exceed
// the SRAM's 45ns access/write time across a wide range of plausible
// system-clock frequencies. It hasn't been tuned against this design's
// actual system clock, and should be verified (and can likely be reduced)
// once that's confirmed.

module upd77c25_extpgm (
  input CLK,
  input enable,

  // fetch interface, consumed by upd77c25.v's opcode_w mux
  input [13:0] pc,

  // Lookahead port (throughput fix -- see CACHE LOOKUP TIMING below).
  // pc_early carries the core's combinational next-pc while it is still
  // in STATE_STORE, one cycle before `pc` itself changes. Driving the
  // cache's read address from it removes the lookup latency from the
  // instruction's critical tail entirely: the tag/data for the new pc
  // are already registered by the time the core reaches STATE_NEXT, so
  // `ready` is combinationally true on the first cycle of that state.
  // Tie pc_early_valid low to fall back to the old behaviour (one extra
  // stall cycle per instruction, still functionally correct).
  input [13:0] pc_early,
  input pc_early_valid,

  output [23:0] dout,
  output ready,

  // firmware download interface (same signals mcu_cmd.v already drives)
  input PGM_WR,
  input [23:0] PGM_DI,
  input [13:0] PGM_WR_ADDR,
  output wr_busy,

  // Readback verification sweep. The MCU's $E9 download path can only
  // prove what it SENT; this reads every word back OUT of the SRAM and
  // checksums it, proving what actually landed in the chip. Triggered by
  // SPI command $E5, result read via $F5.
  // PSRAM fetch path (PGM_IN_PSRAM=1). Reads the DSP program from the
  // main PSRAM instead of the Bus 2 SRAM: 16-bit wide so a 24-bit word
  // takes 2 accesses instead of 3, and it is the bus that already
  // carries game ROM reliably at full SNES speed.
  output reg psram_rrq = 1'b0,
  output reg [23:0] psram_addr = 24'd0,
  input [15:0] psram_din,
  input psram_rdy,

  input vsum_start,
  output reg vsum_busy = 1'b0,
  output reg [31:0] vsum = 32'd0,

  // physical SRAM bus (board's Bus 2 SRAM: nominally 4Mbit/512KB, really
  // 256KB usable -- see comment above; 8-bit, 45ns)
  output reg [18:0] RAM_ADDR,
  inout [7:0] RAM_DATA,
  output reg RAM_OE = 1'b1, // active-low: 1 = deasserted/idle
  output reg RAM_WE = 1'b1
);

  // SRAM needs 45ns settling (4.3 cycles at this design's confirmed
  // 96MHz). The 2-cycle synchronizer latency (ram_data_s1/s2 below)
  // comes out of this budget, so HOLD=8 leaves 6 cycles = 62.5ns of real
  // settling -- still ~1.4x the spec, while saving 6 cycles per word on
  // every cache miss versus the previous value of 10. Speed matters here
  // for the reason described at CACHE_BITS below: uncached fetches are
  // the throughput bottleneck, not a rare path.
  localparam HOLD_CYCLES = 8;

  localparam S_IDLE       = 5'd0,
             S_WR_ADDR0   = 5'd1, S_WR_HOLD0 = 5'd2, S_WR_POST0 = 5'd3,
             S_WR_ADDR1   = 5'd4, S_WR_HOLD1 = 5'd5, S_WR_POST1 = 5'd6,
             S_WR_ADDR2   = 5'd7, S_WR_HOLD2 = 5'd8, S_WR_POST2 = 5'd9,
             S_RD_ADDR0   = 5'd10, S_RD_HOLD0 = 5'd11,
             S_RD_ADDR1   = 5'd12, S_RD_HOLD1 = 5'd13,
             S_RD_ADDR2   = 5'd14, S_RD_HOLD2 = 5'd15;
             // S_CACHE_CHECK (was 5'd16) is gone: the cache lookup is
             // now continuous and needs no state of its own.

  localparam POST_CYCLES = 2; // address/data hold margin after WE deasserts

  reg [4:0] state = S_IDLE;
  reg [6:0] hold_cnt; // widened from [3:0] so HOLD_CYCLES can exceed 15
                       // (needed for the long-settle diagnostic build)
  reg [1:0] post_cnt;

  // Small on-chip cache for recently-fetched program words. Direct-mapped,
  // 512 entries; each entry stores the 24-bit word plus a 5-bit tag and a
  // valid bit, packed into single arrays so Quartus can infer block RAM
  // (~15Kbit total, roughly two M9K blocks -- cheap against this design's
  // ~48% free memory headroom).
  //
  // Intended to absorb hot loops (tight wait-loops, small inner
  // computation loops) without touching the external SRAM bus at all --
  // the one part of this design that can't be fully verified through
  // simulation, since an idealized behavioral SRAM model can't capture
  // real board-level timing/electrical behavior the way physical hardware
  // would exercise it. A cache hit means zero external bus activity for
  // that fetch; a miss falls through to the existing, already-verified
  // external fetch path unchanged.
  //
  // The valid bit is packed as the MSB of the tag word rather than living
  // in its own 1-bit-wide array: a separate narrow array (especially with
  // an `initial` loop clearing it) tends to be implemented as discrete
  // logic registers instead of block RAM, which would cost ~512 registers
  // and add routing pressure this design doesn't need -- particularly
  // given it has already hit one timing-closure failure.
  //
  // Power-up state comes from the array's initial value, applied by FPGA
  // configuration (same mechanism the rest of this module relies on --
  // see the header comment about deliberately having no RST dependency).
  // Set to 0 to bypass the cache entirely (diagnostic builds): every
  // fetch then goes straight to the external SRAM sequence, exactly as
  // it did before the cache existed. Kept as a parameter so a
  // cache-disabled build differs from the real one by a single line,
  // with no risk of hand-editing introducing unrelated changes.
  parameter CACHE_ENABLE = 1;

  // 4096 entries, covering 25% of ST011's 16,364-word program.
  //
  // Sized this way because the cache turns out to be architecturally
  // necessary, not an optimization. The external SRAM is 8-bit at 45ns,
  // so a 24-bit instruction needs three sequential byte reads: ~135ns
  // minimum, against ~122ns per instruction on the real 8.192MHz chip.
  // Uncached execution therefore CANNOT reach real-chip speed no matter
  // how the read sequence is tuned, and these games are real-time
  // coprocessors whose host expects results within a hardware-derived
  // window.
  //
  // That explains the observed behaviour precisely: ST010's 533 words
  // fit the cache entirely, so it runs several times faster than real
  // silicon and works; with the cache off it runs ~3x SLOWER than real
  // and glitches. The SRAM path itself is fine -- every cached word came
  // through it correctly exactly once, which is why one pass works and
  // sustained uncached execution does not.
  //
  // 8192 entries was tried first and did NOT fit: Quartus reported the
  // design needing more than the device's 56 M9K blocks, with total
  // memory at 93%. A 24-bit-wide memory packs poorly into M9K blocks
  // (which favour widths like 8/9, 16/18, 32/36), so block count runs
  // out before bit count does. 4096 entries needs ~13 blocks instead of
  // ~23, putting total memory near 73% with real margin.
  // Read-verify: read every word from the external SRAM twice and only
  // commit when two consecutive reads agree, retrying on disagreement.
  //
  // DEFAULT IS NOW 0. It was written to test the hypothesis that the
  // external SRAM read path had a low but nonzero error rate. That
  // hypothesis is dead: the readback sweep matched across all 16,384
  // words through this same path, the sticky-DR and fault-injection
  // experiments found nothing, and the actual fault turned out to be
  // throughput, not data integrity.
  //
  // Leaving it on was expensive. Measured with miss_latency_tb.v at
  // 96MHz:
  //
  //     READ_VERIFY=1   630.7 ns per miss  (60.5 cycles)
  //     READ_VERIFY=0   323.1 ns per miss  (31.0 cycles)
  //
  // ST011's host protocol gives the DSP 372 ns per byte, so a single
  // verified miss cost 1.7 entire byte slots -- and every instruction
  // costs one the first time it executes. Turning it off is what took
  // the fix from "runs much longer, still dies" to stable.
  //
  // Set to 1 to restore double-read behaviour if an SRAM integrity
  // question ever comes back; the retry/MAX_RETRY machinery below is
  // unchanged and simply goes unused at 0.
  parameter READ_VERIFY = 0;

  /* Fetch program words from the main PSRAM rather than the Bus 2 SRAM.
     Rationale: PSRAM is 16-bit (2 accesses per 24-bit word vs 3), and it
     is proven -- it carries the game ROM and is read continuously at full
     SNES speed. The Bus 2 SRAM is the bus implicated by the observation
     that running a 16384-word readback sweep introduced fresh glitches
     in an otherwise-working ST010, which points at sustained traffic on
     that bus disturbing the board rather than at any per-read fault.
     Word N occupies bytes N*3 .. N*3+2 at PSRAM byte address
     PGM_PSRAM_BASE + N*3, matching the layout the MCU writes. */
  // 0 = use the Bus 2 SRAM path (known good). The PSRAM path is
  // incomplete and fails its own testbench -- see README_PSRAM_WIP.md.
  parameter PGM_IN_PSRAM = 0;
  parameter [23:0] PGM_PSRAM_BASE = 24'hD00000;

  localparam P_IDLE = 3'd0, P_REQ0 = 3'd1, P_WAIT0 = 3'd2,
             P_REQ1 = 3'd3, P_WAIT1 = 3'd4, P_DONE = 3'd5;
  reg [2:0] pstate = P_IDLE;
  reg [15:0] pword0;
  reg [23:0] pbyte_addr;

  // Retry cap. Without one, a high error rate would livelock: two reads
  // would rarely agree, the fetch would never complete, and the DSP would
  // stall -- which on hardware looks exactly like a hang, i.e. the very
  // symptom being investigated. After MAX_RETRY disagreements the last
  // read is accepted as best effort so forward progress is guaranteed.
  // Found by fault-injection simulation, which hung at a 1-in-7 error
  // rate before this was added.
  localparam MAX_RETRY = 4;

  reg [13:0] vsum_addr = 14'd0;
  reg vsum_active = 1'b0;    // sweep in progress: drives pc_r instead of pc

  reg [23:0] rd_word_a;      // first read, awaiting confirmation
  reg verify_pass = 1'b0;    // 0 = first read, 1 = confirming read
  reg [2:0] retry_cnt = 3'd0;
  reg [15:0] verify_errors = 16'd0; // mismatches seen (diagnostic counter)

  // 8192 entries. Static reachability on the real ST011 firmware shows
  // 6603 live words (only 12 dispatch commands are ever issued by the
  // game), so 8192 covers the whole working set with headroom while
  // 4096 leaves ~2500 words permanently thrashing. Associativity was
  // measured and does not help -- this is a capacity limit, not a
  // conflict one.
  localparam CACHE_BITS = 12; // 4096 entries
  //
  // 4096 rather than 8192, to free 12 M9K blocks for the full 16384-word
  // msu_databuf. The time-critical path survives the halving: the trace's
  // real-time windows are four CONSECUTIVE words (380 of 382 of them), and
  // four consecutive addresses can never conflict in a direct-mapped cache.
  // The transfer loops live at words 197-200 and 243-246, both inside the
  // prewarmed 0..4095 range, so they stay resident. What degrades is
  // command code above word 4095, which is not real-time -- there the host
  // is waiting on the DSP rather than the reverse.
  //
  // An entry is now valid(1) + tag(2) + data(24) = 27 bits. Packed as
  // 18 + 9, both native M9K widths:
  //     cache_data_lo  4096 x 18  {tag[1:0], data[15:0]}   8 blocks
  //     cache_data_hi  4096 x  9  {valid,    data[23:16]}  4 blocks
  // The valid bit moved from lo to hi so the 18-bit half is exactly full;
  // invalidation and the power-on sweep therefore clear HI, not LO.
  localparam CACHE_TAG_BITS = 14 - CACHE_BITS; // 2 bits at 4096 entries
                                                // (index+tag must cover
                                                // pc's full 14 bits)
  // Split into 16-bit and 8-bit arrays rather than one 24-bit array.
  // M9K blocks are optimised for 8/9, 16/18 and 32/36-bit widths; a
  // 24-bit array wastes part of every block, which is why an earlier
  // 8192-entry attempt exhausted the device's 56 blocks at only 93% of
  // total memory BITS. Two native-width arrays pack cleanly.
  /* 18 bits wide: {valid, tag, data[15:0]}. M9K natively supports an
     18-bit width (16 + 2 spare bits), so this costs exactly the same 16
     blocks as a 16-bit array while carrying the tag and valid bit for
     free -- removing the separate tag array entirely and the 8 blocks it
     needed. */
  reg [CACHE_TAG_BITS+15:0] cache_data_lo [0:(1<<CACHE_BITS)-1];
  reg [8:0]  cache_data_hi [0:(1<<CACHE_BITS)-1];
  // [CACHE_TAG_BITS] = valid, [CACHE_TAG_BITS-1:0] = tag

  // Cache invalidation sweep state.
  //
  // Clears one entry per clock after configuration rather than using an
  // `initial` loop: Quartus refuses to unroll loops beyond 5000
  // iterations, so an initial-block clear fails synthesis outright at
  // 8192 entries ("loop must terminate within 5000 iterations"). Icarus
  // has no such limit, which is why simulation passed while synthesis
  // did not. A sweep is also the conventional way to initialize inferred
  // block RAM, since block RAM has no reset input.
  //
  // The sweep runs inside the main always block below, not its own:
  // cache_data_lo must have exactly one driver, and the fetch/write paths
  // already write it.
  //
  // It completes in 4096 cycles (~43us at 96MHz) -- vastly shorter than
  // the firmware download that follows, so it always finishes long
  // before the first fetch. cache_ready gates hits until then, so a
  // fetch during the sweep simply misses and goes to the external SRAM,
  // which is always correct.
  reg [CACHE_BITS-1:0] init_addr = {CACHE_BITS{1'b0}};
  reg cache_ready = 1'b0;

  // registered cache-read outputs, matching block RAM's synchronous-read
  // behavior (address presented one cycle, data available the next)
  /* Single write port for cache_data_lo.
     Block RAM can only be inferred when an array has ONE write address
     expression. cache_data_lo was previously written from three
     different addresses (init sweep, write-invalidate, fill), so Quartus
     built all 8192x18 bits from registers -- 147456 of the 151217
     registers in the failing fit. cache_data_hi inferred correctly only
     because every one of its writes happened to use pc_r.
     All writes now funnel through these, with a single array assignment
     at the end of the always block. Blocking assignments, so the value
     set earlier in the same evaluation is the one that gets written. */
  reg        hi_we;
  reg [CACHE_BITS-1:0] hi_addr;
  reg [8:0]  hi_data;
  reg        lo_we;
  reg [CACHE_BITS-1:0] lo_addr;
  reg [CACHE_TAG_BITS+15:0] lo_data;

  // ---- CACHE LOOKUP TIMING ------------------------------------------
  //
  // The lookup is issued unconditionally, every cycle, from cache_raddr.
  // It used to be issued only once the fetch FSM reached S_IDLE and
  // noticed pc had changed, which cost THREE cycles on every cache HIT
  // (S_IDLE notices, S_CACHE_CHECK compares, ready asserts). Against a
  // seven-state core that was a third of the entire instruction time,
  // and it was paid on hits -- the common case -- not just on misses.
  //
  // ST011 has no slack for that. Its host protocol is DMA-paced with no
  // handshake: the SNEES Emulator trace shows a host access to DR every 8 DSP
  // instructions, never fewer, while the DSP's transfer loop is 4
  // instructions long. Miss that budget and DR is overwritten before the
  // DSP consumes it, the loop counter never reaches zero, and the DSP
  // parks in its JRQM wait forever. See upd77c25.v's throughput note.
  //
  // cache_raddr follows pc_early during the core's STATE_STORE and pc
  // otherwise, so the tag comparison for the NEXT instruction has
  // already been registered before the core asks for it, and `ready` is
  // combinationally true on the first cycle of STATE_NEXT.
  wire [13:0] cache_raddr = pc_early_valid ? pc_early : pc;

  reg [CACHE_TAG_BITS+15:0] cache_rdata_lo;
  reg [8:0]  cache_rdata_hi;
  reg [13:0] cache_q_pc = 14'h3fff; // address cache_rdata_* belongs to
  // Read-during-write guard. The lookup registers are loaded from the
  // array at the top of the always block while the fill/invalidate write
  // lands at the bottom of the same block, so a lookup issued on the
  // cycle its own entry is written captures the PRE-write contents.
  // Believing that gives a hit on a just-invalidated entry -- caught by
  // extpgm_tb's cycle-aligned cache/write hazard case. Flagged here and
  // treated exactly like "not yet current": wait one cycle and re-check,
  // by which time the lookup has re-read the post-write value.
  reg cache_q_dirty = 1'b0;
  wire [23:0] cache_rdata = {cache_rdata_hi[7:0], cache_rdata_lo[15:0]};

  // Only believable when the registered lookup actually corresponds to
  // the pc being asked about. For one cycle after any address change it
  // does not, and the FSM must wait rather than treat it as a miss.
  wire cache_q_current = (cache_q_pc == pc) && !cache_q_dirty;
  wire cache_hit_now = (CACHE_ENABLE != 0)
                   && cache_ready   // no hits until the sweep has cleared
                                     // every entry; before that the tag
                                     // memory holds undefined contents
                   && cache_q_current
                   && cache_rdata_hi[8]                        // valid
                   && (cache_rdata_lo[CACHE_TAG_BITS+15:16]
                       == pc[13:CACHE_BITS]);                   // tag

  reg [13:0] pc_r;          // pc the in-flight (or most recent) read is for
  reg [13:0] pc_last_done = 14'h3fff; // "never fetched" sentinel;
                                       // guaranteed mismatch vs pc=0
  reg [23:0] dout_r;        // last completed demand fetch
  reg [7:0] byte0, byte1;

  // ---- ONE-SHOT CACHE PREWARM ----------------------------------------
  //
  // Even with a one-cycle hit, the FIRST execution of any instruction
  // still costs a full external fetch: 3 bytes x (HOLD_CYCLES+1) plus
  // overhead, about 30 cycles, roughly one entire host DMA byte slot.
  //
  // That alone is enough to break ST011. Its inbound transfer loop
  // (words 197-200 in the SNES Emulator trace) is entered with 199 and 200
  // uncached; the two cold fetches push the DSP's consumption of the
  // second byte past the arrival of the third, one byte is lost, the
  // loop counter never reaches zero, and the DSP hangs. This is why
  // growing the cache from 512 to 8192 entries changed nothing: the
  // cache is cold on the first transfer at any size, and the first
  // transfer is where it dies.
  //
  // So: once the firmware download has gone quiet, walk words
  // 0..(2^CACHE_BITS - 1) through the ordinary read path and fill every
  // entry, before the core is allowed to fetch anything. `ready` is held
  // low throughout, so the core simply stalls. Cost is ~2.6ms at 96MHz,
  // spent while the DSP is doing nothing but spinning in its
  // command-wait loop, long before the game first invokes it.
  //
  // Note this covers words 0..8191 only -- with a direct-mapped
  // 2^CACHE_BITS-entry cache the upper half of a 16384-word program
  // aliases onto the same entries, so anything the firmware executes
  // above word 8191 will still take a cold miss. ST011's measured live
  // set is 6603 words; if any meaningful part of it turns out to live
  // above 8191, this needs revisiting (associativity, or the PSRAM
  // fetch path).
  //
  // Set PREWARM_ENABLE to 0 to remove it entirely -- one line, so a
  // build without it differs by nothing else.
  parameter PREWARM_ENABLE = 1;
  localparam [15:0] PREWARM_WR_IDLE = 16'hffff; // ~0.68ms of no PGM_WR

  reg prewarm_armed  = 1'b0;  // a download has been seen since last warm
  reg prewarm_active = 1'b0;
  reg prewarm_done   = 1'b0;
  reg [CACHE_BITS-1:0] prewarm_addr = {CACHE_BITS{1'b0}};
  reg prewarm_abort  = 1'b0;
  reg [15:0] wr_idle_cnt = 16'd0;

  // Any PGM_WR pulse is captured immediately regardless of current state,
  // so a write request arriving mid-read is never silently dropped.
  reg wr_pending = 1'b0;
  reg [13:0] wr_pending_addr;
  reg [23:0] wr_pending_data;
  reg [13:0] wr_addr_r;
  reg [23:0] wr_data_r;

  reg [7:0] ram_data_out;
  reg ram_data_drive = 1'b0;

  // Two-stage synchronizer for the incoming SRAM data.
  //
  // RAM_DATA is genuinely asynchronous with respect to CLK: it's driven
  // by an external SRAM whose output timing has no relationship to this
  // FPGA's clock. Sampling it directly into a register (as the read
  // states did previously) is a metastability hazard -- when the data
  // transition lands too close to the sampling edge, the captured bit
  // can settle to either value, or briefly to neither.
  //
  // This is invisible in simulation: a behavioral SRAM model responds
  // perfectly synchronously, so every sample is clean by construction.
  // It is also completely unaffected by increasing HOLD_CYCLES, because
  // setup/access time was never the problem -- which is why the earlier
  // doubled-hold-time diagnostic changed nothing and (wrongly) seemed to
  // rule timing out entirely.
  //
  // The cache experiment is what exposed this: with the cache enabled,
  // ST010 stopped glitching because most of its 533-word program stopped
  // touching this path at all; with the cache disabled, the glitches
  // came straight back. ST011's 16,364-word program constantly evicts a
  // 512-entry cache, so it stays on this path and fails regardless.
  reg [7:0] ram_data_s1;
  reg [7:0] ram_data_s2;
  always @(posedge CLK) begin
    ram_data_s1 <= RAM_DATA;
    ram_data_s2 <= ram_data_s1;
  end

  assign RAM_DATA = ram_data_drive ? ram_data_out : 8'bz;
  assign wr_busy = wr_pending | (state >= S_WR_ADDR0 && state <= S_WR_POST2);

  // Combinational, not registered: this is the fix for a real race found
  // on real hardware. When cpu_wait=0 (the ST010/ST011 case -- see
  // smc.c's fpga_dspfeat=0 for has_st0010), the CPU's STATE_NEXT check of
  // this signal can happen on the exact same clock edge pc just changed.
  // A registered "ready" that only updates in reaction to pc changing
  // (one clock edge behind the change itself) would still show the OLD
  // fetch's "ready=1" on that first edge, letting the CPU read `dout`
  // before the real fetch for the new pc had even started -- which reads
  // as "only the first instruction ever fetches correctly" once every
  // instruction after that races ahead on stale data. Defining `ready`
  // this way instead means it reflects the true current state with zero
  // lag: false the instant pc no longer matches what dout holds, true the
  // instant pc_last_done catches back up.
  // A hit that has already been registered by the continuous lookup is
  // servable in the same cycle -- pc_last_done catches up one cycle
  // later, purely so the value stays held if pc stops changing.
  assign ready = ~enable
               | (((pc_last_done == pc) | cache_hit_now)
                  & ~wr_busy & ~prewarm_active);

  // Priority matters: pc_last_done is the authority whenever it matches,
  // because during the fill cycle of an external read the cache array is
  // being written at this very address and its read-during-write value
  // is not defined.
  assign dout = (pc_last_done == pc) ? dout_r : cache_rdata;

  wire pc_stale = enable && (pc_last_done != pc);

  // word address -> byte address (x3), via shift+add rather than a
  // multiplier
  wire [16:0] pc_r_byte0      = {pc_r, 1'b0} + pc_r;
  wire [16:0] wr_addr_r_byte0 = {wr_addr_r, 1'b0} + wr_addr_r;

  /* PSRAM program fetch.
     Two 16-bit reads cover the three bytes of a word:
       addr+0 -> bytes 0,1     addr+2 -> byte 2 (low half)
     Byte order matches what the MCU stores, and the same reversal the
     SRAM path applies is applied here, so the CPU sees identical data
     either way. Runs only when PGM_IN_PSRAM=1; otherwise this block is
     inert and the SRAM path below is used unchanged. */
  always @(posedge CLK) begin
    hi_we = 1'b0;
    hi_addr = {CACHE_BITS{1'b0}};
    hi_data = 9'd0;
    lo_we = 1'b0;              // default: no write this cycle
    lo_addr = {CACHE_BITS{1'b0}};
    lo_data = {(CACHE_TAG_BITS+16){1'b0}};
    if(PGM_IN_PSRAM != 0) begin
      // ---- PSRAM fetch path ----
      // Continuous cache lookup, same as the SRAM path below: `ready`
      // now consults cache_hit_now, so these registers must track a real
      // address on this path too rather than holding whatever they were
      // initialised to.
      cache_rdata_lo <= cache_data_lo[cache_raddr[CACHE_BITS-1:0]];
      cache_rdata_hi <= cache_data_hi[cache_raddr[CACHE_BITS-1:0]];
      cache_q_pc <= cache_raddr;
      // Firmware writes are still captured so the download path is
      // unaffected by where the program is read from.
      if(PGM_WR) begin
        wr_pending <= 1'b1;
        wr_pending_addr <= PGM_WR_ADDR;
        wr_pending_data <= PGM_DI;
      end
      // Cache invalidation sweep -- must run on this path too. It
      // previously lived only in the SRAM branch, so selecting PSRAM
      // left cache_ready deasserted forever and the fetch FSM gated off.
      if(!cache_ready) begin
        hi_we = 1'b1; hi_addr = init_addr; hi_data = 9'd0;
        if(init_addr == {CACHE_BITS{1'b1}}) cache_ready <= 1'b1;
        else init_addr <= init_addr + 1'b1;
      end
      psram_rrq <= 1'b0;
      if(cache_ready)
      case(pstate)
        P_IDLE: begin
          if(enable && (pc_last_done != pc) && !wr_busy) begin
            pc_r <= pc;
            pbyte_addr <= PGM_PSRAM_BASE + {pc, 1'b0} + pc; // base + pc*3
            pstate <= P_REQ0;
          end
        end
        P_REQ0: begin
          psram_addr <= pbyte_addr;
          psram_rrq <= 1'b1;
          pstate <= P_WAIT0;
        end
        P_WAIT0: begin
          if(psram_rdy && !psram_rrq) begin
            pword0 <= psram_din;
            pstate <= P_REQ1;
          end
        end
        P_REQ1: begin
          psram_addr <= pbyte_addr + 24'd2;
          psram_rrq <= 1'b1;
          pstate <= P_WAIT1;
        end
        P_WAIT1: begin
          if(psram_rdy && !psram_rrq) begin
            // pword0 = {byte1, byte0}, psram_din[7:0] = byte2
            // reassembled with the same byte-order correction the SRAM
            // path uses, so the CPU sees the same instruction either way
            dout_r <= {pword0[7:0], pword0[15:8], psram_din[7:0]};
            lo_we = 1'b1; lo_addr = pc_r[CACHE_BITS-1:0];
            lo_data = {pc_r[13:CACHE_BITS], pword0[15:8], psram_din[7:0]};
            hi_we = 1'b1; hi_addr = pc_r[CACHE_BITS-1:0]; hi_data = {1'b1, pword0[7:0]};
            pc_last_done <= pc_r;
            pstate <= P_IDLE;
          end
        end
        default: pstate <= P_IDLE;
      endcase

    end else begin
    // ---- Bus 2 SRAM fetch path (PGM_IN_PSRAM=0) ----

    // Continuous cache lookup. Issued every cycle, unconditionally, from
    // cache_raddr -- see the CACHE LOOKUP TIMING note above. Read and
    // write of these arrays stay in this one always block so Quartus
    // still infers simple dual-port block RAM; the write port is the
    // lo_we/hi_we funnel applied at the very end.
    cache_rdata_lo <= cache_data_lo[cache_raddr[CACHE_BITS-1:0]];
    cache_rdata_hi <= cache_data_hi[cache_raddr[CACHE_BITS-1:0]];
    cache_q_pc <= cache_raddr;

    // capture write requests unconditionally, every cycle -- no RST gating,
    // see module header comment for why
    if(PGM_WR) begin
      wr_pending <= 1'b1;
      wr_pending_addr <= PGM_WR_ADDR;
      wr_pending_data <= PGM_DI;
      // A download invalidates any prewarm: re-arm, and flag an abort
      // for one that happens to be running. The abort is deferred to
      // S_IDLE rather than clearing prewarm_active here, so a read
      // already in flight is never orphaned mid-sequence with the
      // completion path no longer recognising it as a prewarm word.
      prewarm_armed  <= 1'b1;
      prewarm_done   <= 1'b0;
      prewarm_abort  <= 1'b1;
      wr_idle_cnt <= 16'd0;
    end else if(wr_idle_cnt != PREWARM_WR_IDLE) begin
      wr_idle_cnt <= wr_idle_cnt + 1'b1;
    end

    if(!cache_ready) begin
      // Cache invalidation sweep (see cache_ready declaration above for
      // why this is a sweep rather than an initial-block loop, and why
      // it lives in this always block rather than its own). One entry
      // per clock; the state machine is held off until it completes.
      // PGM_WR capture above still runs, so nothing is lost meanwhile.
      hi_we = 1'b1; hi_addr = init_addr; hi_data = 9'd0;
      if(init_addr == {CACHE_BITS{1'b1}}) cache_ready <= 1'b1;
      else init_addr <= init_addr + 1'b1;
    end else
    case(state)
      S_IDLE: begin
        RAM_OE <= 1'b1;
        RAM_WE <= 1'b1;
        ram_data_drive <= 1'b0;
        if(wr_pending) begin
          wr_addr_r <= wr_pending_addr;
          wr_data_r <= wr_pending_data;
          wr_pending <= 1'b0;
          state <= S_WR_ADDR0;
        end else if(vsum_start & ~vsum_busy) begin
          // begin readback sweep: walk every word, checksum what the
          // SRAM actually returns
          vsum <= 32'd0;
          vsum_addr <= 14'd0;
          vsum_busy <= 1'b1;
          vsum_active <= 1'b1;
          pc_r <= 14'd0;
          verify_pass <= 1'b0;
          retry_cnt <= 3'd0;
          state <= S_RD_ADDR0;
        end else if(vsum_busy) begin
          // next word of the sweep
          pc_r <= vsum_addr;
          vsum_active <= 1'b1;
          verify_pass <= 1'b0;
          retry_cnt <= 3'd0;
          state <= S_RD_ADDR0;
        end else if(prewarm_active) begin
          // Continue (or abandon) the one-shot prewarm. Sits below the
          // write and checksum branches so neither is ever delayed by
          // more than the single word currently in flight.
          if(prewarm_abort) begin
            prewarm_active <= 1'b0;
            prewarm_abort <= 1'b0;
          end else begin
            verify_pass <= 1'b0;
            retry_cnt <= 3'd0;
            state <= S_RD_ADDR0;
          end
        end else if(PREWARM_ENABLE != 0 && enable && prewarm_armed
                    && !prewarm_done && cache_ready
                    && (wr_idle_cnt == PREWARM_WR_IDLE)) begin
          // One-shot prewarm, taken in preference to the core's own
          // fetch: `ready` is gated by prewarm_active, so the core just
          // stalls until this finishes. See the PREWARM block above.
          prewarm_active <= 1'b1;
          prewarm_addr <= {CACHE_BITS{1'b0}};
          pc_r <= 14'd0;
          verify_pass <= 1'b0;
          retry_cnt <= 3'd0;
          state <= S_RD_ADDR0;
        end else if(pc_stale) begin
          // Fresh fetch: clear any half-finished verify state. The
          // re-read path jumps straight to S_RD_ADDR0 and never passes
          // through here, so this only ever resets an abandoned pass
          // (e.g. one interrupted by a firmware write taking priority).
          verify_pass <= 1'b0;
          retry_cnt <= 3'd0;
          if(PGM_WR) begin
            // A write is landing on this very edge. Do not start
            // anything; it was captured into wr_pending above and the
            // wr_pending branch will service it next cycle, after which
            // pc_stale is still true and the fetch re-issues naturally
            // against post-write data.
            state <= S_IDLE;
          end else if(CACHE_ENABLE != 0 && !cache_q_current) begin
            // The continuous lookup has not caught up with this pc yet
            // (it changed on this very edge, and pc_early_valid was not
            // driven -- e.g. a savestate restore, or a build with the
            // lookahead tied off). Wait one cycle rather than treating
            // an unrelated tag as a miss and burning 30 cycles on the
            // SRAM for a word that is very likely cached.
            state <= S_IDLE;
          end else if(CACHE_ENABLE != 0 && cache_hit_now) begin
            // Fast path: no external SRAM access at all. `ready` and
            // `dout` are already serving this from cache_rdata
            // combinationally; this just latches it so the value stays
            // held once the lookup address moves on.
            //
            // PGM_WR is checked LIVE, not via the registered wr_pending:
            // wr_pending is assigned non-blocking, so it still reads 0
            // during the very edge a write arrives. Without this a write
            // landing on this edge for the address being checked would
            // let the hit serve the stale pre-write value. A write that
            // arrived strictly earlier was already taken by the
            // wr_pending branch above and never reaches here.
            dout_r <= cache_rdata;
            pc_last_done <= pc;
            state <= S_IDLE;
          end else begin
            // Miss (or cache disabled): the existing, unmodified
            // external fetch sequence, exactly as before.
            pc_r <= pc;
            state <= S_RD_ADDR0;
          end
        end
      end

      // ---- write byte 0 (bits 7:0) ----
      S_WR_ADDR0: begin
        // address presented, WE still deasserted: basic address-setup
        // margin before the write pulse
        RAM_ADDR <= {2'b0, wr_addr_r_byte0};
        ram_data_out <= wr_data_r[7:0];
        ram_data_drive <= 1'b1;
        RAM_WE <= 1'b1;
        hold_cnt <= HOLD_CYCLES;
        state <= S_WR_HOLD0;
      end
      S_WR_HOLD0: begin
        RAM_WE <= 1'b0; // assert
        if(hold_cnt == 0) begin
          RAM_WE <= 1'b1; // deassert -- write pulse complete
          post_cnt <= POST_CYCLES;
          state <= S_WR_POST0;
        end else hold_cnt <= hold_cnt - 1;
      end
      S_WR_POST0: begin
        // address/data held stable a little longer (tAH/tDH margin) --
        // nothing here changes RAM_ADDR/ram_data_out
        if(post_cnt == 0) state <= S_WR_ADDR1;
        else post_cnt <= post_cnt - 1;
      end
      // ---- write byte 1 (bits 15:8) ----
      S_WR_ADDR1: begin
        RAM_ADDR <= {2'b0, wr_addr_r_byte0} + 19'd1;
        ram_data_out <= wr_data_r[15:8];
        RAM_WE <= 1'b1;
        hold_cnt <= HOLD_CYCLES;
        state <= S_WR_HOLD1;
      end
      S_WR_HOLD1: begin
        RAM_WE <= 1'b0;
        if(hold_cnt == 0) begin
          RAM_WE <= 1'b1;
          post_cnt <= POST_CYCLES;
          state <= S_WR_POST1;
        end else hold_cnt <= hold_cnt - 1;
      end
      S_WR_POST1: begin
        if(post_cnt == 0) state <= S_WR_ADDR2;
        else post_cnt <= post_cnt - 1;
      end
      // ---- write byte 2 (bits 23:16) ----
      S_WR_ADDR2: begin
        RAM_ADDR <= {2'b0, wr_addr_r_byte0} + 19'd2;
        ram_data_out <= wr_data_r[23:16];
        RAM_WE <= 1'b1;
        hold_cnt <= HOLD_CYCLES;
        state <= S_WR_HOLD2;
      end
      S_WR_HOLD2: begin
        RAM_WE <= 1'b0;
        if(hold_cnt == 0) begin
          RAM_WE <= 1'b1;
          post_cnt <= POST_CYCLES;
          state <= S_WR_POST2;
        end else hold_cnt <= hold_cnt - 1;
      end
      S_WR_POST2: begin
        if(post_cnt == 0) begin
          ram_data_drive <= 1'b0;
          // A write just landed -- invalidate any cached fetch result.
          // Defense in depth: in the traced normal flow, no fetch can
          // happen at all until the CPU core leaves reset, well after
          // download completes, so this shouldn't ever have stale data to
          // invalidate in practice -- but it costs nothing to keep, and
          // protects against any load path that doesn't match the one
          // traced (a mid-session reload without a full FPGA
          // reconfiguration, for instance).
          pc_last_done <= 14'h3fff;
          // Also invalidate the small on-chip cache's corresponding slot
          // (unconditional, no tag check needed: if this slot wasn't
          // caching this exact address, invalidating it is harmless).
          hi_we = 1'b1; hi_addr = wr_addr_r[CACHE_BITS-1:0]; hi_data = 9'd0;
          state <= S_IDLE;
        end else post_cnt <= post_cnt - 1;
      end

      // ---- read the three bytes of one word ----
      //
      // OE is asserted ONCE at the start and held LOW across all three
      // bytes, rather than pulsed separately for each. The previous
      // version deasserted OE between every byte, which meant:
      //   - the bus went high-impedance (floating) three times per word,
      //     and the synchronizer sampled that floating bus into its
      //     pipeline during each gap
      //   - every byte had to re-satisfy the SRAM's full access time
      //     (tAA) from scratch after OE re-asserted
      // Holding OE low across the word removes both. Only the address
      // changes between bytes, so each subsequent byte needs the SRAM's
      // address-access time with the output already enabled and driving
      // -- no float, no output-enable turn-on delay, no chance to sample
      // an undriven bus.
      //
      // This matters more than it looks: the read path was the one part
      // of the design that real hardware exercised differently from
      // simulation. A behavioural SRAM model drives a defined value the
      // instant OE asserts and never floats meaningfully, so the
      // pulse-per-byte scheme looked perfectly clean in every simulation
      // while being fragile on the actual board.
      S_RD_ADDR0: begin
        RAM_ADDR <= {2'b0, pc_r_byte0};
        RAM_OE <= 1'b0; // assert once, stays low for the whole word
        hold_cnt <= HOLD_CYCLES;
        state <= S_RD_HOLD0;
      end
      S_RD_HOLD0: begin
        RAM_OE <= 1'b0; // held
        if(hold_cnt == 0) begin
          byte0 <= ram_data_s2; // synchronized (2-stage), not raw RAM_DATA
          state <= S_RD_ADDR1;
        end else hold_cnt <= hold_cnt - 1;
      end
      S_RD_ADDR1: begin
        RAM_ADDR <= {2'b0, pc_r_byte0} + 19'd1;
        RAM_OE <= 1'b0; // held -- no float between bytes
        hold_cnt <= HOLD_CYCLES;
        state <= S_RD_HOLD1;
      end
      S_RD_HOLD1: begin
        RAM_OE <= 1'b0;
        if(hold_cnt == 0) begin
          byte1 <= ram_data_s2;
          state <= S_RD_ADDR2;
        end else hold_cnt <= hold_cnt - 1;
      end
      S_RD_ADDR2: begin
        RAM_ADDR <= {2'b0, pc_r_byte0} + 19'd2;
        RAM_OE <= 1'b0; // held
        hold_cnt <= HOLD_CYCLES;
        state <= S_RD_HOLD2;
      end
      S_RD_HOLD2: begin
        RAM_OE <= 1'b0;
        if(hold_cnt == 0) begin
          RAM_OE <= 1'b1; // release only now, after the whole word
          // Byte-order correction: PGM_DI as received is byte-reversed
          // relative to the true instruction (ares dumps little-endian,
          // this loader assembles big-endian). Verified numerically
          // against the real firmware: 0/20 words matched without this
          // correction, 20/20 with it. See also upd77c25.v's
          // dat_doutb_fixed for the identical fix on the data-ROM path.
          if(prewarm_active) begin
            // Prewarm word complete: fill the entry and step on.
            // Deliberately bypasses dout_r/pc_last_done -- the core is
            // stalled (ready is gated by prewarm_active) and must not
            // observe any of this as a fetch result. Single read, no
            // READ_VERIFY second pass: this runs 8192 times and a wrong
            // word here is self-correcting, since a cache miss on it
            // later just re-reads from the SRAM.
            lo_we = 1'b1; lo_addr = pc_r[CACHE_BITS-1:0];
            lo_data = {pc_r[13:CACHE_BITS], byte1, ram_data_s2};
            hi_we = 1'b1; hi_addr = pc_r[CACHE_BITS-1:0]; hi_data = {1'b1, byte0};
            verify_pass <= 1'b0;
            if(prewarm_addr == {CACHE_BITS{1'b1}}) begin
              prewarm_active <= 1'b0;
              prewarm_done <= 1'b1;
            end else begin
              prewarm_addr <= prewarm_addr + 1'b1;
              pc_r <= {{(14-CACHE_BITS){1'b0}}, prewarm_addr} + 14'd1;
            end
            state <= S_IDLE;
          end else if(vsum_active) begin
            // Sweep word complete: accumulate and move on. Deliberately
            // bypasses dout/cache/pc_last_done so the sweep leaves no
            // trace on normal fetch state.
            // Accumulate the RAW STORED word, i.e. PGM_DI as the MCU sent
            // it ({SRAM[+2],SRAM[+1],SRAM[+0]}), NOT the byte-corrected
            // instruction -- so this is directly comparable with the
            // checksum load_dspx computes while sending.
            vsum <= vsum + {8'd0, ram_data_s2, byte1, byte0};
            vsum_active <= 1'b0;
            verify_pass <= 1'b0;
            if(vsum_addr == 14'd16383) begin
              vsum_busy <= 1'b0;   // sweep finished
            end else begin
              vsum_addr <= vsum_addr + 1'b1;
            end
            state <= S_IDLE;
          end else if(READ_VERIFY == 0) begin
            dout_r <= {byte0, byte1, ram_data_s2};
            pc_last_done <= pc_r;
            lo_we = 1'b1; lo_addr = pc_r[CACHE_BITS-1:0];
            lo_data = {pc_r[13:CACHE_BITS], byte1, ram_data_s2};
            hi_we = 1'b1; hi_addr = pc_r[CACHE_BITS-1:0]; hi_data = {1'b1, byte0};
            state <= S_IDLE;
          end else if(!verify_pass) begin
            // First read of this word: stash it and read the same word
            // again, rather than committing straight away.
            rd_word_a <= {byte0, byte1, ram_data_s2};
            verify_pass <= 1'b1;
            state <= S_RD_ADDR0;
          end else if({byte0, byte1, ram_data_s2} == rd_word_a) begin
            // Two consecutive reads agree -- commit.
            dout_r <= rd_word_a;
            pc_last_done <= pc_r;
            lo_we = 1'b1; lo_addr = pc_r[CACHE_BITS-1:0];
            lo_data = {pc_r[13:CACHE_BITS], rd_word_a[15:0]};
            hi_we = 1'b1; hi_addr = pc_r[CACHE_BITS-1:0]; hi_data = {1'b1, rd_word_a[23:16]};
            verify_pass <= 1'b0;
            state <= S_IDLE;
          end else if(retry_cnt >= MAX_RETRY) begin
            // Too many disagreements. Accept the latest read rather than
            // retrying forever -- a stalled fetch hangs the DSP outright,
            // which is worse than an occasional wrong word.
            verify_errors <= verify_errors + 1'b1;
            dout_r <= {byte0, byte1, ram_data_s2};
            pc_last_done <= pc_r;
            lo_we = 1'b1; lo_addr = pc_r[CACHE_BITS-1:0];
            lo_data = {pc_r[13:CACHE_BITS], byte1, ram_data_s2};
            hi_we = 1'b1; hi_addr = pc_r[CACHE_BITS-1:0]; hi_data = {1'b1, byte0};
            verify_pass <= 1'b0;
            retry_cnt <= 3'd0;
            state <= S_IDLE;
          end else begin
            // Disagreement: at least one of the two reads was wrong.
            // Start over rather than guessing which. Counted so the
            // rate is observable if a readback path is ever added.
            verify_errors <= verify_errors + 1'b1;
            retry_cnt <= retry_cnt + 1'b1;
            verify_pass <= 1'b0;
            state <= S_RD_ADDR0;
          end
        end else hold_cnt <= hold_cnt - 1;
      end

      default: state <= S_IDLE;
    endcase
    end

    // THE single write port for cache_data_lo (see declaration above).
    // One address expression, one data expression, one enable -- which
    // is what block RAM inference requires.
    if(lo_we) cache_data_lo[lo_addr] <= lo_data;
    if(hi_we) cache_data_hi[hi_addr] <= hi_data;
    // Evaluated here, at the end of the block, so lo_we/lo_addr already
    // hold their final values for this cycle.
    cache_q_dirty <= (lo_we && (lo_addr == cache_raddr[CACHE_BITS-1:0]))
                  || (hi_we && (hi_addr == cache_raddr[CACHE_BITS-1:0]));
  end

endmodule
