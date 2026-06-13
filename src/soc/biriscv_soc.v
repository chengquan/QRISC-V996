//-----------------------------------------------------------------
// biriscv_soc.v —— 把 biRISC-V 双发射核接进 ultraembedded riscv_soc 的
//                  互联 + 全套真 RTL 外设(uart_lite/timer/gpio/spi/irq_ctrl)。
//
//   core(biriscv riscv_top, 2 路 AXI 主口) ──► soc(arb→tap)
//        ├─ 0x80000000.. (else)  → mem_* AXI4 主口 → 外部 DRAM(tb 提供)
//        ├─ 0x90000000 PERIPH0   → irq_ctrl
//        ├─ 0x91000000 PERIPH1   → timer
//        ├─ 0x92000000 PERIPH2   → uart_lite(真串行 tx_o/rx_i)  ← Linux 控制台
//        ├─ 0x93000000 PERIPH3   → spi_lite
//        └─ 0x94000000 PERIPH4   → gpio
//   soc.intr_o → core.intr_i(timer/uart/spi/gpio 经 irq_ctrl 汇聚)
//
// 外部只暴露:DRAM 的 AXI4 主口 + UART 串行线 + spi/gpio 引脚。
//-----------------------------------------------------------------
module biriscv_soc
(
     input           clk_i
    ,input           rst_i
    ,input  [ 31:0]  reset_vector_i

    // 外部 DRAM(AXI4 master)—— 由 tb 的 axi4_ram 承接
    ,input           mem_awready_i
    ,input           mem_wready_i
    ,input           mem_bvalid_i
    ,input  [  1:0]  mem_bresp_i
    ,input  [  3:0]  mem_bid_i
    ,input           mem_arready_i
    ,input           mem_rvalid_i
    ,input  [ 31:0]  mem_rdata_i
    ,input  [  1:0]  mem_rresp_i
    ,input  [  3:0]  mem_rid_i
    ,input           mem_rlast_i
    ,output          mem_awvalid_o
    ,output [ 31:0]  mem_awaddr_o
    ,output [  3:0]  mem_awid_o
    ,output [  7:0]  mem_awlen_o
    ,output [  1:0]  mem_awburst_o
    ,output          mem_wvalid_o
    ,output [ 31:0]  mem_wdata_o
    ,output [  3:0]  mem_wstrb_o
    ,output          mem_wlast_o
    ,output          mem_bready_o
    ,output          mem_arvalid_o
    ,output [ 31:0]  mem_araddr_o
    ,output [  3:0]  mem_arid_o
    ,output [  7:0]  mem_arlen_o
    ,output [  1:0]  mem_arburst_o
    ,output          mem_rready_o

    // 真实串行 UART
    ,input           uart_rx_i      // 进 SoC(soc.uart_txd_i)
    ,output          uart_tx_o      // 出 SoC(soc.uart_rxd_o)

    // 其它外设引脚
    ,input           spi_miso_i
    ,output          spi_clk_o
    ,output          spi_mosi_o
    ,output          spi_cs_o
    ,input  [ 31:0]  gpio_input_i
    ,output [ 31:0]  gpio_output_o
    ,output [ 31:0]  gpio_output_enable_o

    // OpenOCD 兼容的 JTAG 调试口(SBA:读写内存/外设,不暂停 CPU)
    ,input           jtag_tck_i
    ,input           jtag_tms_i
    ,input           jtag_tdi_i
    ,output          jtag_tdo_o

    ,output          intr_o         // 调试用:观察汇聚后的中断
);

