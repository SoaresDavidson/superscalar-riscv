// FIFO circular de fronteira entre estágios (wiki: Pipeline-Control; usada em
// Fetch->Decode e Decode->Dispatch). O dado é opaco: quem instancia empacota o
// bundle (instruções, uop_t[WIDTH], máscaras de dependência) em DATA_W bits.
//
// - Handshake valid/ready: a transferência ocorre quando os dois estão altos.
// - in_ready depende só da ocupação, nunca de out_ready: com a FIFO cheia, uma
//   saída no ciclo não libera vaga para uma entrada no mesmo ciclo.
// - out_data é a entrada mais antiga (first-word-fall-through): válida assim
//   que out_valid sobe, estável enquanto out_valid && !out_ready.
// - flush esvazia a FIFO e tem precedência sobre o handshake dos dois lados.
//   PROVISÓRIO: descarte total no flush. A estratégia de recuperação de
//   desvios (global no retire ou seletiva por tag) ainda não foi decidida; se
//   for seletiva, cada entrada ganha a máscara do desvio e o flush passa a
//   invalidar só as entradas marcadas.
module PipeFifo #(
    parameter int DATA_W = 32,
    parameter int DEPTH  = 4
) (
    input  logic              clk,
    input  logic              reset,  // síncrono, ativo-alto
    input  logic              flush,  // descarta todo o conteúdo

    input  logic              in_valid,
    output logic              in_ready,
    input  logic [DATA_W-1:0] in_data,

    output logic              out_valid,
    input  logic              out_ready,
    output logic [DATA_W-1:0] out_data
);
    localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int CNT_W = $clog2(DEPTH + 1);

    logic [DATA_W-1:0] mem[DEPTH];
    logic [PTR_W-1:0]  head, tail;
    logic [CNT_W-1:0]  count;

    logic push, pop;
    assign in_ready  = (count != CNT_W'(DEPTH));
    assign out_valid = (count != '0);
    assign out_data  = mem[head];
    assign push = in_valid && in_ready;
    assign pop  = out_valid && out_ready;

    function automatic logic [PTR_W-1:0] next_ptr(input logic [PTR_W-1:0] p);
        next_ptr = (p == PTR_W'(DEPTH - 1)) ? '0 : p + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            head  <= '0;
            tail  <= '0;
            count <= '0;
        end else begin
            if (push) begin
                mem[tail] <= in_data;
                tail      <= next_ptr(tail);
            end
            if (pop) head <= next_ptr(head);
            count <= count + CNT_W'(push) - CNT_W'(pop);
        end
    end
endmodule
