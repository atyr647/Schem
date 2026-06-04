// soc_tb.v -- reference testbench / oracle generator for soc.v (Arlet 6502).
//
// Holds reset across two clocks (the Arlet core needs the reset asserted long
// enough to flush its state machine to BRK0), releases it, then free-runs the
// clock for a fixed number of cycles. On every rising edge it samples the
// post-edge bus state and prints exactly one oracle line:
//
//     cycle <n> AB=<hhhh> DB=<hh> WE=<b> DI=<hh> R10=<hh> R24=<hh>
//
// where AB = address bus (4 hex), DB = CPU write-data DO (2 hex), WE = write
// enable (0/1), DI = data presented to the CPU (2 hex), R10 = RAM[$0010],
// R24 = RAM[$0024]. These are the few observable signals the README documents.
// Output goes to stdout (-> cpu6502.ref.trace) and a VCD is dumped.
//
// Cycle numbering: the reset edges are NOT counted. cycle 0 is the first
// post-reset rising edge. The trace is deterministic and reproduces byte-for-
// byte on the pinned tools (Icarus 12.0).
`timescale 1ns/1ps
module soc_tb;
    reg         clk = 1'b0;
    reg         reset = 1'b1;
    wire [15:0] AB;
    wire [7:0]  DO;
    wire        WE;
    wire [7:0]  DI;
    wire [7:0]  R10;
    wire [7:0]  R24;
    integer     cyc;

    soc dut(
        .clk   (clk),
        .reset (reset),
        .AB    (AB),
        .DO    (DO),
        .WE    (WE),
        .DI    (DI),
        .ram10 (R10),
        .ram24 (R24)
    );

    initial begin
        $dumpfile("soc.ref.vcd");
        $dumpvars(0, soc_tb);

        // Hold reset across two full clocks so the core reaches BRK0.
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;            // release reset before the next rising edge

        for (cyc = 0; cyc < 220; cyc = cyc + 1) begin
            @(posedge clk);
            #1;                 // let nonblocking updates settle before sampling
            $display("cycle %0d AB=%04h DB=%02h WE=%0d DI=%02h R10=%02h R24=%02h",
                     cyc, AB, DO, WE, DI, R10, R24);
        end
        $finish;
    end

    // free-running clock, 10ns period
    always #5 clk = ~clk;
endmodule