//-----------------------------------------------------------------
// core <-> soc 之间的 CPU I/D AXI 交叉连线
//-----------------------------------------------------------------
// I 口(core 主 -> soc 从)
wire        ci_awvalid, ci_wvalid, ci_bready, ci_arvalid, ci_rready, ci_wlast;
wire [31:0] ci_awaddr,  ci_wdata,  ci_araddr;
wire [3:0]  ci_awid,    ci_wstrb,  ci_arid;
wire [7:0]  ci_awlen,   ci_arlen;
wire [1:0]  ci_awburst, ci_arburst;
wire        ci_awready, ci_wready, ci_bvalid, ci_arready, ci_rvalid, ci_rlast;
wire [31:0] ci_rdata;
wire [3:0]  ci_bid,     ci_rid;
wire [1:0]  ci_bresp,   ci_rresp;
// D 口
wire        cd_awvalid, cd_wvalid, cd_bready, cd_arvalid, cd_rready, cd_wlast;
wire [31:0] cd_awaddr,  cd_wdata,  cd_araddr;
wire [3:0]  cd_awid,    cd_wstrb,  cd_arid;
wire [7:0]  cd_awlen,   cd_arlen;
wire [1:0]  cd_awburst, cd_arburst;
wire        cd_awready, cd_wready, cd_bvalid, cd_arready, cd_rvalid, cd_rlast;
wire [31:0] cd_rdata;
wire [3:0]  cd_bid,     cd_rid;
wire [1:0]  cd_bresp,   cd_rresp;

wire        intr_w;
assign      intr_o = intr_w;

