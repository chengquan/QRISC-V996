//-----------------------------------------------------------------
// dm_sba.v —— RISC-V Debug Spec 0.13 Debug Module(只做 System Bus Access)
//
//   实现的 DMI 寄存器(够 OpenOCD 走 sysbus 内存访问):
//     0x10 dmcontrol   (dmactive / ndmreset)
//     0x11 dmstatus    (version=2, authenticated, 报告 1 个「运行中」hart)
//     0x38 sbcs        (sbversion/sbbusy/sbreadonaddr/sbaccess/sbautoincrement/
//                       sbreadondata/sberror/sbasize/支持的访问位宽)
//     0x39 sbaddress0
//     0x3c sbdata0
//
//   SBA 语义:写 sbaddress0(若 sbreadonaddr)触发读;写 sbdata0 触发写;
//   读 sbdata0 返回上次读数据(若 sbreadondata 再触发一次读);忙时对 sbdata0
//   的访问回 DMI busy(3),OpenOCD 自动重试。实际总线事务交给 dm_axi_master。
//
//   不支持 halt/单步/读 CPU 寄存器(那需要核有调试模式)——纯 SBA。
//-----------------------------------------------------------------
module dm_sba
#(
    parameter ABITS = 7
)
(
     input             clk_i
    ,input             rst_i
    // DMI(来自 jtag_dtm)
    ,input             dmi_req_i           // 1 拍脉冲
    ,input  [ABITS-1:0] dmi_addr_i
    ,input  [31:0]     dmi_wdata_i
    ,input  [1:0]      dmi_op_i            // 1=read 2=write
    ,output [31:0]     dmi_rdata_o         // 持续呈现上次结果
    ,output [1:0]      dmi_resp_o          // 0=ok 2=fail 3=busy
    // 总线主(交给 dm_axi_master 执行)
    ,output            bus_req_o           // 1 拍脉冲:发起一次总线事务
    ,output            bus_we_o            // 1=写 0=读
    ,output [31:0]     bus_addr_o
    ,output [31:0]     bus_wdata_o
    ,output [2:0]      bus_size_o          // 0=byte 1=half 2=word
    ,input             bus_done_i          // 1 拍脉冲:事务完成
    ,input  [31:0]     bus_rdata_i
    ,input             bus_err_i
    // 系统软复位请求(ndmreset),tb/soc 可选用
    ,output            ndmreset_o
    // 核 halt 接口(里程碑A):haltreq -> dbg_halt_o;dbg_pc_i = 核下一条 PC(= dpc)
    ,output            dbg_halt_o
    ,input  [31:0]     dbg_pc_i
    // 调试读写 GPR(里程碑B,抽象命令用)
    ,output [4:0]      dbg_reg_idx_o
    ,input  [31:0]     dbg_reg_rdata_i
    ,output            dbg_reg_we_o
    ,output [31:0]     dbg_reg_wdata_o
    // 单步(里程碑C)
    ,output            dbg_step_o
    ,input             dbg_issued_i
    // 断点 + 恢复重定向(里程碑D)
    ,output            dbg_ebreakm_o
    ,input             dbg_ebreak_i
    ,input  [31:0]     dbg_ebreak_pc_i
    ,output            dbg_redirect_o
    ,output [31:0]     dbg_redirect_pc_o
);

// DMI 寄存器地址
localparam A_DMCONTROL=7'h10, A_DMSTATUS=7'h11,
           A_DPC=7'h40,    // 非标准:读核 dpc(里程碑A;另 abstract 命令也支持 0x7b1)
           A_DATA0=7'h04, A_ABSTRACTCS=7'h16, A_COMMAND=7'h17,   // 抽象命令
           A_SBCS=7'h38, A_SBADDR0=7'h39, A_SBDATA0=7'h3c;
