//-----------------------------------------------------------------
// jtag_rbb.cpp —— OpenOCD remote_bitbang 协议的仿真侧桥(DPI-C)。
//
// OpenOCD(adapter driver remote_bitbang)经 TCP 连到这里,发 ASCII 命令逐位
// 驱动 JTAG;本桥把 TCK/TMS/TDI 喂给 DUT,并把 DUT 的 TDO 回送给 OpenOCD。
//
// remote_bitbang 协议(每字符一条命令):
//   '0'..'7' = 设 (tck,tms,tdi)，值 = tck*4+tms*2+tdi
//   'R'      = 读回 TDO，回送 '0'/'1'
//   'r','s','t','u' = 复位组合(trst,srst)；'B'/'b' = LED；'Q' = 退出
//
// 过采样配合:DUT 的 DTM 在系统时钟域对 TCK 做 2-FF 同步 + 边沿检测,需要 TCK
// 每个电平稳定若干个系统时钟。所以本桥每 HOLD 个系统时钟才消费一条新命令,
// 命令之间保持引脚不变 —— 保证不漏边沿。
//-----------------------------------------------------------------
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <svdpi.h>

static int  g_listen = -1;
static int  g_client = -1;
static int  g_port   = 0;
static int  g_hold   = 0;          // 当前命令已保持的系统时钟数
static const int HOLD = 12;        // 每条命令保持多少个系统时钟(>= 同步链深度)
static unsigned char g_tck=0, g_tms=1, g_tdi=0;   // 上电:tms=1(让 TAP 复位)
static int  g_quit   = 0;

static void try_accept() {
    if (g_client >= 0) return;
    int c = accept(g_listen, NULL, NULL);
    if (c >= 0) {
        int one = 1;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        fcntl(c, F_SETFL, O_NONBLOCK);
        g_client = c;
        fprintf(stderr, "[jtag_rbb] OpenOCD 已连接\n");
    }
}

// 初始化:监听端口(只调一次)。返回 0 成功。
extern "C" int jtag_rbb_init(int port) {
    g_port = port;
    g_listen = socket(AF_INET, SOCK_STREAM, 0);
    if (g_listen < 0) { perror("socket"); return -1; }
    int one = 1;
    setsockopt(g_listen, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(g_listen, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("bind"); return -1; }
    if (listen(g_listen, 1) < 0) { perror("listen"); return -1; }
    fcntl(g_listen, F_SETFL, O_NONBLOCK);
    fprintf(stderr, "[jtag_rbb] 监听 0.0.0.0:%d，等 OpenOCD(remote_bitbang)连接...\n", port);
    return 0;
}

// 每个系统时钟调一次:喂 tdo,取回当前 tck/tms/tdi。返回 1 继续,0 退出。
extern "C" int jtag_rbb_tick(char tdo,
                             char* tck, char* tms, char* tdi) {
    if (g_quit) { *tck=0; *tms=1; *tdi=0; return 0; }
    try_accept();

    // 保持当前命令 HOLD 个时钟,期间不读新命令(让 DTM 看清 TCK 电平)
    if (g_hold > 0) { g_hold--; }
    else if (g_client >= 0) {
        unsigned char ch;
        int n = recv(g_client, &ch, 1, 0);
        if (n == 1) {
            if (ch >= '0' && ch <= '7') {
                unsigned v = ch - '0';
                g_tck = (v>>2)&1; g_tms = (v>>1)&1; g_tdi = v&1;
                g_hold = HOLD;                      // 新引脚电平保持一段
            } else if (ch == 'R') {
                char r = tdo ? '1' : '0';
                send(g_client, &r, 1, 0);           // 回送 TDO
            } else if (ch=='r'||ch=='s'||ch=='t'||ch=='u') {
                // (t)rst/(s)rst 组合:本桥不接系统复位,忽略电平,仅当作 nop
            } else if (ch == 'Q') {
                g_quit = 1;
            }
            // 'B'/'b'(LED)忽略
        } else if (n == 0) {
            // 对端关闭
            close(g_client); g_client = -1;
            fprintf(stderr, "[jtag_rbb] OpenOCD 断开\n");
        }
    }
    *tck = g_tck; *tms = g_tms; *tdi = g_tdi;
    return 1;
}
