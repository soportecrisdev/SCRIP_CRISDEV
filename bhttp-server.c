/*
 * CRISDEV BHTTP Server — Motor Nativo en C de Ultra-Alto Rendimiento (BHP1)
 * Optimizado con AVX2 x8 SIMD, Long-Polling en Kernel (pthread_cond_timedwait),
 * Multi-Puerto Nativo y Keep-Alive HTTP/1.1 / BHP1 de 2048 peticiones por conexión.
 *
 * Compilar:
 *   gcc -O3 -march=native -mtune=native -pthread -o /usr/local/bin/bhttp-server bhttp-server.c
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <malloc.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define VERSION "3.0-CRISDEV-AVX2-BHP2"

#define MODE_PROBE 0
#define MODE_UPLOAD 1
#define MODE_DOWNLOAD 2
#define MODE_BATCH 3
#define MODE_ACK 4
#define MODE_LANE 5
#define LANE_UPLOAD 1
#define LANE_DOWNLOAD 2
#define BHP2_VERSION 2
#define ST_OK 0
#define ST_ERR 1
#define ST_DATA 2

#define HEADER 29
#define MAX_REQUEST (1u << 20)
#define MAX_PROBE_REPLY (1u << 20)
#define MAX_CHUNK 65536
#define MAX_BATCH 32
#define MAX_WINDOW_AHEAD 65536u
#define DEFAULT_REQUEST_TIMEOUT_MS 25000
#define DEFAULT_KEEPALIVE_IDLE_MS 55000
#define DEFAULT_MAX_REQUESTS_PER_CONN 2048
#define BACKLOG_MAX (8u << 20)
#define UP_PENDING_MAX (8u << 20)
#define THREAD_STACK (256 * 1024)
#define HASH_BUCKETS 8192
#define MAX_LISTENERS 32

/* ------------------------------------------------------------------ utilidades */

static int g_verbose = 0;
static volatile sig_atomic_t g_stop = 0;
static void on_term(int sig) { (void)sig; g_stop = 1; }

static void logmsg(const char *lvl, const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    fprintf(stderr, "%s [%s] ", ts, lvl);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static inline uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static inline uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p) << 32) | be32(p + 4); }
static inline void put_be32(uint8_t *p, uint32_t v) {
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

/* ------------------------------------------------------------------ SHA-256 + ofuscacion SIMD */

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
static const uint32_t IV256[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t st[8], const uint32_t w16[16]) {
    uint32_t W[64];
    int i;
    memcpy(W, w16, 64);
    for (i = 16; i < 64; i++) {
        uint32_t s0 = ROR(W[i - 15], 7) ^ ROR(W[i - 15], 18) ^ (W[i - 15] >> 3);
        uint32_t s1 = ROR(W[i - 2], 17) ^ ROR(W[i - 2], 19) ^ (W[i - 2] >> 10);
        W[i] = W[i - 16] + s0 + W[i - 7] + s1;
    }
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7];
    for (i = 0; i < 64; i++) {
        uint32_t S1 = ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + K256[i] + W[i];
        uint32_t S0 = ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d; st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

static void crypt_prep(uint32_t w[16], uint32_t *w6hi, const uint8_t sid[16], unsigned mode, uint64_t seq, int resp) {
    uint8_t pre[26];
    int i;
    memcpy(pre, sid, 16);
    pre[16] = (uint8_t)mode;
    for (i = 0; i < 8; i++) pre[17 + i] = (uint8_t)(seq >> (56 - 8 * i));
    pre[25] = resp ? 1 : 0;
    for (i = 0; i < 6; i++) w[i] = be32(pre + 4 * i);
    *w6hi = ((uint32_t)pre[24] << 24) | ((uint32_t)pre[25] << 16);
    for (i = 8; i < 15; i++) w[i] = 0;
    w[15] = 240; /* 30 bytes = 240 bits */
}

static void ks_scalar(const uint32_t w0[16], uint32_t w6hi, uint32_t ctr, uint8_t ks[32]) {
    uint32_t w[16], st[8];
    int i;
    memcpy(w, w0, sizeof w);
    w[6] = w6hi | (ctr >> 16);
    w[7] = (ctr << 16) | 0x8000u;
    memcpy(st, IV256, sizeof st);
    sha256_block(st, w);
    for (i = 0; i < 8; i++) put_be32(ks + 4 * i, st[i]);
}

#ifndef NO_SIMD
typedef uint32_t v4u __attribute__((vector_size(16)));
#define VROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define DEFINE_MB(NAME, V, L, ATTR)                                                                          \
    ATTR static void NAME(const uint32_t w[16], uint32_t w6hi, uint32_t ctr0, uint8_t *ks) {                \
        V W[64], zero = (V){0};                                                                              \
        int i, l, j;                                                                                         \
        for (i = 0; i < 16; i++) W[i] = zero + w[i];                                                         \
        {                                                                                                    \
            uint32_t a6[L], a7[L];                                                                           \
            for (l = 0; l < L; l++) {                                                                        \
                uint32_t c = ctr0 + (uint32_t)l;                                                             \
                a6[l] = w6hi | (c >> 16);                                                                    \
                a7[l] = (c << 16) | 0x8000u;                                                                 \
            }                                                                                                \
            memcpy(&W[6], a6, sizeof(V));                                                                    \
            memcpy(&W[7], a7, sizeof(V));                                                                    \
        }                                                                                                    \
        for (i = 16; i < 64; i++) {                                                                          \
            V x15 = W[i - 15], x2 = W[i - 2];                                                                \
            V s0 = VROR(x15, 7) ^ VROR(x15, 18) ^ (x15 >> 3);                                                \
            V s1 = VROR(x2, 17) ^ VROR(x2, 19) ^ (x2 >> 10);                                                 \
            W[i] = W[i - 16] + s0 + W[i - 7] + s1;                                                           \
        }                                                                                                    \
        V a = zero + IV256[0], b = zero + IV256[1], c = zero + IV256[2], d = zero + IV256[3];                \
        V e = zero + IV256[4], f = zero + IV256[5], g = zero + IV256[6], h = zero + IV256[7];                \
        for (i = 0; i < 64; i++) {                                                                           \
            V S1 = VROR(e, 6) ^ VROR(e, 11) ^ VROR(e, 25);                                                   \
            V ch = (e & f) ^ (~e & g);                                                                       \
            V t1 = h + S1 + ch + (zero + K256[i]) + W[i];                                                    \
            V S0 = VROR(a, 2) ^ VROR(a, 13) ^ VROR(a, 22);                                                   \
            V maj = (a & b) ^ (a & c) ^ (b & c);                                                             \
            V t2 = S0 + maj;                                                                                 \
            h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;                               \
        }                                                                                                    \
        V r[8] = {a + IV256[0], b + IV256[1], c + IV256[2], d + IV256[3],                                    \
                  e + IV256[4], f + IV256[5], g + IV256[6], h + IV256[7]};                                   \
        for (j = 0; j < 8; j++) {                                                                            \
            uint32_t t[L];                                                                                   \
            memcpy(t, &r[j], sizeof(V));                                                                     \
            for (l = 0; l < L; l++) put_be32(ks + 32 * l + 4 * j, t[l]);                                     \
        }                                                                                                    \
    }

DEFINE_MB(ks_x4, v4u, 4, )
#if defined(__x86_64__) && defined(__GNUC__)
typedef uint32_t v8u __attribute__((vector_size(32)));
DEFINE_MB(ks_x8, v8u, 8, __attribute__((target("avx2"))))
#define HAVE_X8 1
#endif
#endif /* NO_SIMD */

static int g_simd = 0;

static void xor_bytes(uint8_t *d, const uint8_t *k, size_t m) {
    size_t i = 0;
    for (; i + 8 <= m; i += 8) {
        uint64_t a, b;
        memcpy(&a, d + i, 8);
        memcpy(&b, k + i, 8);
        a ^= b;
        memcpy(d + i, &a, 8);
    }
    for (; i < m; i++) d[i] ^= k[i];
}

static void crypt_ex(uint8_t *d, size_t n, const uint8_t sid[16], unsigned mode, uint64_t seq, int resp, int level) {
    if (n == 0) return;
    uint32_t w[16], w6hi, ctr = 0;
    uint8_t ks[256];
    size_t off = 0;
    crypt_prep(w, &w6hi, sid, mode, seq, resp);
#if defined(HAVE_X8)
    if (level >= 2)
        while (n - off >= 256) { ks_x8(w, w6hi, ctr, ks); xor_bytes(d + off, ks, 256); off += 256; ctr += 8; }
#endif
#ifndef NO_SIMD
    if (level >= 1)
        while (n - off >= 128) { ks_x4(w, w6hi, ctr, ks); xor_bytes(d + off, ks, 128); off += 128; ctr += 4; }
#endif
    (void)level;
    while (off < n) {
        size_t m = n - off < 32 ? n - off : 32;
        ks_scalar(w, w6hi, ctr, ks);
        xor_bytes(d + off, ks, m);
        off += 32;
        ctr++;
    }
}

static void crypt_buf(uint8_t *d, size_t n, const uint8_t sid[16], unsigned mode, uint64_t seq, int resp) {
    crypt_ex(d, n, sid, mode, seq, resp, g_simd);
}

static int simd_pick(int verbose) {
    int best = 0;
#ifndef NO_SIMD
    best = 1;
#if defined(HAVE_X8)
    __builtin_cpu_init();
    if (__builtin_cpu_supports("avx2")) best = 2;
#endif
#endif
    static const size_t lens[] = {1, 31, 32, 33, 127, 128, 129, 255, 256, 257, 511, 1000, 4097, 65536};
    uint8_t sid[16];
    int lv, ok = 1;
    size_t k, i;
    uint8_t *a = malloc(65536), *b = malloc(65536);
    if (!a || !b) { free(a); free(b); return 0; }
    for (i = 0; i < 16; i++) sid[i] = (uint8_t)(0xA0 + i);
    for (lv = best; lv >= 1; lv--) {
        ok = 1;
        for (k = 0; k < sizeof lens / sizeof lens[0] && ok; k++) {
            for (i = 0; i < lens[k]; i++) a[i] = b[i] = (uint8_t)(i * 7 + k);
            crypt_ex(a, lens[k], sid, MODE_BATCH, 0x1122334455667788ULL + k, 1, 0);
            crypt_ex(b, lens[k], sid, MODE_BATCH, 0x1122334455667788ULL + k, 1, lv);
            if (memcmp(a, b, lens[k]) != 0) ok = 0;
        }
        if (ok) { best = lv; break; }
        if (verbose) printf("aviso: la ruta SIMD nivel %d no coincide con la escalar: desactivada\n", lv);
        best = lv - 1;
    }
    if (best < 1) best = 0;
    free(a);
    free(b);
    return best;
}

static int self_test(int quiet) {
    uint32_t w[16] = {0}, st[8];
    memcpy(st, IV256, sizeof st);
    w[0] = 0x61626380u;
    w[15] = 24;
    sha256_block(st, w);
    static const uint32_t abc[8] = {0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223,
                                    0xb00361a3, 0x96177a9c, 0xb410ff61, 0xf20015ad};
    if (memcmp(st, abc, sizeof st) != 0) { printf("FALLO: SHA-256\n"); return 1; }
    uint8_t sid[16], buf[70];
    int i;
    for (i = 0; i < 16; i++) sid[i] = (uint8_t)i;
    for (i = 0; i < 70; i++) buf[i] = (uint8_t)i;
    crypt_ex(buf, sizeof buf, sid, 3, 0x0102030405060708ULL, 1, 0);
    static const uint8_t want[70] = {
        0x98, 0x42, 0x0a, 0x75, 0x59, 0x66, 0x08, 0xb3, 0x0c, 0x05, 0x60, 0x50, 0x21, 0x54, 0x5f, 0x27,
        0xd2, 0x72, 0xe4, 0xa1, 0xbc, 0xca, 0xda, 0xb4, 0x77, 0xe7, 0x64, 0x37, 0x9c, 0x61, 0x7f, 0xf3,
        0xa5, 0xf3, 0x9e, 0xcb, 0x9d, 0x58, 0xe0, 0x7b, 0x12, 0x0e, 0x6f, 0x90, 0x56, 0x4c, 0xb1, 0xbd,
        0xa9, 0xc9, 0xc5, 0x86, 0xd6, 0x13, 0xbd, 0x99, 0xb0, 0x47, 0x19, 0x4e, 0x65, 0x98, 0x6e, 0xd2,
        0x07, 0x33, 0xec, 0x01, 0x89, 0x8b};
    if (memcmp(buf, want, sizeof buf) != 0) { printf("FALLO: ofuscacion\n"); return 1; }
    g_simd = simd_pick(!quiet);
    uint8_t buf2[70];
    for (i = 0; i < 70; i++) buf2[i] = (uint8_t)i;
    crypt_buf(buf2, sizeof buf2, sid, 3, 0x0102030405060708ULL, 1);
    if (memcmp(buf2, want, sizeof buf2) != 0) { printf("FALLO: ofuscacion (ruta SIMD)\n"); return 1; }
    if (!quiet) printf("self-test OK (SHA-256 y ofuscacion BHP1; calculo: %s)\n",
                       g_simd == 2 ? "AVX2 x8" : g_simd == 1 ? "SIMD x4" : "escalar");
    return 0;
}

/* ------------------------------------------------------------------ E/S de red */

static int read_full(int fd, uint8_t *buf, size_t n, int64_t deadline) {
    size_t got = 0;
    while (got < n) {
        int64_t left = deadline - now_ms();
        if (left <= 0) return -1;
        struct pollfd p = {fd, POLLIN, 0};
        int r = poll(&p, 1, left > INT_MAX ? INT_MAX : (int)left);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        ssize_t k = recv(fd, buf + got, n - got, 0);
        if (k == 0) return -1;
        if (k < 0) { if (errno == EINTR || errno == EAGAIN) continue; return -1; }
        got += (size_t)k;
    }
    return 0;
}

static int write_full(int fd, const uint8_t *buf, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        ssize_t k = send(fd, buf + sent, n - sent, MSG_NOSIGNAL);
        if (k < 0) { if (errno == EINTR) continue; return -1; }
        if (k == 0) return -1;
        sent += (size_t)k;
    }
    return 0;
}

static void set_timeouts(int fd, int sec) {
    struct timeval tv = {sec, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

/* ------------------------------------------------------------------ configuracion */

static struct sockaddr_storage g_backend;
static socklen_t g_backend_len;
static char g_backend_txt[128] = "127.0.0.1:22";
static int g_poll_wait_ms = 800;
static int g_max_sessions = 4096;
static int g_max_per_ip = 256;
static int g_idle = 180;
static int g_max_requests_per_conn = DEFAULT_MAX_REQUESTS_PER_CONN;
static int g_request_timeout_ms = DEFAULT_REQUEST_TIMEOUT_MS;
static long g_max_conns = 0;
static long g_conns = 0;

/* ------------------------------------------------------------------ sesiones */

typedef struct Slot { uint8_t *p; uint32_t n; } Slot;
typedef struct Pend { uint64_t seq; uint8_t *p; uint32_t n; struct Pend *next; } Pend;

typedef struct Session {
    uint8_t sid[16];
    uint8_t ipk[16];
    struct Session *next;
    int fd;
    pthread_mutex_t m;
    pthread_cond_t cv;
    int ready, failed, closed, dead;
    int64_t last;
    uint8_t *bl;
    size_t bl_head, bl_tail, bl_cap;
    Slot *sl;
    size_t sl_head, sl_n, sl_cap;
    uint64_t sl_base, filled;
    pthread_mutex_t um;
    uint64_t next_up;
    Pend *pend;
    size_t pend_bytes;
    int refs;
} Session;

static pthread_mutex_t g_T = PTHREAD_MUTEX_INITIALIZER;
static Session *g_tab[HASH_BUCKETS];
static int g_total = 0;

typedef struct { uint8_t ip[16]; int n; } IpCnt;
static IpCnt *g_ipt;
static size_t g_ipn, g_ipcap;

static unsigned hash_sid(const uint8_t *sid) {
    uint32_t h = be32(sid) ^ (be32(sid + 4) * 2654435761u);
    return h & (HASH_BUCKETS - 1);
}

static int ip_count(const uint8_t *ip) {
    for (size_t i = 0; i < g_ipn; i++) if (!memcmp(g_ipt[i].ip, ip, 16)) return g_ipt[i].n;
    return 0;
}
static void ip_inc(const uint8_t *ip) {
    for (size_t i = 0; i < g_ipn; i++) if (!memcmp(g_ipt[i].ip, ip, 16)) { g_ipt[i].n++; return; }
    if (g_ipn == g_ipcap) {
        size_t nc = g_ipcap ? g_ipcap * 2 : 256;
        IpCnt *nt = realloc(g_ipt, nc * sizeof *nt);
        if (!nt) return;
        g_ipt = nt; g_ipcap = nc;
    }
    memcpy(g_ipt[g_ipn].ip, ip, 16);
    g_ipt[g_ipn].n = 1;
    g_ipn++;
}
static void ip_dec(const uint8_t *ip) {
    for (size_t i = 0; i < g_ipn; i++)
        if (!memcmp(g_ipt[i].ip, ip, 16)) {
            if (--g_ipt[i].n <= 0) g_ipt[i] = g_ipt[--g_ipn];
            return;
        }
}

static void cond_init_mono(pthread_cond_t *cv) {
    pthread_condattr_t at;
    pthread_condattr_init(&at);
    pthread_condattr_setclock(&at, CLOCK_MONOTONIC);
    pthread_cond_init(cv, &at);
    pthread_condattr_destroy(&at);
}

static int cond_wait_until(Session *s, int64_t deadline) {
    struct timespec ts;
    ts.tv_sec = deadline / 1000;
    ts.tv_nsec = (deadline % 1000) * 1000000L;
    return pthread_cond_timedwait(&s->cv, &s->m, &ts) == ETIMEDOUT;
}

static Session *session_new(const uint8_t *sid, const uint8_t *ipk) {
    Session *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    memcpy(s->sid, sid, 16);
    memcpy(s->ipk, ipk, 16);
    s->fd = -1;
    pthread_mutex_init(&s->m, NULL);
    pthread_mutex_init(&s->um, NULL);
    cond_init_mono(&s->cv);
    s->last = now_ms();
    s->refs = 2;
    return s;
}

static void session_free(Session *s) {
    if (s->fd >= 0) close(s->fd);
    free(s->bl);
    for (size_t i = 0; i < s->sl_n; i++) free(s->sl[s->sl_head + i].p);
    free(s->sl);
    while (s->pend) { Pend *p = s->pend; s->pend = p->next; free(p->p); free(p); }
    pthread_mutex_destroy(&s->m);
    pthread_mutex_destroy(&s->um);
    pthread_cond_destroy(&s->cv);
    free(s);
}

static void session_release(Session *s) {
    if (__atomic_sub_fetch(&s->refs, 1, __ATOMIC_ACQ_REL) == 0) session_free(s);
}
static void session_ref(Session *s) { __atomic_add_fetch(&s->refs, 1, __ATOMIC_ACQ_REL); }

static void *pump_thread(void *arg) {
    Session *s = arg;
    uint8_t *tmp = malloc(65536);
    for (;;) {
        pthread_mutex_lock(&s->m);
        while (!s->dead && (s->bl_tail - s->bl_head) >= BACKLOG_MAX) cond_wait_until(s, now_ms() + 20);
        int dead = s->dead;
        pthread_mutex_unlock(&s->m);
        if (dead || !tmp) break;
        ssize_t k = recv(s->fd, tmp, 65536, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) break;
        pthread_mutex_lock(&s->m);
        size_t len = s->bl_tail - s->bl_head;
        if (s->bl_head > 0 && (s->bl_head > s->bl_cap / 2 || s->bl_tail + (size_t)k > s->bl_cap)) {
            memmove(s->bl, s->bl + s->bl_head, len);
            s->bl_head = 0;
            s->bl_tail = len;
        }
        if (s->bl_tail + (size_t)k > s->bl_cap) {
            size_t nc = s->bl_cap ? s->bl_cap : 65536;
            while (nc < s->bl_tail + (size_t)k) nc *= 2;
            uint8_t *nb = realloc(s->bl, nc);
            if (!nb) { pthread_mutex_unlock(&s->m); break; }
            s->bl = nb;
            s->bl_cap = nc;
        }
        memcpy(s->bl + s->bl_tail, tmp, (size_t)k);
        s->bl_tail += (size_t)k;
        pthread_cond_broadcast(&s->cv);
        pthread_mutex_unlock(&s->m);
    }
    free(tmp);
    pthread_mutex_lock(&s->m);
    s->closed = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
    session_release(s);
    return NULL;
}

static int start_thread(void *(*fn)(void *), void *arg) {
    pthread_attr_t at;
    pthread_t th;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, THREAD_STACK);
    int r = pthread_create(&th, &at, fn, arg);
    pthread_attr_destroy(&at);
    return r;
}

static int backend_connect(void) {
    int fd = socket(g_backend.ss_family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&g_backend, g_backend_len);
    if (r < 0 && errno == EINPROGRESS) {
        struct pollfd p = {fd, POLLOUT, 0};
        if (poll(&p, 1, 5000) == 1) {
            int err = 0;
            socklen_t el = sizeof err;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
            r = err ? -1 : 0;
        } else r = -1;
    }
    if (r < 0) { close(fd); return -1; }
    fcntl(fd, F_SETFL, fl);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
    int v = 30; setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &v, sizeof v);
    v = 10; setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &v, sizeof v);
    v = 3; setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &v, sizeof v);
    set_timeouts(fd, 30);
    return fd;
}

