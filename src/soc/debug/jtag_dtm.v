//-----------------------------------------------------------------
// jtag_dtm.v —— RISC-V Debug Spec 0.13 的 JTAG Debug Transport Module
//
//   实现标准 JTAG TAP(16 状态)+ 三个扫描寄存器:
//     IDCODE (IR=0x01, 32b)  DTMCS (IR=0x10, 32b)  DMI (IR=0x11, abits+34b)
//   其余 IR -> BYPASS(1b)。OpenOCD 的 remote_bitbang 驱动可原生识别。
//
//   单时钟域设计:整个 DTM 跑在 clk_i,对 tck/tms/tdi 做 2-FF 同步 + 边沿检测
//   (clk_i 远快于 OpenOCD 的 TCK,过采样安全),从而免去 TCK/clk 跨时钟域。
//
//   DMI 接口(同 clk 域)对接 Debug Module(dm_sba):
//     Update-DR 且 IR=DMI、op!=0 时,把 {addr,data,op} 发给 DM(dmi_req_o 脉冲);
//     DM 立即处理寄存器读写(1 拍),把读数据/状态经 dmi_rdata_i/dmi_resp_i 返回,
//     下次 Capture-DR 时回填给主机。SBA 总线事务在后台跑,忙时 DM 让 dmi_resp=BUSY。
//-----------------------------------------------------------------
module jtag_dtm
#(
     parameter [31:0] IDCODE_VALUE = 32'hDEB10001   // bit0 必须为 1
    ,parameter        ABITS        = 7              // DMI 地址位宽
)
(
     input            clk_i
    ,input            rst_i
    // JTAG 引脚(由 tb 的 remote_bitbang 桥驱动)
    ,input            tck_i
    ,input            tms_i
    ,input            tdi_i
    ,output           tdo_o
    // DMI <-> Debug Module(clk_i 域)
    ,output           dmi_req_o            // 1 拍脉冲:发起一次 DMI 访问
    ,output [ABITS-1:0] dmi_addr_o
    ,output [31:0]    dmi_wdata_o
    ,output [1:0]     dmi_op_o             // 1=read 2=write
    ,input  [31:0]    dmi_rdata_i
    ,input  [1:0]     dmi_resp_i           // 0=ok 2=fail 3=busy
);

//--------------------------------------------------------------
// TCK/TMS/TDI 同步 + 边沿检测(过采样)
//--------------------------------------------------------------
reg [2:0] tck_sync_q;
reg [1:0] tms_sync_q;
reg [1:0] tdi_sync_q;
always @(posedge clk_i or posedge rst_i)
if (rst_i) begin
    tck_sync_q <= 3'b0; tms_sync_q <= 2'b0; tdi_sync_q <= 2'b0;
end else begin
    tck_sync_q <= {tck_sync_q[1:0], tck_i};
    tms_sync_q <= {tms_sync_q[0],   tms_i};
    tdi_sync_q <= {tdi_sync_q[0],   tdi_i};
