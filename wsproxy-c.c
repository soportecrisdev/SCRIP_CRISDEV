/*
 * =============================================================================
 * CRISDEV wsproxy-c — High-Performance Native Linux epoll WebSocket/HTTP Proxy
 * =============================================================================
 * Designed for HTTP Conexion (DoriaXVPN / CrisDEV) on Port 80 (or custom port):
 *  - Single-threaded Linux epoll event loop (non-blocking I/O, zero threads/conn)
 *  - Supports 16,384+ concurrent tunnels (no 1024 FD select() limit)
 *  - Constant ~2-5 MB RAM footprint, zero per-connection disk I/O
 *  - Universal handshake:
 *      * Raw SSH-WS (Cloudflare, CloudFront, Direct, Tigo/Claro Payloads) -> 0 ms
 *      * Genuine RFC 6455 WebSocket (Sec-WebSocket-Key + Sec-WebSocket-Version)
 *      * Direct SSH passthrough (SSH-2.0-...)
 *      * [split] decoy second HTTP header stripping before SSH banner
 *  - CDN & Mobile Carrier anti-disconnect TCP tuning:
 *      TCP_NODELAY, TCP_QUICKACK, TCP_KEEPIDLE=25s, TCP_KEEPINTVL=10s,
 *      TCP_KEEPCNT=3, TCP_USER_TIMEOUT=45000ms
 *  - Zero external dependencies (glibc only, built-in SHA-1 + Base64)
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -o /usr/local/bin/wsproxy-c wsproxy-c.c
 * =============================================================================
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define WSPROXY_VERSION        "1.0.0-epoll"
#define MAX_EVENTS             1024
#define MAX_FDS                65536
#define MAX_HEADER_BYTES       16384
#define READ_CHUNK_SIZE        32768
#define MAX_PIPE_BUF           (256 * 1024)
#define MAX_WS_FRAME_LEN       (4 * 1024 * 1024)
#define HANDSHAKE_TIMEOUT_MS   12000ULL
#define CONNECT_TIMEOUT_MS     8000ULL
#define SWEEP_INTERVAL_MS      2000ULL

#ifndef TCP_USER_TIMEOUT
#define TCP_USER_TIMEOUT       18
#endif

static const char *WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/* --------------------------------------------------------------------------
 * Configuration & Runtime Globals
 * -------------------------------------------------------------------------- */
static char g_bind_addr[64]     = "0.0.0.0";
static int  g_listen_port       = 80;
static char g_target_host[128]  = "127.0.0.1";
static int  g_target_port       = 22;
static char g_http_status[16]   = "auto";
static char g_banner_msg[256]   = "";
static char g_pass[128]         = "";
static uint64_t g_idle_ms       = 300000ULL; /* 300s default */
static int  g_max_conns         = 16384;

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_dump_stats = 0;

static int g_epfd = -1;
static int g_listen_fd = -1;

static uint64_t g_active_conns = 0;
static uint64_t g_peak_conns   = 0;
static uint64_t g_total_conns  = 0;
static uint64_t g_total_rx     = 0;
static uint64_t g_total_tx     = 0;

/* --------------------------------------------------------------------------
 * Monotonic Clock (ms)
 * -------------------------------------------------------------------------- */
static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000ULL);
}

/* --------------------------------------------------------------------------
 * Minimal RFC 3174 SHA-1 + Base64 (zero external library dependency)
 * -------------------------------------------------------------------------- */
typedef struct {
    uint32_t state[5];
    uint64_t count;
    uint8_t  buf[64];
} sha1_ctx_t;

static inline uint32_t rol32(uint32_t v, unsigned int b) {
    return (v << b) | (v >> (32U - b));
}

static void sha1_transform(uint32_t state[5], const uint8_t block[64]) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) |
               ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) |
               ((uint32_t)block[i * 4 + 3]);
    }
    for (int i = 16; i < 80; i++) {
        w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    uint32_t a = state[0], b = state[1], c = state[2], d = state[3], e = state[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20) {
            f = (b & c) | ((~b) & d);
            k = 0x5A827999U;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1U;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDCU;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6U;
        }
        uint32_t temp = rol32(a, 5) + f + e + k + w[i];
        e = d;
        d = c;
        c = rol32(b, 30);
        b = a;
        a = temp;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
}

static void sha1_compute(const uint8_t *data, size_t len, uint8_t out[20]) {
    sha1_ctx_t ctx;
    ctx.state[0] = 0x67452301U;
    ctx.state[1] = 0xEFCDAB89U;
    ctx.state[2] = 0x98BADCFEU;
    ctx.state[3] = 0x10325476U;
    ctx.state[4] = 0xC3D2E1F0U;
    ctx.count = 0;

    size_t i = 0;
    while (len - i >= 64) {
        sha1_transform(ctx.state, data + i);
        i += 64;
        ctx.count += 512;
    }

    size_t rem = len - i;
    ctx.count += (uint64_t)rem * 8ULL;
    uint8_t pad[128];
    memset(pad, 0, sizeof(pad));
    if (rem > 0) memcpy(pad, data + i, rem);
    pad[rem] = 0x80;
    size_t pad_len = (rem < 56) ? 64 : 128;
    for (int j = 0; j < 8; j++) {
        pad[pad_len - 8 + j] = (uint8_t)(ctx.count >> (56 - j * 8));
    }
    sha1_transform(ctx.state, pad);
    if (pad_len == 128) sha1_transform(ctx.state, pad + 64);

    for (int j = 0; j < 5; j++) {
        out[j * 4]     = (uint8_t)(ctx.state[j] >> 24);
        out[j * 4 + 1] = (uint8_t)(ctx.state[j] >> 16);
        out[j * 4 + 2] = (uint8_t)(ctx.state[j] >> 8);
        out[j * 4 + 3] = (uint8_t)(ctx.state[j]);
    }
}

