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
);

// DMI 寄存器地址
localparam A_DMCONTROL=7'h10, A_DMSTATUS=7'h11,
           A_DPC=7'h40,    // 非标准:读核 dpc(里程碑A;标准方式后续用抽象命令)
           A_SBCS=7'h38, A_SBADDR0=7'h39, A_SBDATA0=7'h3c;

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
assign dbg_halt_o = halt_req_q;
wire [31:0] dmstatus_rd =
    (1<<7) | 32'd2 |                                  // authenticated + version=2
    (halted_q  ? ((1<<9)|(1<<8)) : 32'b0) |          // all/any halted
    (halted_q  ? 32'b0 : ((1<<11)|(1<<10)));         // all/any running
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
    halt_req_q<=1'b0; halted_q<=1'b0; drain_q<=5'd0;
    sbreadonaddr_q<=1'b0; sbautoincrement_q<=1'b0; sbreadondata_q<=1'b0;
    sbaccess_q<=3'd2; sberror_q<=3'd0; sbbusy_q<=1'b0; sbbusyerror_q<=1'b0;
    sbaddr_q<=32'b0; sbdata_q<=32'b0;
    bus_req_q<=1'b0; bus_we_q<=1'b0; bus_addr_q<=32'b0; bus_wdata_q<=32'b0;
    dmi_rdata_q<=32'b0; dmi_resp_q<=2'b0;
end else begin
    bus_req_q <= 1'b0;          // 默认拉低,仅发起那拍为 1

    // ---- halt 排空:halt 请求后等 ~16 拍(流水线排空)-> 视为 halted ----
    if (halt_req_q && !halted_q) begin
        if (drain_q == 5'd16) halted_q <= 1'b1;
        else                  drain_q <= drain_q + 5'd1;
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
                if (dmi_wdata_i[31]) begin           // haltreq:请求暂停
                    halt_req_q <= 1'b1; drain_q <= 5'd0;
                end
                if (dmi_wdata_i[30]) begin           // resumereq:恢复运行
                    halt_req_q <= 1'b0; halted_q <= 1'b0;
                end
            end
            dmi_rdata_q <= {halt_req_q,30'b0, dmactive_q};
        end
        //--------------------------------------------------
        A_DMSTATUS: dmi_rdata_q <= dmstatus_rd;
        //--------------------------------------------------
        A_DPC: dmi_rdata_q <= dbg_pc_i;     // 读核当前 PC(里程碑A)
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
