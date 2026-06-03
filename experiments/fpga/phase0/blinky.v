// blinky.v - parameterized clock divider that toggles an LED output
//
// Phase 0 ground-truth fixture for the software-FPGA initiative. Synthesizable.
//
// Parameter:
//   WIDTH    - width of the internal divider counter (default 4 to keep the
//              synthesized netlist tiny for the spike). The led toggles every
//              time the counter reaches DIVISOR-1.
//   DIVISOR  - count value at which the led toggles and the counter resets.
//
// Ports:
//   clk - clock
//   rst - synchronous active-high reset (clears counter and led)
//   led - divided/toggled output
module blinky #(
    parameter integer WIDTH   = 4,
    parameter integer DIVISOR = 10
) (
    input  wire clk,
    input  wire rst,
    output reg  led
);
    reg [WIDTH-1:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt <= {WIDTH{1'b0}};
            led <= 1'b0;
        end else if (cnt == DIVISOR[WIDTH-1:0] - 1) begin
            cnt <= {WIDTH{1'b0}};
            led <= ~led;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule
