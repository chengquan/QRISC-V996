//-----------------------------------------------------------------
// dbg_fast_test.vh —— 快速调试自测(+DBGTEST)。
// tb 直接驱动 DM 的 DMI(tdmi_*,绕过慢 JTAG),几千周期即可验证:
//   halt -> 读 misa/dpc/x10 -> 写 x10 -> 读回 -> resume。
// 结果同时打到屏幕和 dbg_result.txt(跨调用可读)。
//-----------------------------------------------------------------
localparam [6:0] T_DMCONTROL=7'h10, T_DMSTATUS=7'h11, T_DATA0=7'h04,
                 T_ABSTRACTCS=7'h16, T_COMMAND=7'h17;
integer dt_f;

// 一次 DMI 访问(直接驱动 tdmi_*)
task t_dmi(input [6:0] a, input [31:0] d, input [1:0] op,
           output [31:0] rd, output [1:0] resp);
begin
    @(posedge clk);
    tdmi_addr <= a; tdmi_wdata <= d; tdmi_op <= op; tdmi_req <= 1'b1;
    @(posedge clk);
    tdmi_req <= 1'b0;
    repeat (4) @(posedge clk);
    rd = tdmi_rdata; resp = tdmi_resp;
end
endtask
task t_abs_read(input [15:0] regno, output [31:0] val);
    reg [31:0] r; reg [1:0] resp;
begin
    t_dmi(T_COMMAND, {8'd0,5'd0,1'b1,1'b0,regno}, 2'd2, r, resp);
    repeat (6) @(posedge clk);
    t_dmi(T_DATA0, 32'b0, 2'd1, r, resp);
    val = r;
end
endtask
task t_abs_write(input [15:0] regno, input [31:0] val);
    reg [31:0] r; reg [1:0] resp;
begin
    t_dmi(T_DATA0,   val, 2'd2, r, resp);
    t_dmi(T_COMMAND, {8'd0,5'd0,1'b1,1'b1,regno}, 2'd2, r, resp);
    repeat (6) @(posedge clk);
end
endtask
// 打印到屏幕 + 文件
task pr(input [1023:0] s);
begin $display("%0s", s); $fwrite(dt_f, "%0s\n", s); end
endtask
task prv(input [1023:0] s, input [31:0] v);
begin $display("%0s0x%08x", s, v); $fwrite(dt_f, "%0s0x%08x\n", s, v); end
endtask

integer dt_err;
reg [31:0] dt_rd; reg [1:0] dt_resp;
reg ok;

initial begin : DBG_FAST_TEST
    if ($test$plusargs("DBGTEST")) begin
        dt_err = 0;
        dt_f = $fopen("dbg_result.txt", "w");
        tdmi_en = 1'b1;
        wait (rst == 1'b0);
        repeat (300) @(posedge clk);
        pr("============ 调试快速自测(直驱 DMI)============");

        // 1) halt
        t_dmi(T_DMCONTROL, 32'h8000_0001, 2'd2, dt_rd, dt_resp);
        repeat (40) @(posedge clk);
        t_dmi(T_DMSTATUS, 32'b0, 2'd1, dt_rd, dt_resp);
        prv("[DBG] halt 后 dmstatus = ", dt_rd);
        ok = dt_rd[9]; if (!ok) dt_err=dt_err+1;
        pr(ok ? "[DBG]   halt:PASS" : "[DBG]   halt:FAIL");

        // 2) 读 misa
        t_abs_read(16'h0301, dt_rd);
        prv("[DBG] 读 misa = ", dt_rd);
        ok = (dt_rd===32'h4000_1101); if (!ok) dt_err=dt_err+1;
        pr(ok ? "[DBG]   读 misa:PASS" : "[DBG]   读 misa:FAIL");

        // 3) 读 dpc
        t_abs_read(16'h07b1, dt_rd);
        prv("[DBG] 读 dpc = ", dt_rd);
        ok = (dt_rd[31:28]==4'h8); if (!ok) dt_err=dt_err+1;
        pr(ok ? "[DBG]   读 dpc:PASS" : "[DBG]   读 dpc:FAIL");

        // 4) 写 x10 再读回
        t_abs_write(16'h100A, 32'h1234_ABCD);
        t_abs_read (16'h100A, dt_rd);
        prv("[DBG] 写 x10=0x1234ABCD,读回 = ", dt_rd);
        ok = (dt_rd===32'h1234_ABCD); if (!ok) dt_err=dt_err+1;
        pr(ok ? "[DBG]   写/读 GPR x10:PASS" : "[DBG]   写/读 GPR x10:FAIL");

        // 5) resume
        t_dmi(T_DMCONTROL, 32'h4000_0001, 2'd2, dt_rd, dt_resp);
        pr("[DBG] resume");
        pr(dt_err==0 ? "[DBG] ===== 调试快速自测 全 PASS =====" : "[DBG] ===== 有 FAIL =====");
        $fwrite(dt_f, "ERR=%0d\n", dt_err);
        $fclose(dt_f);
        $finish;
    end
end
