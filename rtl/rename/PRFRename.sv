// Unified physical register file rename (wiki: Register-Rename, decision 14).
// The ROB is external: it keeps dst_tag/old_tag and drives commit_* in order.
// Reset state: arch reg i maps to tag i (state AR); tags 32..ENTRIES-1 are free.
module PRFRename #(
    parameter  int XLEN    = 64,
    parameter  int ENTRIES = 64,              // 32 architectural + rename tags
    localparam int TAG_W   = $clog2(ENTRIES)
) (
    input logic clk,
    input logic reset,
    input logic flush,

    // dispatch
    input  logic             dispatch_valid,
    input  logic [      4:0] rs1,
    input  logic [      4:0] rs2,
    input  logic [      4:0] rd,
    input  logic             writes_rd,
    input  logic             rob_ready,
    output logic             dispatch_ready,
    output logic [      1:0] src_ready,
    output logic [ XLEN-1:0] src1_data,
    output logic [ XLEN-1:0] src2_data,
    output logic [TAG_W-1:0] src1_tag,
    output logic [TAG_W-1:0] src2_tag,
    output logic [TAG_W-1:0] dst_tag,
    output logic [TAG_W-1:0] old_tag,

    // writeback
    input logic             wb_valid,
    input logic [TAG_W-1:0] wb_tag,
    input logic [ XLEN-1:0] wb_data,

    // commit (only instructions with a destination)
    input logic             commit_valid,
    input logic [      4:0] commit_rd,
    input logic [TAG_W-1:0] commit_tag,
    input logic [TAG_W-1:0] commit_old_tag
);
    logic needs_tag, alloc, free_empty;
    logic [31:0][TAG_W-1:0] committed_map;

    assign needs_tag      = writes_rd && rd != 5'd0;
    assign dispatch_ready = !needs_tag || !free_empty;
    assign alloc          = dispatch_valid && dispatch_ready && rob_ready && needs_tag;

    PRFFreeList #(
        .ENTRIES(ENTRIES)
    ) free_list (
        .clk,
        .reset,
        .flush,
        .alloc,
        .alloc_tag(dst_tag),
        .empty    (free_empty),
        .commit_valid,
        .commit_old_tag
    );

    PRFMapTable #(
        .ENTRIES(ENTRIES)
    ) map_table (
        .clk,
        .reset,
        .flush,
        .rs1,
        .rs2,
        .rd,
        .rs1_tag    (src1_tag),
        .rs2_tag    (src2_tag),
        .rd_old_tag (old_tag),
        .write_valid(alloc),
        .write_tag  (dst_tag),
        .committed_map,
        .commit_valid,
        .commit_rd,
        .commit_tag
    );

    PRFCommittedTable #(
        .ENTRIES(ENTRIES)
    ) committed_table (
        .clk,
        .reset,
        .commit_valid,
        .commit_rd,
        .commit_tag,
        .committed_map
    );

    PRFRegFile #(
        .XLEN(XLEN),
        .ENTRIES(ENTRIES)
    ) reg_file (
        .clk,
        .reset,
        .flush,
        .rs1_tag  (src1_tag),
        .rs2_tag  (src2_tag),
        .rs1_valid(src_ready[0]),
        .rs2_valid(src_ready[1]),
        .rs1_data (src1_data),
        .rs2_data (src2_data),
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

// Circular queue of free tags. Pops at head on alloc, pushes the replaced tag
// at tail on commit. On flush, every speculatively allocated tag returns.
module PRFFreeList #(
    parameter  int ENTRIES = 64,
    localparam int TAG_W   = $clog2(ENTRIES),
    localparam int FREE_N  = ENTRIES - 32,
    localparam int PTR_W   = FREE_N > 1 ? $clog2(FREE_N) : 1,  // index into the queue
    localparam int CNT_W   = $clog2(FREE_N + 1)                // count goes 0..FREE_N
) (
    input  logic             clk,
    input  logic             reset,
    input  logic             flush,
    input  logic             alloc,
    output logic [TAG_W-1:0] alloc_tag,      // tag at head, valid when !empty
    output logic             empty,
    input  logic             commit_valid,
    input  logic [TAG_W-1:0] commit_old_tag
);
    logic [PTR_W-1:0] head, tail;
    logic [TAG_W-1:0] tags[FREE_N];
    logic [CNT_W-1:0] count;

    assign alloc_tag = tags[head];
    assign empty = count == 0;

    function automatic logic [PTR_W-1:0] next(input logic [PTR_W-1:0] ptr);
        return (ptr == PTR_W'(FREE_N - 1)) ? '0 : ptr + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < FREE_N; i++) tags[i] <= TAG_W'(32 + i);
            head  <= 0;
            tail  <= 0;
            count <= CNT_W'(FREE_N);
        end else if (flush) begin
            if (commit_valid) begin
                tags[tail] <= commit_old_tag;
                tail       <= next(tail);
            end
            head  <= commit_valid ? next(tail) : tail;
            count <= CNT_W'(FREE_N);  // always FREE_N non-AR tags
        end else begin
            if (alloc) begin
                // Pop head tag for allocation
                head <= next(head);
            end
            if (commit_valid) begin
                // Push commit_old_tag to tail of free list
                tags[tail] <= commit_old_tag;
                tail <= next(tail);
            end
            case ({
                alloc, commit_valid
            })
                2'b01:   count <= count + 1'b1;
                2'b10:   count <= count - 1'b1;
                default: ;
            endcase
        end

    end