end
wire tck_rise = (tck_sync_q[2:1] == 2'b01);   // TCK 上升沿:采样/移位/换状态
wire tck_fall = (tck_sync_q[2:1] == 2'b10);   // TCK 下降沿:更新 TDO
wire tms      = tms_sync_q[1];
wire tdi      = tdi_sync_q[1];

//--------------------------------------------------------------
// TAP 状态机(IEEE 1149.1 标准 16 态)
//--------------------------------------------------------------
localparam TLR=4'h0, RTI=4'h1, SEL_DR=4'h2, CAP_DR=4'h3, SHIFT_DR=4'h4,
           EXIT1_DR=4'h5, PAUSE_DR=4'h6, EXIT2_DR=4'h7, UPDATE_DR=4'h8,
           SEL_IR=4'h9, CAP_IR=4'hA, SHIFT_IR=4'hB, EXIT1_IR=4'hC,
           PAUSE_IR=4'hD, EXIT2_IR=4'hE, UPDATE_IR=4'hF;

reg [3:0] state_q;
reg [3:0] next_state;
always @* begin
    case (state_q)
    TLR:      next_state = tms ? TLR      : RTI;
    RTI:      next_state = tms ? SEL_DR   : RTI;
    SEL_DR:   next_state = tms ? SEL_IR   : CAP_DR;
    CAP_DR:   next_state = tms ? EXIT1_DR : SHIFT_DR;
    SHIFT_DR: next_state = tms ? EXIT1_DR : SHIFT_DR;
    EXIT1_DR: next_state = tms ? UPDATE_DR: PAUSE_DR;
    PAUSE_DR: next_state = tms ? EXIT2_DR : PAUSE_DR;
    EXIT2_DR: next_state = tms ? UPDATE_DR: SHIFT_DR;
    UPDATE_DR:next_state = tms ? SEL_DR   : RTI;
    SEL_IR:   next_state = tms ? TLR      : CAP_IR;
    CAP_IR:   next_state = tms ? EXIT1_IR : SHIFT_IR;
    SHIFT_IR: next_state = tms ? EXIT1_IR : SHIFT_IR;
    EXIT1_IR: next_state = tms ? UPDATE_IR: PAUSE_IR;
    PAUSE_IR: next_state = tms ? EXIT2_IR : PAUSE_IR;
    EXIT2_IR: next_state = tms ? UPDATE_IR: SHIFT_IR;
    UPDATE_IR:next_state = tms ? SEL_DR   : RTI;
    default:  next_state = TLR;
    endcase
end
always @(posedge clk_i or posedge rst_i)
if (rst_i)         state_q <= TLR;
else if (tck_rise) state_q <= next_state;

//--------------------------------------------------------------
// IR(5 位)
//--------------------------------------------------------------
localparam IR_IDCODE=5'h01, IR_DTMCS=5'h10, IR_DMI=5'h11, IR_BYPASS=5'h1f;
reg [4:0] ir_shift_q;
reg [4:0] ir_q;
always @(posedge clk_i or posedge rst_i)
if (rst_i) begin
    ir_shift_q <= 5'b0; ir_q <= IR_IDCODE;   // 复位后默认 IDCODE
end else if (tck_rise) begin
    if (state_q == CAP_IR)        ir_shift_q <= 5'b00001;            // 规范:capture 低位为 01
    else if (state_q == SHIFT_IR) ir_shift_q <= {tdi, ir_shift_q[4:1]};
    else if (state_q == UPDATE_IR)ir_q       <= ir_shift_q;
    if (state_q == TLR)           ir_q       <= IR_IDCODE;
end

//--------------------------------------------------------------
// DTMCS(只读+两个 W1 reset 位)
//   [3:0]=version(1=0.13) [9:4]=abits [11:10]=dmistat
//   [14:12]=idle [16]=dmireset(W1) [17]=dmihardreset(W1)
//--------------------------------------------------------------
wire [31:0] dtmcs_rd = {15'b0, 1'b0 /*dmihardreset rd0*/, 1'b0 /*dmireset rd0*/,
                        3'd1 /*idle: 1 个 RTI 周期*/, 2'b00 /*dmistat ok*/,
                        ABITS[5:0], 4'd1 /*version 0.13*/};

//--------------------------------------------------------------
// DR 移位寄存器:宽度随 IR 变化
//   IDCODE=32 / DTMCS=32 / DMI=ABITS+34 / BYPASS=1
//--------------------------------------------------------------
localparam DMI_W = ABITS + 34;   // {addr[ABITS], data[32], op[2]}
reg [DMI_W-1:0] dr_shift_q;

// 捕获值(Capture-DR 时载入)
wire [DMI_W-1:0] dmi_cap   = {dmi_addr_hold_q, dmi_rdata_i, dmi_resp_i};
reg  [ABITS-1:0] dmi_addr_hold_q;   // 上次访问的地址,回读时回显

reg [DMI_W-1:0] capture_val;
always @* begin
    case (ir_q)
    IR_IDCODE: capture_val = {{(DMI_W-32){1'b0}}, IDCODE_VALUE};
    IR_DTMCS:  capture_val = {{(DMI_W-32){1'b0}}, dtmcs_rd};
    IR_DMI:    capture_val = dmi_cap;
    default:   capture_val = {DMI_W{1'b0}};   // BYPASS: 0
    endcase
end

// 当前 IR 下 DR 的有效位宽(决定移位时回灌位置 & UPDATE 时怎么解读)
function [5:0] dr_len; input [4:0] ir;
    case (ir)
    IR_IDCODE: dr_len = 6'd32;
    IR_DTMCS:  dr_len = 6'd32;
    IR_DMI:    dr_len = DMI_W[5:0];
    default:   dr_len = 6'd1;     // BYPASS
    endcase
endfunction
wire [5:0] curlen = dr_len(ir_q);

always @(posedge clk_i or posedge rst_i)
if (rst_i)
    dr_shift_q <= {DMI_W{1'b0}};
else if (tck_rise) begin
    if (state_q == CAP_DR)
        dr_shift_q <= capture_val;
    else if (state_q == SHIFT_DR)
        // 从 MSB 注入 tdi 到第 (curlen-1) 位,整体右移;TDO = 最低位
        dr_shift_q <= (dr_shift_q >> 1) | ({{(DMI_W-1){1'b0}}, tdi} << (curlen-1));
end

// TDO:Shift 态输出 DR 最低位;在 TCK 下降沿更新(JTAG 主机此时采样)
reg tdo_q;
always @(posedge clk_i or posedge rst_i)
if (rst_i) tdo_q <= 1'b0;
else if (tck_fall) begin
    if (state_q == SHIFT_DR)      tdo_q <= dr_shift_q[0];
    else if (state_q == SHIFT_IR) tdo_q <= ir_shift_q[0];
end
assign tdo_o = tdo_q;

//--------------------------------------------------------------
// DMI 访问:Update-DR 且 IR=DMI 时,取 {addr,data,op} 发给 DM
//--------------------------------------------------------------
reg              dmi_req_q;
reg [ABITS-1:0]  dmi_addr_q;
reg [31:0]       dmi_wdata_q;
reg [1:0]        dmi_op_q;
always @(posedge clk_i or posedge rst_i)
if (rst_i) begin
    dmi_req_q <= 1'b0; dmi_addr_q <= {ABITS{1'b0}}; dmi_wdata_q <= 32'b0; dmi_op_q <= 2'b0;
    dmi_addr_hold_q <= {ABITS{1'b0}};
end else begin
    dmi_req_q <= 1'b0;   // 默认拉低,只在 update 那一拍为 1
    if (tck_rise && state_q == UPDATE_DR && ir_q == IR_DMI) begin
        dmi_op_q        <= dr_shift_q[1:0];
        dmi_wdata_q     <= dr_shift_q[33:2];
        dmi_addr_q      <= dr_shift_q[DMI_W-1:34];
        dmi_addr_hold_q <= dr_shift_q[DMI_W-1:34];
        if (dr_shift_q[1:0] != 2'b00)   // op != nop
            dmi_req_q <= 1'b1;
    end
end
assign dmi_req_o   = dmi_req_q;
assign dmi_addr_o  = dmi_addr_q;
assign dmi_wdata_o = dmi_wdata_q;
assign dmi_op_o    = dmi_op_q;

endmodule
