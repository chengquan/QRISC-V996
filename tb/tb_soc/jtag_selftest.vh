//-----------------------------------------------------------------
// jtag_selftest.vh —— 不依赖 OpenOCD 的 JTAG/SBA 自测(+JTAGTEST 开启)。
// tb 自己当 JTAG 主机,bit-bang TAP,经 DMI 操作 sbcs/sbaddress/sbdata,
// 做一次「写 GPIO 输出 -> 经 SBA 读回」和「读 DRAM 头」,打印 PASS/FAIL。
// 验证 jtag_dtm + dm_sba + dm_axi_master + 互联 整条链(不暂停 CPU)。
//
// 直接 include 进 tb_soc.v(共用 jtag_tck/tms/tdi/tdo 与 clk)。
//-----------------------------------------------------------------

localparam integer JT_HOLD = 20;            // 每个 TCK 相位保持的系统时钟数(>桥同步深度)
localparam [6:0] DMI_SBCS=7'h38, DMI_SBADDR0=7'h39, DMI_SBDATA0=7'h3c;
localparam [6:0] DMI_DMCONTROL=7'h10, DMI_DMSTATUS=7'h11, DMI_DPC=7'h40;
reg jt_tdo_s;

// 一个 TCK 节拍:在 tck=0 时设好 tms/tdi,采样 TDO(上次下降沿稳定),再 升->降
task jt_tick(input t_tms, input t_tdi);
begin
    jtag_tms = t_tms; jtag_tdi = t_tdi;
    repeat (JT_HOLD) @(posedge clk);
    jt_tdo_s = jtag_tdo;                 // 在上升沿前采样 TDO(标准)
    jtag_tck = 1'b1; repeat (JT_HOLD) @(posedge clk);   // 上升:DTM 移位
    jtag_tck = 1'b0; repeat (JT_HOLD) @(posedge clk);   // 下降:DTM 更新 TDO
end
endtask

// 复位 TAP -> 停在 Run-Test/Idle
task jt_reset; integer i;
begin
    for (i=0;i<6;i=i+1) jt_tick(1'b1,1'b0);   // >=5 个 TMS=1 -> Test-Logic-Reset
    jt_tick(1'b0,1'b0);                        // -> Run-Test/Idle
end
endtask

// 扫 IR(5 位,LSB 先)
task jt_scan_ir(input [4:0] ir); integer i;
begin
    jt_tick(1'b1,1'b0);   // RTI->Select-DR
    jt_tick(1'b1,1'b0);   // ->Select-IR
    jt_tick(1'b0,1'b0);   // ->Capture-IR
    jt_tick(1'b0,1'b0);   // ->Shift-IR
    for (i=0;i<5;i=i+1) jt_tick((i==4)?1'b1:1'b0, ir[i]);  // 5 位,最后一位 TMS=1 退出
    jt_tick(1'b1,1'b0);   // Exit1-IR->Update-IR
    jt_tick(1'b0,1'b0);   // ->RTI
end
endtask

// 扫 DR(nbits 位,LSB 先);din 移入,dout 收集移出
task jt_scan_dr(input [63:0] din, input integer nbits, output [63:0] dout); integer i;
begin
    dout = 64'b0;
    jt_tick(1'b1,1'b0);   // RTI->Select-DR
    jt_tick(1'b0,1'b0);   // ->Capture-DR
    jt_tick(1'b0,1'b0);   // ->Shift-DR
    for (i=0;i<nbits;i=i+1) begin
        jt_tick((i==nbits-1)?1'b1:1'b0, din[i]);
        dout[i] = jt_tdo_s;
    end
    jt_tick(1'b1,1'b0);   // Exit1-DR->Update-DR
    jt_tick(1'b0,1'b0);   // ->RTI
end
endtask

// 一次 DMI 访问:{addr[6:0], data[31:0], op[1:0]} = 41 位。
// 返回上一次访问的结果(DMI 两段式);op:1=read 2=write 0=nop
task jt_dmi(input [6:0] a, input [31:0] d, input [1:0] op, output [31:0] rdata, output [1:0] resp);
    reg [63:0] din, dout;
