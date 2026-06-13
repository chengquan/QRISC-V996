//-----------------------------------------------------------------
// riscv_debug.v —— OpenOCD 兼容的 JTAG 调试子系统(SBA-only)封装
//
//   jtag_dtm(JTAG TAP/DTM) ── DMI ── dm_sba(Debug Module) ── dm_axi_master ── AXI4
//
//   对外暴露:JTAG 4 线(tck/tms/tdi/tdo)+ 一个 AXI4 主口(接 soc 空闲 inport)。
//   能力:OpenOCD 经 JTAG 读写系统总线上的 DRAM 与所有外设寄存器(不暂停 CPU)。
//-----------------------------------------------------------------
module riscv_debug
#(
     parameter [31:0] IDCODE_VALUE = 32'hDEB10001
)
(
     input            clk_i
    ,input            rst_i
    // JTAG
    ,input            jtag_tck_i
    ,input            jtag_tms_i
    ,input            jtag_tdi_i
    ,output           jtag_tdo_o
    ,output           ndmreset_o
    // 核 halt + 寄存器读写接口
    ,output           dbg_halt_o
    ,input  [31:0]    dbg_pc_i
    ,output [4:0]     dbg_reg_idx_o
    ,input  [31:0]    dbg_reg_rdata_i
    ,output           dbg_reg_we_o
    ,output [31:0]    dbg_reg_wdata_o
    // AXI4 主口 -> soc.inport
    ,output           awvalid_o ,output [31:0] awaddr_o ,output [3:0] awid_o
    ,output [7:0]     awlen_o   ,output [1:0]  awburst_o ,input awready_i
    ,output           wvalid_o  ,output [31:0] wdata_o  ,output [3:0] wstrb_o
    ,output           wlast_o   ,input wready_i
    ,input            bvalid_i  ,input [1:0] bresp_i ,output bready_o
    ,output           arvalid_o ,output [31:0] araddr_o ,output [3:0] arid_o
    ,output [7:0]     arlen_o   ,output [1:0]  arburst_o ,input arready_i
    ,input            rvalid_i  ,input [31:0] rdata_i ,input [1:0] rresp_i
    ,input            rlast_i   ,output rready_o
);

localparam ABITS = 7;

// DTM <-> DM
wire             dmi_req;
wire [ABITS-1:0] dmi_addr;
wire [31:0]      dmi_wdata;
wire [1:0]       dmi_op;
wire [31:0]      dmi_rdata;
wire [1:0]       dmi_resp;

// DM <-> AXI master
wire        bus_req, bus_we;
wire [31:0] bus_addr, bus_wdata;
wire [2:0]  bus_size;
wire        bus_done, bus_err;
wire [31:0] bus_rdata;

jtag_dtm #(.IDCODE_VALUE(IDCODE_VALUE), .ABITS(ABITS)) u_dtm (
     .clk_i(clk_i), .rst_i(rst_i)
    ,.tck_i(jtag_tck_i), .tms_i(jtag_tms_i), .tdi_i(jtag_tdi_i), .tdo_o(jtag_tdo_o)
    ,.dmi_req_o(dmi_req), .dmi_addr_o(dmi_addr), .dmi_wdata_o(dmi_wdata)
    ,.dmi_op_o(dmi_op), .dmi_rdata_i(dmi_rdata), .dmi_resp_i(dmi_resp)
);

dm_sba #(.ABITS(ABITS)) u_dm (
     .clk_i(clk_i), .rst_i(rst_i)
    ,.dmi_req_i(dmi_req), .dmi_addr_i(dmi_addr), .dmi_wdata_i(dmi_wdata)
    ,.dmi_op_i(dmi_op), .dmi_rdata_o(dmi_rdata), .dmi_resp_o(dmi_resp)
    ,.bus_req_o(bus_req), .bus_we_o(bus_we), .bus_addr_o(bus_addr)
    ,.bus_wdata_o(bus_wdata), .bus_size_o(bus_size)
    ,.bus_done_i(bus_done), .bus_rdata_i(bus_rdata), .bus_err_i(bus_err)
    ,.ndmreset_o(ndmreset_o)
    ,.dbg_halt_o(dbg_halt_o), .dbg_pc_i(dbg_pc_i)
    ,.dbg_reg_idx_o(dbg_reg_idx_o), .dbg_reg_rdata_i(dbg_reg_rdata_i)
    ,.dbg_reg_we_o(dbg_reg_we_o), .dbg_reg_wdata_o(dbg_reg_wdata_o)
);

dm_axi_master u_axi (
     .clk_i(clk_i), .rst_i(rst_i)
    ,.bus_req_i(bus_req), .bus_we_i(bus_we), .bus_addr_i(bus_addr)
    ,.bus_wdata_i(bus_wdata), .bus_size_i(bus_size)
    ,.bus_done_o(bus_done), .bus_rdata_o(bus_rdata), .bus_err_o(bus_err)
    ,.awvalid_o(awvalid_o), .awaddr_o(awaddr_o), .awid_o(awid_o), .awlen_o(awlen_o)
    ,.awburst_o(awburst_o), .awready_i(awready_i)
    ,.wvalid_o(wvalid_o), .wdata_o(wdata_o), .wstrb_o(wstrb_o), .wlast_o(wlast_o)
    ,.wready_i(wready_i)
    ,.bvalid_i(bvalid_i), .bresp_i(bresp_i), .bready_o(bready_o)
    ,.arvalid_o(arvalid_o), .araddr_o(araddr_o), .arid_o(arid_o), .arlen_o(arlen_o)
    ,.arburst_o(arburst_o), .arready_i(arready_i)
    ,.rvalid_i(rvalid_i), .rdata_i(rdata_i), .rresp_i(rresp_i), .rlast_i(rlast_i)
    ,.rready_o(rready_o)
);

endmodule