static void wait_ready(Session *s) {
    pthread_mutex_lock(&s->m);
    while (!s->ready) pthread_cond_wait(&s->cv, &s->m);
    pthread_mutex_unlock(&s->m);
}

static Session *tab_find_locked(const uint8_t *sid) {
    for (Session *s = g_tab[hash_sid(sid)]; s; s = s->next)
        if (!memcmp(s->sid, sid, 16)) return s;
    return NULL;
}
static int tab_remove_locked(Session *s) {
    Session **pp = &g_tab[hash_sid(s->sid)];
    while (*pp) {
        if (*pp == s) { *pp = s->next; g_total--; ip_dec(s->ipk); return 1; }
        pp = &(*pp)->next;
    }
    return 0;
}

static void session_drop(Session *s) {
    pthread_mutex_lock(&g_T);
    int removed = tab_remove_locked(s);
    int left = g_total;
    pthread_mutex_unlock(&g_T);
    if (!removed) return;
    pthread_mutex_lock(&s->m);
    s->dead = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
    if (s->fd >= 0) shutdown(s->fd, SHUT_RDWR);
    if (g_verbose) logmsg("INFO", "sesion cerrada (%d activas)", left);
    session_release(s);
}

static Session *get_session(const uint8_t *sid, const uint8_t *ipk, int create) {
    pthread_mutex_lock(&g_T);
    Session *s = tab_find_locked(sid);
    if (s) {
        session_ref(s);
        pthread_mutex_unlock(&g_T);
        wait_ready(s);
        pthread_mutex_lock(&s->m);
        int failed = s->failed;
        pthread_mutex_unlock(&s->m);
        if (failed) { session_release(s); return NULL; }
        return s;
    }
    if (!create) { pthread_mutex_unlock(&g_T); return NULL; }
    if (g_total >= g_max_sessions) {
        pthread_mutex_unlock(&g_T);
        logmsg("WARNING", "limite de sesiones alcanzado (%d)", g_max_sessions);
        return NULL;
    }
    if (ip_count(ipk) >= g_max_per_ip) {
        pthread_mutex_unlock(&g_T);
        logmsg("WARNING", "limite de sesiones por IP alcanzado (%d)", g_max_per_ip);
        return NULL;
    }
    s = session_new(sid, ipk);
    if (!s) { pthread_mutex_unlock(&g_T); return NULL; }
    unsigned h = hash_sid(sid);
    s->next = g_tab[h];
    g_tab[h] = s;
    g_total++;
    ip_inc(ipk);
    pthread_mutex_unlock(&g_T);

    int fd = backend_connect();
    int ok = fd >= 0;
    if (ok) {
        s->fd = fd;
        session_ref(s);
        if (start_thread(pump_thread, s) != 0) { session_release(s); ok = 0; }
    } else {
        logmsg("WARNING", "no se pudo conectar al destino SSH (%s): %s", g_backend_txt, strerror(errno));
    }
    pthread_mutex_lock(&s->m);
    s->failed = !ok;
    s->ready = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
    if (!ok) {
        pthread_mutex_lock(&g_T);
        tab_remove_locked(s);
        pthread_mutex_unlock(&g_T);
        session_release(s);
        session_release(s);
        return NULL;
    }
    if (g_verbose) { pthread_mutex_lock(&g_T); int n = g_total; pthread_mutex_unlock(&g_T); logmsg("INFO", "sesion abierta (%d activas)", n); }
    return s;
}

