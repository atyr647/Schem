// soc.v -- minimal 6502 system-on-chip harness for the phase3 fixture.
//
// Wraps Arlet Ottens' `cpu` (cpu.v + ALU.v) around a small synchronous RAM
// preloaded with a tiny test program (see README.md for the listing). This is
// the SYNTHESIS top: a self-contained, deterministic 6502 + memory with no
// external ports except clk/reset and a handful of observation outputs, so the
// whole thing bit-blasts to the engine's current cell set (gates + MUX +
// $_DFF_P_) once the RAM is mapped to flip-flops.
//
// Memory map (16-bit address space, but only the low 11 bits select RAM):
//   $0000-$07FF  2 KB RAM (program + data), address = AB[10:0].
//   $FFFC/$FFFD  reset vector, supplied by a tiny constant decode = $0200.
// The CPU's reset sequence fetches $FFFC/$FFFD; we return $00,$02 there so
// execution starts at $0200 where the program is loaded. Every other address
// reads/writes the 2 KB RAM (mirrored across the space by ignoring AB[15:11]).
//
// Synchronous RAM: on each rising clk the read data DI is registered from
// RAM[AB] and, when WE is asserted, DO is written to RAM[AB]. This matches the
// Arlet core's expectation of memory that presents data the cycle after the
// address (the core registers DI internally as well).

module soc(
    input        clk,
    input        reset,
    output [15:0] AB,    // CPU address bus           (observation)
    output [7:0]  DO,    // CPU write-data bus        (observation)
    output        WE,    // CPU write-enable          (observation)
    output [7:0]  DI,    // memory read-data into CPU (observation)
    output [7:0]  ram10, // RAM[$0010] -- LDA/STA target
    output [7:0]  ram24  // RAM[$0024] -- last indexed-store target
);

    wire [15:0] ab;
    wire [7:0]  do;
    wire        we;
    reg  [7:0]  di;

    // 2 KB RAM, byte addressed by the low 11 bits of the CPU address.
    reg [7:0] mem [0:2047];
    wire [10:0] addr = ab[10:0];

    // Reset-vector decode: $FFFC -> $00, $FFFD -> $02  (=> start PC = $0200).
    wire vec_lo = (ab == 16'hFFFC);
    wire vec_hi = (ab == 16'hFFFD);

    integer i;
    initial begin
        // Zero the RAM for determinism, then load the program at $0200.
        for (i = 0; i < 2048; i = i + 1) mem[i] = 8'h00;
        // ---- test program (assembled by hand, see README.md) -------------
        mem[16'h0200] = 8'hA2; mem[16'h0201] = 8'h00; // LDX #$00
        mem[16'h0202] = 8'hA9; mem[16'h0203] = 8'h42; // LDA #$42
        mem[16'h0204] = 8'h85; mem[16'h0205] = 8'h10; // STA $10
        mem[16'h0206] = 8'hE8;                        // INX
        mem[16'h0207] = 8'h8A;                        // TXA
        mem[16'h0208] = 8'h95; mem[16'h0209] = 8'h20; // STA $20,X
        mem[16'h020A] = 8'hE0; mem[16'h020B] = 8'h05; // CPX #$05
        mem[16'h020C] = 8'hD0; mem[16'h020D] = 8'hF8; // BNE $0206
        mem[16'h020E] = 8'h4C; mem[16'h020F] = 8'h0E; // JMP $020E (spin)
        mem[16'h0210] = 8'h02;
    end

    // Synchronous RAM read + write, plus reset-vector overlay on read.
    always @(posedge clk) begin
        if (we) mem[addr] <= do;
        if (vec_lo)      di <= 8'h00;
        else if (vec_hi) di <= 8'h02;
        else             di <= mem[addr];
    end

    cpu core(
        .clk   (clk),
        .reset (reset),
        .AB    (ab),
        .DI    (di),
        .DO    (do),
        .WE    (we),
        .IRQ   (1'b0),
        .NMI   (1'b0),
        .RDY   (1'b1)
    );

    assign AB    = ab;
    assign DO    = do;
    assign WE    = we;
    assign DI    = di;
    assign ram10 = mem[16'h0010];
    assign ram24 = mem[16'h0024];

endmodule
