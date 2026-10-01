#include <stdlib.h>

int main(void)
{
    void *a;
    void *b;
    void *c;

    a = malloc(0x20);
    b = malloc(0x30);
    c = malloc(0x40);

    free(b);

    return 0;
}