static void base64_encode(const uint8_t *in, size_t len, char *out) {
    static const char tbl[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i = 0, o = 0;
    while (i < len) {
        uint32_t a = in[i++];
        uint32_t b = (i < len) ? in[i++] : 0;
        uint32_t c = (i < len) ? in[i++] : 0;
        uint32_t triple = (a << 16) | (b << 8) | c;

        out[o++] = tbl[(triple >> 18) & 0x3F];
        out[o++] = tbl[(triple >> 12) & 0x3F];
        out[o++] = tbl[(triple >> 6) & 0x3F];
        out[o++] = tbl[triple & 0x3F];
    }
    size_t mod = len % 3;
    if (mod == 1) {
        out[o - 2] = '=';
        out[o - 1] = '=';
    } else if (mod == 2) {
        out[o - 1] = '=';
    }
    out[o] = '\0';
}

static void compute_ws_accept(const char *sec_key, char out_b64[64]) {
    char combined[256];
    int n = snprintf(combined, sizeof(combined), "%s%s", sec_key, WS_GUID);
    if (n < 0 || (size_t)n >= sizeof(combined)) {
        out_b64[0] = '\0';
        return;
    }
    uint8_t digest[20];
    sha1_compute((const uint8_t *)combined, (size_t)n, digest);
    base64_encode(digest, 20, out_b64);
}

/* --------------------------------------------------------------------------
 * Dynamic Byte Buffer
 * -------------------------------------------------------------------------- */
typedef struct {
    uint8_t *data;
    size_t   cap;
    size_t   len;
    size_t   off;
} buf_t;

static inline size_t buf_avail(const buf_t *b) {
    return (b->len > b->off) ? (b->len - b->off) : 0;
}

static inline uint8_t *buf_ptr(const buf_t *b) {
    return b->data + b->off;
}

static void buf_free(buf_t *b) {
    free(b->data);
    b->data = NULL;
    b->cap = b->len = b->off = 0;
}

static void buf_consume(buf_t *b, size_t n) {
    b->off += n;
    if (b->off >= b->len) {
        b->off = 0;
        b->len = 0;
    } else if (b->off >= 16384 && b->off >= b->cap / 2) {
        size_t rem = b->len - b->off;
        memmove(b->data, b->data + b->off, rem);
        b->off = 0;
        b->len = rem;
    }
}

static int buf_append(buf_t *b, const void *src, size_t n) {
    if (n == 0) return 0;
    if (b->off > 0 && b->len + n > b->cap) {
        size_t rem = b->len - b->off;
        if (rem > 0) memmove(b->data, b->data + b->off, rem);
        b->off = 0;
        b->len = rem;
    }
    if (b->len + n > b->cap) {
        size_t new_cap = b->cap ? b->cap : 4096;
        while (new_cap < b->len + n) {
            if (new_cap > (16 * 1024 * 1024)) return -1;
            new_cap *= 2;
        }
        uint8_t *nd = realloc(b->data, new_cap);
        if (!nd) return -1;
        b->data = nd;
        b->cap = new_cap;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
    return 0;
}

/* --------------------------------------------------------------------------
 * Connection State Machine
 * -------------------------------------------------------------------------- */
typedef enum {
    ST_HANDSHAKE = 0,
    ST_CONNECTING,
    ST_TUNNEL,
    ST_CLOSING_FLUSH
} conn_state_t;

typedef struct conn conn_t;
struct conn {
    int          cfd;
    int          bfd;
    conn_state_t state;
    int          ws_mode;        /* 0 = raw TCP/SSH, 1 = RFC 6455 WS */
    int          ssh_started;
    int          banner_split_done;    /* 1 once real non-HTTP payload forwarded */
    int          client_eof;
    int          backend_eof;
    int          closed;
    int          target_port;
    uint32_t     c_events;
    uint32_t     b_events;
    uint64_t     created_ms;
    uint64_t     last_active_ms;
    buf_t        hdr;            /* incoming HTTP handshake buffer */
    buf_t        c2b;            /* client -> backend write queue */
    buf_t        b2c;            /* backend -> client write queue */
    buf_t        ws_rx;          /* partial RFC 6455 client frames */
    buf_t        pre_ssh;        /* decoy [split] HTTP strip buffer */
    char         resp_buf[512];  /* prepared HTTP 101/200 response */
    size_t       resp_len;
    conn_t      *prev;
    conn_t      *next;
    conn_t      *free_next;
};

typedef struct {
    conn_t *c;
    int     is_backend;
} fd_slot_t;

static fd_slot_t g_fds[MAX_FDS];
static conn_t   *g_conn_head = NULL;
static conn_t   *g_free_head = NULL;

/* --------------------------------------------------------------------------
 * Socket Helpers
 * -------------------------------------------------------------------------- */
static void tune_client_socket(int fd) {
    int one = 1;
    int mss = 1220; /* MTU 1280 efectivo (1:1 con redes moviles 4G/LTE) */
    int tos = 0x10; /* IPTOS_LOWDELAY para Juegos y Llamadas VoIP */
#ifdef TCP_MAXSEG
    setsockopt(fd, IPPROTO_TCP, TCP_MAXSEG, &mss, sizeof(mss));
#endif
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));
    setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    int keepidle = 25;
    int keepintvl = 10;
    int keepcnt = 6;
    unsigned int user_timeout = 90000; /* 90s Anti-Drop cambio de antena LTE */
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &keepidle, sizeof(keepidle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepintvl, sizeof(keepintvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &keepcnt, sizeof(keepcnt));
    setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &user_timeout, sizeof(user_timeout));
}

static void tune_backend_socket(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
}

static void epoll_update(int fd, uint32_t *cur_ev, uint32_t new_ev) {
    if (fd < 0 || *cur_ev == new_ev) return;
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = new_ev;
    ev.data.fd = fd;
    if (*cur_ev == 0) {
        epoll_ctl(g_epfd, EPOLL_CTL_ADD, fd, &ev);
    } else {
        epoll_ctl(g_epfd, EPOLL_CTL_MOD, fd, &ev);
    }
    *cur_ev = new_ev;
}

