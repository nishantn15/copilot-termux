/* Termux/Android bionic compatibility shim for @github/copilot's
 * prebuilds/linux-arm64/runtime.node (glibc-linked Rust napi-rs binary).
 *
 * Strategy: forward glibc-specific symbol names to bionic equivalents.
 * Statically links libunwind.a to provide _Unwind_* symbols.
 */
#define _GNU_SOURCE
#include <string.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <ctype.h>
#include <wctype.h>

/* --- libc forwarders --- */

int bcmp(const void *s1, const void *s2, size_t n) {
    return memcmp(s1, s2, n);
}

/* bionic's strerror_r is GNU-style (returns char*); XSI semantics (int) needed. */
#include <errno.h>
int __xpg_strerror_r(int errnum, char *buf, size_t buflen) {
    if (buflen == 0) return ERANGE;
    char *msg = strerror(errnum);
    if (!msg) { buf[0] = '\0'; return EINVAL; }
    size_t len = strlen(msg);
    if (len >= buflen) {
        memcpy(buf, msg, buflen - 1);
        buf[buflen - 1] = '\0';
        return ERANGE;
    }
    memcpy(buf, msg, len + 1);
    return 0;
}

extern int *__errno(void);
int *__errno_location(void) {
    return __errno();
}

/* glibc-2.17 stat wrappers. _STAT_VER ignored — bionic struct stat is compatible enough for Rust's libc crate.*/
int __xstat64(int ver, const char *path, struct stat *buf)             { (void)ver; return stat(path, buf); }
int __lxstat64(int ver, const char *path, struct stat *buf)            { (void)ver; return lstat(path, buf); }
int __fxstat64(int ver, int fd, struct stat *buf)                      { (void)ver; return fstat(fd, buf); }
int __fxstatat64(int ver, int fd, const char *path, struct stat *buf, int flag) {
    (void)ver; return fstatat(fd, path, buf, flag);
}

/* glibc ctype: __ctype_b_loc returns a per-thread pointer to a 384-entry table
 * indexed by (signed char + 128). Each entry is a bitmask of character classes.
 * Populated at module load via __attribute__((constructor)) so isalpha/isspace/
 * isdigit/etc. behave correctly when a glibc-built native module is dlopen'd
 * into a bionic process.
 *
 * Glibc mask layout (little-endian unsigned short, see bits/types/__ctype_b.h):
 *   _ISupper=0x0100, _ISlower=0x0200, _ISalpha=0x0400, _ISdigit=0x0800,
 *   _ISxdigit=0x1000, _ISspace=0x2000, _ISprint=0x4000, _ISgraph=0x8000,
 *   _ISblank=0x0001, _IScntrl=0x0002, _ISpunct=0x0004, _ISalnum=0x0008
 */
#define _IS_upper  0x0100
#define _IS_lower  0x0200
#define _IS_alpha  0x0400
#define _IS_digit  0x0800
#define _IS_xdigit 0x1000
#define _IS_space  0x2000
#define _IS_print  0x4000
#define _IS_graph  0x8000
#define _IS_blank  0x0001
#define _IS_cntrl  0x0002
#define _IS_punct  0x0004
#define _IS_alnum  0x0008

static unsigned short __ctype_b_table[384];
static __thread const unsigned short *__ctype_b_ptr = NULL;

__attribute__((constructor))
static void __ctype_b_init(void) {
    unsigned short *t = &__ctype_b_table[128];  /* zero-based for the (c+128) index */
    for (int c = 0; c < 128; c++) {
        unsigned short m = 0;
        if (c < 0x20 || c == 0x7f)            m |= _IS_cntrl;
        if (c == ' ' || c == '\t')            m |= _IS_blank;
        if (c == ' ' || (c >= '\t' && c <= '\r')) m |= _IS_space;
        if (c >= '0' && c <= '9')             m |= _IS_digit | _IS_xdigit | _IS_alnum;
        if (c >= 'A' && c <= 'F')             m |= _IS_xdigit;
        if (c >= 'a' && c <= 'f')             m |= _IS_xdigit;
        if (c >= 'A' && c <= 'Z')             m |= _IS_upper | _IS_alpha | _IS_alnum;
        if (c >= 'a' && c <= 'z')             m |= _IS_lower | _IS_alpha | _IS_alnum;
        if (c > 0x20 && c != 0x7f && !(m & (_IS_alnum | _IS_cntrl))) m |= _IS_punct;
        if (c > 0x20 && c != 0x7f)            m |= _IS_graph;
        if (c >= 0x20 && c != 0x7f)           m |= _IS_print;
        t[c] = m;
    }
    /* (c+128) for c in [-128, -1] stays zero — non-ASCII bytes are class-less,
       matching glibc's default "C" locale behavior. */
    __ctype_b_ptr = t;
}

/* Per-thread pointer initialization is lazy: the constructor sets it on the
 * thread that loaded the .so; new threads get NULL until they call __ctype_b_loc.
 * Glibc's pthread_create hook usually does this, but we replicate it here. */
const unsigned short **__ctype_b_loc(void) {
    if (__ctype_b_ptr == NULL) __ctype_b_ptr = &__ctype_b_table[128];
    return (const unsigned short **)&__ctype_b_ptr;
}

/* glibc __assert_fail → bionic __assert2 */
extern void __assert2(const char *file, int line, const char *func, const char *expr) __attribute__((noreturn));
__attribute__((noreturn))
void __assert_fail(const char *expr, const char *file, unsigned int line, const char *func) {
    __assert2(file, (int)line, func ? func : "?", expr);
}

/* __cxa_thread_atexit_impl: bionic has it in libc since API 26; but the SONAME differs.
 * Provide a forwarder in case the dynamic linker fails to find it under the glibc name. */
extern int __cxa_thread_atexit_impl(void (*func)(void *), void *arg, void *dso_handle) __attribute__((weak));
/* The shim doesn't override if bionic already exports it — weak ref above. */

