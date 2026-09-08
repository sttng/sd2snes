`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// st011_rate_tb -- does the core keep up with ST011's host protocol?
//
// This is the test the previous investigation was missing. Every earlier
// test asked whether the core computed or fetched the RIGHT data. None
// asked whether it did so FAST ENOUGH, and that turns out to be the whole
// problem.
//
// The MesenCE reference trace (mesen_trace/) shows the host accessing the
// DSP's data register on a rigid schedule: 309 of 399 gaps are exactly 8
// DSP instructions, 73 are 9, and not one is ever shorter. A fixed cadence
// with no dependence on what the DSP is doing means DMA -- the SNES cannot
// drive an A-bus location that fast from a CPU loop -- so there is no
// handshake and no backpressure. One byte per 8 SNES master cycles, 372ns.
//
// The DSP's transfer loop is 4 instructions (trace words 197-200 inbound,
// 243-246 outbound), and its byte counter is decremented once per byte the
// DSP itself consumes. So if the core cannot retire 4 instructions per
// 372ns, DR is overwritten before it is read, the counter never reaches
// zero, and the DSP parks in its JRQM wait forever while the game polls SR
// forever. That is the observed hang.
//
// The test below reproduces exactly that: a host writing DR every 372ns,
// unconditionally, against the same 4-instruction loop. Run it with
// SKIP_ALU2/PC_LOOKAHEAD at 0 to see the old core fail it.
//
//   iverilog -g2005 -DMK3 -o rate.out -s st011_rate_tb \
//       st011_rate_tb.v upd77c25.v upd77c25_extpgm.v ip_stubs.v && vvp rate.out
// ---------------------------------------------------------------------------

module st011_rate_tb;

  // A/B knobs, overridden per-instance below.
  parameter integer OPT = 1;   // 0 = pre-fix core, for A/B
  parameter integer WAITSTATES = 0;  // dsp_feat[3:0], as smc.c sets it
  parameter integer WARM = 1;        // 0 = enter the loop with a cold cache,
                                     //     which is what happens on the very
                                     //     first command the game issues
  parameter integer RD_VERIFY = 1;   // module's READ_VERIFY
  parameter integer PREWARM_EN = 1;  // module's PREWARM_ENABLE, for the
                                     //   with/without control pair
  parameter integer PREWARM = 0;     // 1 = load the program through PGM_WR
                                     //     (as the MCU does) and wait for the
                                     //     one-shot cache prewarm to finish
                                     //     before the first command

  localparam real CLK_NS      = 1000.0/96.0;  // 96MHz, as main.v
  localparam integer HOST_PS  = 372549;       // 8 SNES master cycles @21.477MHz
  localparam integer WARM_N   = 16;           // bytes to warm the loop
  localparam integer TEST_N   = 64;           // bytes that must all arrive

  reg CLK = 0;
  always #(CLK_NS/2.0) CLK = ~CLK;

  reg RST = 0;
  reg [7:0] DI = 0;
  reg A0 = 0;
  reg enable = 0;
  reg reg_we_rising = 0;
  reg reg_oe_rising = 0;

  reg PGM_WR = 0;
  reg [23:0] PGM_DI = 0;
  reg [13:0] PGM_WR_ADDR = 0;

  wire [18:0] RAM_ADDR;
  wire [7:0]  RAM_DATA;
  wire RAM_OE, RAM_WE;

  // ---- device under test ----
  upd77c25 #(.SKIP_ALU2(OPT), .PC_LOOKAHEAD(OPT),
             .PREWARM_ENABLE(PREWARM_EN), .READ_VERIFY(RD_VERIFY)) dut (
    .DI(DI), .DO(), .A0(A0), .enable(enable),
    .reg_oe_falling(1'b0), .reg_oe_rising(reg_oe_rising),
    .reg_we_rising(reg_we_rising),
    .RST(RST), .CLK(CLK),
    .PGM_WR(PGM_WR), .PGM_DI(PGM_DI), .PGM_WR_ADDR(PGM_WR_ADDR),
    .psram_rrq(), .psram_addr(), .psram_din(16'd0), .psram_rdy(1'b0),
    .vsum_start(1'b0), .vsum_busy(), .vsum(),
    .DAT_WR(1'b0), .DAT_DI(16'd0), .DAT_WR_ADDR(11'd0),
    .DP_enable(1'b0), .DP_ADDR(12'd0),
    .dsp_feat(WAITSTATES[15:0]),      // cpu_wait
    .ext_pgm_en(1'b1),
    .RAM_ADDR(RAM_ADDR), .RAM_DATA(RAM_DATA), .RAM_OE(RAM_OE), .RAM_WE(RAM_WE),
    .ss_halt(1'b0), .ss_window_en(1'b0), .ss_halted(),
    .updDR(), .updSR(), .updPC(), .updA(), .updB(), .updFL_A(), .updFL_B()
  );

  // ---- behavioural async SRAM, 45ns access (same model as extpgm_tb) ----
  reg [7:0] mem [0:262143];
  wire [7:0] sram_out = (!RAM_OE && RAM_WE) ? mem[RAM_ADDR] : 8'bz;
  assign #45 RAM_DATA = sram_out;
  // Write capture on the rising edge of WE, as a real async SRAM latches.
  // Needed for the PREWARM path, which loads the program through PGM_WR
  // rather than poking mem[] directly.
  always @(posedge RAM_WE) mem[RAM_ADDR] <= RAM_DATA;

  // ---- program image ------------------------------------------------------
  // Big-endian in SRAM: mem[3w+0] = opcode[23:16], and so on.
  task put; input [13:0] w; input [23:0] op; begin
    mem[3*w+0] = op[23:16]; mem[3*w+1] = op[15:8]; mem[3*w+2] = op[7:0];
  end endtask

  // Same word, but delivered the way the MCU actually delivers it: through
  // PGM_WR, which stores little-endian and is un-reversed again on the read
  // side. Going through this path is what arms the one-shot prewarm.
  task put_pgm; input [13:0] w; input [23:0] op; begin
    @(posedge CLK);
    PGM_WR_ADDR = w; PGM_DI = {op[7:0], op[15:8], op[23:16]}; PGM_WR = 1'b1;
    @(posedge CLK); PGM_WR = 1'b0;
    wait (!dut.extpgm.wr_busy);
  end endtask

  // opcode builders
  function [23:0] LD;  input [15:0] id; input [3:0] dst;
    LD = {2'b11, id, 2'b00, dst}; endfunction
  function [23:0] JP;  input [8:0] brch; input [10:0] na;
    JP = {2'b10, brch, na, 2'b00}; endfunction
  function [23:0] OPI; input [3:0] alu; input [3:0] src; input [3:0] dst;
    OPI = {2'b00, 2'b00, alu, 1'b0, 2'b00, 4'b0000, 1'b0, src, dst}; endfunction

  localparam [8:0] BR_JRQM = 9'b010_111_110; // jump while RQM == 1
  localparam [8:0] BR_JMP  = 9'b100_000_000; // unconditional, page bit clear
  localparam [3:0] SRC_DR  = 4'b1000;        // reading DR sets RQM
  localparam [3:0] DST_DR  = 4'b0110;        // writing DR sets RQM
  localparam [3:0] DST_SR  = 4'b0111;
  localparam [3:0] DST_NON = 4'b0000;

  // ---- observers ----------------------------------------------------------
  integer consumed;      // times the core executed the DR-read instruction
  integer host_writes;
  integer insn_count;
  integer t_first, t_last;
  reg [13:0] pc_prev;
  reg counting;

  always @(posedge CLK) begin
    if(RST) begin
      // one event per instruction: the FETCH state is entered once each
      if(dut.insn_state == dut.STATE_FETCH) begin
        insn_count <= insn_count + 1;
        if(dut.pc == 14'd3 && counting) consumed <= consumed + 1;
      end
    end
  end

  // ---- host: writes DR on a fixed period, exactly like DMA ----------------
  task host_write_dr; input [7:0] v; begin
    @(posedge CLK); DI = v; A0 = 1'b0; enable = 1'b1; reg_we_rising = 1'b1;
    @(posedge CLK); reg_we_rising = 1'b0; enable = 1'b0;
    host_writes = host_writes + 1;
  end endtask

  integer i;
  real cyc_per_insn;
  integer insn_at_start;

  initial begin
    consumed = 0; host_writes = 0; insn_count = 0; counting = 0;
    pc_prev = 0;

    for(i = 0; i < 262144; i = i + 1) mem[i] = 8'h00;

    // program: word 0-1 set up, 2-5 are the transfer loop
    if(PREWARM == 0) begin
      put(14'd0, LD(16'h0400, DST_SR));     // DRC=1 -> 8-bit DR transfers
      put(14'd1, LD(16'h0000, DST_DR));     // post a result -> sets RQM
      put(14'd2, JP(BR_JRQM, 11'd2));       // spin while RQM==1 (host pending)
      put(14'd3, OPI(4'd0, SRC_DR, DST_NON));// consume the byte -> sets RQM
      put(14'd4, OPI(4'd0, 4'b0001, DST_NON));// filler, as trace word 200
      put(14'd5, JP(BR_JMP, 11'd2));        // back to the wait
    end

    RST = 0;
    repeat (10) @(posedge CLK);
    RST = 1;

    // The cache invalidation sweep takes 2^CACHE_BITS cycles after
    // configuration and gates every hit until it finishes; on hardware
    // it completes long before the firmware download does.
    wait (dut.extpgm.cache_ready);

    if(PREWARM != 0) begin
      // Download through PGM_WR, exactly as the MCU does. This sets
      // prewarm_armed; the module then waits PREWARM_WR_IDLE cycles of
      // quiet before sweeping every entry into the cache.
      put_pgm(14'd0, LD(16'h0400, DST_SR));
      put_pgm(14'd1, LD(16'h0000, DST_DR));
      put_pgm(14'd2, JP(BR_JRQM, 11'd2));
      put_pgm(14'd3, OPI(4'd0, SRC_DR, DST_NON));
      put_pgm(14'd4, OPI(4'd0, 4'b0001, DST_NON));
      put_pgm(14'd5, JP(BR_JMP, 11'd2));
      $display("  download done at %0t, waiting for prewarm...", $time);
      if(PREWARM_EN != 0) begin
        wait (dut.extpgm.prewarm_active);
        $display("  prewarm started at %0t", $time);
        wait (dut.extpgm.prewarm_done);
        $display("  prewarm finished at %0t", $time);
      end else begin
        // control: no prewarm, just let the download settle
        repeat (70000) @(posedge CLK);
        $display("  prewarm DISABLED (control run)");
      end
    end

    // Optionally warm the loop first. WARM=0 is the honest case: on the
    // game's first command, words 199/200 of the real loop have never
    // been executed and each costs a full ~30-cycle external fetch.
    if(WARM != 0) begin
      for(i = 0; i < WARM_N; i = i + 1) begin
        #(HOST_PS/1000.0) host_write_dr(8'h20 + i[7:0]);
      end
    end else begin
      // just let it reach the wait loop
      repeat (400) @(posedge CLK);
    end

    // ---- measurement window ----
    counting = 1;
    consumed = 0;
    insn_at_start = insn_count;
    t_first = $time;
    for(i = 0; i < TEST_N; i = i + 1) begin
      #(HOST_PS/1000.0) host_write_dr(8'h40 + i[7:0]);
    end
    #(HOST_PS/1000.0 * 4);
    t_last = $time;

    cyc_per_insn = ((t_last - t_first) / CLK_NS)
                   / (insn_count - insn_at_start);

    $display("");
    $display("  OPT=%0d  waitstates=%0d  warm=%0d", OPT, WAITSTATES, WARM);
    $display("  cycles per instruction         = %0.2f", cyc_per_insn);
    $display("  instructions per 372ns slot    = %0.2f",
             (HOST_PS/1000.0) / (cyc_per_insn * CLK_NS));
    $display("  host bytes written             = %0d", TEST_N);
    $display("  bytes the DSP consumed         = %0d", consumed);
    if(consumed >= TEST_N)
      $display("  RESULT: PASS -- keeps up with the DMA cadence");
    else
      $display("  RESULT: FAIL -- dropped %0d bytes; ST011 would hang here",
               TEST_N - consumed);
    $display("");
    $finish;
  end

  initial begin
    #4000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