static void *janitor_thread(void *arg) {
    (void)arg;
    int step = g_idle / 2;
    if (step < 1) step = 1;
    if (step > 15) step = 15;
    for (;;) {
        sleep((unsigned)step);
        int64_t now = now_ms();
        Session **list = NULL;
        size_t n = 0, cap = 0;
        pthread_mutex_lock(&g_T);
        for (int b = 0; b < HASH_BUCKETS; b++)
            for (Session *s = g_tab[b]; s; s = s->next) {
                pthread_mutex_lock(&s->m);
                int stale = s->ready && !s->failed && (now - s->last) > (int64_t)g_idle * 1000;
                pthread_mutex_unlock(&s->m);
                if (!stale) continue;
                if (n == cap) {
                    size_t nc = cap ? cap * 2 : 64;
                    Session **nl = realloc(list, nc * sizeof *nl);
                    if (!nl) continue;
                    list = nl; cap = nc;
                }
                session_ref(s);
                list[n++] = s;
            }
        pthread_mutex_unlock(&g_T);
        for (size_t i = 0; i < n; i++) { session_drop(list[i]); session_release(list[i]); }
        free(list);
    }
    return NULL;
}

/* ---- subida (en orden estricto de seq) */

static int session_upload(Session *s, uint64_t seq, uint8_t *data, uint32_t n) {
    pthread_mutex_lock(&s->m);
    s->last = now_ms();
    pthread_mutex_unlock(&s->m);
    if (n == 0) return ST_OK;
    int rc = ST_OK;
    pthread_mutex_lock(&s->um);
    if (seq < s->next_up) { pthread_mutex_unlock(&s->um); return ST_OK; }
    if (seq == s->next_up && s->pend == NULL) {
        s->next_up++;
        if (write_full(s->fd, data, n) < 0) rc = ST_ERR;
        pthread_mutex_unlock(&s->um);
        return rc;
    }
    int have = 0;
    for (Pend *p = s->pend; p; p = p->next) if (p->seq == seq) { have = 1; break; }
    if (!have) {
        if (s->pend_bytes + n > UP_PENDING_MAX) { pthread_mutex_unlock(&s->um); return ST_ERR; }
        Pend *p = malloc(sizeof *p);
        uint8_t *cp = malloc(n);
        if (!p || !cp) { free(p); free(cp); pthread_mutex_unlock(&s->um); return ST_ERR; }
        memcpy(cp, data, n);
        p->seq = seq; p->p = cp; p->n = n; p->next = s->pend;
        s->pend = p;
        s->pend_bytes += n;
    }
    for (;;) {
        Pend **pp = &s->pend;
        while (*pp && (*pp)->seq != s->next_up) pp = &(*pp)->next;
        if (!*pp) break;
        Pend *p = *pp;
        *pp = p->next;
        s->pend_bytes -= p->n;
        s->next_up++;
        if (write_full(s->fd, p->p, p->n) < 0) rc = ST_ERR;
        free(p->p);
        free(p);
        if (rc == ST_ERR) break;
    }
    pthread_mutex_unlock(&s->um);
    return rc;
}

/* ---- bajada con Long-Polling en kernel (pthread_cond_timedwait) */

