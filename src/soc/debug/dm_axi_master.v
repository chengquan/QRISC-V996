//-----------------------------------------------------------------
// dm_axi_master.v —— 把 Debug Module 的 SBA 读/写请求变成 AXI4 单拍事务,
//                    接到 soc 空闲的 inport(从而经互联访问 DRAM 与所有外设)。
//
//   单拍(len=0, INCR);支持 8/16/32 位访问(byte/half/word):
//     写:按 size + 地址低位算 wstrb,数据移到对应字节车道;
//     读:取回整字,把被寻址车道右对齐返回(符合 sbdata0 低位放数据的约定)。
//-----------------------------------------------------------------
module dm_axi_master
(
     input            clk_i
    ,input            rst_i
    // 来自 dm_sba 的请求
    ,input            bus_req_i        // 1 拍脉冲
    ,input            bus_we_i         // 1=写 0=读
    ,input  [31:0]    bus_addr_i
    ,input  [31:0]    bus_wdata_i
    ,input  [2:0]     bus_size_i       // 0=byte 1=half 2=word
    ,output           bus_done_o       // 1 拍脉冲
    ,output [31:0]    bus_rdata_o
    ,output           bus_err_o
    // AXI4 主口 -> soc.inport
    ,output           awvalid_o
    ,output [31:0]    awaddr_o
    ,output [3:0]     awid_o
    ,output [7:0]     awlen_o
    ,output [1:0]     awburst_o
    ,input            awready_i
    ,output           wvalid_o
    ,output [31:0]    wdata_o
    ,output [3:0]     wstrb_o
    ,output           wlast_o
    ,input            wready_i
    ,input            bvalid_i
    ,input  [1:0]     bresp_i
    ,output           bready_o
    ,output           arvalid_o
    ,output [31:0]    araddr_o
    ,output [3:0]     arid_o
    ,output [7:0]     arlen_o
    ,output [1:0]     arburst_o
    ,input            arready_i
    ,input            rvalid_i
    ,input  [31:0]    rdata_i
    ,input  [1:0]     rresp_i
    ,input            rlast_i
    ,output           rready_o
);

localparam S_IDLE=3'd0, S_WRITE=3'd1, S_B=3'd3, S_AR=3'd4, S_R=3'd5, S_DONE=3'd6;
reg [2:0]  state_q;
reg [31:0] addr_q, wdata_q;
reg [2:0]  size_q;
reg [31:0] rdata_q;
reg        err_q;
reg        we_q;
reg        aw_done_q, w_done_q;   // 写:AW/W 并发,各自被接受后置位

wire [4:0] shamt = {addr_q[1:0], 3'b0};   // 字节车道位移(0/8/16/24)

// 写选通 + 数据车道(按 size/addr)
reg [3:0]  wstrb_c;
always @* begin
    case (size_q)
    3'd0: wstrb_c = 4'b0001 << addr_q[1:0];                 // byte
    3'd1: wstrb_c = addr_q[1] ? 4'b1100 : 4'b0011;          // half
    default: wstrb_c = 4'b1111;                             // word
    endcase
end
wire [31:0] wdata_lane = wdata_q << shamt;
// 读右对齐
wire [31:0] rdata_align = rdata_q >> shamt;
reg  [31:0] rdata_masked;
always @* begin
    case (size_q)
    3'd0: rdata_masked = {24'b0, rdata_align[7:0]};
    3'd1: rdata_masked = {16'b0, rdata_align[15:0]};
    default: rdata_masked = rdata_align;
    endcase
end

always @(posedge clk_i or posedge rst_i)
if (rst_i) begin
    state_q<=S_IDLE; addr_q<=32'b0; wdata_q<=32'b0; size_q<=3'd2;
    rdata_q<=32'b0; err_q<=1'b0; we_q<=1'b0; aw_done_q<=1'b0; w_done_q<=1'b0;
end else begin
    case (state_q)
    S_IDLE: if (bus_req_i) begin
        addr_q<=bus_addr_i; wdata_q<=bus_wdata_i; size_q<=bus_size_i; err_q<=1'b0;
        we_q<=bus_we_i; aw_done_q<=1'b0; w_done_q<=1'b0;
        state_q <= bus_we_i ? S_WRITE : S_AR;
    end
    // ---- 写:AW 与 W 并发拉起,各自被接受后置位,两者都完成 -> B ----
    S_WRITE: begin
        if (awready_i) aw_done_q<=1'b1;
        if (wready_i)  w_done_q <=1'b1;
        if ((aw_done_q||awready_i) && (w_done_q||wready_i)) state_q<=S_B;
    end
    S_B:  if (bvalid_i) begin err_q<=err_q|(bresp_i!=2'b00); state_q<=S_DONE; end
    // ---- 读 ----
    S_AR: if (arready_i) state_q<=S_R;
    S_R:  if (rvalid_i) begin rdata_q<=rdata_i; err_q<=err_q|(rresp_i!=2'b00); state_q<=S_DONE; end
    // ---- 完成 ----
    S_DONE: state_q<=S_IDLE;
    default: state_q<=S_IDLE;
    endcase
end

// AXI 输出(单拍);写时 AW/W 并发,被各自 ready 接受后撤销
assign awvalid_o = (state_q==S_WRITE) && !aw_done_q;
assign awaddr_o  = {addr_q[31:2],2'b0};
assign awid_o    = 4'd0;
assign awlen_o   = 8'd0;
assign awburst_o = 2'b01;
assign wvalid_o  = (state_q==S_WRITE) && !w_done_q;
assign wdata_o   = wdata_lane;
assign wstrb_o   = wstrb_c;
assign wlast_o   = 1'b1;
assign bready_o  = (state_q==S_B);
assign arvalid_o = (state_q==S_AR);
assign araddr_o  = {addr_q[31:2],2'b0};
assign arid_o    = 4'd0;
assign arlen_o   = 8'd0;
assign arburst_o = 2'b01;
assign rready_o  = (state_q==S_R);

assign bus_done_o  = (state_q==S_DONE);
assign bus_rdata_o = rdata_masked;
assign bus_err_o   = err_q;

endmodule
