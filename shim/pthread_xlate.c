/* pthread_mutexattr_t width translator, scoped to runtime.node via DT_NEEDED.
 *
 * ROOT CAUSE of the 1.0.61+ "unfixable" Termux crash:
 *
 *   musl   pthread_mutexattr_t = unsigned  (4 bytes)
 *   bionic pthread_mutexattr_t = long      (8 bytes)   <-- twice as wide
 *
 * runtime.node is musl-built, so it reserves only 4 bytes for a
 * pthread_mutexattr_t. In the faulting singleton-init the attr lives on the
 * stack at sp+0xc, IMMEDIATELY BELOW the callee-saved spill slot written by
 * `stp x20, x19, [sp, #0x10]`.
 *
 * Bionic then writes 8 bytes through that pointer:
 *   pthread_mutexattr_init()    -> *attr = 0        (zeroes 8 bytes)
 *   pthread_mutexattr_destroy() -> *attr = -1       (writes 8x 0xFF)
 *
 * The upper 4 bytes land on the saved x19/x20, producing the observed
 * corruption: a callee-saved register returning as 0x..ffffffff. Which
 * register gets hit varies with the frame layout of the caller, which is
 * exactly the run-to-run variation seen under ptrace.
 *
 * Fix: keep a real 8-byte bionic attr in a local, and only ever read/write the
 * low 4 bytes at the musl-sized address the caller gave us. Bionic only uses
 * low bits (type mask 0xf, pshared, protocol), so 32 bits round-trips safely.
 *
 * As with libgai_xlate.so we do NOT export these via LD_PRELOAD. This .so is
 * add-needed ONLY to runtime.node (ordered before libc.so) and the runtime's
 * .dynstr import names are renamed in place to the capitalised spellings, so
 * ONLY runtime.node is affected. node's own libuv pthread calls stay bound to
 * bionic, untouched.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

typedef int (*mai_fn)(pthread_mutexattr_t *);
typedef int (*mas_fn)(pthread_mutexattr_t *, int);
typedef int (*mad_fn)(pthread_mutexattr_t *);
typedef int (*mi_fn)(pthread_mutex_t *, const pthread_mutexattr_t *);

static mai_fn real_init;
static mas_fn real_settype;
static mad_fn real_destroy;
static mi_fn  real_mutex_init;

static void resolve_real(void) {
    if (real_init && real_settype && real_destroy && real_mutex_init) return;
    void *libc = dlopen("libc.so", RTLD_NOW | RTLD_GLOBAL);
    if (!libc) libc = RTLD_DEFAULT;
    real_init        = (mai_fn)dlsym(libc, "pthread_mutexattr_init");
    real_settype     = (mas_fn)dlsym(libc, "pthread_mutexattr_settype");
    real_destroy     = (mad_fn)dlsym(libc, "pthread_mutexattr_destroy");
    real_mutex_init  = (mi_fn) dlsym(libc, "pthread_mutex_init");
}

/* musl-side attr is exactly 4 bytes. Never touch a 5th. */
static inline pthread_mutexattr_t widen(const void *musl4) {
    uint32_t lo;
    memcpy(&lo, musl4, 4);
    return (pthread_mutexattr_t)(long)(int32_t)lo;
}
static inline void narrow(void *musl4, pthread_mutexattr_t wide) {
    uint32_t lo = (uint32_t)(long)wide;
    memcpy(musl4, &lo, 4);
}

int Pthread_mutexattr_init(void *musl_attr) {
    resolve_real();
    if (!real_init) return 38; /* ENOSYS */
    pthread_mutexattr_t wide = 0;
    int rc = real_init(&wide);
    if (musl_attr) narrow(musl_attr, wide);
    return rc;
}

int Pthread_mutexattr_settype(void *musl_attr, int type) {
    resolve_real();
    if (!real_settype) return 38;
    if (!musl_attr) return 22; /* EINVAL */
    pthread_mutexattr_t wide = widen(musl_attr);
    int rc = real_settype(&wide, type);
    narrow(musl_attr, wide);
    return rc;
}

int Pthread_mutexattr_destroy(void *musl_attr) {
    resolve_real();
    if (!real_destroy) return 38;
    if (!musl_attr) return 22;
    pthread_mutexattr_t wide = widen(musl_attr);
    int rc = real_destroy(&wide);
    /* bionic sets wide = -1 here; write back only the low 4 bytes so the
     * adjacent saved x19/x20 on the caller's stack survive. */
    narrow(musl_attr, wide);
    return rc;
}

/* pthread_mutex_t itself is 40 bytes on BOTH libcs, so the mutex is fine; only
 * the attr pointer needs widening before bionic reads 8 bytes from it. */
int Pthread_mutex_init(pthread_mutex_t *m, const void *musl_attr) {
    resolve_real();
    if (!real_mutex_init) return 38;
    if (!musl_attr) return real_mutex_init(m, NULL);
    pthread_mutexattr_t wide = widen(musl_attr);
    return real_mutex_init(m, &wide);
}
