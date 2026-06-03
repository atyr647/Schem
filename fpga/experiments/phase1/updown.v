// updown.v - 4-bit up/down counter with synchronous load and count-enable
//
// Phase 1 ground-truth fixture for the software-FPGA initiative.  A second,
// independently verified example that exercises MORE of the bit-level cell set
// than the phase 0 counter: a load multiplexer (data vs next-count) feeding a
// bank of enable-able flip-flops, and an up/down adder/subtractor whose carry
// chain synthesizes to XOR/AND/OR/ANDNOT/ORNOT plus 2:1 muxes.
//
// Synchronous active-high reset keeps the netlist a pure bank of D flip-flops
// (with clock-enable) plus combinational next-state logic -- the easiest shape
// for the cycle-accurate interpreter to consume.
//
// Ports:
//   clk    - clock, acts on rising edge
//   rst    - synchronous active-high reset; q <= 0 at a rising edge
//   en     - count enable; when 0 the counter holds (no load, no count)
//   load   - synchronous load; when en && load, q <= din at the rising edge
//   updn   - direction: 1 = count up, 0 = count down
//   din    - load data
//   q[3:0] - current value, wraps mod 16
module updown (
    input  wire       clk,
    input  wire       rst,
    input  wire       en,
    input  wire       load,
    input  wire       updn,
    input  wire [3:0] din,
    output reg  [3:0] q
);
    wire [3:0] step  = updn ? (q + 4'd1) : (q - 4'd1);
    wire [3:0] nextq = load ? din : step;

    always @(posedge clk) begin
        if (rst)
            q <= 4'd0;
        else if (en)
            q <= nextq;
    end
endmodule