endmodule

// Speculative map: arch reg -> tag. Sources are read before rd is overwritten
// in the same cycle. On flush it is restored from the committed map.
module PRFMapTable #(
    parameter  int ENTRIES = 64,
    localparam int TAG_W   = $clog2(ENTRIES)
) (
    input  logic                        clk,
    input  logic                        reset,
    input  logic                        flush,
    input  logic [      4:0]            rs1,
    input  logic [      4:0]            rs2,
    input  logic [      4:0]            rd,
    output logic [TAG_W-1:0]            rs1_tag,
    output logic [TAG_W-1:0]            rs2_tag,
    output logic [TAG_W-1:0]            rd_old_tag,
    input  logic                        write_valid,
    input  logic [TAG_W-1:0]            write_tag,
    input  logic [     31:0][TAG_W-1:0] committed_map,
    // A commit in the flush cycle is not yet in committed_map
    input  logic                        commit_valid,
    input  logic [      4:0]            commit_rd,
    input  logic [TAG_W-1:0]            commit_tag
);
    logic [TAG_W-1:0] speculative_map[32];

    assign rs1_tag    = speculative_map[rs1];
    assign rs2_tag    = speculative_map[rs2];
    assign rd_old_tag = speculative_map[rd];


    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 32; i++) begin
                speculative_map[i] <= TAG_W'(i);
            end
        end else if (flush) begin
            for (int i = 0; i < 32; i++) begin
                speculative_map[i] <= committed_map[i];
            end
            if (commit_valid) speculative_map[commit_rd] <= commit_tag;
        end else if (write_valid) begin
            // Update speculative map with new mapping for rd
            speculative_map[rd] <= write_tag;
        end
    end
endmodule

// Architectural map: arch reg -> tag, updated only on commit.
module PRFCommittedTable #(
    parameter  int ENTRIES = 64,
    localparam int TAG_W   = $clog2(ENTRIES)
) (
    input  logic                        clk,
    input  logic                        reset,
    input  logic                        commit_valid,
    input  logic [      4:0]            commit_rd,
    input  logic [TAG_W-1:0]            commit_tag,
    output logic [     31:0][TAG_W-1:0] committed_map
);

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 32; i++) begin
                committed_map[i] <= TAG_W'(i);
            end
        end else if (commit_valid) begin
            // Update committed map with new mapping for commit_rd
            committed_map[commit_rd] <= commit_tag;
        end
    end
endmodule

// Physical registers: value[] and state[] (FREE, RB_NOT_VALID, RB_VALID, AR).
// A read is valid in RB_VALID or AR. Flush sets every non-AR tag to FREE.
module PRFRegFile #(
    parameter  int XLEN    = 64,
    parameter  int ENTRIES = 64,
    localparam int TAG_W   = $clog2(ENTRIES)
) (
    input  logic             clk,
    input  logic             reset,
    input  logic             flush,
    input  logic [TAG_W-1:0] rs1_tag,
    input  logic [TAG_W-1:0] rs2_tag,
    output logic             rs1_valid,
    output logic             rs2_valid,
    output logic [ XLEN-1:0] rs1_data,
    output logic [ XLEN-1:0] rs2_data,
    input  logic             alloc,
    input  logic [TAG_W-1:0] alloc_tag,
    input  logic             wb_valid,
    input  logic [TAG_W-1:0] wb_tag,
    input  logic [ XLEN-1:0] wb_data,
    input  logic             commit_valid,
    input  logic [TAG_W-1:0] commit_tag,
    input  logic [TAG_W-1:0] commit_old_tag
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

    logic            hit1;
    assign hit1      = wb_valid && wb_tag == rs1_tag && rs1_tag != '0;
    assign rs1_valid = hit1 || has_value(state[rs1_tag]);
    assign rs1_data  = hit1 ? wb_data : regfile[rs1_tag];

    logic hit2;
    assign hit2      = wb_valid && wb_tag == rs2_tag && rs2_tag != '0;
    assign rs2_valid = hit2 || has_value(state[rs2_tag]);
    assign rs2_data  = hit2 ? wb_data : regfile[rs2_tag];


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
            // A commit in the flush cycle is not speculative
            if (commit_valid) begin
                state[commit_tag]     <= AR;
                state[commit_old_tag] <= FREE;
            end
        end else begin
            if (alloc) state[alloc_tag] <= RB_NOT_VALID;
            if (wb_valid) begin
                regfile[wb_tag] <= wb_data;
                state[wb_tag]   <= RB_VALID;
            end
            if (commit_valid) begin
                state[commit_tag]     <= AR;
                state[commit_old_tag] <= FREE;
            end
        end
    end
endmodule

/* verilator lint_on DECLFILENAME */
