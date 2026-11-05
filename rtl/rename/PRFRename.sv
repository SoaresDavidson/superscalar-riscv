// Renomeação com banco de registradores físicos unificado (wiki: Register-Rename,
// decisão 14). O ROB é externo: guarda dst_tag/old_tag e envia commit_* em ordem.
// Estado de reset: o reg arquitetural i aponta para a tag i (estado AR); as tags
// 32..ENTRIES-1 estão livres.
// Bundle de largura W (wiki: "Bundle de largura W", decisões 3 e 15): portas por
// slot são packed arrays, slot 0 é o mais antigo. Dependências dentro do bundle
// vêm do Decode como one-hot rs1_dep/rs2_dep/rd_dep; o bundle entra tudo ou nada.
module PRFRename #(
    parameter  int XLEN    = 64,
    parameter  int ENTRIES = 64,              // 32 arquiteturais + tags de renomeação
    parameter  int W       = 3,               // largura do bundle (dispatch e commit)
    parameter  int WB_N    = 1,               // portas de writeback
    localparam int TAG_W   = $clog2(ENTRIES),
    localparam int CNT_SLOT_W = $clog2(W + 1)  // contagem vai de 0..W
) (
    input logic clk,
    input logic reset,
    input logic flush,

    // dispatch
    input  logic                      dispatch_valid,
    input  logic [W-1:0]              slot_valid,
    input  logic [W-1:0][      4:0]   rs1,
    input  logic [W-1:0][      4:0]   rs2,
    input  logic [W-1:0][      4:0]   rd,
    input  logic [W-1:0]              writes_rd,
    input  logic [W-1:0][    W-1:0]   rs1_dep,
    input  logic [W-1:0][    W-1:0]   rs2_dep,
    input  logic [W-1:0][    W-1:0]   rd_dep,
    input  logic                      rob_ready,
    output logic                      dispatch_ready,
    output logic [W-1:0][      1:0]   src_ready,
    output logic [W-1:0][ XLEN-1:0]   src1_data,
    output logic [W-1:0][ XLEN-1:0]   src2_data,
    output logic [W-1:0][TAG_W-1:0]   src1_tag,
    output logic [W-1:0][TAG_W-1:0]   src2_tag,
    output logic [W-1:0][TAG_W-1:0]   dst_tag,
    output logic [W-1:0][TAG_W-1:0]   old_tag,

    // writeback
    input logic [WB_N-1:0]              wb_valid,
    input logic [WB_N-1:0][TAG_W-1:0]   wb_tag,
    input logic [WB_N-1:0][ XLEN-1:0]   wb_data,

    // commit (só instruções com destino), slot 0 é o mais antigo
    input logic [W-1:0]              commit_valid,
    input logic [W-1:0][      4:0]   commit_rd,
    input logic [W-1:0][TAG_W-1:0]   commit_tag,
    input logic [W-1:0][TAG_W-1:0]   commit_old_tag
);
    localparam int CNT_W = $clog2(ENTRIES - 32 + 1);

    logic [W-1:0] alloc_req, alloc;
    logic [CNT_SLOT_W-1:0] n_alloc;
    logic [CNT_W-1:0] free_count;
    logic [W-1:0][TAG_W-1:0] free_tags;
    logic [W-1:0][TAG_W-1:0] map_rs1_tag, map_rs2_tag, map_old_tag;
    logic [W-1:0] rf_rs1_valid, rf_rs2_valid;
    logic [W-1:0][XLEN-1:0] rf_rs1_data, rf_rs2_data;
    logic [31:0][TAG_W-1:0] committed_map;

    // O slot k pega a tag livre seguinte às dos slots anteriores que alocam
    always_comb begin
        n_alloc = '0;
        for (int k = 0; k < W; k++) begin
            alloc_req[k] = slot_valid[k] && writes_rd[k] && rd[k] != 5'd0;
            dst_tag[k]   = free_tags[n_alloc];
            if (alloc_req[k]) n_alloc = n_alloc + 1'b1;
        end
    end

    assign dispatch_ready = CNT_W'(n_alloc) <= free_count;
    assign alloc = (dispatch_valid && dispatch_ready && rob_ready) ? alloc_req : '0;

    // Uma fonte ou old_tag com escritor anterior no bundle usa o dst_tag dele
    // (só os bits i < k dos one-hot de dependência podem estar ligados)
    for (genvar k = 0; k < W; k++) begin : g_intra_bundle
        always_comb begin
            src1_tag[k]     = map_rs1_tag[k];
            src2_tag[k]     = map_rs2_tag[k];
            old_tag[k]      = map_old_tag[k];
            src_ready[k][0] = rf_rs1_valid[k];
            src_ready[k][1] = rf_rs2_valid[k];
            for (int i = 0; i < W; i++) begin
                if (i < k && rs1_dep[k][i]) begin
                    src1_tag[k]     = dst_tag[i];
                    src_ready[k][0] = 1'b0;
                end
                if (i < k && rs2_dep[k][i]) begin
                    src2_tag[k]     = dst_tag[i];
                    src_ready[k][1] = 1'b0;
                end
                if (i < k && rd_dep[k][i]) old_tag[k] = dst_tag[i];
            end
        end
    end

    assign src1_data = rf_rs1_data;
    assign src2_data = rf_rs2_data;

    PRFFreeList #(
        .ENTRIES(ENTRIES),
        .W      (W)
    ) free_list (
        .clk,
        .reset,
        .flush,
        .pop_n    (n_alloc),
        .pop_en   (|alloc),
        .head_tags(free_tags),
        .count    (free_count),
        .commit_valid,
        .commit_old_tag
    );

    PRFMapTable #(
        .ENTRIES(ENTRIES),
        .W      (W)
    ) map_table (
        .clk,
        .reset,
        .flush,
        .rs1,
        .rs2,
        .rd,
        .rs1_tag    (map_rs1_tag),
        .rs2_tag    (map_rs2_tag),
        .rd_old_tag (map_old_tag),
        .write_valid(alloc),
        .write_tag  (dst_tag),
        .committed_map,
        .commit_valid,
        .commit_rd,
        .commit_tag
    );

    PRFCommittedTable #(
        .ENTRIES(ENTRIES),
        .W      (W)
    ) committed_table (
        .clk,
        .reset,
        .commit_valid,
        .commit_rd,
        .commit_tag,
        .committed_map
    );

    PRFRegFile #(
        .XLEN   (XLEN),
        .ENTRIES(ENTRIES),
        .W      (W),
        .WB_N   (WB_N)
    ) reg_file (
        .clk,
        .reset,
        .flush,
        .rs1_tag  (map_rs1_tag),
        .rs2_tag  (map_rs2_tag),
        .rs1_valid(rf_rs1_valid),
        .rs2_valid(rf_rs2_valid),
        .rs1_data (rf_rs1_data),
        .rs2_data (rf_rs2_data),
        .alloc,
        .alloc_tag(dst_tag),
        .wb_valid,
        .wb_tag,
        .wb_data,
        .commit_valid,
        .commit_tag,
        .commit_old_tag
    );
