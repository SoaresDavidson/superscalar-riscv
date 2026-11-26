// Invólucro de P&R: o PipeFifo com os parâmetros da instância do core
// (u_fetch_q, entre o Fetch e o Decode).
//
//   FQ_W = W + W*XLEN + W*32 = 3 + 3*64 + 3*32 = 291   (W = 3, XLEN = 64)
//   FQ_DEPTH = 4 bundles
//
// Existe porque o LibreLane 3.0.17 não tem variável para passar parâmetro de
// módulo (só VERILOG_DEFINES), e medir o PipeFifo no DATA_W = 32 do default
// não diria nada sobre o uso real. Este arquivo é só para a síntese física:
// mora em pnr/ e não entra em rtl/, então não é compilado pelos testes.
module PipeFifo_fq (
    input  logic         clk,
    input  logic         reset,
    input  logic         flush,

    input  logic         in_valid,
    output logic         in_ready,
    input  logic [290:0] in_data,

    output logic         out_valid,
    input  logic         out_ready,
    output logic [290:0] out_data
);

  PipeFifo #(.DATA_W(291), .DEPTH(4)) u_fq (
      .clk, .reset, .flush,
      .in_valid, .in_ready, .in_data,
      .out_valid, .out_ready, .out_data
  );

endmodule
