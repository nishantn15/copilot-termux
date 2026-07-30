#include <stdio.h>
#include <unistd.h>
#include <sys/mman.h>
#include <pthread.h>
int main(void){
    long ps=sysconf(_SC_PAGESIZE);
    char *b=mmap(NULL,ps*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    mprotect(b+ps,ps,PROT_NONE);
    void *attr=b+ps-4;
    printf("calling REAL bionic pthread_mutexattr_init on 4-byte page-end slot %p\n",attr);
    fflush(stdout);
    pthread_mutexattr_init((pthread_mutexattr_t*)attr);   /* writes 8 bytes */
    printf("returned without fault (unexpected)\n");
    return 0;
}
