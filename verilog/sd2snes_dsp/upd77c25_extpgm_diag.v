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
  output reg [23:0] dout,
  output ready,

  // firmware download interface (same signals mcu_cmd.v already drives)
  input PGM_WR,
  input [23:0] PGM_DI,
  input [13:0] PGM_WR_ADDR,
  output wr_busy,

  // physical SRAM bus (board's Bus 2 SRAM: nominally 4Mbit/512KB, really
  // 256KB usable -- see comment above; 8-bit, 45ns)
  output reg [18:0] RAM_ADDR,
  inout [7:0] RAM_DATA,
  output reg RAM_OE = 1'b1, // active-low: 1 = deasserted/idle
  output reg RAM_WE = 1'b1
);

  // DIAGNOSTIC BUILD: HOLD_CYCLES/POST_CYCLES doubled from the original
  // conservative values (8/2) to test whether real SRAM timing margin is
  // the remaining issue. If this changes behavior on real hardware at
  // all, timing is implicated and these can be tuned properly from here;
  // if nothing changes, this rules timing out. Not meant as a permanent
  // fix on its own -- see the accompanying note for what to report back.
  localparam HOLD_CYCLES = 16;

  localparam S_IDLE       = 4'd0,
             S_WR_ADDR0   = 4'd1, S_WR_HOLD0 = 4'd2, S_WR_POST0 = 4'd3,
             S_WR_ADDR1   = 4'd4, S_WR_HOLD1 = 4'd5, S_WR_POST1 = 4'd6,
             S_WR_ADDR2   = 4'd7, S_WR_HOLD2 = 4'd8, S_WR_POST2 = 4'd9,
             S_RD_ADDR0   = 4'd10, S_RD_HOLD0 = 4'd11,
             S_RD_ADDR1   = 4'd12, S_RD_HOLD1 = 4'd13,
             S_RD_ADDR2   = 4'd14, S_RD_HOLD2 = 4'd15;

  localparam POST_CYCLES = 4; // address/data hold margin after WE deasserts (doubled for this diagnostic build)

  reg [3:0] state = S_IDLE;
  reg [4:0] hold_cnt; // widened from [3:0]: HOLD_CYCLES=16 needs 5 bits
  reg [2:0] post_cnt; // widened from [1:0]: POST_CYCLES=4 needs 3 bits

  reg [13:0] pc_r;          // pc the in-flight (or most recent) read is for
  reg [13:0] pc_last_done = 14'h3fff; // "never fetched" sentinel;
                                       // guaranteed mismatch vs pc=0
  reg [7:0] byte0, byte1;

  // Any PGM_WR pulse is captured immediately regardless of current state,
  // so a write request arriving mid-read is never silently dropped.
  reg wr_pending = 1'b0;
  reg [13:0] wr_pending_addr;
  reg [23:0] wr_pending_data;
  reg [13:0] wr_addr_r;
  reg [23:0] wr_data_r;

  reg [7:0] ram_data_out;
  reg ram_data_drive = 1'b0;

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
  assign ready = ~enable | ((pc_last_done == pc) & ~wr_busy);

  wire pc_stale = enable && (pc_last_done != pc);

  // word address -> byte address (x3), via shift+add rather than a
  // multiplier
  wire [16:0] pc_r_byte0      = {pc_r, 1'b0} + pc_r;
  wire [16:0] wr_addr_r_byte0 = {wr_addr_r, 1'b0} + wr_addr_r;

  always @(posedge CLK) begin
    // capture write requests unconditionally, every cycle -- no RST gating,
    // see module header comment for why
    if(PGM_WR) begin
      wr_pending <= 1'b1;
      wr_pending_addr <= PGM_WR_ADDR;
      wr_pending_data <= PGM_DI;
    end

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
        end else if(pc_stale) begin
          pc_r <= pc;
          state <= S_RD_ADDR0;
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
          state <= S_IDLE;
        end else post_cnt <= post_cnt - 1;
      end

      // ---- read byte 0 (bits 7:0) ----
      S_RD_ADDR0: begin
        RAM_ADDR <= {2'b0, pc_r_byte0};
        RAM_OE <= 1'b1;
        hold_cnt <= HOLD_CYCLES;
        state <= S_RD_HOLD0;
      end
      S_RD_HOLD0: begin
        RAM_OE <= 1'b0; // assert
        if(hold_cnt == 0) begin
          byte0 <= RAM_DATA; // sampled while still asserted (this cycle's
                              // non-blocking RAM_OE update takes effect
                              // next edge)
          RAM_OE <= 1'b1;
          state <= S_RD_ADDR1;
        end else hold_cnt <= hold_cnt - 1;
      end
      // ---- read byte 1 (bits 15:8) ----
      S_RD_ADDR1: begin
        RAM_ADDR <= {2'b0, pc_r_byte0} + 19'd1;
        RAM_OE <= 1'b1;
        hold_cnt <= HOLD_CYCLES;
        state <= S_RD_HOLD1;
      end
      S_RD_HOLD1: begin
        RAM_OE <= 1'b0;
        if(hold_cnt == 0) begin
          byte1 <= RAM_DATA;
          RAM_OE <= 1'b1;
          state <= S_RD_ADDR2;
        end else hold_cnt <= hold_cnt - 1;
      end
      // ---- read byte 2 (bits 23:16) ----
      S_RD_ADDR2: begin
        RAM_ADDR <= {2'b0, pc_r_byte0} + 19'd2;
        RAM_OE <= 1'b1;
        hold_cnt <= HOLD_CYCLES;
        state <= S_RD_HOLD2;
      end
      S_RD_HOLD2: begin
        RAM_OE <= 1'b0;
        if(hold_cnt == 0) begin
          // Corrects a byte-order mismatch between ares's firmware dump
          // format (little-endian: word's LSB is the first file byte)
          // and this system's loader (big-endian: first file byte
          // becomes the word's MSB, traced through load_dspx() /
          // fpga_write_dspx_pgm() / mcu_cmd.v's assembly). PGM_DI as
          // received is byte-reversed relative to the true instruction
          // (outer bytes swapped, middle byte unaffected) when the
          // firmware file on the SD card is in ares's native format.
          // Verified numerically against the actual st011.rom dump, not
          // just derived: simulating this exact byte path against ares's
          // own ground-truth instruction values showed 0/20 words
          // matching without this correction, 20/20 matching with it.
          // The write side stores PGM_DI's raw bytes as-is; this is
          // where that gets corrected, by swapping which SRAM byte
          // position (first-written/read vs last) supplies the high vs
          // low byte of the reassembled 24-bit word. See also
          // upd77c25.v's dat_doutb_fixed, which corrects the identical
          // mismatch on the data-ROM path.
          dout <= {byte0, byte1, RAM_DATA};
          RAM_OE <= 1'b1;
          pc_last_done <= pc_r;
          state <= S_IDLE;
        end else hold_cnt <= hold_cnt - 1;
      end

      default: state <= S_IDLE;
    endcase
  end

endmodule