static int slot_push_locked(Session *s, size_t take) {
    if (s->sl_head + s->sl_n == s->sl_cap) {
        if (s->sl_head > 0) {
            memmove(s->sl, s->sl + s->sl_head, s->sl_n * sizeof *s->sl);
            s->sl_head = 0;
        } else {
            size_t nc = s->sl_cap ? s->sl_cap * 2 : 64;
            Slot *ns = realloc(s->sl, nc * sizeof *ns);
            if (!ns) return -1;
            s->sl = ns;
            s->sl_cap = nc;
        }
    }
    Slot *sl = &s->sl[s->sl_head + s->sl_n];
    sl->p = NULL;
    sl->n = (uint32_t)take;
    if (take) {
        sl->p = malloc(take);
        if (!sl->p) return -1;
        memcpy(sl->p, s->bl + s->bl_head, take);
        s->bl_head += take;
        if (s->bl_head == s->bl_tail) s->bl_head = s->bl_tail = 0;
    }
    s->sl_n++;
    s->filled++;
    return 0;
}

static uint8_t *session_batch(Session *s, uint64_t base, uint32_t chunk, uint32_t count, unsigned crypt_mode, size_t *outn) {
    uint64_t end = base + count;
    pthread_mutex_lock(&s->m);
    s->last = now_ms();
    if (end > s->filled && end - s->filled > MAX_WINDOW_AHEAD) { pthread_mutex_unlock(&s->m); return NULL; }
    if (g_poll_wait_ms > 0 && end > s->filled && s->bl_tail == s->bl_head && !s->closed && !s->dead) {
        int64_t deadline = now_ms() + g_poll_wait_ms;
        while (!(s->filled >= end || s->closed || s->dead || s->bl_tail > s->bl_head))
            if (cond_wait_until(s, deadline)) break;
        s->last = now_ms();
    }
    int changed = 0;
    while (s->filled < end) {
        size_t avail = s->bl_tail - s->bl_head;
        size_t take = avail < chunk ? avail : chunk;
        if (slot_push_locked(s, take) < 0) { pthread_mutex_unlock(&s->m); return NULL; }
        changed = 1;
    }
    if (changed) pthread_cond_broadcast(&s->cv);

    size_t total = 0;
    uint32_t i;
    uint32_t lens[MAX_BATCH];
    for (i = 0; i < count; i++) {
        uint64_t k = base + i;
        lens[i] = (k >= s->sl_base && k < s->filled) ? s->sl[s->sl_head + (size_t)(k - s->sl_base)].n : 0;
        total += 9 + lens[i];
    }
    uint8_t *out = malloc(total);
    if (!out) { pthread_mutex_unlock(&s->m); return NULL; }
    uint8_t *o = out;
    for (i = 0; i < count; i++) {
        uint64_t k = base + i;
        *o++ = ST_DATA;
        put_be32(o, 4 + lens[i]); o += 4;
        put_be32(o, lens[i]); o += 4;
        if (lens[i]) memcpy(o, s->sl[s->sl_head + (size_t)(k - s->sl_base)].p, lens[i]);
        o += lens[i];
    }
    pthread_mutex_unlock(&s->m);

    o = out;
    for (i = 0; i < count; i++) {
        crypt_buf(o + 9, lens[i], s->sid, crypt_mode, base + i, 1);
        o += 9 + lens[i];
    }
    *outn = total;
    return out;
}

static void session_ack(Session *s, uint64_t seq) {
    pthread_mutex_lock(&s->m);
    s->last = now_ms();
    while (s->sl_n > 0 && s->sl_base <= seq) {
        free(s->sl[s->sl_head].p);
        s->sl_head++;
        s->sl_n--;
        s->sl_base++;
    }
    if (s->sl_n == 0) { s->sl_head = 0; s->sl_base = s->filled; }
    pthread_mutex_unlock(&s->m);
}

/* ------------------------------------------------------------------ despacho de peticiones */

static uint8_t *mkreply(uint8_t st, const uint8_t *body, uint32_t n, size_t *outn) {
    uint8_t *o = malloc(5 + (size_t)n);
    if (!o) return NULL;
    o[0] = st;
    put_be32(o + 1, n);
    if (n) memcpy(o + 5, body, n);
    *outn = 5 + (size_t)n;
    return o;
}

static uint8_t *dispatch(unsigned mode, const uint8_t *sid, uint64_t seq, uint8_t *data, uint32_t n,
                         const uint8_t *ipk, size_t *outn) {
    Session *s;
    if (mode == MODE_PROBE) {
        crypt_buf(data, n, sid, MODE_PROBE, 0, 0);
        if (n < 10 || memcmp(data, "BHP1", 4) != 0 || data[4] != 1) return mkreply(ST_ERR, NULL, 0, outn);
        unsigned pm = data[5];
        int32_t param = (int32_t)be32(data + 6);
        uint32_t length = 10;
        if (pm == MODE_DOWNLOAD && param > 10) length = (uint32_t)param;
        if (length > MAX_PROBE_REPLY) return mkreply(ST_ERR, NULL, 0, outn);
        uint8_t *body = malloc(length);
        if (!body) return NULL;
        if (pm == MODE_LANE && param >= BHP2_VERSION) {
            memcpy(body, "BHP2", 4);
            body[4] = BHP2_VERSION;
        } else {
            memcpy(body, "BHP1", 4);
            body[4] = 1;
        }
        body[5] = (uint8_t)pm;
        memcpy(body + 6, data + 6, 4);
        for (uint32_t i = 10; i < length; i++) body[i] = (uint8_t)((i * 31u) & 0xFF);
        crypt_buf(body, length, sid, MODE_PROBE, 0, 1);
        uint8_t *r = mkreply(ST_OK, body, length, outn);
        free(body);
        return r;
    }
    if (mode == MODE_UPLOAD) {
        s = get_session(sid, ipk, 1);
        if (!s) return mkreply(ST_ERR, NULL, 0, outn);
        crypt_buf(data, n, sid, MODE_UPLOAD, seq, 0);
        int st = session_upload(s, seq, data, n);
        session_release(s);
        return mkreply((uint8_t)st, NULL, 0, outn);
    }
    if (mode == MODE_DOWNLOAD) {
        s = get_session(sid, ipk, 0);
        crypt_buf(data, n, sid, MODE_DOWNLOAD, seq, 0);
        if (!s || n < 4) { if (s) session_release(s); return mkreply(ST_ERR, NULL, 0, outn); }
        int32_t chunk = (int32_t)be32(data);
        if (chunk < 1 || chunk > MAX_CHUNK) { session_release(s); return mkreply(ST_ERR, NULL, 0, outn); }
        uint8_t *r = session_batch(s, seq, (uint32_t)chunk, 1, MODE_DOWNLOAD, outn);
        session_release(s);
        return r ? r : mkreply(ST_ERR, NULL, 0, outn);
    }
    if (mode == MODE_BATCH) {
        s = get_session(sid, ipk, 0);
        crypt_buf(data, n, sid, MODE_BATCH, seq, 0);
        if (!s || n < 6) { if (s) session_release(s); return mkreply(ST_ERR, NULL, 0, outn); }
        int32_t chunk = (int32_t)be32(data);
        unsigned count = data[5];
        if (chunk < 1 || chunk > MAX_CHUNK || count < 1 || count > MAX_BATCH) {
            session_release(s);
            return mkreply(ST_ERR, NULL, 0, outn);
        }
        uint8_t *r = session_batch(s, seq, (uint32_t)chunk, count, MODE_BATCH, outn);
        session_release(s);
        return r ? r : mkreply(ST_ERR, NULL, 0, outn);
    }
    if (mode == MODE_ACK) {
        s = get_session(sid, ipk, 0);
        if (!s) return mkreply(ST_ERR, NULL, 0, outn);
        session_ack(s, seq);
        session_release(s);
        return mkreply(ST_OK, NULL, 0, outn);
    }
    return mkreply(ST_ERR, NULL, 0, outn);
}

