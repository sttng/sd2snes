`timescale 1ns/1ns

module extpgm_tb;

  reg CLK = 0;
  reg enable = 1;
  reg [13:0] pc = 0;
  wire [23:0] dout;
  wire ready;

  reg PGM_WR = 0;
  reg [23:0] PGM_DI = 0;
  reg [13:0] PGM_WR_ADDR = 0;
  wire wr_busy;

  wire [18:0] RAM_ADDR;
  wire [7:0] RAM_DATA;
  wire RAM_OE;
  wire RAM_WE;

  always #5 CLK = ~CLK; // 100MHz-ish, arbitrary for this test

  upd77c25_extpgm dut (
    .CLK(CLK), .enable(enable),
    .pc(pc), .pc_early(14'd0), .pc_early_valid(1'b0), .dout(dout), .ready(ready),
    .PGM_WR(PGM_WR), .PGM_DI(PGM_DI), .PGM_WR_ADDR(PGM_WR_ADDR), .wr_busy(wr_busy),
    .RAM_ADDR(RAM_ADDR), .RAM_DATA(RAM_DATA), .RAM_OE(RAM_OE), .RAM_WE(RAM_WE)
  );

  // ---- behavioral async SRAM model, active-low OE/WE (matches real part) ----
  reg [7:0] mem [0:262143];
  // SRAM drives RAM_DATA only when OE asserted and WE deasserted (a real
  // chip never drives its output pins during a write cycle) -- driven from
  // the memory array only, no feedback through RAM_DATA itself.
  //
  // Modelled with a realistic access delay rather than responding
  // instantaneously. A zero-delay model is perfectly synchronous with CLK
  // by construction, which is exactly why every earlier simulation missed
  // the unsynchronized-read bug: samples looked clean no matter when they
  // were taken. 45ns matches the part's spec and deliberately does not
  // divide evenly into the 96MHz clock period, so data transitions land
  // at varying phases relative to the sampling edge -- much closer to
  // real hardware behaviour.
  wire [7:0] sram_out = (!RAM_OE && RAM_WE) ? mem[RAM_ADDR] : 8'bz;
  assign #45 RAM_DATA = sram_out;
  // capture happens when WE returns high (real SRAM latches on this edge);
  // by then the module under test has held address/data stable for
  // POST_CYCLES already, so this is safe to sample directly
  always @(posedge RAM_WE) begin
    mem[RAM_ADDR] <= RAM_DATA;
  end
  // sanity: OE and WE should never both be asserted at once
  always @(*) begin
    if (!RAM_OE && !RAM_WE)
      $display("*** BUS CONTENTION: RAM_OE and RAM_WE both asserted at t=%0t ***", $time);
  end

  integer errors = 0;

  task write_word(input [13:0] addr, input [23:0] data);
    begin
      @(posedge CLK);
      PGM_WR_ADDR = addr;
      PGM_DI = data;
      PGM_WR = 1;
      @(posedge CLK);
      PGM_WR = 0;
      // realistic MCU pacing: the real download protocol is SPI-paced and
      // gives many tens-to-hundreds of cycles of slack between words (see
      // mcu_cmd.v's spi_byte_cnt-driven sequencing) -- wait for this write
      // to fully land before the next one, rather than firing back-to-back
      // faster than any real scenario would.
      while (wr_busy) begin @(posedge CLK); #1; end
      repeat(5) @(posedge CLK);
    end
  endtask

  task check_fetch(input [13:0] addr, input [23:0] expected);
    begin
      pc = addr;
      @(posedge CLK); #1;
      while (!ready) begin @(posedge CLK); #1; end
      if (dout !== expected) begin
        $display("FAIL: pc=%0d expected=%h got=%h", addr, expected, dout);
        errors = errors + 1;
      end else begin
        $display("OK:   pc=%0d dout=%h", addr, dout);
      end
    end
  endtask

  // ---- race-condition test ----
  // Sets pc via a NON-BLOCKING assignment landing on a clock edge, exactly
  // matching how upd77c25's real pc register updates during STATE_STORE,
  // then checks `ready` on that SAME edge with no extra settle cycle --
  // exactly the scenario cpu_wait=0 (ST010/ST011's real configuration,
  // confirmed from smc.c's fpga_dspfeat=0 for has_st0010) creates, where
  // the CPU's own ready-check can land on the identical edge pc changes.
  // The earlier registered-ready design would show stale ready=1 here;
  // this combinational one shouldn't.
  task race_check_fetch(input [13:0] addr, input [23:0] expected);
    begin
      @(posedge CLK);
      pc <= addr; // non-blocking: takes effect at the end of THIS edge,
                  // same as upd77c25's real pc <= ... in STATE_STORE
      #1;         // let this edge's non-blocking updates settle, nothing more
      if (ready) begin
        // ready=1 immediately after pc changed is only valid if this is a
        // real, deliberate "no fetch needed" case. Either way, ready=1 is
        // a promise that dout is correct RIGHT NOW -- check immediately,
        // don't give it extra cycles to become correct after the fact.
        if (dout !== expected) begin
          $display("RACE FAIL: pc=%0d ready was immediately 1 but dout=%h (expected %h) -- stale data raced through", addr, dout, expected);
          errors = errors + 1;
        end else begin
          $display("RACE OK:   pc=%0d ready immediately 1 and dout=%h correctly matches (no fetch was needed)", addr, dout);
        end
      end else begin
        // correctly not ready yet -- wait for the real fetch, then check
        while (!ready) @(posedge CLK);
        #1;
        if (dout !== expected) begin
          $display("RACE FAIL: pc=%0d expected=%h got=%h after waiting for ready", addr, expected, dout);
          errors = errors + 1;
        end else begin
          $display("RACE OK:   pc=%0d dout=%h (correctly waited for ready, no race)", addr, dout);
        end
      end
    end
  endtask

  initial begin
    // No RST input on this module anymore (see its header comment for
    // why) -- its power-up state comes from Verilog initial values,
    // matching what real FPGA configuration does. Just let a few cycles
    // pass before driving stimulus.
    repeat(3) @(posedge CLK);

    $monitor("t=%0t state=%0d pc=%0d pc_r=%0d pc_last_done=%0d RAM_ADDR=%h RAM_OE=%b RAM_WE=%b RAM_DATA=%h dout=%h ready=%b wr_pending=%b",
             $time, dut.state, pc, dut.pc_r, dut.pc_last_done, RAM_ADDR, RAM_OE, RAM_WE, RAM_DATA, dout, ready, dut.wr_pending);

    // ---- targeted test: fetch-before-firmware-loaded ----
    // pc is already 0 (its post-reset default, matching upd77c25's real pc
    // register), enable=1, and no write has happened yet -- this forces
    // exactly the scenario that motivated the cache-invalidation fix: a
    // garbage pre-load read gets cached, then the real word 0 is written,
    // then pc=0 is fetched again and must NOT return the stale garbage.
    pc = 0;
    repeat(60) @(posedge CLK); // let the bogus pre-load fetch complete and cache
    write_word(0, 24'hAA5511);
    check_fetch(0, 24'h1155AA);
    if (dout === 24'hAA5511)
      $display("PRE-LOAD-FETCH TEST: OK (cache correctly invalidated after write)");

    // write three words at addresses 0, 1, 2
    write_word(0, 24'h123456);
    write_word(1, 24'hABCDEF);
    write_word(2, 24'h010203);

    // let any in-flight write sequence drain before fetching
    while (wr_busy) @(posedge CLK);
    repeat(20) @(posedge CLK);

    check_fetch(0, 24'h563412);
    check_fetch(1, 24'hEFCDAB);
    check_fetch(2, 24'h030201);
    // re-fetch pc=0 again (tests the "already matches, no re-fetch needed" path)
    check_fetch(0, 24'h563412);
    // jump around using EXACT real-CPU timing (non-blocking pc update,
    // checked on the same edge, no settle cycle) -- this is what actually
    // stresses the cpu_wait=0 race
    race_check_fetch(2, 24'h030201);
    race_check_fetch(1, 24'hEFCDAB);
    race_check_fetch(0, 24'h563412);
    race_check_fetch(2, 24'h030201);
    race_check_fetch(0, 24'h563412);

    // ---- cache/write ordering hazard test ----
    // Specifically targets a hazard found while reviewing the cache
    // implementation: a PGM_WR landing while a fetch of that SAME address
    // is mid-cache-check could let the cache serve the stale pre-write
    // value (and assert ready on it) before the write lands and
    // invalidates the slot. Address 1 is known-cached at this point (it
    // was fetched above), so this exercises exactly that path.
    $display("--- cache/write ordering hazard test ---");
    // Kick off a fetch of address 1 (currently cached -> would hit), then
    // fire a write to address 1 one cycle later, landing while that fetch
    // is in the cache-check state.
    pc = 1;
    @(posedge CLK);
    PGM_WR_ADDR = 1;
    PGM_DI = 24'h999999;
    PGM_WR = 1;
    @(posedge CLK);
    PGM_WR = 0;
    // let everything settle: write must complete, and the fetch must
    // re-resolve against post-write data
    while (wr_busy) begin @(posedge CLK); #1; end
    repeat(10) @(posedge CLK);
    // Now read address 1 -- must return the NEW value, byte-reversed by
    // the read-side correction (999999 reversed is still 999999, so use a
    // distinguishable value check via a second write below instead).
    check_fetch(1, 24'h999999);

    // Repeat with an asymmetric value so a byte-order or staleness error
    // can't hide behind a palindrome.
    pc = 1;
    @(posedge CLK);
    PGM_WR_ADDR = 1;
    PGM_DI = 24'h112233;
    PGM_WR = 1;
    @(posedge CLK);
    PGM_WR = 0;
    while (wr_busy) begin @(posedge CLK); #1; end
    repeat(10) @(posedge CLK);
    check_fetch(1, 24'h332211); // read-side byte-order correction applied

    // ---- precise cycle-aligned hazard test ----
    // The tests above don't actually hit the dangerous window: they let
    // the write settle before re-fetching. The real hazard needs PGM_WR
    // high on the EXACT edge the fetch is in S_CACHE_CHECK. Reproduce
    // that alignment deliberately: address 1 is cached (just fetched),
    // so setting pc=1 from a settled state enters S_CACHE_CHECK exactly
    // one cycle later -- fire PGM_WR on that edge.
    $display("--- precise cycle-aligned cache/write hazard ---");
    pc = 0;                       // move away so pc=1 will be "stale"
    @(posedge CLK); #1;
    while (!ready) begin @(posedge CLK); #1; end
    // now settled in S_IDLE with pc=0 resolved
    pc = 1;                       // request address 1 (cached -> would hit)
    @(posedge CLK);               // this edge: S_IDLE sees pc_stale -> S_CACHE_CHECK
    PGM_WR_ADDR = 1;              // set up write to that SAME address
    PGM_DI = 24'h445566;
    PGM_WR = 1;                   // high during the S_CACHE_CHECK edge
    @(posedge CLK);               // <-- the dangerous edge
    PGM_WR = 0;
    while (wr_busy) begin @(posedge CLK); #1; end
    repeat(10) @(posedge CLK);
    // Must see the NEW value. If the cache served the stale pre-write
    // value on that edge, pc_last_done was set for address 1 with old
    // data and this returns 332211 instead.
    check_fetch(1, 24'h665544);

    if (errors == 0)
      $display("ALL TESTS PASSED");
    else
      $display("%0d TEST(S) FAILED", errors);

    $finish;
  end

  // safety timeout
  initial begin
    #100000;
    $display("*** TIMEOUT -- ready never asserted, module likely hung ***");
    $finish;
  end

endmodule