//-----------------------------------------------------------------
// biRISC-V 核(Linux Capable 参数)
//-----------------------------------------------------------------
riscv_top
#(
     .SUPPORT_SUPER(1)
    ,.SUPPORT_MMU(1)
    ,.EXTRA_DECODE_STAGE(1)
    // ★ 关键:soc 的 axi4_arb 按 rid[3:2] 把读响应路由回 inport。
    //   soc.v 接法:inport1=cpu_d,inport2=cpu_i。所以:
    //     icache(cpu_i) 的 AXI ID 必须 [3:2]=2'b10 → 8
    //     dcache(cpu_d) 的 AXI ID 必须 [3:2]=2'b01 → 4
    //   biriscv 默认两者都是 0 → 响应全被路由到 inport0(没接核)→ 取指 stall。
    ,.ICACHE_AXI_ID(4'd8)
    ,.DCACHE_AXI_ID(4'd4)
)
u_core
(
     .clk_i(clk_i)
    ,.rst_i(rst_i)
    ,.intr_i(intr_w)
    ,.reset_vector_i(reset_vector_i)

    // I 口:core 主 -> 线
    ,.axi_i_awvalid_o(ci_awvalid) ,.axi_i_awaddr_o(ci_awaddr) ,.axi_i_awid_o(ci_awid)
    ,.axi_i_awlen_o(ci_awlen) ,.axi_i_awburst_o(ci_awburst)
    ,.axi_i_wvalid_o(ci_wvalid) ,.axi_i_wdata_o(ci_wdata) ,.axi_i_wstrb_o(ci_wstrb) ,.axi_i_wlast_o(ci_wlast)
    ,.axi_i_bready_o(ci_bready)
    ,.axi_i_arvalid_o(ci_arvalid) ,.axi_i_araddr_o(ci_araddr) ,.axi_i_arid_o(ci_arid)
    ,.axi_i_arlen_o(ci_arlen) ,.axi_i_arburst_o(ci_arburst) ,.axi_i_rready_o(ci_rready)
    // I 口:线 -> core
    ,.axi_i_awready_i(ci_awready) ,.axi_i_wready_i(ci_wready)
    ,.axi_i_bvalid_i(ci_bvalid) ,.axi_i_bresp_i(ci_bresp) ,.axi_i_bid_i(ci_bid)
    ,.axi_i_arready_i(ci_arready)
    ,.axi_i_rvalid_i(ci_rvalid) ,.axi_i_rdata_i(ci_rdata) ,.axi_i_rresp_i(ci_rresp)
    ,.axi_i_rid_i(ci_rid) ,.axi_i_rlast_i(ci_rlast)

    // D 口:core 主 -> 线
    ,.axi_d_awvalid_o(cd_awvalid) ,.axi_d_awaddr_o(cd_awaddr) ,.axi_d_awid_o(cd_awid)
    ,.axi_d_awlen_o(cd_awlen) ,.axi_d_awburst_o(cd_awburst)
    ,.axi_d_wvalid_o(cd_wvalid) ,.axi_d_wdata_o(cd_wdata) ,.axi_d_wstrb_o(cd_wstrb) ,.axi_d_wlast_o(cd_wlast)
    ,.axi_d_bready_o(cd_bready)
    ,.axi_d_arvalid_o(cd_arvalid) ,.axi_d_araddr_o(cd_araddr) ,.axi_d_arid_o(cd_arid)
    ,.axi_d_arlen_o(cd_arlen) ,.axi_d_arburst_o(cd_arburst) ,.axi_d_rready_o(cd_rready)
    // D 口:线 -> core
    ,.axi_d_awready_i(cd_awready) ,.axi_d_wready_i(cd_wready)
    ,.axi_d_bvalid_i(cd_bvalid) ,.axi_d_bresp_i(cd_bresp) ,.axi_d_bid_i(cd_bid)
    ,.axi_d_arready_i(cd_arready)
    ,.axi_d_rvalid_i(cd_rvalid) ,.axi_d_rdata_i(cd_rdata) ,.axi_d_rresp_i(cd_rresp)
    ,.axi_d_rid_i(cd_rid) ,.axi_d_rlast_i(cd_rlast)
    ,.dbg_halt_i(dbg_halt) ,.dbg_pc_o(dbg_pc)
    ,.dbg_reg_idx_i(dbg_reg_idx) ,.dbg_reg_rdata_o(dbg_reg_rdata)
    ,.dbg_reg_we_i(dbg_reg_we) ,.dbg_reg_wdata_i(dbg_reg_wdata)
);
wire        dbg_halt;     // Debug Module -> core:请求暂停
wire [31:0] dbg_pc;       // core -> Debug Module:下一条待发射 PC(= dpc)
wire [4:0]  dbg_reg_idx;  // DM -> core:要读写的 GPR 号
wire [31:0] dbg_reg_rdata;// core -> DM:GPR 读出
wire        dbg_reg_we;   // DM -> core:写 GPR 使能
wire [31:0] dbg_reg_wdata;// DM -> core:GPR 写值

//-----------------------------------------------------------------
// riscv_soc 的 soc:arb + tap + 全外设
//-----------------------------------------------------------------
// JTAG 调试子系统(OpenOCD 兼容,SBA)—— 主口接到 soc 的 inport
//-----------------------------------------------------------------
wire        dbg_awvalid, dbg_wvalid, dbg_bready, dbg_arvalid, dbg_rready, dbg_wlast;
wire [31:0] dbg_awaddr,  dbg_wdata,  dbg_araddr;
wire [3:0]  dbg_awid,    dbg_wstrb,  dbg_arid;
wire [7:0]  dbg_awlen,   dbg_arlen;
wire [1:0]  dbg_awburst, dbg_arburst;
wire        dbg_awready, dbg_wready, dbg_bvalid, dbg_arready, dbg_rvalid, dbg_rlast;
wire [31:0] dbg_rdata;
wire [1:0]  dbg_bresp,   dbg_rresp;

riscv_debug u_debug
(
     .clk_i(clk_i), .rst_i(rst_i)
    ,.jtag_tck_i(jtag_tck_i), .jtag_tms_i(jtag_tms_i)
    ,.jtag_tdi_i(jtag_tdi_i), .jtag_tdo_o(jtag_tdo_o)
    ,.ndmreset_o()
    ,.dbg_halt_o(dbg_halt), .dbg_pc_i(dbg_pc)   // 暂停核 / 读核 PC
    ,.dbg_reg_idx_o(dbg_reg_idx), .dbg_reg_rdata_i(dbg_reg_rdata)
    ,.dbg_reg_we_o(dbg_reg_we), .dbg_reg_wdata_o(dbg_reg_wdata)
    ,.awvalid_o(dbg_awvalid), .awaddr_o(dbg_awaddr), .awid_o(dbg_awid)
    ,.awlen_o(dbg_awlen), .awburst_o(dbg_awburst), .awready_i(dbg_awready)
    ,.wvalid_o(dbg_wvalid), .wdata_o(dbg_wdata), .wstrb_o(dbg_wstrb)
    ,.wlast_o(dbg_wlast), .wready_i(dbg_wready)
    ,.bvalid_i(dbg_bvalid), .bresp_i(dbg_bresp), .bready_o(dbg_bready)
    ,.arvalid_o(dbg_arvalid), .araddr_o(dbg_araddr), .arid_o(dbg_arid)
    ,.arlen_o(dbg_arlen), .arburst_o(dbg_arburst), .arready_i(dbg_arready)
    ,.rvalid_i(dbg_rvalid), .rdata_i(dbg_rdata), .rresp_i(dbg_rresp)
    ,.rlast_i(dbg_rlast), .rready_o(dbg_rready)
);

//-----------------------------------------------------------------
soc u_soc
(
     .clk_i(clk_i)
    ,.rst_i(rst_i)

    // inport AXI 从口 —— 接 JTAG 调试子系统的 SBA 主口(OpenOCD 读写内存/外设)
    ,.inport_awvalid_i(dbg_awvalid) ,.inport_awaddr_i(dbg_awaddr) ,.inport_awid_i(dbg_awid)
    ,.inport_awlen_i(dbg_awlen) ,.inport_awburst_i(dbg_awburst)
    ,.inport_wvalid_i(dbg_wvalid) ,.inport_wdata_i(dbg_wdata) ,.inport_wstrb_i(dbg_wstrb) ,.inport_wlast_i(dbg_wlast)
    ,.inport_bready_i(dbg_bready)
    ,.inport_arvalid_i(dbg_arvalid) ,.inport_araddr_i(dbg_araddr) ,.inport_arid_i(dbg_arid)
    ,.inport_arlen_i(dbg_arlen) ,.inport_arburst_i(dbg_arburst) ,.inport_rready_i(dbg_rready)
    ,.inport_awready_o(dbg_awready) ,.inport_wready_o(dbg_wready) ,.inport_bvalid_o(dbg_bvalid) ,.inport_bresp_o(dbg_bresp)
    ,.inport_bid_o() ,.inport_arready_o(dbg_arready) ,.inport_rvalid_o(dbg_rvalid) ,.inport_rdata_o(dbg_rdata)
    ,.inport_rresp_o(dbg_rresp) ,.inport_rid_o() ,.inport_rlast_o(dbg_rlast)

    // 外部 DRAM 主口
    ,.mem_awready_i(mem_awready_i) ,.mem_wready_i(mem_wready_i)
    ,.mem_bvalid_i(mem_bvalid_i) ,.mem_bresp_i(mem_bresp_i) ,.mem_bid_i(mem_bid_i)
    ,.mem_arready_i(mem_arready_i) ,.mem_rvalid_i(mem_rvalid_i) ,.mem_rdata_i(mem_rdata_i)
    ,.mem_rresp_i(mem_rresp_i) ,.mem_rid_i(mem_rid_i) ,.mem_rlast_i(mem_rlast_i)
    ,.mem_awvalid_o(mem_awvalid_o) ,.mem_awaddr_o(mem_awaddr_o) ,.mem_awid_o(mem_awid_o)
    ,.mem_awlen_o(mem_awlen_o) ,.mem_awburst_o(mem_awburst_o)
    ,.mem_wvalid_o(mem_wvalid_o) ,.mem_wdata_o(mem_wdata_o) ,.mem_wstrb_o(mem_wstrb_o) ,.mem_wlast_o(mem_wlast_o)
    ,.mem_bready_o(mem_bready_o)
    ,.mem_arvalid_o(mem_arvalid_o) ,.mem_araddr_o(mem_araddr_o) ,.mem_arid_o(mem_arid_o)
    ,.mem_arlen_o(mem_arlen_o) ,.mem_arburst_o(mem_arburst_o) ,.mem_rready_o(mem_rready_o)

    // CPU I 口(从 core 主口接入)
    ,.cpu_i_awvalid_i(ci_awvalid) ,.cpu_i_awaddr_i(ci_awaddr) ,.cpu_i_awid_i(ci_awid)
    ,.cpu_i_awlen_i(ci_awlen) ,.cpu_i_awburst_i(ci_awburst)
    ,.cpu_i_wvalid_i(ci_wvalid) ,.cpu_i_wdata_i(ci_wdata) ,.cpu_i_wstrb_i(ci_wstrb) ,.cpu_i_wlast_i(ci_wlast)
    ,.cpu_i_bready_i(ci_bready)
    ,.cpu_i_arvalid_i(ci_arvalid) ,.cpu_i_araddr_i(ci_araddr) ,.cpu_i_arid_i(ci_arid)
    ,.cpu_i_arlen_i(ci_arlen) ,.cpu_i_arburst_i(ci_arburst) ,.cpu_i_rready_i(ci_rready)
    ,.cpu_i_awready_o(ci_awready) ,.cpu_i_wready_o(ci_wready)
    ,.cpu_i_bvalid_o(ci_bvalid) ,.cpu_i_bresp_o(ci_bresp) ,.cpu_i_bid_o(ci_bid)
    ,.cpu_i_arready_o(ci_arready)
    ,.cpu_i_rvalid_o(ci_rvalid) ,.cpu_i_rdata_o(ci_rdata) ,.cpu_i_rresp_o(ci_rresp)
    ,.cpu_i_rid_o(ci_rid) ,.cpu_i_rlast_o(ci_rlast)

    // CPU D 口
    ,.cpu_d_awvalid_i(cd_awvalid) ,.cpu_d_awaddr_i(cd_awaddr) ,.cpu_d_awid_i(cd_awid)
    ,.cpu_d_awlen_i(cd_awlen) ,.cpu_d_awburst_i(cd_awburst)
    ,.cpu_d_wvalid_i(cd_wvalid) ,.cpu_d_wdata_i(cd_wdata) ,.cpu_d_wstrb_i(cd_wstrb) ,.cpu_d_wlast_i(cd_wlast)
    ,.cpu_d_bready_i(cd_bready)
    ,.cpu_d_arvalid_i(cd_arvalid) ,.cpu_d_araddr_i(cd_araddr) ,.cpu_d_arid_i(cd_arid)
    ,.cpu_d_arlen_i(cd_arlen) ,.cpu_d_arburst_i(cd_arburst) ,.cpu_d_rready_i(cd_rready)
    ,.cpu_d_awready_o(cd_awready) ,.cpu_d_wready_o(cd_wready)
    ,.cpu_d_bvalid_o(cd_bvalid) ,.cpu_d_bresp_o(cd_bresp) ,.cpu_d_bid_o(cd_bid)
    ,.cpu_d_arready_o(cd_arready)
    ,.cpu_d_rvalid_o(cd_rvalid) ,.cpu_d_rdata_o(cd_rdata) ,.cpu_d_rresp_o(cd_rresp)
    ,.cpu_d_rid_o(cd_rid) ,.cpu_d_rlast_o(cd_rlast)

    // 外设引脚
    ,.spi_miso_i(spi_miso_i)
    ,.uart_txd_i(uart_rx_i)
    ,.gpio_input_i(gpio_input_i)
    ,.intr_o(intr_w)
    ,.spi_clk_o(spi_clk_o) ,.spi_mosi_o(spi_mosi_o) ,.spi_cs_o(spi_cs_o)
    ,.uart_rxd_o(uart_tx_o)
    ,.gpio_output_o(gpio_output_o) ,.gpio_output_enable_o(gpio_output_enable_o)
);

endmodule
