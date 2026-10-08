// PRFRename with the external ROB interface (wiki decision 14).
// The ROB is a behavioral mock inside this testbench: it records dst_tag and
// old_tag at dispatch, marks entries finished on writeback, and retires in
// program order, sending commit_* to the rename only for entries with has_dest.
module PRFRename_tb;
    localparam int XLEN = 64;
    localparam int ENTRIES = 35;  // 32 architectural + 3 rename tags
    localparam int TAG_W = $clog2(ENTRIES);
    localparam int ROB_N = 8;

    logic clk = 0;
    always #5 clk = ~clk;

    // DUT ports
    logic reset = 1, flush = 0;
    logic dispatch_valid = 0, writes_rd = 0, rob_ready;
    logic [4:0] rs1 = 0, rs2 = 0, rd = 0;
    logic dispatch_ready;
    logic [1:0] src_ready;
    logic [XLEN-1:0] src1_data, src2_data;
    logic [TAG_W-1:0] src1_tag, src2_tag, dst_tag, old_tag;
    logic wb_valid = 0;
    logic [TAG_W-1:0] wb_tag = 0;
    logic [XLEN-1:0] wb_data = 0;
    logic commit_valid = 0;
    logic [4:0] commit_rd = 0;
    logic [TAG_W-1:0] commit_tag = 0, commit_old_tag = 0;

    PRFRename #(.XLEN(XLEN), .ENTRIES(ENTRIES)) dut (.*);

    // ---- ROB mock ----
    logic [4:0] m_rd[0:ROB_N-1];
    logic [TAG_W-1:0] m_tag[0:ROB_N-1], m_old[0:ROB_N-1];
    logic m_has[0:ROB_N-1], m_done[0:ROB_N-1];
    int m_head = 0, m_tail = 0, m_count = 0;
    logic rob_block = 0, do_retire = 0;
    assign rob_ready = !rob_block && m_count < ROB_N;

    logic [TAG_W-1:0] a, c, d, e, f, g, t, h, p, q, t1, t2, t3;

    task automatic check(input logic ok, input string msg);
        if (ok !== 1'b1) $fatal(1, "PRFRename: %s", msg);
    endtask

    // Presents one instruction to dispatch (not yet clocked).
    task automatic present(input logic w, input logic [4:0] dst, s1, s2);
        dispatch_valid = 1;
        writes_rd = w;
        rd = dst;
        rs1 = s1;
        rs2 = s2;
        #1;
    endtask

    task automatic writeback(input logic [TAG_W-1:0] tag, input logic [XLEN-1:0] data);
        wb_valid = 1;
        wb_tag = tag;
        wb_data = data;
    endtask

    // Prepares retirement of the ROB head; commit_* only for writers.
    task automatic retire;
        check(m_count != 0 && m_done[m_head], "mock: head must be finished to retire");
        commit_valid = m_has[m_head];
        commit_rd = m_rd[m_head];
        commit_tag = m_tag[m_head];
        commit_old_tag = m_old[m_head];
        do_retire = 1;
        #1;
    endtask

    // One clock: samples the dispatch transfer and writeback into the mock,
    // clocks the DUT, then pops a retired head and clears the one-cycle pulses.
    task automatic step;
        logic xfer;
        xfer = dispatch_valid && dispatch_ready && rob_ready;
        if (flush) begin
            m_head = 0;
            m_tail = 0;
            m_count = 0;
        end else begin
            if (wb_valid)
                for (int i = 0; i < ROB_N; i++)
                    if (m_has[i] && m_tag[i] == wb_tag) m_done[i] = 1;
            if (do_retire) begin
                m_head = (m_head + 1) % ROB_N;
                m_count--;
            end
            if (xfer) begin
                m_rd[m_tail] = rd;
                m_has[m_tail] = writes_rd && rd != 0;
                m_tag[m_tail] = dst_tag;
                m_old[m_tail] = old_tag;
                m_done[m_tail] = !(writes_rd && rd != 0);  // no result to wait for
                m_tail = (m_tail + 1) % ROB_N;
                m_count++;
            end
        end
        @(posedge clk);
        #1;
        dispatch_valid = 0;
        wb_valid = 0;
        commit_valid = 0;
        do_retire = 0;
        flush = 0;
        #1;
    endtask

    initial begin
        step();
        reset = 0;
        #1;

        // x0: reads zero, never allocates a tag.
        present(1, 0, 0, 0);
        check(src_ready == 2'b11 && src1_data == 0 && src2_data == 0, "x0 must read as zero");
        check(dispatch_ready, "write to x0 needs no tag");
        dispatch_valid = 0;
        present(1, 1, 0, 0);
        t = dst_tag;
        present(1, 0, 0, 0);
        step();
        present(1, 1, 0, 0);
        check(dst_tag == t, "write to x0 must not consume a tag");
        dispatch_valid = 0;
        // The x0 writer still occupies the ROB; it retires without a commit pulse.
        retire();
        check(!commit_valid, "x0 writer retires without commanding the rename");
        step();

        // Same register as source and destination: source sees the old mapping.
        present(1, 5, 5, 5);
        check(dispatch_ready, "first allocation");
        check(src_ready == 2'b11 && src1_data == 0, "x5 source reads architectural value");
        check(old_tag == src1_tag, "old_tag is the mapping before allocation");
        a = dst_tag;
        check(a != old_tag, "new tag differs from the replaced one");
        step();

        // Store reading x5: depends on the previous instruction, allocates nothing.
        present(0, 0, 5, 0);
        check(!src_ready[0] && src1_tag == a, "RAW: store waits on tag of x5");
        step();

        // ROB refuses: the rename must not allocate.
        rob_block = 1;
        present(1, 6, 5, 0);
        check(dispatch_ready, "rename alone could accept");
        t = dst_tag;
        step();
        rob_block = 0;
        present(1, 6, 5, 0);
        check(dst_tag == t, "tag refused by the ROB must stay free");
        check(old_tag == TAG_W'(6), "x6 mapping unchanged after refused dispatch");
        c = dst_tag;
        step();

        // Last free tag, then back-pressure.
        present(1, 7, 0, 0);
        check(dispatch_ready, "last free tag");
        d = dst_tag;
        step();
        present(1, 8, 0, 0);
        check(!dispatch_ready, "no free tag: writer must stall");
        present(0, 0, 0, 0);
        check(dispatch_ready, "non-writer passes without a free tag");
        present(1, 0, 0, 0);
        check(dispatch_ready, "write to x0 passes without a free tag");
        dispatch_valid = 0;

        // Writeback out of order: younger result readable before the older.
        writeback(c, 66);
        step();
        present(0, 0, 6, 5);
        check(src_ready == 2'b01 && src1_data == 66, "younger result ready, older pending");
        dispatch_valid = 0;
        writeback(a, 55);
        step();
        present(0, 0, 5, 6);
        check(src_ready == 2'b11 && src1_data == 55 && src2_data == 66, "both results ready");
        dispatch_valid = 0;

        // Commit x5 (head): its old tag goes back to the free pool.
        retire();
        step();
        present(1, 9, 5, 0);
        check(dispatch_ready && dst_tag == TAG_W'(5), "old tag of x5 is reused");
        check(src_ready[0] && src1_data == 55, "committed x5 still reads 55");
        e = dst_tag;
        // Same cycle: dispatch x9 and retire the store (no commit pulse).
        retire();
        check(!commit_valid, "store retires without commanding the rename");
        step();
        present(1, 10, 0, 0);
        check(!dispatch_ready, "store retirement freed no tag");
        dispatch_valid = 0;

        // Commit x6: frees tag 6.
        retire();
        step();
        present(1, 10, 0, 0);
        check(dispatch_ready && dst_tag == TAG_W'(6), "old tag of x6 is reused");
        dispatch_valid = 0;

        // Same cycle: commit x7 and dispatch a new writer of x7.
        writeback(d, 77);
        step();
        present(1, 7, 7, 0);
        check(src_ready[0] && src1_data == 77 && old_tag == d, "x7 source and old_tag");
        f = dst_tag;
        retire();
        step();
        present(0, 0, 7, 0);
        check(!src_ready[0] && src1_tag == f, "commit of older x7 keeps the new mapping");
        dispatch_valid = 0;

        // Flush with x9 and x7 in flight: committed values come back.
        flush = 1;
        step();
        present(0, 0, 7, 5);
        check(src_ready == 2'b11 && src1_data == 77 && src2_data == 55,
              "flush restores committed x7 and x5");
        present(0, 0, 9, 6);
        check(src_ready == 2'b11 && src1_data == 0 && src2_data == 66,
              "flush restores committed x9 and x6");
        dispatch_valid = 0;

        // Stale writeback of a discarded tag is ignored, then the tag is reused.
        writeback(e, 999);
        step();
        present(1, 11, 0, 0);
        g = dst_tag;
        check(g == e, "tag discarded by flush is reused");
        step();
        present(0, 0, 11, 0);
        check(!src_ready[0] && src1_tag == g, "reused tag starts not ready");
        dispatch_valid = 0;
        writeback(g, 111);
        step();
        retire();
        step();
        present(0, 0, 11, 0);
        check(src_ready[0] && src1_data == 111, "x11 commits the new result");
        dispatch_valid = 0;

        // Bypass: a source reads its tag in the same cycle as that tag's writeback.
        present(1, 12, 0, 0);
        h = dst_tag;
        step();
        writeback(h, 121);
        present(0, 0, 12, 0);
        check(src_ready[0] && src1_data == 121, "writeback in the dispatch cycle is bypassed");
        step();
        retire();  // x12
        step();
        retire();  // reader of x12
        step();

        // Flush and commit in the same cycle: the commit is not speculative.
        present(1, 13, 0, 0);
        p = dst_tag;
        step();
        writeback(p, 131);
        step();
        present(1, 14, 13, 0);
        check(src_ready[0] && src1_data == 131, "x13 result ready before commit");
        q = dst_tag;
        step();
        retire();  // x13 commits while x14 is discarded
        check(commit_valid && commit_tag == p, "mock commits x13");
        flush = 1;
        step();
        present(0, 0, 13, 14);
        check(src_ready == 2'b11 && src1_data == 131, "commit in the flush cycle keeps x13");
        check(src2_tag == TAG_W'(14) && src2_data == 0, "discarded x14 returns to its committed tag");
        dispatch_valid = 0;

        // After that flush every non-architectural tag is free exactly once:
        // the discarded tag of x14 and the old tag of x13 come back, p does not.
        present(1, 15, 0, 0);
        t1 = dst_tag;
        step();
        present(1, 16, 0, 0);
        t2 = dst_tag;
        step();
        present(1, 17, 0, 0);
        check(dispatch_ready, "three tags free after flush with commit");
        t3 = dst_tag;
        step();
        present(1, 18, 0, 0);
        check(!dispatch_ready, "only ENTRIES-32 tags are free");
        dispatch_valid = 0;
        check(t1 != t2 && t1 != t3 && t2 != t3, "free tags are distinct");
        check(t1 != p && t2 != p && t3 != p, "committed tag of x13 is not reallocated");
        check(q == t1 || q == t2 || q == t3, "discarded tag of x14 is free again");
        check(TAG_W'(13) == t1 || TAG_W'(13) == t2 || TAG_W'(13) == t3,
              "old tag of x13 is free again");
        // Reused tags (including one that was AR) start not ready.
        present(0, 0, 15, 16);
        check(src_ready == 2'b00, "reallocated tags start not ready");
        present(0, 0, 17, 0);
        check(!src_ready[0], "reallocated old AR tag starts not ready");
        dispatch_valid = 0;

        $display("PRFRename PASS");
        $finish;
    end
endmodule