static void conn_update_events(conn_t *c) {
    if (c->closed) return;

    if (c->state == ST_HANDSHAKE) {
        epoll_update(c->cfd, &c->c_events, EPOLLIN | EPOLLRDHUP);
        return;
    }

    if (c->state == ST_CONNECTING) {
        epoll_update(c->cfd, &c->c_events, EPOLLRDHUP);
        epoll_update(c->bfd, &c->b_events, EPOLLOUT | EPOLLRDHUP);
        return;
    }

    if (c->state == ST_CLOSING_FLUSH) {
        uint32_t cev = (buf_avail(&c->b2c) > 0) ? EPOLLOUT : 0;
        if (cev) epoll_update(c->cfd, &c->c_events, cev);
        return;
    }

    /* ST_TUNNEL */
    uint32_t cev = EPOLLRDHUP;
    if (!c->client_eof && buf_avail(&c->c2b) < MAX_PIPE_BUF) cev |= EPOLLIN;
    if (buf_avail(&c->b2c) > 0) cev |= EPOLLOUT;

    uint32_t bev = EPOLLRDHUP;
    if (!c->backend_eof && buf_avail(&c->b2c) < MAX_PIPE_BUF) bev |= EPOLLIN;
    if (buf_avail(&c->c2b) > 0) bev |= EPOLLOUT;

    epoll_update(c->cfd, &c->c_events, cev);
    epoll_update(c->bfd, &c->b_events, bev);
}

static void conn_schedule_close(conn_t *c) {
    if (!c || c->closed) return;
    c->closed = 1;

    if (c->cfd >= 0) {
        if (c->cfd < MAX_FDS) {
            g_fds[c->cfd].c = NULL;
            g_fds[c->cfd].is_backend = 0;
        }
        epoll_ctl(g_epfd, EPOLL_CTL_DEL, c->cfd, NULL);
        close(c->cfd);
        c->cfd = -1;
    }
    if (c->bfd >= 0) {
        if (c->bfd < MAX_FDS) {
            g_fds[c->bfd].c = NULL;
            g_fds[c->bfd].is_backend = 0;
        }
        epoll_ctl(g_epfd, EPOLL_CTL_DEL, c->bfd, NULL);
        close(c->bfd);
        c->bfd = -1;
    }

    /* Unlink from active list */
    if (c->prev) c->prev->next = c->next;
    else g_conn_head = c->next;
    if (c->next) c->next->prev = c->prev;
    c->prev = c->next = NULL;

    if (g_active_conns > 0) g_active_conns--;

    /* Deferred free after current epoll_wait batch */
    c->free_next = g_free_head;
    g_free_head = c;
}

static void drain_free_list(void) {
    while (g_free_head) {
        conn_t *c = g_free_head;
        g_free_head = c->free_next;
        buf_free(&c->hdr);
        buf_free(&c->c2b);
        buf_free(&c->b2c);
        buf_free(&c->ws_rx);
        buf_free(&c->pre_ssh);
        free(c);
    }
}

/* --------------------------------------------------------------------------
 * WebSocket Framing (RFC 6455) & Decoy [split] Stripper
 * -------------------------------------------------------------------------- */
static int ws_append_frame(buf_t *out, uint8_t opcode, const uint8_t *payload, size_t len) {
    uint8_t hdr[10];
    size_t hlen = 0;
    hdr[0] = (uint8_t)(0x80U | (opcode & 0x0FU));
    if (len < 126) {
        hdr[1] = (uint8_t)len;
        hlen = 2;
    } else if (len <= 0xFFFFU) {
        hdr[1] = 126;
        hdr[2] = (uint8_t)(len >> 8);
        hdr[3] = (uint8_t)(len & 0xFFU);
        hlen = 4;
    } else {
        hdr[1] = 127;
        for (int i = 0; i < 8; i++) {
            hdr[2 + i] = (uint8_t)((uint64_t)len >> (56 - i * 8));
        }
        hlen = 10;
    }
    if (buf_append(out, hdr, hlen) < 0) return -1;
    if (len > 0 && buf_append(out, payload, len) < 0) return -1;
    return 0;
}

static __attribute__((unused)) int starts_with_http_method(const uint8_t *p, size_t len) {
    static const char *methods[] = {
        "GET ", "POST ", "CONNECT ", "HEAD ", "PUT ",
        "OPTIONS ", "DELETE ", "PATCH ", "TRACE ", "CF-RAY "
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        size_t mlen = strlen(methods[i]);
        size_t cmp = (len < mlen) ? len : mlen;
        if (cmp > 0 && memcmp(p, methods[i], cmp) == 0) {
            return 1;
        }
    }
    return 0;
}

static const uint8_t *find_header_end(const uint8_t *buf, size_t len, size_t *sep_len) {
    for (size_t i = 0; i + 3 < len; i++) {
        if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n') {
            *sep_len = 4;
            return buf + i;
        }
    }
    for (size_t i = 0; i + 1 < len; i++) {
        if (buf[i] == '\n' && buf[i + 1] == '\n') {
            *sep_len = 2;
            return buf + i;
        }
    }
    return NULL;
}

static int feed_client_payload(conn_t *c, const uint8_t *data, size_t len) {
    if (len == 0) return 0;
    if (c->ssh_started) {
        return buf_append(&c->c2b, data, len);
    }

    /* Si el destino es SSH (no OpenVPN 1194), descartar cualquier basura ofuscada/[split] hasta detectar "SSH-" */
    if (c->target_port != 1194) {
        if (buf_append(&c->pre_ssh, data, len) < 0) return -1;
        uint8_t *p = buf_ptr(&c->pre_ssh);
        size_t avail = buf_avail(&c->pre_ssh);
        const uint8_t *ssh_pos = (const uint8_t *)memmem(p, avail, "SSH-", 4);
        if (ssh_pos) {
            size_t skip = (size_t)(ssh_pos - p);
            buf_consume(&c->pre_ssh, skip);
            c->ssh_started = 1;
            if (buf_append(&c->c2b, buf_ptr(&c->pre_ssh), buf_avail(&c->pre_ssh)) < 0) return -1;
            buf_free(&c->pre_ssh);
            return 0;
        }
        if (avail > MAX_HEADER_BYTES * 2) {
            return -1;
        }
        /* Conservar solo ultimos 3 bytes por si "SSH-" llega partido entre paquetes */
        if (avail > 3) {
            buf_consume(&c->pre_ssh, avail - 3);
        }
        return 0;
    }

    c->ssh_started = 1;
    return buf_append(&c->c2b, data, len);
}