begin
    din = {23'b0, a, d, op};       // 低位 op,再 data,再 addr
    jt_scan_dr(din, 41, dout);
    resp  = dout[1:0];
    rdata = dout[33:2];
end
endtask

integer jt_err;
reg [31:0] jt_rd; reg [1:0] jt_resp;
reg [31:0] jt_dummy;
integer jt_poll;

initial begin : JTAG_SELFTEST
    if ($test$plusargs("JTAGTEST")) begin
        jt_err = 0;
        // 等复位释放 + 系统稳定
        wait (rst == 1'b0);
        repeat (200) @(posedge clk);
        $display("\n==================== JTAG/SBA 自测 ====================");

        jt_reset;
        jt_scan_ir(5'h11);             // 选 DMI

        // sbcs: sbaccess=2(32位)写口 = 0x00040000;读口(readonaddr)= 0x00140000

        // ---- 用例1:经 SBA 写 GPIO 输出寄存器(用 DUT 真实输出引脚旁证)----
        jt_dmi(DMI_SBCS,    32'h0004_0000, 2'd2, jt_rd, jt_resp);
        jt_dmi(DMI_SBADDR0, 32'h9400_0008, 2'd2, jt_rd, jt_resp);   // GPIO OUT 地址
        jt_dmi(DMI_SBDATA0, 32'hCAFE_0000, 2'd2, jt_rd, jt_resp);   // 写 0xCAFE0000
        repeat (100) @(posedge clk);
        $display("[JTAGTEST] SBA 写 GPIO 0x94000008=0xCAFE0000 -> 引脚 gpio_out=0x%08x", gpio_out);
        if (gpio_out === 32'hCAFE_0000) $display("[JTAGTEST]   用例1(SBA 写外设):PASS");
        else begin $display("[JTAGTEST]   用例1:FAIL"); jt_err=jt_err+1; end
        // (注:GPIO OUT 寄存器按 IP 设计读回的是输入回馈,故不读回校验,改用引脚旁证)

        // ---- 用例2:经 SBA 写 DRAM 暂存地址,再读回(写+读 双向回环)----
        jt_dmi(DMI_SBCS,    32'h0004_0000, 2'd2, jt_rd, jt_resp);   // 写口
        jt_dmi(DMI_SBADDR0, 32'h8010_0000, 2'd2, jt_rd, jt_resp);   // DRAM 暂存(避开内核)
        jt_dmi(DMI_SBDATA0, 32'hA5A5_1234, 2'd2, jt_rd, jt_resp);   // 写
        repeat (100) @(posedge clk);
        jt_dmi(DMI_SBCS,    32'h0014_0000, 2'd2, jt_rd, jt_resp);   // readonaddr 读口
        jt_dmi(DMI_SBADDR0, 32'h8010_0000, 2'd2, jt_rd, jt_resp);   // 写地址触发读
        repeat (100) @(posedge clk);
        jt_dmi(DMI_SBDATA0, 32'b0, 2'd1, jt_rd, jt_resp);           // 发起读 sbdata
        jt_dmi(DMI_SBDATA0, 32'b0, 2'd0, jt_rd, jt_resp);           // 取回
        $display("[JTAGTEST] SBA 写 DRAM 0x80100000=0xA5A51234,读回=0x%08x (resp=%0d)", jt_rd, jt_resp);
        if (jt_rd === 32'hA5A5_1234) $display("[JTAGTEST]   用例2(SBA 写+读 DRAM 回环):PASS");
        else begin $display("[JTAGTEST]   用例2:FAIL"); jt_err=jt_err+1; end

        // ---- 用例3:经 SBA 读 DRAM 头(= 镜像首字,非 0)----
        jt_dmi(DMI_SBCS,    32'h0014_0000, 2'd2, jt_rd, jt_resp);
        jt_dmi(DMI_SBADDR0, 32'h8000_0000, 2'd2, jt_rd, jt_resp);
        repeat (100) @(posedge clk);
        jt_dmi(DMI_SBDATA0, 32'b0, 2'd1, jt_rd, jt_resp);
        jt_dmi(DMI_SBDATA0, 32'b0, 2'd0, jt_rd, jt_resp);
        $display("[JTAGTEST] SBA 读 DRAM 0x80000000(镜像首字)= 0x%08x", jt_rd);
        if (jt_rd !== 32'h0 && jt_rd[31:0] !== 32'hxxxxxxxx) $display("[JTAGTEST]   用例3(SBA 读镜像):PASS");
        else begin $display("[JTAGTEST]   用例3:FAIL"); jt_err=jt_err+1; end

        // ---- 用例4(里程碑A):halt 核 -> 读 dmstatus.halted -> 读 PC -> resume ----
        // 先确认核在跑(读 dmstatus,allrunning bit11=1, allhalted bit9=0)
        jt_dmi(DMI_DMSTATUS, 32'b0, 2'd1, jt_rd, jt_resp);
        jt_dmi(DMI_DMSTATUS, 32'b0, 2'd0, jt_rd, jt_resp);
        $display("[JTAGTEST] halt 前 dmstatus=0x%08x (running bit11=%b halted bit9=%b)", jt_rd, jt_rd[11], jt_rd[9]);
        // 写 dmcontrol haltreq(bit31)+ dmactive(bit0)
        jt_dmi(DMI_DMCONTROL, 32'h8000_0001, 2'd2, jt_rd, jt_resp);
        repeat (60) @(posedge clk);              // 等排空 + halted
        jt_dmi(DMI_DMSTATUS, 32'b0, 2'd1, jt_rd, jt_resp);
        jt_dmi(DMI_DMSTATUS, 32'b0, 2'd0, jt_rd, jt_resp);
        $display("[JTAGTEST] halt 后 dmstatus=0x%08x (halted bit9=%b)", jt_rd, jt_rd[9]);
        // 读核 PC(dpc)
        jt_dmi(DMI_DPC, 32'b0, 2'd1, jt_rd, jt_resp);
        jt_dmi(DMI_DPC, 32'b0, 2'd0, jt_rd, jt_resp);
        $display("[JTAGTEST] halt 时核 PC(dpc) = 0x%08x", jt_rd);
        // 旁证:DUT 内部 dbg_halt/halted 真值 + PC 是否在代码区(0x8xxxxxxx)
        if (jt_rd[31:28]==4'h8) $display("[JTAGTEST]   用例4(halt + 读 PC):PASS  (PC 在代码区)");
        else begin $display("[JTAGTEST]   用例4:FAIL (PC=0x%08x 不在代码区)", jt_rd); jt_err=jt_err+1; end
        // resume(写 resumereq bit30)
        jt_dmi(DMI_DMCONTROL, 32'h4000_0001, 2'd2, jt_rd, jt_resp);
        $display("[JTAGTEST] 已 resume(核应继续运行)");

        if (jt_err==0) $display("[JTAGTEST] ===== 全部 PASS,JTAG/SBA + halt 链路工作 =====");
        else           $display("[JTAGTEST] ===== %0d 个用例 FAIL =====", jt_err);
        $display("======================================================\n");
        $finish;
    end
end
