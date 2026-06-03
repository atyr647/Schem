// updown_tb.v - reference testbench / oracle generator for updown.v
//
// Drives one reset rising edge, then a scripted sequence of rising edges that
// exercises load, count-up, count-down, enable-hold, and wrap-around.  On every
// COUNTED rising edge it samples q (the value AFTER that edge) and prints exactly
// one line:
//     cycle <n> q=<decimal>
// to stdout (redirected into updown.ref.trace), and dumps a VCD.
//
// Cycle numbering convention (mirrors phase0/counter_tb.v):
//   * The reset edge is NOT counted/printed.
//   * cycle 0 is the first post-reset counted edge; q is sampled AFTER the edge.
//
// Stimulus script (control values are set on the negedge BEFORE each counted
// rising edge so they are stable at the edge -- the same discipline phase0 uses
// for releasing reset).  The exact schedule is reproduced bit-for-bit by the
// interpreter test (tests/test_fpga2.tcl).
`timescale 1ns/1ps
module updown_tb;
    reg        clk  = 1'b0;
    reg        rst  = 1'b1;
    reg        en   = 1'b0;
    reg        load = 1'b0;
    reg        updn = 1'b1;
    reg  [3:0] din  = 4'd0;
    wire [3:0] q;
    integer    cyc;

    updown dut (.clk(clk), .rst(rst), .en(en), .load(load),
                .updn(updn), .din(din), .q(q));

    // The per-cycle control schedule, applied on the negedge before each counted
    // rising edge.  {en, load, updn, din} for cycles 0..19.  Chosen to walk
    // through: load 10, count up (wrap 15->0), hold, count down (wrap 0->15),
    // and a reload.
    // cyc: en load updn din   effect
    //   0:  1   1    1    10   load 10
    //   1:  1   0    1    -    11
    //   2:  1   0    1    -    12
    //   3:  1   0    1    -    13
    //   4:  1   0    1    -    14
    //   5:  1   0    1    -    15
    //   6:  1   0    1    -    0   (wrap up)
    //   7:  0   0    1    -    0   (disabled -> hold)
    //   8:  1   0    0    -    15  (wrap down)
    //   9:  1   0    0    -    14
    //  10:  1   0    0    -    13
    //  11:  1   1    0    3    load 3
    //  12:  1   0    0    -    2
    //  13:  1   0    0    -    1
    //  14:  1   0    0    -    0
    //  15:  1   0    0    -    15  (wrap down)
    //  16:  0   1    1    9    disabled -> hold (load ignored)
    //  17:  1   0    1    -    0   (15 up -> wrap)
    //  18:  1   0    1    -    1
    //  19:  1   1    1    7    load 7
    reg [9:0] script [0:19];
    initial begin
        // pack {en[9], load[8], updn[7], din[3:0] padded to 8} -> use fields:
        // we encode as {en, load, updn, din[3:0]} = 7 bits, low to high din.
        script[0]  = {1'b1,1'b1,1'b1,4'd10};
        script[1]  = {1'b1,1'b0,1'b1,4'd0};
        script[2]  = {1'b1,1'b0,1'b1,4'd0};
        script[3]  = {1'b1,1'b0,1'b1,4'd0};
        script[4]  = {1'b1,1'b0,1'b1,4'd0};
        script[5]  = {1'b1,1'b0,1'b1,4'd0};
        script[6]  = {1'b1,1'b0,1'b1,4'd0};
        script[7]  = {1'b0,1'b0,1'b1,4'd0};
        script[8]  = {1'b1,1'b0,1'b0,4'd0};
        script[9]  = {1'b1,1'b0,1'b0,4'd0};
        script[10] = {1'b1,1'b0,1'b0,4'd0};
        script[11] = {1'b1,1'b1,1'b0,4'd3};
        script[12] = {1'b1,1'b0,1'b0,4'd0};
        script[13] = {1'b1,1'b0,1'b0,4'd0};
        script[14] = {1'b1,1'b0,1'b0,4'd0};
        script[15] = {1'b1,1'b0,1'b0,4'd0};
        script[16] = {1'b0,1'b1,1'b1,4'd9};
        script[17] = {1'b1,1'b0,1'b1,4'd0};
        script[18] = {1'b1,1'b0,1'b1,4'd0};
        script[19] = {1'b1,1'b1,1'b1,4'd7};
    end

    initial begin
        $dumpfile("updown.ref.vcd");
        $dumpvars(0, updown_tb);

        // Hold reset across one full clock so the reset edge clears q.
        @(posedge clk);          // reset rising edge: q <= 0
        @(negedge clk);
        rst = 1'b0;              // release reset before the next rising edge

        for (cyc = 0; cyc < 20; cyc = cyc + 1) begin
            // Apply this cycle's controls while clk is low (stable at the edge).
            en   = script[cyc][6];
            load = script[cyc][5];
            updn = script[cyc][4];
            din  = script[cyc][3:0];
            @(posedge clk);      // counting edge
            #1;                  // settle nonblocking update before sampling
            $display("cycle %0d q=%0d", cyc, q);
            @(negedge clk);
        end
        $finish;
    end

    // free-running clock, 10ns period
    always #5 clk = ~clk;
endmodule