static int process_ws_client_bytes(conn_t *c, const uint8_t *data, size_t len) {
    if (buf_append(&c->ws_rx, data, len) < 0) return -1;

    while (buf_avail(&c->ws_rx) >= 2) {
        uint8_t *p = buf_ptr(&c->ws_rx);
        size_t total = buf_avail(&c->ws_rx);

        uint8_t b0 = p[0];
        uint8_t b1 = p[1];
        uint8_t opcode = b0 & 0x0FU;
        int masked = (b1 & 0x80U) != 0;
        uint64_t plen = b1 & 0x7FU;
        size_t idx = 2;

        if (plen == 126) {
            if (total < 4) break;
            plen = ((uint64_t)p[2] << 8) | p[3];
            idx = 4;
        } else if (plen == 127) {
            if (total < 10) break;
            plen = 0;
            for (int i = 0; i < 8; i++) plen = (plen << 8) | p[2 + i];
            idx = 10;
        }

        if (plen > MAX_WS_FRAME_LEN) return -1;

        size_t mask_len = masked ? 4 : 0;
        if (idx + mask_len + plen > total) break;

        uint8_t *payload = p + idx + mask_len;
        if (masked && plen > 0) {
            uint8_t m[4] = { p[idx], p[idx + 1], p[idx + 2], p[idx + 3] };
            for (size_t i = 0; i < (size_t)plen; i++) {
                payload[i] ^= m[i & 3U];
            }
        }

        if (opcode == 0x00 || opcode == 0x01 || opcode == 0x02) {
            if (plen > 0 && feed_client_payload(c, payload, (size_t)plen) < 0) return -1;
        } else if (opcode == 0x09) {
            /* Ping -> Pong */
            if (ws_append_frame(&c->b2c, 0x0A, payload, (size_t)plen) < 0) return -1;
        } else if (opcode == 0x08) {
            /* Close */
            const uint8_t code[2] = { 0x03, 0xE8 };
            ws_append_frame(&c->b2c, 0x08, code, 2);
            buf_consume(&c->ws_rx, idx + mask_len + (size_t)plen);
            c->state = ST_CLOSING_FLUSH;
            return 0;
        }
        /* Pong (0x0A) or unknown control -> consume safely */
        buf_consume(&c->ws_rx, idx + mask_len + (size_t)plen);
    }
    return 0;
}

/* --------------------------------------------------------------------------
 * HTTP Header Parsing & Backend Connection Startup
 * -------------------------------------------------------------------------- */
static void trim_ws(char *s) {
    char *p = s;
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n')) {
        s[--n] = '\0';
    }
}

static int parse_local_port(const char *host_hdr) {
    if (!host_hdr || !host_hdr[0]) return g_target_port;
    char tmp[160];
    snprintf(tmp, sizeof(tmp), "%s", host_hdr);
    trim_ws(tmp);
    char *colon = strrchr(tmp, ':');
    int port = g_target_port;
    if (colon) {
        *colon = '\0';
        int p = atoi(colon + 1);
        if (p >= 1 && p <= 65535) port = p;
    }
    if (strcasecmp(tmp, "127.0.0.1") == 0 || strcasecmp(tmp, "localhost") == 0) {
        return port;
    }
    /* Bug Host / CloudFront / Cloudflare domain -> route safely to local backend */
    return g_target_port;
}

static int start_backend_connect(conn_t *c) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0 || fd >= MAX_FDS) {
        if (fd >= 0) close(fd);
        return -1;
    }
    tune_backend_socket(fd);

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)c->target_port);
    if (inet_pton(AF_INET, g_target_host, &sa.sin_addr) != 1) {
        inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
    }

    int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }

    c->bfd = fd;
    g_fds[fd].c = c;
    g_fds[fd].is_backend = 1;

    if (rc == 0) {
        /* Connected immediately on loopback */
        c->state = ST_TUNNEL;
        if (c->resp_len > 0) {
            if (buf_append(&c->b2c, c->resp_buf, c->resp_len) < 0) return -1;
            c->resp_len = 0;
            /* Immediate zero-latency flush of HTTP 101 response */
            while (buf_avail(&c->b2c) > 0) {
                ssize_t wn = send(c->cfd, buf_ptr(&c->b2c), buf_avail(&c->b2c), MSG_NOSIGNAL);
                if (wn < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                    return -1;
                }
                if (wn == 0) return -1;
                buf_consume(&c->b2c, (size_t)wn);
                g_total_tx += (uint64_t)wn;
            }
        }
        /* Flush any leftover client bytes from handshake */
        if (buf_avail(&c->hdr) > 0) {
            uint8_t *rem = buf_ptr(&c->hdr);
            size_t rlen = buf_avail(&c->hdr);
            int prc = c->ws_mode ? process_ws_client_bytes(c, rem, rlen)
                                 : feed_client_payload(c, rem, rlen);
            buf_free(&c->hdr);
            if (prc < 0) return -1;
        }
    } else {
        c->state = ST_CONNECTING;
    }
    conn_update_events(c);
    return 0;
}

