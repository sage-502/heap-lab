#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define COUNT 10000

pthread_barrier_t barrier;

void *worker(void *arg)
{
    void *p;

    pthread_barrier_wait(&barrier);

    for (int i = 0; i < COUNT; i++) {
        p = malloc(0x100);
        if (p == NULL)
            exit(1);
    }

    printf("worker last chunk = %p\n", p);

    pthread_barrier_wait(&barrier);

    return NULL;
}

int main(void)
{
    pthread_t tid;
    void *p;

    pthread_barrier_init(&barrier, NULL, 2);

    pthread_create(&tid, NULL, worker, NULL);

    pthread_barrier_wait(&barrier);

    for (int i = 0; i < COUNT; i++) {
        p = malloc(0x100);
        if (p == NULL)
            exit(1);
    }

    printf("main last chunk   = %p\n", p);

    pthread_barrier_wait(&barrier);

    pthread_join(tid, NULL);

    return 0;
}