endmodule

/* verilator lint_off DECLFILENAME */

// Fila circular de tags livres. Tira pop_n tags do head com pop_en e insere cada
// commit_old_tag válido no tail, em ordem de slot. No flush, toda tag alocada
// especulativamente volta: as posições [tail, head) guardam essas tags em ordem
// de alocação.
module PRFFreeList #(
    parameter  int ENTRIES = 64,
    parameter  int W       = 3,
    localparam int TAG_W   = $clog2(ENTRIES),
    localparam int FREE_N  = ENTRIES - 32,
    localparam int PTR_W   = FREE_N > 1 ? $clog2(FREE_N) : 1,  // índice na fila
    localparam int CNT_W   = $clog2(FREE_N + 1),               // contagem vai de 0..FREE_N
    localparam int CNT_SLOT_W = $clog2(W + 1)
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    flush,
    input  logic [CNT_SLOT_W-1:0]    pop_n,
    input  logic                    pop_en,
    output logic [W-1:0][TAG_W-1:0] head_tags,      // próximas W tags, válidas até count
    output logic [CNT_W-1:0]        count,
    input  logic [W-1:0]            commit_valid,
    input  logic [W-1:0][TAG_W-1:0] commit_old_tag
);
    logic [PTR_W-1:0] head, tail;
    logic [TAG_W-1:0] tags[FREE_N];
    logic [W-1:0][PTR_W-1:0] push_ptr;
    logic [CNT_SLOT_W-1:0] n_push;

    function automatic logic [PTR_W-1:0] wrap(input logic [PTR_W-1:0] ptr, input int n);
        return PTR_W'((int'(ptr) + n) % FREE_N);
    endfunction

    always_comb begin
        for (int j = 0; j < W; j++) head_tags[j] = tags[wrap(head, j)];
    end

    // Commits válidos são empacotados no tail em ordem de slot
    always_comb begin
        n_push = '0;
        for (int j = 0; j < W; j++) begin
            push_ptr[j] = wrap(tail, int'(n_push));
            if (commit_valid[j]) n_push = n_push + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < FREE_N; i++) tags[i] <= TAG_W'(32 + i);
            head  <= 0;
            tail  <= 0;
            count <= CNT_W'(FREE_N);
        end else begin
            for (int j = 0; j < W; j++)
                if (commit_valid[j]) tags[push_ptr[j]] <= commit_old_tag[j];
            tail <= wrap(tail, int'(n_push));
            if (flush) begin
                head  <= wrap(tail, int'(n_push));
                count <= CNT_W'(FREE_N);  // sempre FREE_N tags não AR
            end else begin
                if (pop_en) head <= wrap(head, int'(pop_n));
                count <= count + CNT_W'(n_push) - (pop_en ? CNT_W'(pop_n) : '0);
            end
        end
    end
endmodule

// Mapa especulativo: reg arquitetural -> tag. As fontes são lidas antes de rd
// ser sobrescrito no mesmo ciclo. Se dois slots escrevem o mesmo rd, vale o
// mais novo. No flush é restaurado a partir do mapa confirmado.
module PRFMapTable #(
    parameter  int ENTRIES = 64,
    parameter  int W       = 3,
    localparam int TAG_W   = $clog2(ENTRIES)
) (
    input  logic                        clk,
    input  logic                        reset,
    input  logic                        flush,
    input  logic [  W-1:0][      4:0]   rs1,
    input  logic [  W-1:0][      4:0]   rs2,
    input  logic [  W-1:0][      4:0]   rd,
    output logic [  W-1:0][TAG_W-1:0]   rs1_tag,
    output logic [  W-1:0][TAG_W-1:0]   rs2_tag,
    output logic [  W-1:0][TAG_W-1:0]   rd_old_tag,
    input  logic [  W-1:0]              write_valid,
    input  logic [  W-1:0][TAG_W-1:0]   write_tag,
    input  logic [   31:0][TAG_W-1:0]   committed_map,
    // Commits do ciclo de flush ainda não estão em committed_map
    input  logic [  W-1:0]              commit_valid,
    input  logic [  W-1:0][      4:0]   commit_rd,
    input  logic [  W-1:0][TAG_W-1:0]   commit_tag
);
    logic [TAG_W-1:0] speculative_map[32];

    always_comb begin
        for (int k = 0; k < W; k++) begin
            rs1_tag[k]    = speculative_map[rs1[k]];
            rs2_tag[k]    = speculative_map[rs2[k]];
            rd_old_tag[k] = speculative_map[rd[k]];
        end
    end

    // Loops em ordem crescente de slot: vale a última escrita nonblocking (a mais nova)
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 32; i++) begin
                speculative_map[i] <= TAG_W'(i);
            end
        end else if (flush) begin
            for (int i = 0; i < 32; i++) begin
                speculative_map[i] <= committed_map[i];
            end
            for (int j = 0; j < W; j++)
                if (commit_valid[j]) speculative_map[commit_rd[j]] <= commit_tag[j];
        end else begin
            for (int k = 0; k < W; k++)
                if (write_valid[k]) speculative_map[rd[k]] <= write_tag[k];
        end
    end
endmodule

// Mapa arquitetural: reg arquitetural -> tag, atualizado só no commit. Se dois
// commits do ciclo escrevem o mesmo rd, vale o mais novo.
module PRFCommittedTable #(
    parameter  int ENTRIES = 64,
    parameter  int W       = 3,
    localparam int TAG_W   = $clog2(ENTRIES)
) (
    input  logic                        clk,
    input  logic                        reset,
    input  logic [  W-1:0]              commit_valid,
    input  logic [  W-1:0][      4:0]   commit_rd,
    input  logic [  W-1:0][TAG_W-1:0]   commit_tag,
    output logic [   31:0][TAG_W-1:0]   committed_map
);

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 32; i++) begin
                committed_map[i] <= TAG_W'(i);
            end
        end else begin
            for (int j = 0; j < W; j++)
                if (commit_valid[j]) committed_map[commit_rd[j]] <= commit_tag[j];
        end
    end
