// counter_tb.v - reference testbench / oracle generator for counter.v
//
// Drives one reset cycle then 40 free-running clock cycles. On every rising
// edge it samples q (the value AFTER that edge) and prints exactly one line:
//     cycle <n> q=<decimal>
// to stdout (redirected into counter.ref.trace), and dumps a VCD.
//
// Cycle numbering convention (see NOTES.md):
//   * The reset edge is NOT counted/printed.
//   * cycle 0 is the first post-reset rising edge; after it q==0 (the design
//     was already held at 0 by reset, so the first counted edge increments...
//     actually q goes 0 -> 1). We sample q AFTER the edge: cycle 0 prints the
//     value latched at that edge. With reset clearing q to 0 on the reset edge,
//     the first counted edge yields q=1. cycle n prints q == (n+1) & 0xFF.
// The downstream oracle only needs the literal text; the exact convention is
// documented so a re-implementation can reproduce identical lines.
`timescale 1ns/1ps
module counter_tb;
    reg        clk = 1'b0;
    reg        rst = 1'b1;
    wire [7:0] q;
    integer    cyc;

    counter dut (.clk(clk), .rst(rst), .q(q));

    initial begin
        $dumpfile("counter.ref.vcd");
        $dumpvars(0, counter_tb);

        // Hold reset across one full clock so the reset edge clears q.
        @(posedge clk);          // reset rising edge: q <= 0
        @(negedge clk);
        rst = 1'b0;              // release reset before next rising edge

        for (cyc = 0; cyc < 40; cyc = cyc + 1) begin
            @(posedge clk);      // counting edge
            #1;                  // settle nonblocking update before sampling
            $display("cycle %0d q=%0d", cyc, q);
        end
        $finish;
    end

    // free-running clock, 10ns period
    always #5 clk = ~clk;
endmodule
