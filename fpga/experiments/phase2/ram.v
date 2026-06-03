// ram.v -- a small synchronous RAM, to drive Schem's $mem support.
//
// One write port (synchronous, write-enable) and one synchronous read port --
// the canonical block-RAM shape Yosys infers a $mem/$mem_v2 cell for, and the
// shape every real core (register files, video RAM, ROM) is built from.
module ram #(
    parameter AW = 4,           // address width  -> 16 words
    parameter DW = 8            // data width
) (
    input              clk,
    input              we,      // write enable
    input  [AW-1:0]    waddr,
    input  [DW-1:0]    wdata,
    input  [AW-1:0]    raddr,
    output reg [DW-1:0] rdata    // registered (synchronous) read
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];     // read latched on the same edge (read-old-data)
    end
endmodule
