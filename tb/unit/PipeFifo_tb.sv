// PipeFifo: FIFO genérico de fronteira entre estágios (Fetch->Decode,
// Decode->Dispatch). O testbench mantém um modelo de referência (scoreboard) e
// o compara a cada ciclo: ocupação, in_ready, out_valid e out_data.
// DEPTH vem de PARAMS_PipeFifo no Makefile (inclui 1 e profundidade que não é
// potência de 2, para exercitar o wrap dos ponteiros).
module PipeFifo_tb #(
    parameter int DEPTH = 4
);
    localparam int DATA_W = 16;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset = 1, flush = 0;
    logic in_valid = 0, in_ready;
    logic [DATA_W-1:0] in_data = 0;
    logic out_valid, out_ready = 0;
    logic [DATA_W-1:0] out_data;

    PipeFifo #(.DATA_W(DATA_W), .DEPTH(DEPTH)) dut (.*);

    // ---- Modelo de referência ----
    logic [DATA_W-1:0] model[0:4095];
    int m_head = 0, m_tail = 0, m_count = 0;
    logic [DATA_W-1:0] next_data = 16'h0100;  // dado único por enfileiramento
    int accepted_in = 0, accepted_out = 0, stalled_in = 0, flushes = 0;

    task automatic fail(input string msg);
        $fatal(1, "PipeFifo(DEPTH=%0d): %s (t=%0t count=%0d)", DEPTH, msg, $time, m_count);
    endtask

    // Um ciclo: aplica as entradas, confere as saídas combinacionais contra o
    // modelo, avança o clock e atualiza o modelo.
    task automatic step(input logic iv, input logic orr, input logic fl);
        logic acc_in, acc_out;
        in_valid = iv;
        in_data = next_data;
        out_ready = orr;
        flush = fl;
        #1;
        if (in_ready !== (m_count < DEPTH)) fail("in_ready diferente de (ocupação < DEPTH)");
        if (out_valid !== (m_count > 0)) fail("out_valid diferente de (ocupação > 0)");
        if (m_count > 0 && out_data !== model[m_head]) fail("out_data fora de ordem ou corrompido");
        // flush tem precedência sobre o handshake nos dois lados
        acc_in = in_valid && in_ready && !fl;
        acc_out = out_valid && out_ready && !fl;
        if (iv && !in_ready) stalled_in++;
        @(posedge clk);
        if (fl) begin
            m_head = 0;
            m_tail = 0;
            m_count = 0;
            flushes++;
        end else begin
            if (acc_out) begin
                m_head = (m_head + 1) % 4096;
                m_count--;
                accepted_out++;
            end
            if (acc_in) begin
                model[m_tail] = in_data;
                m_tail = (m_tail + 1) % 4096;
                m_count++;
                accepted_in++;
            end
        end
        if (acc_in) next_data = next_data + 1;
        #1;
    endtask

    task automatic idle();
        step(0, 0, 0);
    endtask

    // Enche até in_ready cair, sem consumir.
    task automatic fill();
        for (int i = 0; i < DEPTH; i++) step(1, 0, 0);
    endtask

    // Esvazia, conferindo cada dado contra o modelo.
    task automatic drain();
        while (m_count > 0) step(0, 1, 0);
    endtask

    int p_in, p_out, p_flush;

    // Fase aleatória: p_* em porcentagem.
    task automatic random_phase(input int cycles);
        for (int i = 0; i < cycles; i++)
            step($urandom_range(99) < p_in, $urandom_range(99) < p_out, $urandom_range(99) < p_flush);
    endtask

    initial begin
        // ---- Reset ----
        reset = 1;
        repeat (3) @(posedge clk);
        #1;
        reset = 0;
        if (out_valid !== 1'b0) fail("out_valid deve ser 0 após o reset");
        if (in_ready !== 1'b1) fail("in_ready deve ser 1 após o reset");

        // ---- Um elemento entra e sai ----
        idle();
        step(1, 0, 0);          // entra
        step(0, 0, 0);          // fica parado com out_ready = 0: dado estável
        step(0, 0, 0);
        step(0, 1, 0);          // sai
        if (m_count !== 0) fail("deveria estar vazio");

        // ---- Encher: in_ready cai e o excedente é recusado ----
        fill();
        if (in_ready !== 1'b0) fail("in_ready deve cair com a FIFO cheia");
        step(1, 0, 0);          // recusado: o modelo não enfileira
        step(1, 0, 0);
        if (m_count !== DEPTH) fail("ocupação mudou com a FIFO cheia");
        drain();                // confere ordem e conteúdo dos DEPTH dados

        // ---- Cheia + saída no mesmo ciclo: entrada recusada, só sai ----
        fill();
        step(1, 1, 0);
        if (m_count !== DEPTH - 1) fail("cheia com in_valid e out_ready: deveria só sair um");
        step(1, 0, 0);          // agora há vaga: entra
        if (m_count !== DEPTH) fail("deveria ter reenchido");
        drain();

        // ---- Entrada e saída simultâneas com ocupação intermediária ----
        step(1, 0, 0);
        if (DEPTH > 1) begin
            step(1, 1, 0);
            step(1, 1, 0);
            step(1, 1, 0);
            if (m_count !== 1) fail("ocupação deveria ficar em 1 com entrada e saída por ciclo");
        end
        drain();

        // ---- Wrap dos ponteiros: várias voltas com ocupação baixa ----
        for (int i = 0; i < DEPTH * 3 + 2; i++) begin
            step(1, 0, 0);
            step(0, 1, 0);
        end
        if (m_count !== 0) fail("deveria estar vazio após as voltas");

        // ---- Flush com dados em voo: esvazia e libera ----
        fill();
        step(0, 0, 1);
        if (out_valid !== 1'b0) fail("out_valid deve ser 0 após o flush");
        if (in_ready !== 1'b1) fail("in_ready deve ser 1 após o flush");

        // ---- Flush no mesmo ciclo do handshake de entrada: dado descartado ----
        step(1, 0, 1);
        if (out_valid !== 1'b0) fail("entrada no ciclo do flush não pode ser enfileirada");
        // ---- Flush no mesmo ciclo do handshake de saída: nada sai ----
        step(1, 0, 0);
        step(1, 1, 1);
        if (out_valid !== 1'b0) fail("saída no ciclo do flush deveria esvaziar");

        // ---- Depois do flush a FIFO começa limpa e mantém a ordem ----
        fill();
        step(0, 0, 1);
        step(1, 0, 0);
        step(1, 0, 0);
        drain();

        // ---- Reset no meio da operação ----
        fill();
        reset = 1;
        @(posedge clk);
        #1;
        reset = 0;
        m_head = 0;
        m_tail = 0;
        m_count = 0;
        if (out_valid !== 1'b0 || in_ready !== 1'b1) fail("reset deve esvaziar a FIFO");
        step(1, 1, 0);
        step(1, 1, 0);
        drain();

        // ---- Aleatório: enche, drena, equilibrado e com flush ----
        p_flush = 0;
        p_in = 90; p_out = 20; random_phase(400);   // tende a encher
        p_in = 20; p_out = 90; random_phase(400);   // tende a esvaziar
        p_in = 60; p_out = 60; random_phase(2000);  // equilibrado
        p_in = 80; p_out = 50; p_flush = 3; random_phase(2000);  // com flush
        p_flush = 0;
        drain();

        if (stalled_in == 0) fail("o teste nunca exercitou back-pressure");
        if (flushes == 0) fail("o teste nunca exercitou flush");

        $display("PASS PipeFifo DEPTH=%0d (aceitos=%0d, recusados=%0d, flushes=%0d)",
                 DEPTH, accepted_in, stalled_in, flushes);
        $finish;
    end

    // Evita travar se algo ficar preso
    initial begin
        #5_000_000;
        $fatal(1, "PipeFifo: timeout");
    end
endmodule