typedef struct { int fd; uint8_t ipk[16]; } ConnArg;

static void run_upload_lane(int fd, Session *s) {
    uint64_t up_seq = 0;
    uint8_t hdr[4];
    for (;;) {
        if (read_full(fd, hdr, 4, now_ms() + DEFAULT_KEEPALIVE_IDLE_MS) < 0) break;
        pthread_mutex_lock(&s->m);
        s->last = now_ms();
        int dead = s->dead;
        pthread_mutex_unlock(&s->m);
        if (dead) break;

        uint32_t flen = be32(hdr);
        if (flen == 0xFFFFFFFFu) break; /* EOF limpio */
        if (flen == 0) continue;        /* Heartbeat keepalive */
        if (flen > MAX_CHUNK) break;

        uint8_t *buf = malloc(flen);
        if (!buf) break;
        if (read_full(fd, buf, flen, now_ms() + g_request_timeout_ms) < 0) {
            free(buf);
            break;
        }
        crypt_buf(buf, flen, s->sid, MODE_LANE, up_seq++, 0);
        pthread_mutex_lock(&s->um);
        int werr = write_full(s->fd, buf, flen);
        pthread_mutex_unlock(&s->um);
        free(buf);
        if (werr < 0) break;
    }
}

static void run_download_lane(int fd, Session *s, uint32_t max_chunk) {
    if (max_chunk < 512) max_chunk = 512;
    if (max_chunk > MAX_CHUNK) max_chunk = MAX_CHUNK;
    uint8_t *buf = malloc(4 + (size_t)max_chunk);
    if (!buf) return;
    uint64_t dl_seq = 0;

    for (;;) {
        pthread_mutex_lock(&s->m);
        while (s->bl_tail == s->bl_head && !s->closed && !s->dead) {
            int to = cond_wait_until(s, now_ms() + 15000);
            if (to) break;
        }
        s->last = now_ms();
        size_t avail = s->bl_tail - s->bl_head;
        int finished = (s->dead || (s->closed && avail == 0));
        if (finished) {
            pthread_mutex_unlock(&s->m);
            put_be32(buf, 0xFFFFFFFFu);
            write_full(fd, buf, 4);
            break;
        }
        if (avail == 0) {
            pthread_mutex_unlock(&s->m);
            put_be32(buf, 0);
            if (write_full(fd, buf, 4) < 0) break;
            continue;
        }
        size_t take = avail < max_chunk ? avail : max_chunk;
        memcpy(buf + 4, s->bl + s->bl_head, take);
        s->bl_head += take;
        if (s->bl_head == s->bl_tail) s->bl_head = s->bl_tail = 0;
        pthread_mutex_unlock(&s->m);

        put_be32(buf, (uint32_t)take);
        crypt_buf(buf + 4, (uint32_t)take, s->sid, MODE_LANE, dl_seq++, 1);
        if (write_full(fd, buf, 4 + take) < 0) break;
    }
    free(buf);
}

static int handle_lane_conn(int fd, const uint8_t *sid, uint64_t seq, uint8_t *data, uint32_t n, const uint8_t *ipk) {
    if (!data || n < 4 || n > MAX_REQUEST) {
        size_t outn = 0;
        uint8_t *err = mkreply(ST_ERR, NULL, 0, &outn);
        if (err) { write_full(fd, err, outn); free(err); }
        return -1;
    }
    crypt_buf(data, n, sid, MODE_LANE, seq, 0);
    if (memcmp(data, "BLN2", 4) != 0) {
        size_t outn = 0;
        uint8_t *err = mkreply(ST_ERR, NULL, 0, &outn);
        if (err) { write_full(fd, err, outn); free(err); }
        return -1;
    }
    uint32_t chunk_lim = 32768;
    if (n >= 8) chunk_lim = be32(data + 4);

    Session *s = get_session(sid, ipk, 1);
    if (!s) {
        size_t outn = 0;
        uint8_t *err = mkreply(ST_ERR, NULL, 0, &outn);
        if (err) { write_full(fd, err, outn); free(err); }
        return -1;
    }

    size_t outn = 0;
    uint8_t *ok = mkreply(ST_OK, NULL, 0, &outn);
    if (!ok || write_full(fd, ok, outn) < 0) {
        free(ok);
        session_release(s);
        return -1;
    }
    free(ok);

    if (seq == LANE_UPLOAD) {
        run_upload_lane(fd, s);
    } else if (seq == LANE_DOWNLOAD) {
        run_download_lane(fd, s, chunk_lim);
    }
    session_release(s);
    return 0;
}

static void *conn_thread(void *arg) {
    ConnArg ca = *(ConnArg *)arg;
    free(arg);
    int fd = ca.fd;
    for (int nreq = 0; nreq < g_max_requests_per_conn; nreq++) {
        uint8_t head[HEADER];
        int64_t wait_ms = (nreq == 0) ? g_request_timeout_ms : DEFAULT_KEEPALIVE_IDLE_MS;
        if (read_full(fd, head, HEADER, now_ms() + wait_ms) < 0) break;
        unsigned mode = head[0];
        const uint8_t *sid = head + 1;
        uint64_t seq = be64(head + 17);
        uint32_t n = be32(head + 25);
        size_t outn = 0;
        uint8_t *out;
        if (n > MAX_REQUEST) {
            out = mkreply(ST_ERR, NULL, 0, &outn);
            if (out) { write_full(fd, out, outn); free(out); }
            break;
        }
        uint8_t *data = NULL;
        if (n) {
            data = malloc(n);
            if (!data) break;
            if (read_full(fd, data, n, now_ms() + g_request_timeout_ms) < 0) { free(data); break; }
        }
        if (mode == MODE_LANE) {
            handle_lane_conn(fd, sid, seq, data, n, ca.ipk);
            free(data);
            break;
        }
        out = dispatch(mode, sid, seq, data, n, ca.ipk, &outn);
        free(data);
        if (!out) break;
        int bad = write_full(fd, out, outn);
        free(out);
        if (bad) break;
    }
    close(fd);
    __atomic_sub_fetch(&g_conns, 1, __ATOMIC_RELAXED);
    return NULL;
}

