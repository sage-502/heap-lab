#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    char *p1;
    int *p2;
    char *p3;

    // malloc
    p1 = malloc(0x20);
    if (p1 == NULL) {
        perror("malloc");
        return 1;
    }

    strcpy(p1, "hello heap");
    printf("p1 = %p, data = %s\n", (void *)p1, p1);

    // calloc
    p2 = calloc(8, sizeof(int));
    if (p2 == NULL) {
        perror("calloc");
        free(p1);
        return 1;
    }

    printf("p2 = %p\n", (void *)p2);
    printf("p2[0] = %d\n", p2[0]);

    // realloc
    p3 = realloc(p1, 0x40);
    if (p3 == NULL) {
        perror("realloc");
        free(p1);
        free(p2);
        return 1;
    }

    p1 = p3;

    strcat(p1, " - realloc");
    printf("p1 after realloc = %p, data = %s\n",
           (void *)p1, p1);

    // free
    free(p1);
    free(p2);

    return 0;
}