endmodule

// Registradores físicos: value[] e state[] (FREE, RB_NOT_VALID, RB_VALID, AR).
// Uma leitura é válida em RB_VALID ou AR, ou com writeback no mesmo ciclo (bypass).
// O flush leva toda tag não AR para FREE.
module PRFRegFile #(
    parameter  int XLEN    = 64,
    parameter  int ENTRIES = 64,
    parameter  int W       = 3,
    parameter  int WB_N    = 1,
    localparam int TAG_W   = $clog2(ENTRIES)
) (
    input  logic                         clk,
    input  logic                         reset,
    input  logic                         flush,
    input  logic [   W-1:0][TAG_W-1:0]   rs1_tag,
    input  logic [   W-1:0][TAG_W-1:0]   rs2_tag,
    output logic [   W-1:0]              rs1_valid,
    output logic [   W-1:0]              rs2_valid,
    output logic [   W-1:0][ XLEN-1:0]   rs1_data,
    output logic [   W-1:0][ XLEN-1:0]   rs2_data,
    input  logic [   W-1:0]              alloc,
    input  logic [   W-1:0][TAG_W-1:0]   alloc_tag,
    input  logic [WB_N-1:0]              wb_valid,
    input  logic [WB_N-1:0][TAG_W-1:0]   wb_tag,
    input  logic [WB_N-1:0][ XLEN-1:0]   wb_data,
    input  logic [   W-1:0]              commit_valid,
    input  logic [   W-1:0][TAG_W-1:0]   commit_tag,
    input  logic [   W-1:0][TAG_W-1:0]   commit_old_tag
);
    typedef enum logic [1:0] {
        FREE,
        RB_NOT_VALID,
        RB_VALID,
        AR
    } state_t;

    function automatic logic has_value(input state_t s);
        return s == RB_VALID || s == AR;
    endfunction

    logic [XLEN-1:0] regfile[ENTRIES];
    state_t          state  [ENTRIES];

    always_comb begin
        for (int k = 0; k < W; k++) begin
            rs1_valid[k] = has_value(state[rs1_tag[k]]);
            rs1_data[k]  = regfile[rs1_tag[k]];
            rs2_valid[k] = has_value(state[rs2_tag[k]]);
            rs2_data[k]  = regfile[rs2_tag[k]];
            for (int p = 0; p < WB_N; p++) begin
                if (wb_valid[p] && wb_tag[p] == rs1_tag[k] && rs1_tag[k] != '0) begin
                    rs1_valid[k] = 1'b1;
                    rs1_data[k]  = wb_data[p];
                end
                if (wb_valid[p] && wb_tag[p] == rs2_tag[k] && rs2_tag[k] != '0) begin
                    rs2_valid[k] = 1'b1;
                    rs2_data[k]  = wb_data[p];
                end
            end
        end
    end

    // Commits em ordem de slot: uma tag promovida a AR e liberada por um commit
    // mais novo do mesmo ciclo (mesmo rd confirmado duas vezes) termina FREE.
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < ENTRIES; i++) begin
                regfile[i] <= '0;
                state[i]   <= (i < 32) ? AR : FREE;
            end
        end else if (flush) begin
            for (int i = 0; i < ENTRIES; i++) begin
                if (state[i] != AR) begin
                    state[i] <= FREE;
                end
            end
            // Commits do ciclo de flush não são especulativos
            for (int j = 0; j < W; j++)
                if (commit_valid[j]) begin
                    state[commit_tag[j]]     <= AR;
                    state[commit_old_tag[j]] <= FREE;
                end
        end else begin
            for (int k = 0; k < W; k++)
                if (alloc[k]) state[alloc_tag[k]] <= RB_NOT_VALID;
            for (int p = 0; p < WB_N; p++)
                if (wb_valid[p]) begin
                    regfile[wb_tag[p]] <= wb_data[p];
                    state[wb_tag[p]]   <= RB_VALID;
                end
            for (int j = 0; j < W; j++)
                if (commit_valid[j]) begin
                    state[commit_tag[j]]     <= AR;
                    state[commit_old_tag[j]] <= FREE;
                end
        end
    end
endmodule

/* verilator lint_on DECLFILENAME */