static void handle_handshake_read(conn_t *c) {
    uint8_t tmp[4096];
    for (;;) {
        ssize_t n = recv(c->cfd, tmp, sizeof(tmp), 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            conn_schedule_close(c);
            return;
        }
        if (n == 0) {
            conn_schedule_close(c);
            return;
        }
        c->last_active_ms = now_ms();
        g_total_rx += (uint64_t)n;
        if (buf_append(&c->hdr, tmp, (size_t)n) < 0) {
            conn_schedule_close(c);
            return;
        }

        uint8_t *hb = buf_ptr(&c->hdr);
        size_t hlen = buf_avail(&c->hdr);

        /* Direct SSH client (no HTTP payload) */
        if (hlen >= 4 && memcmp(hb, "SSH-", 4) == 0) {
            c->ws_mode = 0;
            c->ssh_started = 1;
            c->target_port = g_target_port;
            c->resp_len = 0;
            if (start_backend_connect(c) < 0) {
                conn_schedule_close(c);
            }
            return;
        }

        size_t sep_len = 0;
        const uint8_t *end = find_header_end(hb, hlen, &sep_len);
        if (!end) {
            if (hlen > MAX_HEADER_BYTES) {
                conn_schedule_close(c);
                return;
            }
            /* Payloads modernos sin doble [crlf]: si ya hay al menos un '\n' y no es un Upgrade incompleto, responder al instante */
            if (memchr(hb, '\n', hlen) == NULL) {
                continue;
            }
            if (memmem(hb, hlen, "Upgrade:", 8) != NULL && memmem(hb, hlen, "Sec-WebSocket-Key", 17) == NULL) {
                continue;
            }
            end = hb + hlen;
            sep_len = 0;
        }

        size_t head_total = (size_t)(end - hb) + sep_len;

        /* Copy headers to NUL-terminated stack buffer for clean parsing */
        char header_copy[MAX_HEADER_BYTES + 1];
        size_t copy_len = (size_t)(end - hb);
        if (copy_len > MAX_HEADER_BYTES) copy_len = MAX_HEADER_BYTES;
        memcpy(header_copy, hb, copy_len);
        header_copy[copy_len] = '\0';

        /* Parse headers */
        char upgrade_val[64]  = "";
        char conn_val[64]     = "";
        char ws_key[128]      = "";
        char ws_ver[32]       = "";
        char real_host[160]   = "";
        char x_pass[128]      = "";

        char *saveptr = NULL;
        char *line = strtok_r(header_copy, "\n", &saveptr);
        /* Skip request line */
        line = strtok_r(NULL, "\n", &saveptr);
        while (line) {
            char *colon = strchr(line, ':');
            if (colon) {
                *colon = '\0';
                char *k = line;
                char *v = colon + 1;
                trim_ws(k);
                trim_ws(v);
                if (strcasecmp(k, "Upgrade") == 0) {
                    snprintf(upgrade_val, sizeof(upgrade_val), "%s", v);
                } else if (strcasecmp(k, "Connection") == 0) {
                    snprintf(conn_val, sizeof(conn_val), "%s", v);
                } else if (strcasecmp(k, "Sec-WebSocket-Key") == 0) {
                    snprintf(ws_key, sizeof(ws_key), "%s", v);
                } else if (strcasecmp(k, "Sec-WebSocket-Version") == 0) {
                    snprintf(ws_ver, sizeof(ws_ver), "%s", v);
                } else if (strcasecmp(k, "X-Real-Host") == 0) {
                    snprintf(real_host, sizeof(real_host), "%s", v);
                } else if (strcasecmp(k, "X-Pass") == 0) {
                    snprintf(x_pass, sizeof(x_pass), "%s", v);
                }
            }
            line = strtok_r(NULL, "\n", &saveptr);
        }

        if (g_pass[0] != '\0' && strcmp(g_pass, x_pass) != 0) {
            const char *rej = "HTTP/1.1 400 WrongPass!\r\n\r\n";
            buf_append(&c->b2c, rej, strlen(rej));
            c->state = ST_CLOSING_FLUSH;
            conn_update_events(c);
            return;
        }

        c->target_port = parse_local_port(real_host);

        /*
         * CRITICAL FIX (P80-01):
         * - Only enable RFC 6455 binary framing when BOTH Sec-WebSocket-Key AND
         *   Sec-WebSocket-Version are present (genuine RFC 6455 WS client).
         * - Standard VPN SSH-WS payloads (Cloudflare, CloudFront, HTTP Conexion,
         *   HTTP Custom, DarkTunnel, HTTP Injector) send Upgrade: websocket
         *   WITHOUT Sec-WebSocket-Key and speak RAW SSH immediately after 101!
         */
        int has_ws_key = (ws_key[0] != '\0');
        int has_ws_ver = (ws_ver[0] != '\0');
        int is_ws_upgrade = (strcasestr(upgrade_val, "websocket") != NULL ||
                             strcasestr(conn_val, "upgrade") != NULL ||
                             has_ws_key);
        c->ws_mode = (has_ws_key && has_ws_ver) ? 1 : 0;

        int force_101 = (strcmp(g_http_status, "101") == 0);
        int is_auto   = (strcmp(g_http_status, "auto") == 0);
        int use_101   = (has_ws_key && has_ws_ver) || force_101 || (is_auto && is_ws_upgrade);
        int rn = 0;
        if (has_ws_key && has_ws_ver) {
            /* CDN RFC 6455 estricto (RFC 7230) */
            char accept_b64[64];
            compute_ws_accept(ws_key, accept_b64);
            rn = snprintf(c->resp_buf, sizeof(c->resp_buf),
                          "HTTP/1.1 101 Switching Protocols\r\n"
                          "Upgrade: websocket\r\n"
                          "Connection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n", accept_b64);
            if (g_banner_msg[0] && rn > 0 && (size_t)rn < sizeof(c->resp_buf)) {
                rn += snprintf(c->resp_buf + rn, sizeof(c->resp_buf) - (size_t)rn,
                               "X-Banner: %s\r\n", g_banner_msg);
            }
            if (rn > 0 && (size_t)rn + 2 < sizeof(c->resp_buf)) {
                c->resp_buf[rn++] = '\r';
                c->resp_buf[rn++] = '\n';
                c->resp_buf[rn] = '\0';
            }
        } else if (use_101) {
            const char *reason = g_banner_msg[0] ? g_banner_msg : "Switching Protocols";
            rn = snprintf(c->resp_buf, sizeof(c->resp_buf),
                          "HTTP/1.1 101 %s\r\n"
                          "Upgrade: websocket\r\n"
                          "Connection: Upgrade\r\n\r\n", reason);
        } else {
            /* HTTP 200 limpio (sin Content-Length: 0 ni Upgrade -> Anti-DPI Tigo) */
            const char *reason = g_banner_msg[0] ? g_banner_msg : "Connection Established";
            rn = snprintf(c->resp_buf, sizeof(c->resp_buf),
                          "HTTP/1.1 200 %s\r\n"
                          "Connection: keep-alive\r\n\r\n", reason);
        }
        c->resp_len = (rn > 0) ? (size_t)rn : 0;

        /* SEPARACION ESTRICTA HTTP -> SSH (Anti-DPI): vaciar HTTP/1.1 antes de abrir 127.0.0.1:22 */
        if (c->resp_len > 0) {
            ssize_t wn = send(c->cfd, c->resp_buf, c->resp_len, MSG_NOSIGNAL);
            if (wn > 0) {
                g_total_tx += (uint64_t)wn;
                if ((size_t)wn >= c->resp_len) {
                    c->resp_len = 0;
                } else {
                    memmove(c->resp_buf, c->resp_buf + wn, c->resp_len - (size_t)wn);
                    c->resp_len -= (size_t)wn;
                }
            }
        }

        /* Keep only leftover bytes after header end */
        buf_consume(&c->hdr, head_total);

        if (start_backend_connect(c) < 0) {
            conn_schedule_close(c);
        }
        return;
    }
}