// CSR 号(抽象命令 access register 的 regno)
localparam [11:0] CSR_MISA=12'h301, CSR_DPC=12'h7b1, CSR_DCSR=12'h7b0;
localparam [31:0] MISA_RV32IMA = 32'h4000_1101;   // MXL=1, A+I+M
localparam [31:0] DCSR_VAL     = 32'h4000_0003;   // xdebugver=4, prv=3

// dmstatus 位:[3:0]version=2 [7]authenticated [8]anyhalted [9]allhalted
//             [10]anyrunning [11]allrunning

//--------------------------------------------------------------
// 寄存器
//--------------------------------------------------------------
reg        dmactive_q, ndmreset_q;
// ---- halt 控制(里程碑A)----
reg        halt_req_q;          // dbg_halt_o:请求核停止发射
reg        halted_q;            // 核已 halt(流水线排空后)
reg [4:0]  drain_q;             // halt 请求后等若干拍当作排空完成
reg        resumeack_q;         // dmstatus.allresumeack:resume 已确认(OpenOCD 等这位)
assign dbg_halt_o = halt_req_q;
// ---- 抽象命令(读写 GPR/CSR;里程碑B)----
reg [31:0] data0_q;          // 抽象数据寄存器(读出/写入的值)
reg [15:0] abs_regno_q;      // 当前访问的 regno(0x1000+x = GPR;0x301/0x7bx = CSR)
reg        abs_write_q;      // 1=写 0=读
reg [1:0]  abs_go_q;         // 命令处理小状态:01=本拍发起,10=次拍取结果
reg [2:0]  abs_cmderr_q;     // 0=ok 2=未支持
reg        reg_we_q;
// ---- 单步(里程碑C)----
reg        dcsr_step_q;       // 调试器设的单步标志(dcsr.step)
reg        stepping_q;        // 正在单步窗口(已 resume,等一条指令发射)
assign dbg_step_o = stepping_q;
// ---- 断点 + dpc 寄存器 + 恢复重定向(里程碑D)----
reg        dcsr_ebreakm_q;    // dcsr.ebreakm:ebreak 进调试
reg [31:0] dpc_q;             // 调试 PC(halt 处 / ebreak 处 / 调试器改写)
reg        bp_q;              // 本次 halt 由 ebreak 断点引起
reg        dpc_written_q;     // 调试器改写过 dpc(resume 需重定向)
reg [3:0]  redirect_q;        // 重定向序列倒计时(见下方时序)
reg [2:0]  dcsr_cause_q;      // dcsr.cause:1=ebreak 3=haltreq 4=step(给 OpenOCD/GDB 看停因)
assign dbg_ebreakm_o    = dcsr_ebreakm_q;
// 重定向时序:核仍 halt(冻结)时脉冲 branch_csr 把 pc_x_q+取指都设到 dpc,
// 然后再撤 halt,核就从 dpc 干净起跑(避免先执行旧 PC 的指令再跳)。
//   redirect_q: 6,5 = halt 中注入 redirect(==5 脉冲);4,3,2 = 仍 halt 让取指对齐 dpc;
//               1 = 撤 halt(下一拍核从 dpc 发射);0 = 结束
assign dbg_redirect_o   = (redirect_q == 4'd5);  // halt 中注入(pc_x_q+取指→dpc)
assign dbg_redirect_pc_o= dpc_q;
assign dbg_reg_idx_o   = abs_regno_q[4:0];        // GPR 号(halt 时核读此寄存器)
assign dbg_reg_we_o    = reg_we_q;
assign dbg_reg_wdata_o = data0_q;
wire abs_is_gpr = (abs_regno_q[15:5]==11'h080);   // 0x1000..0x101f
// abstractcs:[3:0]datacount=1 [10:8]cmderr [12]busy [28:24]progbufsize=0
// busy:命令处理中(abs_go!=0)置 1,让轮询的调试器等结果再读 data0
wire abs_busy_w = (abs_go_q != 2'b00);
wire [31:0] abstractcs_rd = {3'b0,5'd0,11'b0,abs_busy_w,1'b0,abs_cmderr_q,4'b0,4'd1};
wire [31:0] dmstatus_rd =
    (1<<7) | 32'd2 |                                  // authenticated + version=2
    (halted_q    ? ((1<<9)|(1<<8)) : 32'b0) |        // [9]allhalted [8]anyhalted
    (halted_q    ? 32'b0 : ((1<<11)|(1<<10))) |      // [11]allrunning [10]anyrunning
    (resumeack_q ? ((1<<17)|(1<<16)) : 32'b0);       // [17]allresumeack [16]anyresumeack
reg        sbreadonaddr_q, sbautoincrement_q, sbreadondata_q;
reg [2:0]  sbaccess_q;                 // 访问位宽:0=8b 1=16b 2=32b
reg [2:0]  sberror_q;                  // 0=none 其它=错误
reg        sbbusy_q;
reg        sbbusyerror_q;
reg [31:0] sbaddr_q;
reg [31:0] sbdata_q;                   // 最近一次读回的数据

assign ndmreset_o = ndmreset_q;

// sbcs 读值
wire [31:0] sbcs_rd =
    {3'd1,                       // [31:29] sbversion = 1
     6'b0,                       // [28:23]
     sbbusyerror_q,              // [22]
     sbbusy_q,                   // [21]
     sbreadonaddr_q,             // [20]
     sbaccess_q,                 // [19:17]
     sbautoincrement_q,          // [16]
     sbreadondata_q,             // [15]
     sberror_q,                  // [14:12]
     7'd32,                      // [11:5] sbasize = 32
     1'b0,1'b0,                  // [4] sbaccess128 [3] sbaccess64
     1'b1,1'b1,1'b1};            // [2]32 [1]16 [0]8  —— 支持 8/16/32

//--------------------------------------------------------------
// 总线事务发起 + 完成
//--------------------------------------------------------------
reg        bus_req_q, bus_we_q;
reg [31:0] bus_addr_q, bus_wdata_q;
assign bus_req_o   = bus_req_q;
assign bus_we_o    = bus_we_q;
assign bus_addr_o  = bus_addr_q;
assign bus_wdata_o = bus_wdata_q;
assign bus_size_o  = sbaccess_q;

// 地址自增步长(按访问位宽)
wire [31:0] incr = (sbaccess_q==3'd0) ? 32'd1 :
                   (sbaccess_q==3'd1) ? 32'd2 : 32'd4;

//--------------------------------------------------------------
// DMI 响应(持续呈现,供 DTM 在 Capture-DR 回读)
//--------------------------------------------------------------
reg [31:0] dmi_rdata_q;
reg [1:0]  dmi_resp_q;
assign dmi_rdata_o = dmi_rdata_q;
assign dmi_resp_o  = dmi_resp_q;

// 触发一次总线读/写的小任务(置位 bus_req_q + 标记 busy)
// (用普通赋值在 always 里展开)

always @(posedge clk_i or posedge rst_i)
if (rst_i) begin
    dmactive_q<=1'b0; ndmreset_q<=1'b0;
    halt_req_q<=1'b0; halted_q<=1'b0; drain_q<=5'd0; resumeack_q<=1'b0;
    data0_q<=32'b0; abs_regno_q<=16'b0; abs_write_q<=1'b0; abs_go_q<=2'b0;
    abs_cmderr_q<=3'b0; reg_we_q<=1'b0;
    dcsr_step_q<=1'b0; stepping_q<=1'b0;
    dcsr_ebreakm_q<=1'b0; dpc_q<=32'b0; bp_q<=1'b0; dpc_written_q<=1'b0; redirect_q<=4'd0;
    dcsr_cause_q<=3'd0;
    sbreadonaddr_q<=1'b0; sbautoincrement_q<=1'b0; sbreadondata_q<=1'b0;
    sbaccess_q<=3'd2; sberror_q<=3'd0; sbbusy_q<=1'b0; sbbusyerror_q<=1'b0;
    sbaddr_q<=32'b0; sbdata_q<=32'b0;
    bus_req_q<=1'b0; bus_we_q<=1'b0; bus_addr_q<=32'b0; bus_wdata_q<=32'b0;
    dmi_rdata_q<=32'b0; dmi_resp_q<=2'b0;
end else begin
    bus_req_q <= 1'b0;          // 默认拉低,仅发起那拍为 1

    reg_we_q <= 1'b0;           // 写 GPR 使能仅脉冲一拍
    // 重定向倒计时:核仍 halt 时(redirect_q==5)脉冲 redirect 把 pc_x_q+取指设到 dpc,
    // 多等几拍让取指真正对齐 dpc,到 ==1 才撤 halt,核就从 dpc 干净起跑。
    if (redirect_q != 4'd0) begin
        redirect_q <= redirect_q - 4'd1;
        // 撤 halt 的同拍置 resumeack(此刻核真正离开 halt 开始跑)
        if (redirect_q == 4'd1) begin halt_req_q <= 1'b0; halted_q <= 1'b0; resumeack_q <= 1'b1; end
    end

    // ---- 断点:核执行 ebreak(ebreakm 开启)-> 进 halt,dpc = ebreak 的 PC ----
    // 注意:resumeack 是 sticky,只由调试器显式 haltreq/新 resumereq 清;ebreak 是
    // 自动 halt(resume 确实发生过并被确认),保留 resumeack 让 OpenOCD 看到“已 resume->已 halt”。
    if (dbg_ebreak_i && !halt_req_q && !halted_q) begin
        halt_req_q <= 1'b1; halted_q <= 1'b0; drain_q <= 5'd0;
        dpc_q <= dbg_ebreak_pc_i; bp_q <= 1'b1; dcsr_cause_q <= 3'd1;  // cause=ebreak
    end

    // ---- 单步:resume 后核发射一条指令(dbg_issued)-> 立刻重新 halt ----
    // 同样保留 resumeack:单步是“resume 一条后自动 halt”,OpenOCD step 要先看到
    // allresumeack 确认 resume 发生,再看到 halted —— 故此处不清 resumeack。
    if (stepping_q && dbg_issued_i) begin
        stepping_q <= 1'b0;
        halt_req_q <= 1'b1; halted_q <= 1'b0; drain_q <= 5'd0; bp_q <= 1'b0; dcsr_cause_q <= 3'd4;  // cause=step
    end

    // ---- halt 排空:halt 请求后等 ~16 拍 -> halted;到 halted 那刻锁存 dpc ----
    if (halt_req_q && !halted_q) begin
        if (drain_q == 5'd16) begin
            halted_q <= 1'b1;
            if (!bp_q) dpc_q <= dbg_pc_i;   // 普通 halt/单步:锁存停下处 PC(断点已锁 ebreak PC)
        end else
            drain_q <= drain_q + 5'd1;
    end

    // ---- 抽象命令两拍处理:01=已发起(idx 稳定),10=取/写结果 ----
    if (abs_go_q == 2'b01) abs_go_q <= 2'b10;
    else if (abs_go_q == 2'b10) begin
        abs_go_q <= 2'b00;
        if (abs_write_q) begin
            // 写:GPR -> dbg_reg_we 脉冲;dcsr -> 存 step 标志
            if (abs_is_gpr) reg_we_q <= 1'b1;
            else if (abs_regno_q[11:0]==CSR_DCSR) begin
                dcsr_step_q    <= data0_q[2];   // step
                dcsr_ebreakm_q <= data0_q[15];  // ebreakm
            end
            else if (abs_regno_q[11:0]==CSR_DPC) begin dpc_q <= data0_q; dpc_written_q <= 1'b1; end
        end else begin
            // 读:GPR 用核读出;已建模 CSR 用内置值;其余 CSR 回 0(不报 cmderr,
            // 否则 OpenOCD 读 mstatus 等会失败而中止。我们无核内 CSR 读口,0 是
            // 诚实的最佳近似:halt 在 M 态、调试器据此判断也不会出错)。
            if (abs_is_gpr)                       data0_q <= dbg_reg_rdata_i;
            else if (abs_regno_q[11:0]==CSR_MISA) data0_q <= MISA_RV32IMA;
            else if (abs_regno_q[11:0]==CSR_DPC)  data0_q <= dpc_q;
            else if (abs_regno_q[11:0]==CSR_DCSR)
                // dcsr: [31:28]xdebugver=4 [15]ebreakm [8:6]cause [2]step [1:0]prv=3
                data0_q <= DCSR_VAL | (dcsr_ebreakm_q ? (1<<15) : 0)
                                    | ({29'b0,dcsr_cause_q} << 6)
                                    | (dcsr_step_q ? (1<<2) : 0);
            else                                  data0_q <= 32'b0;     // 其余 CSR:回 0,不报错
        end
    end

    // ---- 总线事务完成:收数据、清 busy、按需自增地址 ----
    if (bus_done_i) begin
        sbbusy_q <= 1'b0;
        if (!bus_we_q) sbdata_q <= bus_rdata_i;   // 读:存回 sbdata
        if (bus_err_i) sberror_q <= 3'd2;          // 记一个总线错误
        if (sbautoincrement_q) sbaddr_q <= sbaddr_q + incr;
    end

    // ---- 处理一次 DMI 访问 ----
    if (dmi_req_i) begin
        dmi_resp_q <= 2'b00;     // 默认 ok
        case (dmi_addr_i)
        //--------------------------------------------------
        A_DMCONTROL: begin
            if (dmi_op_i==2'd2) begin   // write
                dmactive_q <= dmi_wdata_i[0];
                ndmreset_q <= dmi_wdata_i[1];
                // ndmreset 置位:复位调试 ack/单步/重定向状态(系统软复位语义)
                if (dmi_wdata_i[1]) begin
                    resumeack_q <= 1'b0; stepping_q <= 1'b0; redirect_q <= 4'd0;
                    bp_q <= 1'b0; dpc_written_q <= 1'b0;
                end
                if (dmi_wdata_i[31]) begin           // haltreq:请求暂停
                    halt_req_q <= 1'b1; drain_q <= 5'd0; resumeack_q <= 1'b0; dcsr_cause_q <= 3'd3;  // cause=haltreq
                end
                if (dmi_wdata_i[30]) begin           // resumereq:恢复运行
                    if (bp_q || dpc_written_q) begin
                        // 需重定向:保持 halt(冻结),启动重定向序列;
                        // 序列在 halt 中把 pc_x_q+取指设到 dpc,再撤 halt 从 dpc 起跑。
                        // resumeack 由序列在撤 halt 那拍(redirect_q==1)置位。
                        redirect_q <= 4'd6; bp_q <= 1'b0; dpc_written_q <= 1'b0;
                    end else begin
                        halt_req_q <= 1'b0; halted_q <= 1'b0; resumeack_q <= 1'b1;
                        if (dcsr_step_q) stepping_q <= 1'b1;  // 单步:只放一条指令
                    end
                end
            end
            dmi_rdata_q <= {halt_req_q,30'b0, dmactive_q};
        end
        //--------------------------------------------------
        A_DMSTATUS: dmi_rdata_q <= dmstatus_rd;
        //--------------------------------------------------
        A_DPC: begin                        // 读/写 dpc 寄存器
            if (dmi_op_i==2'd2) begin dpc_q <= dmi_wdata_i; dpc_written_q <= 1'b1; end
            dmi_rdata_q <= dpc_q;
        end
        //--------------------------------------------------
        A_DATA0: begin
            if (dmi_op_i==2'd2) data0_q <= dmi_wdata_i;   // 写抽象数据
            dmi_rdata_q <= data0_q;
        end
        A_ABSTRACTCS: begin
            if (dmi_op_i==2'd2 && dmi_wdata_i[10:8]!=3'b0) abs_cmderr_q <= 3'b0; // W1C
            dmi_rdata_q <= abstractcs_rd;
        end
        A_COMMAND: begin
            if (dmi_op_i==2'd2) begin       // 写 command = 发起一次 access register
                // [31:24]cmdtype=0  [22:20]aarsize  [17]transfer  [16]write  [15:0]regno
                if (dmi_wdata_i[31:24]==8'd0) begin
                    // aarsize:2=32位(我们只支持 32);3=64/4=128 不支持 -> cmderr=2。
                    // (OpenOCD 探 XLEN 会先试 size=64,见 cmderr=2 即回退 32 -> XLEN=32。
                    //  自测发的 aarsize=0,按 32 位处理,不拒。)
                    if (dmi_wdata_i[22:20] > 3'd2)
                        abs_cmderr_q <= 3'd2;          // 不支持的访问位宽
                    else begin
                        abs_regno_q <= dmi_wdata_i[15:0];
                        abs_write_q <= dmi_wdata_i[16];
                        abs_go_q    <= 2'b01;
                        abs_cmderr_q<= 3'b0;
                    end
                end else
                    abs_cmderr_q <= 3'd2;    // 其它 cmdtype 不支持
            end
            dmi_rdata_q <= 32'b0;
        end
        //--------------------------------------------------
        A_SBCS: begin
            if (dmi_op_i==2'd2) begin   // write
                sbreadonaddr_q    <= dmi_wdata_i[20];
                sbaccess_q        <= dmi_wdata_i[19:17];
                sbautoincrement_q <= dmi_wdata_i[16];
                sbreadondata_q    <= dmi_wdata_i[15];
                if (dmi_wdata_i[14:12]!=3'b0) sberror_q     <= 3'd0;  // W1C
                if (dmi_wdata_i[22])          sbbusyerror_q <= 1'b0;  // W1C
            end
            dmi_rdata_q <= sbcs_rd;
        end
        //--------------------------------------------------
        A_SBADDR0: begin
            if (sbbusy_q) begin
                dmi_resp_q <= 2'd3;          // busy
                sbbusyerror_q <= 1'b1;
            end else if (dmi_op_i==2'd2) begin   // write addr
                sbaddr_q <= dmi_wdata_i;
                if (sbreadonaddr_q) begin        // 触发读
                    bus_req_q  <= 1'b1; bus_we_q <= 1'b0;
                    bus_addr_q <= dmi_wdata_i;
                    sbbusy_q   <= 1'b1;
                end
            end else begin
                dmi_rdata_q <= sbaddr_q;
            end
        end
        //--------------------------------------------------
        A_SBDATA0: begin
            if (sbbusy_q) begin
                dmi_resp_q <= 2'd3;          // busy:OpenOCD 重试
                sbbusyerror_q <= 1'b1;
            end else if (dmi_op_i==2'd2) begin   // write data -> 总线写
                bus_req_q   <= 1'b1; bus_we_q <= 1'b1;
                bus_addr_q  <= sbaddr_q;
                bus_wdata_q <= dmi_wdata_i;
                sbbusy_q    <= 1'b1;
            end else begin                       // read data
                dmi_rdata_q <= sbdata_q;
                if (sbreadondata_q) begin        // 再触发一次读
                    bus_req_q  <= 1'b1; bus_we_q <= 1'b0;
                    bus_addr_q <= sbaddr_q;
                    sbbusy_q   <= 1'b1;
                end
            end
        end
        //--------------------------------------------------
        default: dmi_rdata_q <= 32'b0;
        endcase
    end
end

endmodule