static int probe_client(const char *target) {
    char host[128] = "127.0.0.1";
    const char *c = strrchr(target, ':');
    if (!c) { printf("uso: --probe HOST:PUERTO\n"); return 0; }
    if (c > target) { size_t l = (size_t)(c - target); if (l >= sizeof host) l = sizeof host - 1; memcpy(host, target, l); host[l] = 0; }
    struct addrinfo hints = {0}, *ai = NULL;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, c + 1, &hints, &ai) != 0 || !ai) { printf("no se pudo conectar: direccion invalida\n"); return 0; }
    int fd = socket(ai->ai_family, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, ai->ai_addr, ai->ai_addrlen) < 0) { printf("no se pudo conectar: %s\n", strerror(errno)); freeaddrinfo(ai); return 0; }
    freeaddrinfo(ai);
    uint8_t sid[16], plain[10], req[HEADER + 10];
    FILE *ur = fopen("/dev/urandom", "rb");
    if (!ur || fread(sid, 1, 16, ur) != 16) { printf("sin /dev/urandom\n"); close(fd); return 0; }
    fclose(ur);
    memcpy(plain, "BHP1", 4); plain[4] = 1; plain[5] = MODE_BATCH; put_be32(plain + 6, 8);
    crypt_buf(plain, 10, sid, MODE_PROBE, 0, 0);
    req[0] = MODE_PROBE; memcpy(req + 1, sid, 16); memset(req + 17, 0, 8); put_be32(req + 25, 10); memcpy(req + HEADER, plain, 10);
    int64_t dl = now_ms() + 5000;
    uint8_t h[5], body[64];
    if (write_full(fd, req, sizeof req) < 0 || read_full(fd, h, 5, dl) < 0) { printf("el servidor respondio con error o no respondio\n"); close(fd); return 0; }
    uint32_t bn = be32(h + 1);
    if (h[0] != ST_OK || bn != 10 || read_full(fd, body, bn, dl) < 0) { printf("el servidor respondio con error o no respondio\n"); close(fd); return 0; }
    close(fd);
    crypt_buf(body, bn, sid, MODE_PROBE, 0, 1);
    int good = !memcmp(body, "BHP1", 4) && body[4] == 1 && body[5] == MODE_BATCH && be32(body + 6) == 8;
    printf(good ? "sondeo BHP1: OK\n" : "sondeo BHP1: respuesta invalida\n");
    return good;
}

static void ip_key(const struct sockaddr_storage *ss, uint8_t out[16]) {
    memset(out, 0, 16);
    if (ss->ss_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)ss;
        out[10] = out[11] = 0xff;
        memcpy(out + 12, &a->sin_addr, 4);
    } else if (ss->ss_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)ss;
        memcpy(out, &a->sin6_addr, 16);
    }
}

static void *accept_loop(void *arg) {
    int ls = (int)(intptr_t)arg;
    int one = 1;
    for (;;) {
        struct sockaddr_storage ss;
        socklen_t sl = sizeof ss;
        int fd = accept(ls, (struct sockaddr *)&ss, &sl);
        if (fd < 0) {
            if (g_stop) break;
            if (errno == EINTR || errno == ECONNABORTED) continue;
            if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM) { usleep(50000); continue; }
            perror("accept");
            break;
        }
        if (__atomic_add_fetch(&g_conns, 1, __ATOMIC_RELAXED) > g_max_conns) {
            __atomic_sub_fetch(&g_conns, 1, __ATOMIC_RELAXED);
            close(fd);
            continue;
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
        int v = 30; setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &v, sizeof v);
        v = 10; setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &v, sizeof v);
        v = 3; setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &v, sizeof v);
        set_timeouts(fd, 30);
        ConnArg *ca = malloc(sizeof *ca);
        if (!ca) { close(fd); __atomic_sub_fetch(&g_conns, 1, __ATOMIC_RELAXED); continue; }
        ca->fd = fd;
        ip_key(&ss, ca->ipk);
        if (start_thread(conn_thread, ca) != 0) {
            free(ca);
            close(fd);
            __atomic_sub_fetch(&g_conns, 1, __ATOMIC_RELAXED);
        }
    }
    close(ls);
    return NULL;
}

static int parse_duration_seconds(const char *s) {
    if (!s || !*s) return 180;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (v <= 0) return 180;
    if (end && (*end == 'm' || *end == 'M')) return (int)(v * 60);
    if (end && (*end == 'h' || *end == 'H')) return (int)(v * 3600);
    return (int)v;
}

typedef struct {
    char host[128];
    int port;
} ListenSpec;

static int add_listen_spec(ListenSpec *specs, int *nspecs, const char *default_host, const char *token) {
    if (*nspecs >= MAX_LISTENERS || !token || !*token) return 0;
    const char *colon = strrchr(token, ':');
    if (colon) {
        size_t hl = (size_t)(colon - token);
        if (hl == 0) {
            snprintf(specs[*nspecs].host, sizeof specs[*nspecs].host, "%s", default_host);
        } else {
            if (hl >= sizeof specs[*nspecs].host) hl = sizeof specs[*nspecs].host - 1;
            memcpy(specs[*nspecs].host, token, hl);
            specs[*nspecs].host[hl] = 0;
        }
        specs[*nspecs].port = atoi(colon + 1);
    } else {
        int maybe_port = 1;
        for (const char *p = token; *p; p++) {
            if (!isdigit((unsigned char)*p)) { maybe_port = 0; break; }
        }
        if (maybe_port) {
            snprintf(specs[*nspecs].host, sizeof specs[*nspecs].host, "%s", default_host);
            specs[*nspecs].port = atoi(token);
        } else {
            return 0;
        }
    }
    if (specs[*nspecs].port < 1 || specs[*nspecs].port > 65535) return 0;
    for (int i = 0; i < *nspecs; i++) {
        if (specs[i].port == specs[*nspecs].port && !strcmp(specs[i].host, specs[*nspecs].host)) return 1;
    }
    (*nspecs)++;
    return 1;
}