/* --------------------------------------------------------------------------
 * Tunnel I/O Handlers
 * -------------------------------------------------------------------------- */
static int flush_buf_to_fd(int fd, buf_t *b, uint64_t *counter) {
    while (buf_avail(b) > 0) {
        ssize_t n = send(fd, buf_ptr(b), buf_avail(b), MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            return -1;
        }
        if (n == 0) return -1;
        buf_consume(b, (size_t)n);
        if (counter) *counter += (uint64_t)n;
    }
    return 0;
}

static void handle_client_event(conn_t *c, uint32_t ev) {
    if (c->closed) return;

    if (ev & (EPOLLERR | EPOLLHUP)) {
        conn_schedule_close(c);
        return;
    }

    if (c->state == ST_HANDSHAKE) {
        if (ev & (EPOLLIN | EPOLLRDHUP)) {
            handle_handshake_read(c);
        }
        return;
    }

    if (c->state == ST_CLOSING_FLUSH) {
        if (ev & EPOLLOUT) {
            flush_buf_to_fd(c->cfd, &c->b2c, &g_total_tx);
            if (buf_avail(&c->b2c) == 0) {
                conn_schedule_close(c);
                return;
            }
        }
        conn_update_events(c);
        return;
    }

    if (c->state == ST_CONNECTING) {
        if (ev & EPOLLRDHUP) conn_schedule_close(c);
        return;
    }

    /* ST_TUNNEL */
    if (ev & EPOLLOUT) {
        if (flush_buf_to_fd(c->cfd, &c->b2c, &g_total_tx) < 0) {
            conn_schedule_close(c);
            return;
        }
        c->last_active_ms = now_ms();
        if (c->backend_eof && buf_avail(&c->b2c) == 0) {
            conn_schedule_close(c);
            return;
        }
    }

    if (ev & (EPOLLIN | EPOLLRDHUP)) {
        uint8_t tmp[READ_CHUNK_SIZE];
        while (buf_avail(&c->c2b) < MAX_PIPE_BUF) {
            ssize_t n = recv(c->cfd, tmp, sizeof(tmp), 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                conn_schedule_close(c);
                return;
            }
            if (n == 0) {
                c->client_eof = 1;
                if (buf_avail(&c->c2b) == 0) {
                    conn_schedule_close(c);
                    return;
                }
                break;
            }
            c->last_active_ms = now_ms();
            g_total_rx += (uint64_t)n;
            int prc = c->ws_mode ? process_ws_client_bytes(c, tmp, (size_t)n)
                                 : feed_client_payload(c, tmp, (size_t)n);
            if (prc < 0) {
                conn_schedule_close(c);
                return;
            }
            if (c->state == ST_CLOSING_FLUSH) {
                flush_buf_to_fd(c->cfd, &c->b2c, &g_total_tx);
                if (buf_avail(&c->b2c) == 0) {
                    conn_schedule_close(c);
                    return;
                }
                conn_update_events(c);
                return;
            }
            /* Try immediate zero-latency write to backend */
            if (flush_buf_to_fd(c->bfd, &c->c2b, NULL) < 0) {
                conn_schedule_close(c);
                return;
            }
        }
    }

    conn_update_events(c);
}

