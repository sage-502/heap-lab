#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    // 준비: tcache 및 heap 초기화
    void *warmup = malloc(0x10);

    // 1. top chunk에서 새 chunk 할당
    void *a = malloc(0x20);

    // 2. 해제 후 동일 크기로 재할당
    free(a);
    void *b = malloc(0x20);

    // 3. b를 해제하지 않고 추가 할당
    void *c = malloc(0x20);

    printf("a = %p\n", a);
    printf("b = %p\n", b);
    printf("c = %p\n", c);

    free(b);
    free(c);
    free(warmup);

    return 0;
}
