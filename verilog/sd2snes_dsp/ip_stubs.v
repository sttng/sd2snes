module upd77c25_datram(input clock, input wren_a, input [10:0] address_a,
  input [15:0] data_a, output reg [15:0] q_a, input wren_b,
  input [11:0] address_b, input [7:0] data_b, output reg [7:0] q_b);
  reg [15:0] m [0:2047];
  always @(posedge clock) begin
    if(wren_a) m[address_a] <= data_a; q_a <= m[address_a];
    q_b <= address_b[0] ? m[address_b[11:1]][15:8] : m[address_b[11:1]][7:0];
  end
endmodule
module upd77c25_datrom(input clock, input wren, input [10:0] wraddress,
  input [15:0] data, input [10:0] rdaddress, output reg [15:0] q);
  reg [15:0] m [0:2047];
  always @(posedge clock) begin if(wren) m[wraddress]<=data; q<=m[rdaddress]; end
endmodule
module upd77c25_pgmrom(input clock, input wren, input [10:0] wraddress,
  input [23:0] data, input [10:0] rdaddress, output reg [23:0] q);
  reg [23:0] m [0:2047];
  always @(posedge clock) begin if(wren) m[wraddress]<=data; q<=m[rdaddress]; end
endmodule