int main(int argc, char **argv) {
    char listen_arg[512] = "0.0.0.0";
    char port_arg[256] = "";
    char backend_host[128] = "127.0.0.1";
    int backend_port = 22;
    char backend_combined[160] = "";
    const char *probe = NULL;
    int i;

    signal(SIGPIPE, SIG_IGN);
    mallopt(M_ARENA_MAX, 2);
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_term;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);
    }

    for (i = 1; i < argc; i++) {
        char *a = argv[i], *eq = strchr(a, '='), *val = NULL;
        char key[64];
        if (a[0] == '-' && eq) {
            size_t l = (size_t)(eq - a);
            if (l >= sizeof key) l = sizeof key - 1;
            memcpy(key, a, l); key[l] = 0; a = key; val = eq + 1;
        }
        /* Normalizar -flag y --flag */
        const char *flag = a;
        if (flag[0] == '-' && flag[1] == '-') flag += 2;
        else if (flag[0] == '-') flag += 1;

#define NEXTVAL() (val ? val : (i + 1 < argc ? argv[++i] : (fprintf(stderr, "falta valor para %s\n", a), exit(2), (char *)0)))
        if (!strcmp(flag, "listen")) snprintf(listen_arg, sizeof listen_arg, "%s", NEXTVAL());
        else if (!strcmp(flag, "port") || !strcmp(flag, "ports")) snprintf(port_arg, sizeof port_arg, "%s", NEXTVAL());
        else if (!strcmp(flag, "backend") || !strcmp(flag, "target")) snprintf(backend_combined, sizeof backend_combined, "%s", NEXTVAL());
        else if (!strcmp(flag, "backend-host")) snprintf(backend_host, sizeof backend_host, "%s", NEXTVAL());
        else if (!strcmp(flag, "backend-port")) backend_port = atoi(NEXTVAL());
        else if (!strcmp(flag, "poll-wait-ms")) { g_poll_wait_ms = atoi(NEXTVAL()); if (g_poll_wait_ms < 0) g_poll_wait_ms = 0; }
        else if (!strcmp(flag, "max-sessions")) g_max_sessions = atoi(NEXTVAL());
        else if (!strcmp(flag, "max-per-ip")) g_max_per_ip = atoi(NEXTVAL());
        else if (!strcmp(flag, "idle") || !strcmp(flag, "session-ttl") || !strcmp(flag, "session-timeout")) {
            g_idle = parse_duration_seconds(NEXTVAL());
        }
        else if (!strcmp(flag, "max-requests-per-conn")) {
            g_max_requests_per_conn = atoi(NEXTVAL());
            if (g_max_requests_per_conn < 1) g_max_requests_per_conn = DEFAULT_MAX_REQUESTS_PER_CONN;
        }
        else if (!strcmp(flag, "request-timeout")) {
            int rt = atoi(NEXTVAL());
            if (rt > 0) g_request_timeout_ms = (rt < 500) ? rt * 1000 : rt;
        }
        else if (!strcmp(flag, "read-wait-ms") || !strcmp(flag, "sequence-wait") ||
                 !strcmp(flag, "bhttp-v2-max-lanes") || !strcmp(flag, "tls-cert") ||
                 !strcmp(flag, "tls-key") || !strcmp(flag, "xhttp-listen")) {
            (void)NEXTVAL(); /* Compatibilidad con scripts previos */
        }
        else if (!strcmp(flag, "probe")) probe = NEXTVAL();
        else if (!strcmp(flag, "self-test")) return self_test(0);
        else if (!strcmp(flag, "v") || !strcmp(flag, "verbose")) g_verbose = 1;
        else if (!strcmp(flag, "h") || !strcmp(flag, "help") || !strcmp(flag, "version") || !strcmp(flag, "V")) {
            printf("CRISDEV BHTTP C Engine v" VERSION "\n");
            return 0;
        }
    }

    if (self_test(1) != 0) return 1;
    if (probe) return probe_client(probe) ? 0 : 1;

    if (!backend_combined[0]) {
        snprintf(backend_combined, sizeof backend_combined, "%s:%d", backend_host, backend_port);
    }

    ListenSpec specs[MAX_LISTENERS];
    int nspecs = 0;
    char base_host[128] = "0.0.0.0";

    if (strchr(listen_arg, ':') || strchr(listen_arg, ',')) {
        char tmp[512];
        snprintf(tmp, sizeof tmp, "%s", listen_arg);
        char *save = NULL;
        for (char *tok = strtok_r(tmp, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
            add_listen_spec(specs, &nspecs, "0.0.0.0", tok);
        }
    } else if (listen_arg[0]) {
        snprintf(base_host, sizeof base_host, "%s", listen_arg);
    }

    if (port_arg[0]) {
        char tmp[256];
        snprintf(tmp, sizeof tmp, "%s", port_arg);
        char *save = NULL;
        for (char *tok = strtok_r(tmp, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
            add_listen_spec(specs, &nspecs, base_host, tok);
        }
    }

    if (nspecs == 0) {
        add_listen_spec(specs, &nspecs, base_host, "8080");
    }

    if (g_max_sessions < 1) g_max_sessions = 4096;
    if (g_max_per_ip < 1) g_max_per_ip = 256;
    if (g_idle < 10) g_idle = 180;

    {
        char host[128] = "127.0.0.1", pt[16];
        const char *c = strrchr(backend_combined, ':');
        if (!c) { fprintf(stderr, "--backend debe ser HOST:PUERTO\n"); return 2; }
        if (c > backend_combined) {
            size_t l = (size_t)(c - backend_combined);
            if (l >= sizeof host) l = sizeof host - 1;
            memcpy(host, backend_combined, l);
            host[l] = 0;
        }
        snprintf(pt, sizeof pt, "%s", c + 1);
        struct addrinfo hints = {0}, *ai = NULL;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(host, pt, &hints, &ai) != 0 || !ai) {
            fprintf(stderr, "destino invalido: %s\n", backend_combined);
            return 2;
        }
        memcpy(&g_backend, ai->ai_addr, ai->ai_addrlen);
        g_backend_len = ai->ai_addrlen;
        freeaddrinfo(ai);
        snprintf(g_backend_txt, sizeof g_backend_txt, "%s", backend_combined);
    }

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    g_max_conns = (long)g_max_sessions * 16 + 1024;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY && (long)rl.rlim_cur > 128 &&
        g_max_conns > (long)rl.rlim_cur - 128)
        g_max_conns = (long)rl.rlim_cur - 128;
    if (g_max_conns < 64) g_max_conns = 64;

    int ls_fds[MAX_LISTENERS];
    int n_ls = 0;
    for (int k = 0; k < nspecs; k++) {
        struct addrinfo hints = {0}, *ai = NULL;
        char ps[16];
        snprintf(ps, sizeof ps, "%d", specs[k].port);
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags = AI_PASSIVE;
        if (getaddrinfo(specs[k].host, ps, &hints, &ai) != 0 || !ai) {
            logmsg("ERROR", "direccion invalida %s:%d", specs[k].host, specs[k].port);
            continue;
        }
        int ls = socket(ai->ai_family, SOCK_STREAM, 0);
        int one = 1;
        if (ls < 0) { freeaddrinfo(ai); continue; }
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#ifdef SO_REUSEPORT
        setsockopt(ls, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
#endif
        if (bind(ls, ai->ai_addr, ai->ai_addrlen) < 0) {
            logmsg("ERROR", "bind %s:%d fallo: %s", specs[k].host, specs[k].port, strerror(errno));
            close(ls);
            freeaddrinfo(ai);
            continue;
        }
        freeaddrinfo(ai);
        if (listen(ls, 4096) < 0) {
            close(ls);
            continue;
        }
        ls_fds[n_ls++] = ls;
        logmsg("INFO", "BHTTP (motor C v" VERSION ", SIMD=%s, poll=%dms, maxReq=%d) escuchando en %s:%d -> %s",
               g_simd == 2 ? "AVX2-x8" : g_simd == 1 ? "SIMD-x4" : "scalar",
               g_poll_wait_ms, g_max_requests_per_conn, specs[k].host, specs[k].port, g_backend_txt);
    }

    if (n_ls == 0) {
        logmsg("ERROR", "No se pudo abrir ningun puerto de escucha BHTTP");
        return 1;
    }

    if (start_thread(janitor_thread, NULL) != 0) {
        fprintf(stderr, "no pude crear el hilo de limpieza\n");
        return 1;
    }

    for (int k = 1; k < n_ls; k++) {
        start_thread(accept_loop, (void *)(intptr_t)ls_fds[k]);
    }
    accept_loop((void *)(intptr_t)ls_fds[0]);
    logmsg("INFO", "BHTTP detenido");
    return 0;
}

