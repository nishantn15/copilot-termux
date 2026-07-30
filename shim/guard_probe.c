#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <pthread.h>

int main(void){
    long ps = sysconf(_SC_PAGESIZE);
    /* two pages; second one becomes PROT_NONE */
    char *base = mmap(NULL, ps*2, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) { perror("mmap"); return 1; }
    if (mprotect(base+ps, ps, PROT_NONE)) { perror("mprotect"); return 1; }

    void *h = dlopen("./libpthread_xlate.so", RTLD_NOW);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    int (*I)(void*)      = dlsym(h,"Pthread_mutexattr_init");
    int (*S)(void*,int)  = dlsym(h,"Pthread_mutexattr_settype");
    int (*D)(void*)      = dlsym(h,"Pthread_mutexattr_destroy");
    int (*M)(void*,const void*) = dlsym(h,"Pthread_mutex_init");
    if(!I||!S||!D||!M){ printf("dlsym missing\n"); return 1; }

    /* attr occupies the FINAL 4 bytes of the writable page.
       Any 5th byte written -> SIGSEGV into the guard page. */
    void *attr = base + ps - 4;
    printf("attr=%p  guard starts %p (aligned %% 8 = %ld)\n",
           attr, base+ps, (long)((unsigned long)attr % 8));
    fflush(stdout);

    int rc;
    rc = I(attr);           printf("init    rc=%d slot=%08x\n", rc, *(unsigned*)attr);
    rc = S(attr, PTHREAD_MUTEX_RECURSIVE);
                            printf("settype rc=%d slot=%08x\n", rc, *(unsigned*)attr);
    pthread_mutex_t m;
    rc = M(&m, attr);       printf("mtxinit rc=%d slot=%08x\n", rc, *(unsigned*)attr);
    rc = D(attr);           printf("destroy rc=%d slot=%08x\n", rc, *(unsigned*)attr);

    /* prove the recursive type actually survived translation */
    pthread_mutex_t m2; void *a2 = base + ps - 4;
    I(a2); S(a2, PTHREAD_MUTEX_RECURSIVE); M(&m2, a2); D(a2);
    if (pthread_mutex_lock(&m2)==0 && pthread_mutex_lock(&m2)==0) {
        printf("RECURSIVE SEMANTICS: OK (double lock succeeded)\n");
        pthread_mutex_unlock(&m2); pthread_mutex_unlock(&m2);
    } else {
        printf("RECURSIVE SEMANTICS: FAIL (type bits lost in translation)\n");
    }

    /* also exercise a 4-mod-8 misaligned slot mid-page */
    void *a3 = base + 12;
    I(a3); S(a3, PTHREAD_MUTEX_ERRORCHECK); D(a3);
    printf("misaligned(+12) survived, slot=%08x\n", *(unsigned*)a3);

    printf("NO GUARD-PAGE FAULT: translator wrote at most 4 bytes\n");
    return 0;
}