static void handle_backend_event(conn_t *c, uint32_t ev) {
    if (c->closed) return;

    if (ev & (EPOLLERR | EPOLLHUP)) {
        if (c->state == ST_TUNNEL && buf_avail(&c->b2c) > 0) {
            c->backend_eof = 1;
            c->state = ST_CLOSING_FLUSH;
            conn_update_events(c);
            return;
        }
        conn_schedule_close(c);
        return;
    }

    if (c->state == ST_CONNECTING) {
        int err = 0;
        socklen_t elen = sizeof(err);
        if (getsockopt(c->bfd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0 || err != 0) {
            conn_schedule_close(c);
            return;
        }
        c->state = ST_TUNNEL;
        c->last_active_ms = now_ms();
        if (c->resp_len > 0) {
            if (buf_append(&c->b2c, c->resp_buf, c->resp_len) < 0) {
                conn_schedule_close(c);
                return;
            }
            c->resp_len = 0;
            /* Immediate flush of 101 Switching Protocols */
            if (flush_buf_to_fd(c->cfd, &c->b2c, &g_total_tx) < 0) {
                conn_schedule_close(c);
                return;
            }
        }
        if (buf_avail(&c->hdr) > 0) {
            uint8_t *rem = buf_ptr(&c->hdr);
            size_t rlen = buf_avail(&c->hdr);
            int prc = c->ws_mode ? process_ws_client_bytes(c, rem, rlen)
                                 : feed_client_payload(c, rem, rlen);
            buf_free(&c->hdr);
            if (prc < 0) {
                conn_schedule_close(c);
                return;
            }
            if (flush_buf_to_fd(c->bfd, &c->c2b, NULL) < 0) {
                conn_schedule_close(c);
                return;
            }
        }
        conn_update_events(c);
        return;
    }

    /* ST_TUNNEL */
    if (ev & EPOLLOUT) {
        if (flush_buf_to_fd(c->bfd, &c->c2b, NULL) < 0) {
            conn_schedule_close(c);
            return;
        }
        c->last_active_ms = now_ms();
        if (c->client_eof && buf_avail(&c->c2b) == 0) {
            conn_schedule_close(c);
            return;
        }
    }

    if (ev & (EPOLLIN | EPOLLRDHUP)) {
        uint8_t tmp[READ_CHUNK_SIZE];
        while (buf_avail(&c->b2c) < MAX_PIPE_BUF) {
            ssize_t n = recv(c->bfd, tmp, sizeof(tmp), 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                conn_schedule_close(c);
                return;
            }
            if (n == 0) {
                c->backend_eof = 1;
                if (buf_avail(&c->b2c) == 0) {
                    conn_schedule_close(c);
                    return;
                }
                break;
            }
            c->last_active_ms = now_ms();
            /* Fragmentacion Anti-DPI del banner SSH: enviar 'SS' y luego 'H-2.0-...' en 2 segmentos TCP */
            if (!c->ws_mode && !c->banner_split_done && c->target_port != 1194 &&
                n > 4 && memcmp(tmp, "SSH-", 4) == 0 && buf_avail(&c->b2c) == 0) {
                c->banner_split_done = 1;
                ssize_t s2 = send(c->cfd, tmp, 2, MSG_NOSIGNAL);
                if (s2 == 2) {
                    g_total_tx += 2;
                    if (buf_append(&c->b2c, tmp + 2, (size_t)n - 2) < 0) {
                        conn_schedule_close(c);
                        return;
                    }
                    if (flush_buf_to_fd(c->cfd, &c->b2c, &g_total_tx) < 0) {
                        conn_schedule_close(c);
                        return;
                    }
                    continue;
                }
            }
            int prc = c->ws_mode ? ws_append_frame(&c->b2c, 0x02, tmp, (size_t)n)
                                 : buf_append(&c->b2c, tmp, (size_t)n);
            if (prc < 0) {
                conn_schedule_close(c);
                return;
            }
            /* Immediate zero-latency write to client */
            if (flush_buf_to_fd(c->cfd, &c->b2c, &g_total_tx) < 0) {
                conn_schedule_close(c);
                return;
            }
        }
    }

    conn_update_events(c);
}

/* --------------------------------------------------------------------------
 * Accept Loop & Periodic Sweeper
 * -------------------------------------------------------------------------- */
static void handle_accept(void) {
    for (;;) {
        struct sockaddr_in cli;
        socklen_t clilen = sizeof(cli);
        int cfd = accept4(g_listen_fd, (struct sockaddr *)&cli, &clilen,
                          SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            if (errno == EINTR) continue;
            if (errno == EMFILE || errno == ENFILE) break;
            break;
        }

        if (cfd >= MAX_FDS || (int)g_active_conns >= g_max_conns) {
            close(cfd);
            continue;
        }

        tune_client_socket(cfd);

        conn_t *c = calloc(1, sizeof(conn_t));
        if (!c) {
            close(cfd);
            continue;
        }
        c->cfd = cfd;
        c->bfd = -1;
        c->state = ST_HANDSHAKE;
        c->target_port = g_target_port;
        c->created_ms = now_ms();
        c->last_active_ms = c->created_ms;

        /* Link into active list */
        c->next = g_conn_head;
        if (g_conn_head) g_conn_head->prev = c;
        g_conn_head = c;

        g_fds[cfd].c = c;
        g_fds[cfd].is_backend = 0;

        g_active_conns++;
        g_total_conns++;
        if (g_active_conns > g_peak_conns) g_peak_conns = g_active_conns;

        conn_update_events(c);
    }
}

static void sweep_idle_connections(uint64_t now) {
    conn_t *c = g_conn_head;
    while (c) {
        conn_t *next = c->next;
        uint64_t age = (now >= c->last_active_ms) ? (now - c->last_active_ms) : 0;
        if (c->state == ST_HANDSHAKE && age > HANDSHAKE_TIMEOUT_MS) {
            conn_schedule_close(c);
        } else if (c->state == ST_CONNECTING && age > CONNECT_TIMEOUT_MS) {
            conn_schedule_close(c);
        } else if (c->state == ST_CLOSING_FLUSH && age > 5000ULL) {
            conn_schedule_close(c);
        } else if (c->state == ST_TUNNEL && age > g_idle_ms) {
            conn_schedule_close(c);
        }
        c = next;
    }
}

/* --------------------------------------------------------------------------
 * Signals & CLI Parsing
 * -------------------------------------------------------------------------- */
static void on_sigterm(int sig) {
    (void)sig;
    g_stop = 1;
}

static void on_sigusr1(int sig) {
    (void)sig;
    g_dump_stats = 1;
}

static void raise_nofile_limit(void) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        rlim_t want = 65535;
        if (rl.rlim_max < want) want = rl.rlim_max;
        if (rl.rlim_cur < want) {
            rl.rlim_cur = want;
            setrlimit(RLIMIT_NOFILE, &rl);
        }
    }
}

static void parse_target(const char *arg) {
    const char *colon = strrchr(arg, ':');
    if (colon) {
        size_t hlen = (size_t)(colon - arg);
        if (hlen > 0 && hlen < sizeof(g_target_host)) {
            memcpy(g_target_host, arg, hlen);
            g_target_host[hlen] = '\0';
        }
        int p = atoi(colon + 1);
        if (p >= 1 && p <= 65535) g_target_port = p;
    } else {
        int p = atoi(arg);
        if (p >= 1 && p <= 65535) {
            g_target_port = p;
        } else if (arg[0]) {
            snprintf(g_target_host, sizeof(g_target_host), "%s", arg);
        }
    }
    if (strcmp(g_target_host, "0.0.0.0") == 0 || strcmp(g_target_host, "localhost") == 0) {
        strcpy(g_target_host, "127.0.0.1");
    }
}

static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [options] [port]\n"
            "  -b, --bind <ip>         Bind address (default: 0.0.0.0)\n"
            "  -p, --port <port>       Listen port (default: 80)\n"
            "  -t, --target <ip:port>  Backend target (default: 127.0.0.1:22)\n"
            "  -s, --status <code>     HTTP status code (default: 101)\n"
            "  -m, --msg <text>        Optional X-Message banner\n"
            "  -k, --pass <secret>     Optional X-Pass secret\n"
            "  -i, --idle <seconds>    Idle timeout in seconds (default: 300)\n"
            "  -c, --max-conns <n>     Max concurrent tunnels (default: 16384)\n",
            prog);
}

