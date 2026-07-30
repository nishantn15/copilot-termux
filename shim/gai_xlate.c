/* getaddrinfo/freeaddrinfo layout translator, scoped to runtime.node via DT_NEEDED.
 *
 * runtime.node is musl-built and reads struct addrinfo with MUSL field order
 * (ai_addr @0x18, ai_canonname @0x20). Bionic's getaddrinfo returns BIONIC order
 * (ai_canonname @0x18, ai_addr @0x20). The two are otherwise identical (size 0x30).
 * A musl consumer reading a bionic result treats ai_canonname(NULL) as ai_addr and
 * NULL-derefs sa_family -> SIGSEGV. We rebuild the list in musl order.
 *
 * We intentionally do NOT export these via LD_PRELOAD. This .so is add-needed ONLY
 * to runtime.node (ordered before libc.so), so ONLY runtime.node's calls translate.
 * node's own libuv/c-ares getaddrinfo/freeaddrinfo remain bound to bionic, untouched.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>


/* Bionic addrinfo layout (what the real resolver returns). */
struct bionic_ai {
    int ai_flags;         /* 0x00 */
    int ai_family;        /* 0x04 */
    int ai_socktype;      /* 0x08 */
    int ai_protocol;      /* 0x0c */
    unsigned ai_addrlen;  /* 0x10 */
    char *ai_canonname;   /* 0x18  <-- bionic */
    void *ai_addr;        /* 0x20  <-- bionic */
    struct bionic_ai *ai_next; /* 0x28 */
};

/* Musl addrinfo layout (what runtime.node expects). */
struct musl_ai {
    int ai_flags;         /* 0x00 */
    int ai_family;        /* 0x04 */
    int ai_socktype;      /* 0x08 */
    int ai_protocol;      /* 0x0c */
    unsigned ai_addrlen;  /* 0x10 */
    void *ai_addr;        /* 0x18  <-- musl */
    char *ai_canonname;   /* 0x20  <-- musl */
    struct musl_ai *ai_next; /* 0x28 */
};

/* Resolve the REAL bionic getaddrinfo/freeaddrinfo at first use. We can't use
 * RTLD_NEXT reliably from an add-needed lib, so dlopen libc explicitly. */
typedef int  (*gai_fn)(const char*, const char*, const void*, struct bionic_ai**);
typedef void (*fai_fn)(struct bionic_ai*);
static gai_fn real_gai;
static fai_fn real_fai;

static void resolve_real(void) {
    if (real_gai && real_fai) return;
    void *libc = dlopen("libc.so", RTLD_NOW | RTLD_GLOBAL);
    if (!libc) libc = RTLD_DEFAULT;
    real_gai = (gai_fn)dlsym(libc, "getaddrinfo");
    real_fai = (fai_fn)dlsym(libc, "freeaddrinfo");
}

int Getaddrinfo(const char *node, const char *service,
                const void *hints, struct musl_ai **res) {
    resolve_real();
    if (!real_gai) return -11; /* EAI_SYSTEM-ish */
    struct bionic_ai *braw = NULL;
    int rc = real_gai(node, service, hints, &braw);
    if (rc != 0 || !braw) { *res = NULL; return rc; }

    /* Rebuild the whole list in musl layout, deep-copying sockaddrs and canonname
     * so we can free our copy independently of the bionic list. */
    struct musl_ai *head = NULL, *tail = NULL;
    for (struct bionic_ai *b = braw; b; b = b->ai_next) {
        struct musl_ai *m = (struct musl_ai *)calloc(1, sizeof(struct musl_ai));
        if (!m) break;
        m->ai_flags    = b->ai_flags;
        m->ai_family   = b->ai_family;
        m->ai_socktype = b->ai_socktype;
        m->ai_protocol = b->ai_protocol;
        m->ai_addrlen  = b->ai_addrlen;
        if (b->ai_addr && b->ai_addrlen) {
            m->ai_addr = malloc(b->ai_addrlen);
            if (m->ai_addr) memcpy(m->ai_addr, b->ai_addr, b->ai_addrlen);
        }
        if (b->ai_canonname) m->ai_canonname = strdup(b->ai_canonname);
        m->ai_next = NULL;
        if (!head) head = m; else tail->ai_next = m;
        tail = m;
    }
    real_fai(braw);       /* free the bionic list; we handed out our copy */
    *res = head;
    return 0;
}

void Freeaddrinfo(struct musl_ai *res) {
    while (res) {
        struct musl_ai *n = res->ai_next;
        if (res->ai_addr) free(res->ai_addr);
        if (res->ai_canonname) free(res->ai_canonname);
        free(res);
        res = n;
    }
}
