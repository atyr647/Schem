// counter.v - 8-bit synchronous up-counter
//
// Phase 0 ground-truth fixture for the software-FPGA initiative.
// Synthesizable. Synchronous active-high reset (a synchronous reset keeps the
// netlist purely a bank of D flip-flops + adder, which is the easiest shape
// for a cycle-accurate interpreter to consume).
//
// Ports:
//   clk   - clock, counts on rising edge
//   rst   - synchronous active-high reset; when asserted at a rising edge q<=0
//   q[7:0]- current count value, wraps 255 -> 0
module counter (
    input  wire       clk,
    input  wire       rst,
    output reg  [7:0] q
);
    always @(posedge clk) begin
        if (rst)
            q <= 8'h00;
        else
            q <= q + 8'h01;
    end
endmodule
