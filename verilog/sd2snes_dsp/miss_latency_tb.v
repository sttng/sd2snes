`timescale 1ns/1ps
module miss_tb;
  parameter integer RV = 1;
  parameter integer HOLD_OVR = 8;
  reg CLK=0; always #5.20833 CLK=~CLK;   // 96MHz
  reg [13:0] pc=0; wire [23:0] dout; wire ready;
  wire [18:0] RAM_ADDR; wire [7:0] RAM_DATA; wire RAM_OE, RAM_WE;
  upd77c25_extpgm #(.READ_VERIFY(RV), .PREWARM_ENABLE(0)) dut (
    .CLK(CLK), .enable(1'b1), .pc(pc), .pc_early(14'd0), .pc_early_valid(1'b0),
    .dout(dout), .ready(ready),
    .PGM_WR(1'b0), .PGM_DI(24'd0), .PGM_WR_ADDR(14'd0), .wr_busy(),
    .psram_rrq(), .psram_addr(), .psram_din(16'd0), .psram_rdy(1'b0),
    .vsum_start(1'b0), .vsum_busy(), .vsum(),
    .RAM_ADDR(RAM_ADDR), .RAM_DATA(RAM_DATA), .RAM_OE(RAM_OE), .RAM_WE(RAM_WE));
  reg [7:0] mem [0:262143];
  wire [7:0] so = (!RAM_OE && RAM_WE) ? mem[RAM_ADDR] : 8'bz;
  assign #45 RAM_DATA = so;
  integer i; real t0; real tot; integer n;
  initial begin
    for(i=0;i<3*4096;i=i+1) mem[i] = i[7:0];
    wait (dut.cache_ready);
    tot=0; n=0;
    for(i=0;i<64;i=i+1) begin
      @(posedge CLK); pc = i[13:0] + 14'd100;   // every one a cold miss
      t0 = $realtime;
      wait (ready); @(posedge CLK);
      tot = tot + ($realtime - t0); n = n + 1;
    end
    $display("  READ_VERIFY=%0d   miss latency = %0.1f ns = %0.1f cycles @96MHz",
             RV, tot/n, (tot/n)/10.41667);
    $finish;
  end
endmodule