int main(int argc, char **argv) {
    static struct option long_opts[] = {
        {"bind",      required_argument, 0, 'b'},
        {"port",      required_argument, 0, 'p'},
        {"target",    required_argument, 0, 't'},
        {"status",    required_argument, 0, 's'},
        {"msg",       required_argument, 0, 'm'},
        {"pass",      required_argument, 0, 'k'},
        {"idle",      required_argument, 0, 'i'},
        {"max-conns", required_argument, 0, 'c'},
        {"help",      no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:p:t:s:m:k:i:c:h", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': snprintf(g_bind_addr, sizeof(g_bind_addr), "%s", optarg); break;
            case 'p': g_listen_port = atoi(optarg); break;
            case 't': parse_target(optarg); break;
            case 's': snprintf(g_http_status, sizeof(g_http_status), "%s", optarg); break;
            case 'm': snprintf(g_banner_msg, sizeof(g_banner_msg), "%s", optarg); break;
            case 'k': snprintf(g_pass, sizeof(g_pass), "%s", optarg); break;
            case 'i': {
                int sec = atoi(optarg);
                if (sec >= 30 && sec <= 86400) g_idle_ms = (uint64_t)sec * 1000ULL;
                break;
            }
            case 'c': {
                int mc = atoi(optarg);
                if (mc >= 64 && mc <= 30000) g_max_conns = mc;
                break;
            }
            case 'h':
            default:
                usage(argv[0]);
                return (opt == 'h') ? 0 : 2;
        }
    }
    if (optind < argc) {
        int p = atoi(argv[optind]);
        if (p >= 1 && p <= 65535) g_listen_port = p;
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_sigterm);
    signal(SIGINT, on_sigterm);
    signal(SIGUSR1, on_sigusr1);

    raise_nofile_limit();

    g_listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (g_listen_fd < 0) {
        perror("socket");
        return 1;
    }

    int one = 1;
    setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef TCP_MAXSEG
    int listen_mss = 1220;
    setsockopt(g_listen_fd, IPPROTO_TCP, TCP_MAXSEG, &listen_mss, sizeof(listen_mss));
#endif
    setsockopt(g_listen_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)g_listen_port);
    if (inet_pton(AF_INET, g_bind_addr, &sa.sin_addr) != 1) {
        sa.sin_addr.s_addr = INADDR_ANY;
    }

    if (bind(g_listen_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        fprintf(stderr, "[wsproxy-c] bind(%s:%d) failed: %s\n",
                g_bind_addr, g_listen_port, strerror(errno));
        close(g_listen_fd);
        return 1;
    }

    if (listen(g_listen_fd, 4096) < 0) {
        perror("listen");
        close(g_listen_fd);
        return 1;
    }

    g_epfd = epoll_create1(EPOLL_CLOEXEC);
    if (g_epfd < 0) {
        perror("epoll_create1");
        close(g_listen_fd);
        return 1;
    }

    struct epoll_event lev;
    memset(&lev, 0, sizeof(lev));
    lev.events = EPOLLIN;
    lev.data.fd = g_listen_fd;
    if (epoll_ctl(g_epfd, EPOLL_CTL_ADD, g_listen_fd, &lev) < 0) {
        perror("epoll_ctl listen");
        close(g_epfd);
        close(g_listen_fd);
        return 1;
    }

    fprintf(stderr,
            "[wsproxy-c %s] Listening on %s:%d -> %s:%d (status=%s, idle=%lus, max_conns=%d)\n",
            WSPROXY_VERSION, g_bind_addr, g_listen_port, g_target_host, g_target_port,
            g_http_status, (unsigned long)(g_idle_ms / 1000ULL), g_max_conns);
    fflush(stderr);

    struct epoll_event events[MAX_EVENTS];
    uint64_t last_sweep = now_ms();

    while (!g_stop) {
        int nfds = epoll_wait(g_epfd, events, MAX_EVENTS, 1000);
        if (nfds < 0) {
            if (errno == EINTR) {
                if (g_dump_stats) {
                    g_dump_stats = 0;
                    fprintf(stderr,
                            "[wsproxy-c] stats: active=%llu peak=%llu total=%llu rx=%lluB tx=%lluB\n",
                            (unsigned long long)g_active_conns,
                            (unsigned long long)g_peak_conns,
                            (unsigned long long)g_total_conns,
                            (unsigned long long)g_total_rx,
                            (unsigned long long)g_total_tx);
                    fflush(stderr);
                }
                continue;
            }
            fprintf(stderr, "[wsproxy-c] epoll_wait error: %s\n", strerror(errno));
            break;
        }

        for (int i = 0; i < nfds; i++) {
            int fd = events[i].data.fd;
            uint32_t ev = events[i].events;

            if (fd == g_listen_fd) {
                handle_accept();
                continue;
            }
            if (fd < 0 || fd >= MAX_FDS) continue;

            conn_t *c = g_fds[fd].c;
            if (!c || c->closed) continue;

            if (g_fds[fd].is_backend) {
                handle_backend_event(c, ev);
            } else {
                handle_client_event(c, ev);
            }
        }

        uint64_t now = now_ms();
        if (now - last_sweep >= SWEEP_INTERVAL_MS) {
            sweep_idle_connections(now);
            last_sweep = now;
        }

        if (g_dump_stats) {
            g_dump_stats = 0;
            fprintf(stderr,
                    "[wsproxy-c] stats: active=%llu peak=%llu total=%llu rx=%lluB tx=%lluB\n",
                    (unsigned long long)g_active_conns,
                    (unsigned long long)g_peak_conns,
                    (unsigned long long)g_total_conns,
                    (unsigned long long)g_total_rx,
                    (unsigned long long)g_total_tx);
            fflush(stderr);
        }

        drain_free_list();
    }

    /* Clean shutdown */
    while (g_conn_head) {
        conn_schedule_close(g_conn_head);
    }
    drain_free_list();
    close(g_epfd);
    close(g_listen_fd);
    fprintf(stderr, "[wsproxy-c] Shutdown complete.\n");
    return 0;
}
