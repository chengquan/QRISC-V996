//-----------------------------------------------------------------
// tb_soc.v —— biRISC-V + riscv_soc(全 RTL 外设)的测试平台。
//
//  DUT = biriscv_soc(核 + arb/tap + uart_lite/timer/gpio/spi/irq_ctrl)。
//  外部只接:axi4_ram(DRAM)+ 一个 UART 串行接收器(把真实串行线 uart_tx
//  按 8N1/BIT_DIV=24 反序列化成字节打印)。UART 不再是 C++/行为模型,而是
//  真 RTL,在 uart_tx 线上一位一位移出来,这里像示波器一样解出来。
//
//  plusargs:+IMAGE= +MAX_CYCLES= +TRACE +VCD= +PROGRESS=
//-----------------------------------------------------------------
`timescale 1ns/1ps

module tb_soc;

localparam BIT_DIV = 24;     // 必须与 uart_lite.v 的 BIT_DIV 一致

//----------------- 时钟 / 复位 -----------------
reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;        // 100 MHz
initial begin
    rst = 1'b1;
    repeat (20) @(posedge clk);
    rst = 1'b0;
end
reg [31:0] reset_vector = 32'h80000000;

//----------------- DUT <-> DRAM 的 AXI4 线 -----------------
wire        m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready, m_wlast;
wire [31:0] m_awaddr,  m_wdata,  m_araddr;
wire [3:0]  m_awid,    m_wstrb,  m_arid;
wire [7:0]  m_awlen,   m_arlen;
wire [1:0]  m_awburst, m_arburst;
wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid, m_rlast;
wire [31:0] m_rdata;
wire [3:0]  m_bid,     m_rid;
wire [1:0]  m_bresp,   m_rresp;

//----------------- 串行 UART 线 + 其它外设 -----------------
wire uart_tx;                 // SoC 发出(真实串行)
wire spi_clk, spi_mosi, spi_cs;
wire [31:0] gpio_out, gpio_oe;
wire intr;

//----------------- JTAG(remote_bitbang 桥驱动)-----------------
reg  jtag_tck = 1'b0, jtag_tms = 1'b1, jtag_tdi = 1'b0;
wire jtag_tdo;
//----------------- 测试 DMI 注入(快速自测,绕过慢 JTAG)-----------------
reg         tdmi_en = 1'b0, tdmi_req = 1'b0;
reg  [6:0]  tdmi_addr = 7'b0;
reg  [31:0] tdmi_wdata = 32'b0;
reg  [1:0]  tdmi_op = 2'b0;
wire [31:0] tdmi_rdata;
wire [1:0]  tdmi_resp;

//----------------- DUT -----------------
biriscv_soc u_dut
(
     .clk_i(clk)
    ,.rst_i(rst)
    ,.reset_vector_i(reset_vector)
    ,.jtag_tck_i(jtag_tck) ,.jtag_tms_i(jtag_tms) ,.jtag_tdi_i(jtag_tdi) ,.jtag_tdo_o(jtag_tdo)
    ,.tdmi_en_i(tdmi_en) ,.tdmi_req_i(tdmi_req) ,.tdmi_addr_i(tdmi_addr)
    ,.tdmi_wdata_i(tdmi_wdata) ,.tdmi_op_i(tdmi_op)
    ,.tdmi_rdata_o(tdmi_rdata) ,.tdmi_resp_o(tdmi_resp)

    ,.mem_awready_i(m_awready) ,.mem_wready_i(m_wready)
    ,.mem_bvalid_i(m_bvalid) ,.mem_bresp_i(m_bresp) ,.mem_bid_i(m_bid)
    ,.mem_arready_i(m_arready) ,.mem_rvalid_i(m_rvalid) ,.mem_rdata_i(m_rdata)
    ,.mem_rresp_i(m_rresp) ,.mem_rid_i(m_rid) ,.mem_rlast_i(m_rlast)
    ,.mem_awvalid_o(m_awvalid) ,.mem_awaddr_o(m_awaddr) ,.mem_awid_o(m_awid)
    ,.mem_awlen_o(m_awlen) ,.mem_awburst_o(m_awburst)
    ,.mem_wvalid_o(m_wvalid) ,.mem_wdata_o(m_wdata) ,.mem_wstrb_o(m_wstrb) ,.mem_wlast_o(m_wlast)
    ,.mem_bready_o(m_bready)
    ,.mem_arvalid_o(m_arvalid) ,.mem_araddr_o(m_araddr) ,.mem_arid_o(m_arid)
    ,.mem_arlen_o(m_arlen) ,.mem_arburst_o(m_arburst) ,.mem_rready_o(m_rready)

    ,.uart_rx_i(uart_rx_line)      // 由 tb 串行发送器驱动(见下)
    ,.uart_tx_o(uart_tx)
    ,.spi_miso_i(1'b1)
    ,.spi_clk_o(spi_clk) ,.spi_mosi_o(spi_mosi) ,.spi_cs_o(spi_cs)
    ,.gpio_input_i(32'b0)
    ,.gpio_output_o(gpio_out) ,.gpio_output_enable_o(gpio_oe)
    ,.intr_o(intr)
);

//----------------- DRAM -----------------
axi4_ram u_dram
(
     .clk_i(clk) ,.rst_i(rst)
    ,.awvalid_i(m_awvalid) ,.awaddr_i(m_awaddr) ,.awid_i(m_awid)
    ,.awlen_i(m_awlen) ,.awburst_i(m_awburst)
    ,.wvalid_i(m_wvalid) ,.wdata_i(m_wdata) ,.wstrb_i(m_wstrb) ,.wlast_i(m_wlast)
    ,.bready_i(m_bready)
    ,.arvalid_i(m_arvalid) ,.araddr_i(m_araddr) ,.arid_i(m_arid)
    ,.arlen_i(m_arlen) ,.arburst_i(m_arburst) ,.rready_i(m_rready)
    ,.awready_o(m_awready) ,.wready_o(m_wready)
    ,.bvalid_o(m_bvalid) ,.bresp_o(m_bresp) ,.bid_o(m_bid)
    ,.arready_o(m_arready) ,.rvalid_o(m_rvalid) ,.rdata_o(m_rdata)
    ,.rresp_o(m_rresp) ,.rid_o(m_rid) ,.rlast_o(m_rlast)
);

//----------------- UART 串行接收器(8N1, BIT_DIV)-----------------
// 像示波器一样把 uart_tx 线一位一位采出来,组回字节并打印。
localparam U_IDLE = 2'd0, U_RECV = 2'd1, U_DONE = 2'd2;
reg [1:0]  u_state = U_IDLE;
reg [31:0] u_cnt;
reg [3:0]  u_bit;
reg [7:0]  u_data;
reg        u_tx_d1 = 1'b1;

always @(posedge clk) begin
    if (rst) begin u_state <= U_IDLE; u_tx_d1 <= 1'b1; end
    else begin
        u_tx_d1 <= uart_tx;
        case (u_state)
            U_IDLE: if (u_tx_d1 == 1'b1 && uart_tx == 1'b0) begin   // 起始位下降沿
                u_state <= U_RECV;
                u_cnt   <= BIT_DIV + (BIT_DIV/2) - 1;               // 对到 bit0 中心
                u_bit   <= 4'd0;
            end
            U_RECV: if (u_cnt == 0) begin
                if (u_bit < 4'd8) begin
                    u_data <= {uart_tx, u_data[7:1]};               // 采数据位 0..7,LSB 先
                    u_bit  <= u_bit + 4'd1;
                    u_cnt  <= BIT_DIV - 1;                          // 下一位(bit8=停止位)
                end else begin                                     // 停止位中心:打印并立刻就绪
                    $write("%c", u_data); $fflush;
                    u_state <= U_IDLE;                             // 距下一起始位约 0.5 bit,IDLE 来得及抓
                end
            end else u_cnt <= u_cnt - 1;
        endcase
    end
end

//----------------- UART 串行发送器(交互输入)-----------------
// 把 +INPUT 文件里的字符按 8N1/BIT_DIV 一位位移进 uart_rx 线 → 真 uart_lite 接收。
// 字符源用「缓冲空就重开文件+fseek 到上次位置」:不阻塞,且能读到运行中追加的内容,
// 所以可在另一个终端  echo 'ls' >> input.txt  实时把命令送进运行中的 Linux。
reg          sending = 1'b0;
reg [3:0]    tx_idx;                     // 0=起始, 1..8=数据(LSB先), 9=停止
reg [31:0]   tx_cnt;
reg [7:0]    tx_byte;
reg          tx_pending = 1'b0;
reg          in_en = 1'b0;
integer      in_pos = 0;
integer      input_delay = 0;            // +INPUT_DELAY:此周期前不送(给 boot 留时间)
reg [1023:0] input_path;
integer      rfd, rc, rdummy;
reg          awaiting_recv = 1'b0;       // 已发一帧,等 uart 收下并被内核读走

// 流控信号:真 uart_lite 的 RX-pending(收满字节=1,内核读 RX 寄存器后=0)
wire uart_rx_ready = u_dut.u_soc.u_uart.rx_ready_q;

// 串行线电平(组合)
wire uart_rx_line = (!sending)      ? 1'b1 :
                    (tx_idx == 4'd0) ? 1'b0 :          // 起始位
                    (tx_idx == 4'd9) ? 1'b1 :          // 停止位
                    tx_byte[tx_idx - 1];               // 数据位 LSB 先

always @(posedge clk) begin
    if (rst) begin
        sending <= 1'b0; tx_pending <= 1'b0; tx_cnt <= 0; tx_idx <= 0; in_pos <= 0;
        awaiting_recv <= 1'b0;
    end else begin
        // 上一帧被 uart 收下(rx_ready 0->1)→ 解除等待,接着等内核把它读走(->0)
        if (awaiting_recv && uart_rx_ready) awaiting_recv <= 1'b0;

        // 取下一个字节。★流控:必须 uart RX 缓冲已空(!uart_rx_ready)且不在等上一帧收妥,
        // 才发下一个 —— 这样无论内核 hvc0 多久轮询一次(空闲时可达数秒)都不会覆盖丢字。
        if (!sending && !tx_pending && !awaiting_recv && !uart_rx_ready
            && in_en && cyc >= input_delay && cyc[7:0] == 8'h00) begin
            rfd = $fopen(input_path, "r");
            if (rfd != 0) begin
                rdummy = $fseek(rfd, in_pos, 0);
                rc     = $fgetc(rfd);
                if (rc >= 0) begin tx_byte <= rc[7:0]; tx_pending <= 1'b1; in_pos <= in_pos + 1; end
                $fclose(rfd);
            end
        end
        // 启动一帧 / 逐位推进
        if (!sending && tx_pending) begin
            sending <= 1'b1; tx_idx <= 4'd0; tx_cnt <= BIT_DIV - 1; tx_pending <= 1'b0;
        end else if (sending) begin
            if (tx_cnt == 0) begin
                if (tx_idx == 4'd9) begin sending <= 1'b0; awaiting_recv <= 1'b1; end // 帧毕→等收妥
                else begin tx_idx <= tx_idx + 4'd1; tx_cnt <= BIT_DIV - 1; end
            end else tx_cnt <= tx_cnt - 1;
        end
    end
end

//----------------- 诊断探针(+PROBE 开启;调 AXI 互联用)-----------------
reg        probe_en = 1'b0;
reg        seen_ar = 1'b0, seen_aw = 1'b0;
reg [31:0] ar_cnt = 0, aw_cnt = 0;
reg [31:0] ci_ar_cnt = 0, cd_ar_cnt = 0;
reg [31:0] mem_r_cnt = 0, mem_rlast_cnt = 0, ci_r_cnt = 0;
reg [31:0] intr_hi_cnt=0, intr_edge_cnt=0, uart_tx_chars=0, uart_intr_cnt=0, uart_txwr_cnt=0;
    reg intr_d1=0, seen_intr=0, uart_txbusy_d1=0, uart_intr_d1=0, uart_txwr_d1=0;
    integer evlog_start=0;
always @(posedge clk) if (!rst && probe_en) begin
    if (u_dut.ci_arvalid && u_dut.ci_arready) ci_ar_cnt <= ci_ar_cnt + 1; // 核取指请求
    if (u_dut.cd_arvalid && u_dut.cd_arready) cd_ar_cnt <= cd_ar_cnt + 1; // 核访存读请求
    if (m_arvalid && m_arready) begin
        ar_cnt <= ar_cnt + 1;
        if (!seen_ar) begin $display("[probe] 首个 mem 读 @0x%08x len=%0d", m_araddr, m_arlen); seen_ar <= 1'b1; end
    end
    if (m_awvalid && m_awready) begin
        aw_cnt <= aw_cnt + 1;
        if (!seen_aw) begin $display("[probe] 首个 mem 写 @0x%08x", m_awaddr); seen_aw <= 1'b1; end
    end
    if (m_rvalid && m_rready) mem_r_cnt <= mem_r_cnt + 1;
    if (m_rvalid && m_rready && m_rlast) mem_rlast_cnt <= mem_rlast_cnt + 1;
    if (u_dut.ci_rvalid && u_dut.ci_rready) ci_r_cnt <= ci_r_cnt + 1;     // icache 收到的 R 拍
    if (intr) intr_hi_cnt <= intr_hi_cnt + 1;                            // intc->核 中断高电平周期数
    if (intr && !intr_d1) intr_edge_cnt <= intr_edge_cnt + 1;
    intr_d1 <= intr;
    // uart 内部:每发一个字符(tx_busy 上升沿)+ uart 自身中断次数
    if (u_dut.u_soc.u_uart.tx_busy_q && !uart_txbusy_d1) uart_tx_chars <= uart_tx_chars + 1;
    uart_txbusy_d1 <= u_dut.u_soc.u_uart.tx_busy_q;
    if (u_dut.u_soc.u_uart.intr_q && !uart_intr_d1) uart_intr_cnt <= uart_intr_cnt + 1;
    uart_intr_d1 <= u_dut.u_soc.u_uart.intr_q;
    // 驱动写 TX 寄存器的次数(=推了多少字符;若 > uart_tx_chars 则 uart 丢字)
    if (u_dut.u_soc.u_uart.ulite_tx_wr_q && !uart_txwr_d1) uart_txwr_cnt <= uart_txwr_cnt + 1;
    uart_txwr_d1 <= u_dut.u_soc.u_uart.ulite_tx_wr_q;

    // 事件日志:挂死点附近逐事件记录(+EVLOG=起始周期开启),看中断链怎么断的
    if (evlog_start != 0 && cyc >= evlog_start) begin
        if (u_dut.u_soc.u_uart.ulite_tx_wr_q && !uart_txwr_d1)
            $fwrite(32'h80000002, "[ev %0d] TXW '%c'\n", cyc, u_dut.u_soc.u_uart.ulite_tx_data_out_w);
        if (|u_dut.u_soc.u_intc.irq_iar_ack_q)
            $fwrite(32'h80000002, "[ev %0d] IAR=%b\n", cyc, u_dut.u_soc.u_intc.irq_iar_ack_q);
        if (intr && !intr_d1) $fwrite(32'h80000002, "[ev %0d] INTR^ (uart_intr_o=%b)\n", cyc, u_dut.u_soc.u_uart.intr_q);
        if (!intr && intr_d1) $fwrite(32'h80000002, "[ev %0d] INTRv\n", cyc);
    end
    if (cyc[15:0] == 16'h0 && cyc != 0)
        $fwrite(32'h80000002, "[probe] cyc=%0dK intr_edges=%0d intr_hi=%0d  intc_pend=%b intc_en=%b rxrdy=%b uart_intr_o=%b\n",
                cyc>>10, intr_edge_cnt, intr_hi_cnt,
                u_dut.u_soc.u_intc.irq_pending_q, u_dut.u_soc.u_intc.irq_enable_q,
                u_dut.u_soc.u_uart.rx_ready_q, u_dut.u_soc.u_uart.intr_q);
end

//----------------- JTAG remote_bitbang DPI 桥 -----------------
import "DPI-C" context function int jtag_rbb_init(input int port);
import "DPI-C" context function int jtag_rbb_tick(input byte tdo,
            output byte tck, output byte tms, output byte tdi);
integer jtag_port; reg jtag_en = 1'b0; reg jtag_want = 1'b0; reg jtag_inited = 1'b0;
byte    rbb_tck, rbb_tms, rbb_tdi;
initial begin
    // 只在 initial 里解析 plusarg(不在 initial 里调 DPI —— --timing 下会出问题)
    if (!$test$plusargs("JTAGTEST") && $value$plusargs("JTAG=%d", jtag_port))
        jtag_want = 1'b1;
end
// DPI 调用放到 always(时钟)域:首拍初始化 socket,之后每拍 tick
integer jtag_rc;
// DPI 调用放到时钟域(避免 --timing 下在 initial 块里调 DPI):
//   首拍初始化 remote_bitbang socket,之后每拍 tick 一次。
always @(posedge clk) if (jtag_want) begin
    if (!jtag_inited) begin
        jtag_inited <= 1'b1;
        jtag_rc = jtag_rbb_init(jtag_port);
        if (jtag_rc == 0) jtag_en <= 1'b1;
        $display("[tb_soc] JTAG 调试:OpenOCD 用 remote_bitbang 连 localhost:%0d", jtag_port);
    end else if (jtag_en) begin
        if (jtag_rbb_tick(jtag_tdo ? 8'd1 : 8'd0, rbb_tck, rbb_tms, rbb_tdi) == 0)
            $finish;
        jtag_tck <= rbb_tck[0]; jtag_tms <= rbb_tms[0]; jtag_tdi <= rbb_tdi[0];
    end
end

//----------------- 跑控制 / 波形 / 心跳 -----------------
integer    max_cycles, progress;
reg [1023:0] vcd_path;
reg [63:0] cyc;

initial begin
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 0;
    if (!$value$plusargs("PROGRESS=%d",   progress))   progress   = 0;
    probe_en = $test$plusargs("PROBE");
    if (!$value$plusargs("EVLOG=%d", evlog_start)) evlog_start=0;

    if ($value$plusargs("INPUT=%s", input_path)) begin
        in_en  = 1'b1;
        in_pos = 0;
        $display("[tb_soc] 串口输入 <- %0s (可在另一个终端 echo cmd >> 此文件)", input_path);
    end
    if (!$value$plusargs("INPUT_DELAY=%d", input_delay)) input_delay = 0;
    if ($test$plusargs("TRACE")) begin
        if (!$value$plusargs("VCD=%s", vcd_path)) vcd_path = "tb_soc.vcd";
        $dumpfile(vcd_path);
        $dumpvars(1, tb_soc);    // 只顶层(配合 --trace-depth);要全层次改 0 并重编 trace
        $display("[tb_soc] VCD -> %0s", vcd_path);
    end
    $display("[tb_soc] biRISC-V + riscv_soc(全RTL外设),reset_vector=0x%08x", reset_vector);
    $display("[tb_soc] UART = 真 RTL uart_lite @0x92000000,串行线反序列化打印如下:");
    $display("------------------------------------------------------------------");
end

always @(posedge clk) begin
    if (rst) cyc <= 0;
    else begin
        cyc <= cyc + 1;
        if (progress != 0 && (cyc % progress == 0))
            $fwrite(32'h80000002, "[tb_soc] cycle %0d\n", cyc);
        if (max_cycles != 0 && cyc >= max_cycles) begin
            $display("\n[tb_soc] 到达 MAX_CYCLES=%0d,结束。", max_cycles);
            $finish;
        end
    end
end

// 不依赖 OpenOCD 的 JTAG/SBA 自测(+JTAGTEST 开启)
`include "jtag_selftest.vh"
// 快速调试自测(+DBGTEST,直驱 DMI,几千周期)
`include "dbg_fast_test.vh"

endmodule
