// PRFRename com bundle de largura W (wiki: Register-Rename, "Bundle de largura W";
// decisões 3 e 15). Portas por slot são packed arrays, slot 0 é o mais antigo.
// Dois mocks vivem neste testbench:
//   - Decode: calcula rs1_dep/rs2_dep/rd_dep (one-hot do escritor anterior mais próximo).
//   - ROB: registra dst_tag/old_tag por slot válido no dispatch, marca entradas
//     como terminadas no writeback, retira até W por ciclo em ordem de programa
//     e envia commit_* só para entradas com destino.
module PRFRenameBundle_tb;
    localparam int XLEN = 64;
    localparam int ENTRIES = 37;  // 32 arquiteturais + 5 tags de renomeação
    localparam int TAG_W = $clog2(ENTRIES);
    localparam int W = 3;
    localparam int WB_N = 2;
    localparam int ROB_N = 16;

    logic clk = 0;
    always #5 clk = ~clk;

    // Portas do DUT
    logic reset = 1, flush = 0;
    logic dispatch_valid = 0, rob_ready, rs_ready, dispatch_ready;
    logic [W-1:0] slot_valid = '0, writes_rd = '0;
    logic [W-1:0][4:0] rs1 = '0, rs2 = '0, rd = '0;
    logic [W-1:0][W-1:0] rs1_dep, rs2_dep, rd_dep;
    logic [W-1:0][1:0] src_ready;
    logic [W-1:0][XLEN-1:0] src1_data, src2_data;
    logic [W-1:0][TAG_W-1:0] src1_tag, src2_tag, dst_tag, old_tag;
    logic [WB_N-1:0] wb_valid = '0;
    logic [WB_N-1:0][TAG_W-1:0] wb_tag = '0;
    logic [WB_N-1:0][XLEN-1:0] wb_data = '0;
    logic [W-1:0] commit_valid = '0;
    logic [W-1:0][4:0] commit_rd = '0;
    logic [W-1:0][TAG_W-1:0] commit_tag = '0, commit_old_tag = '0;

    PRFRename #(.XLEN(XLEN), .ENTRIES(ENTRIES), .W(W), .WB_N(WB_N)) dut (.*);

    // ---- Mock do Decode: escritor válido anterior mais próximo de cada registrador ----
    always_comb begin
        for (int k = 0; k < W; k++) begin
            rs1_dep[k] = '0;
            rs2_dep[k] = '0;
            rd_dep[k]  = '0;
            for (int i = 0; i < k; i++)  // i crescente: vale o escritor mais próximo
                if (slot_valid[i] && writes_rd[i] && rd[i] != 0) begin
                    if (rs1[k] == rd[i]) rs1_dep[k] = W'(1) << i;
                    if (rs2[k] == rd[i]) rs2_dep[k] = W'(1) << i;
                    if (rd[k] == rd[i]) rd_dep[k] = W'(1) << i;
                end
        end
    end

    // ---- Mock do ROB ----
    logic [4:0] m_rd[0:ROB_N-1];
    logic [TAG_W-1:0] m_tag[0:ROB_N-1], m_old[0:ROB_N-1];
    logic m_has[0:ROB_N-1], m_done[0:ROB_N-1];
    int m_head = 0, m_tail = 0, m_count = 0, n_retire = 0;
    logic rob_block = 0;
    assign rob_ready = !rob_block && m_count + $countones(slot_valid) <= ROB_N;
    // Mock da Reservation Station: só a recusa importa para o rename
    logic rs_block = 0;
    assign rs_ready = !rs_block;

    logic [TAG_W-1:0] b0, b1, b2, t;
    logic [TAG_W-1:0] got[0:4];
    logic [XLEN-1:0] v;

    task automatic check(input logic ok, input string msg);
        if (ok !== 1'b1) $fatal(1, "PRFRenameBundle: %s", msg);
    endtask

    // Esvazia o bundle; slots são preenchidos com put() e oferecidos com offer().
    task automatic clear;
        slot_valid = '0;
        writes_rd = '0;
        rs1 = '0;
        rs2 = '0;
        rd = '0;
    endtask

    task automatic put(input int k, input logic w, input logic [4:0] dst, s1, s2);
        slot_valid[k] = 1;
        writes_rd[k] = w;
        rd[k] = dst;
        rs1[k] = s1;
        rs2[k] = s2;
    endtask

    task automatic offer;
        dispatch_valid = 1;
        #1;
    endtask

    task automatic writeback(input int p, input logic [TAG_W-1:0] tag,
                             input logic [XLEN-1:0] data);
        wb_valid[p] = 1;
        wb_tag[p] = tag;
        wb_data[p] = data;
    endtask

    // Prepara a retirada das n entradas mais antigas do ROB, um slot de commit cada.
    task automatic retire(input int n);
        int idx;
        check(m_count >= n, "mock: not enough entries to retire");
        for (int j = 0; j < n; j++) begin
            idx = (m_head + j) % ROB_N;
            check(m_done[idx], "mock: entry must be finished to retire");
            commit_valid[j] = m_has[idx];
            commit_rd[j] = m_rd[idx];
            commit_tag[j] = m_tag[idx];
            commit_old_tag[j] = m_old[idx];
        end
        n_retire = n;
        #1;
    endtask

    // Um clock: registra no mock a transferência do bundle e os writebacks,
    // aplica o clock no DUT, depois remove as entradas retiradas e limpa os pulsos.
    task automatic step;
        logic xfer;
        xfer = dispatch_valid && dispatch_ready && rob_ready && rs_ready;
        if (flush) begin
            m_head = 0;
            m_tail = 0;
            m_count = 0;
        end else begin
            for (int p = 0; p < WB_N; p++)
                if (wb_valid[p])
                    for (int i = 0; i < ROB_N; i++)
                        if (m_has[i] && m_tag[i] == wb_tag[p]) m_done[i] = 1;
            m_head = (m_head + n_retire) % ROB_N;
            m_count -= n_retire;
            if (xfer)
                for (int k = 0; k < W; k++)
                    if (slot_valid[k]) begin
                        m_rd[m_tail] = rd[k];
                        m_has[m_tail] = writes_rd[k] && rd[k] != 0;
                        m_tag[m_tail] = dst_tag[k];
                        m_old[m_tail] = old_tag[k];
                        m_done[m_tail] = !(writes_rd[k] && rd[k] != 0);
                        m_tail = (m_tail + 1) % ROB_N;
                        m_count++;
                    end
        end
        @(posedge clk);
        #1;
        dispatch_valid = 0;
        wb_valid = '0;
        commit_valid = '0;
        n_retire = 0;
        flush = 0;
        #1;
    endtask

    // Lê x[r] pelo slot 0 sem fazer dispatch; retorna ready e valor.
    task automatic peek(input logic [4:0] r, output logic ready, output logic [XLEN-1:0] data,
                        output logic [TAG_W-1:0] tag);
        clear();
        put(0, 0, 0, r, 0);
        offer();
        ready = src_ready[0][0];
        data = src1_data[0];
        tag = src1_tag[0];
        dispatch_valid = 0;
        clear();
        #1;
    endtask

    logic rdy;

    initial begin
        step();
        reset = 0;
        #1;

        // ---- Bundle incompleto, x0 ----
        // Slot 2 é inválido: seus campos de escritor não podem alocar nada.
        clear();
        put(0, 1, 0, 0, 0);  // escrita em x0
        put(1, 0, 0, 0, 0);  // tipo store, lê x0
        writes_rd[2] = 1;
        rd[2] = 9;
        offer();
        check(dispatch_ready, "bundle without allocations is ready");
        check(src_ready[0] == 2'b11 && src_ready[1] == 2'b11, "x0 sources are ready");
        check(src1_data[0] == 0 && src2_data[1] == 0, "x0 reads zero");
        step();
        retire(2);
        check(commit_valid == '0, "x0 writer and store retire without commands");
        step();
        peek(9, rdy, v, t);
        check(t == TAG_W'(9), "invalid slot did not rename x9");

        // ---- RAW, WAW e fonte = destino dentro de um bundle ----
        clear();
        put(0, 1, 5, 5, 1);  // add x5, x5, x1
        put(1, 1, 6, 5, 2);  // sub x6, x5, x2   rs1 <- slot 0
        put(2, 1, 5, 6, 5);  // or  x5, x6, x5   rs1 <- slot 1, rs2 <- slot 0, WAW slot 0
        offer();
        check(dispatch_ready, "three free tags for three writers");
        b0 = dst_tag[0];
        b1 = dst_tag[1];
        b2 = dst_tag[2];
        check(b0 == TAG_W'(32) && b1 == TAG_W'(33) && b2 == TAG_W'(34),
              "tags leave the free list in slot order");
        check(src_ready[0] == 2'b11 && src1_data[0] == 0, "slot 0 reads committed x5");
        check(old_tag[0] == TAG_W'(5), "slot 0 old_tag is map[x5]");
        check(!src_ready[1][0] && src1_tag[1] == b0, "slot 1 rs1 chained to slot 0");
        check(src_ready[1][1], "slot 1 rs2 (x2) read from the map");
        check(old_tag[1] == TAG_W'(6), "slot 1 old_tag is map[x6]");
        check(!src_ready[2][0] && src1_tag[2] == b1, "slot 2 rs1 chained to slot 1");
        check(!src_ready[2][1] && src2_tag[2] == b0, "slot 2 rs2 chained to slot 0");
        check(old_tag[2] == b0, "WAW: slot 2 old_tag is slot 0 dst_tag");
        step();
        peek(5, rdy, v, t);
        check(t == b2 && !rdy, "map[x5] holds the youngest writer of the bundle");
        peek(6, rdy, v, t);
        check(t == b1 && !rdy, "map[x6] holds slot 1");

        // ---- Tudo ou nada ----
        // Restam duas tags: um bundle com três escritores espera inteiro.
        clear();
        put(0, 1, 10, 0, 0);
        put(1, 1, 11, 0, 0);
        put(2, 1, 12, 0, 0);
        offer();
        check(!dispatch_ready, "three writers with two free tags stall the bundle");
        step();
        // O ROB recusa um bundle que o rename aceitaria: nada é alocado.
        rob_block = 1;
        clear();
        put(0, 1, 10, 1, 0);  // x10 <- x1
        put(1, 0, 0, 10, 0);  // store lê x10: encadeado ao slot 0
        put(2, 1, 11, 0, 0);
        offer();
        check(dispatch_ready, "two writers fit in two free tags");
        step();
        rob_block = 0;
        // A RS recusa o mesmo bundle: também nada é alocado.
        rs_block = 1;
        offer();
        check(dispatch_ready, "rename alone accepts while the RS refuses");
        step();
        rs_block = 0;
        offer();
        check(dst_tag[0] == TAG_W'(35) && dst_tag[2] == TAG_W'(36),
              "refused bundles allocated nothing; slot 1 consumed no tag");
        check(!src_ready[1][0] && src1_tag[1] == dst_tag[0], "store source chained");
        check(old_tag[0] == TAG_W'(10) && old_tag[2] == TAG_W'(11), "old tags of x10 and x11");
        step();
        clear();
        put(0, 1, 12, 0, 0);
        offer();
        check(!dispatch_ready, "free list empty");
        dispatch_valid = 0;
        clear();

        // ---- Writeback em duas portas, bypass para fontes lidas do mapa ----
        writeback(0, b1, 66);
        writeback(1, b0, 55);
        clear();
        put(0, 0, 0, 6, 10);  // x6 = b1 (escrito agora), x10 = 35 (pendente)
        put(1, 0, 0, 5, 1);  // x5 = b2 (pendente), x1 arquitetural
        offer();
        check(src_ready[0][0] && src1_data[0] == 66, "port 0 writeback bypassed");
        check(!src_ready[0][1] && src2_tag[0] == TAG_W'(35), "x10 still pending");
        check(!src_ready[1][0] && src1_tag[1] == b2, "x5 youngest writer pending");
        check(src_ready[1][1], "x1 architectural");
        dispatch_valid = 0;
        clear();
        step();
        peek(6, rdy, v, t);
        check(rdy && v == 66, "x6 value stored after writeback");
        writeback(0, b2, 77);
        writeback(1, TAG_W'(35), 100);
        step();
        writeback(0, TAG_W'(36), 110);
        step();

        // ---- Três commits em um ciclo; x5 confirmado duas vezes ----
        // ROB: b0 (x5), b1 (x6), b2 (x5), x10, store, x11.
        retire(3);
        check(commit_valid == 3'b111 && commit_rd[0] == 5 && commit_rd[2] == 5,
              "mock commits x5, x6, x5");
        step();
        peek(5, rdy, v, t);
        check(t == b2 && rdy && v == 77, "youngest commit of x5 wins");
        // As tags antigas 5, 6 e b0 voltaram em ordem de commit.
        clear();
        put(0, 1, 13, 0, 0);
        put(1, 1, 14, 0, 0);
        put(2, 1, 15, 0, 0);
        offer();
        check(dispatch_ready, "three tags freed by three commits");
        check(dst_tag[0] == TAG_W'(5) && dst_tag[1] == TAG_W'(6) && dst_tag[2] == b0,
              "freed tags reused in commit order");
        step();
        peek(13, rdy, v, t);
        check(!rdy, "reallocated tag (was AR) starts not ready");

        // ---- Flush com commits no mesmo ciclo (slot 1 não tem destino) ----
        // ROB: x10 (35), store, x11 (36), x13, x14, x15.
        retire(3);
        check(commit_valid == 3'b101, "store leaves a hole in the commit slots");
        flush = 1;
        step();
        peek(10, rdy, v, t);
        check(rdy && v == 100 && t == TAG_W'(35), "x10 committed in the flush cycle");
        peek(11, rdy, v, t);
        check(rdy && v == 110 && t == TAG_W'(36), "x11 committed in the flush cycle");
        peek(5, rdy, v, t);
        check(rdy && v == 77, "x5 keeps its committed value");
        peek(6, rdy, v, t);
        check(rdy && v == 66, "x6 keeps its committed value");
        peek(13, rdy, v, t);
        check(rdy && v == 0 && t == TAG_W'(13), "discarded x13 back to its committed tag");
        peek(15, rdy, v, t);
        check(rdy && v == 0 && t == TAG_W'(15), "discarded x15 back to its committed tag");

        // Depois do flush exatamente ENTRIES-32 tags estão livres: 5, 6, b0, 10, 11.
        clear();
        put(0, 1, 20, 0, 0);
        put(1, 1, 21, 0, 0);
        put(2, 1, 22, 0, 0);
        offer();
        check(dispatch_ready, "three of five free tags");
        for (int k = 0; k < 3; k++) got[k] = dst_tag[k];
        step();
        offer();  // os mesmos três escritores de novo: só restam duas tags
        check(!dispatch_ready, "all or nothing after flush");
        clear();
        put(0, 1, 23, 0, 0);
        put(1, 0, 0, 0, 0);
        put(2, 1, 24, 0, 0);
        offer();
        check(dispatch_ready, "two writers take the last two tags");
        got[3] = dst_tag[0];
        got[4] = dst_tag[2];
        step();
        for (int i = 0; i < 5; i++) begin
            check(got[i] == TAG_W'(5) || got[i] == TAG_W'(6) || got[i] == b0 ||
                  got[i] == TAG_W'(10) || got[i] == TAG_W'(11),
                  "only non-architectural tags are free after flush");
            for (int j = 0; j < i; j++) check(got[i] != got[j], "free tags are distinct");
        end
        peek(20, rdy, v, t);
        check(!rdy && t == got[0], "tags reallocated after flush start not ready");

        $display("PRFRenameBundle PASS");
        $finish;
    end
endmodule
