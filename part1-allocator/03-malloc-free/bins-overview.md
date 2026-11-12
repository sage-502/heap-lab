# bins-overview

glibc malloc은 해제된 chunk를 재사용하기 위해 여러 종류의 free list와 bin을 사용한다.

이 문서에서는 glibc malloc이 free chunk를 관리하는 이유와 각 bin의 역할, 그리고 `malloc_state`에서 bin을 관리하는 구조에 대해 알아본다.

각 bin의 구체적인 삽입·제거 과정과 내부 동작은 이후 개별 실습에서 다룬다.

본 문서의 기준 환경은 다음과 같다.

- Ubuntu 20.04
- glibc 2.31
- x86-64
- 64bit

---

## 1. Free chunk 관리

### 1.1 Free chunk의 재사용

`malloc()`으로 할당받은 메모리를 `free()`하면 해당 메모리는 allocator에 반환된다.

하지만 `free()`가 호출되었다고 해서 메모리 영역 자체가 즉시 사라지는 것은 아니다.

allocator는 반환받은 chunk를 이후 `malloc()` 요청에서 다시 사용할 수 있다.

예를 들어 다음 코드를 보자.

```c
void *a = malloc(0x20);
free(a);

void *b = malloc(0x20);
```

`a`가 가리키던 chunk는 `free(a)` 이후 재사용 가능한 상태가 된다.

따라서 `malloc(0x20)`을 다시 호출했을 때 새로운 메모리를 확보하는 대신 기존 chunk를 재사용할 수 있다.

단, 항상 같은 주소가 반환되는 것은 아니다. 실제 재사용 여부는 allocator의 상태와 할당 경로에 따라 결정된다.

### 1.2 Free list가 필요한 이유

프로그램이 여러 chunk를 할당하고 해제하면 heap에는 재사용 가능한 chunk들이 생긴다.

```text
heap

+-------------------+
| allocated chunk A |
+-------------------+
| free chunk B      |
+-------------------+
| allocated chunk C |
+-------------------+
| free chunk D      |
+-------------------+
| top chunk         |
+-------------------+
```

allocator는 어떤 chunk가 재사용 가능한 상태인지 관리해야 한다.

이를 위해 사용할 수 있는 자료구조가 **free list**이다.

```text
free list
    |
    v
free chunk B
    |
    v
free chunk D
```

실제 chunk들은 heap의 원래 위치에 존재하며, 연결 리스트의 포인터를 이용해 서로 연결된다.

즉, free list에 chunk를 넣는다고 해서 chunk 자체가 새로운 메모리 영역으로 이동하는 것은 아니다.

### 1.3 하나의 free list만 사용한다면?

모든 free chunk를 하나의 리스트에서 관리한다고 가정하자.

```text
free list
    |
    v
 [0x30] -> [0x410] -> [0x50] -> [0x100] -> NULL
```

새로운 메모리 할당 요청이 들어오면 allocator는 요청을 만족할 수 있는 chunk를 찾아야 한다.

하지만 하나의 리스트에서 다양한 크기의 chunk를 관리하면 다음과 같은 문제가 발생할 수 있다.

- 적절한 크기의 chunk를 찾기 위해 여러 노드를 탐색해야 할 수 있다.
- 요청보다 큰 chunk를 사용하는 경우 메모리 분할이나 낭비가 발생할 수 있다.
- 인접한 free chunk를 병합하는 과정에 추가적인 처리 비용이 필요할 수 있다.
- 멀티스레드 환경에서 공유 자료구조에 대한 lock 경합이 발생할 수 있다.

이러한 문제는 자료구조와 탐색 알고리즘에 따라 달라지므로, free list가 하나라는 이유만으로 반드시 비효율적인 것은 아니다.

glibc malloc은 다양한 크기와 상황의 메모리 요청을 효율적으로 처리하기 위해 여러 관리 구조를 사용한다.

---

## 2. Bin

### 2.1 Bin이란?

**Bin은 allocator가 재사용 가능한 free chunk를 관리하기 위한 자료구조이다.**

glibc malloc은 chunk의 크기와 관리 목적에 따라 여러 종류의 bin을 사용한다.

대표적인 구조는 다음과 같다.

- tcache
- fastbin
- unsorted bin
- smallbin
- largebin

이 구조들은 모두 free chunk의 재사용과 관련되어 있지만, 관리 방식과 목적에는 차이가 있다.

### 2.2 여러 bin을 사용하는 이유

glibc malloc이 해결해야 하는 문제는 크게 다음과 같다.

1. 할당과 해제에 필요한 처리 시간을 줄이는 것
2. 재사용할 chunk의 탐색 비용을 줄이는 것
3. 메모리 단편화를 줄이는 것
4. 멀티스레드 환경에서 lock 경합을 줄이는 것

이러한 목표는 서로 충돌할 수 있다.

예를 들어 인접한 free chunk를 즉시 병합하면 메모리 단편화를 줄이는 데 도움이 될 수 있지만, 그만큼 해제 과정에서 추가적인 작업이 필요하다.

반대로 작은 chunk를 병합하지 않고 빠르게 관리하면 해제와 재사용이 빨라질 수 있지만, 병합이 나중으로 미뤄질 수 있다.

glibc malloc은 이러한 특성을 고려하여 서로 다른 관리 정책을 가진 여러 bin을 사용한다.

### 2.3 각 bin의 역할

| 구조 | 주요 역할 |
|---|---|
| tcache | 스레드별로 free chunk를 캐싱하여 빠르게 재사용 |
| fastbin | 작은 chunk를 즉시 병합하지 않고 빠르게 관리 |
| unsorted bin | 해제되거나 분할된 chunk를 크기별 bin으로 분류하기 전에 임시로 관리 |
| smallbin | 동일한 크기의 free chunk를 크기별로 관리 |
| largebin | 비교적 큰 free chunk를 크기 범위별로 관리 |

**tcache와 fastbin은 빠른 재사용에 중점을 두며, 일반 bin은 크기별 탐색과 메모리 재사용을 위한 구조를 제공한다.**

단, 실제 `malloc()`이 bin을 확인하는 순서와 각 bin으로 chunk가 들어가는 조건은 단순히 이 표만으로 결정되지 않는다.

구체적인 분기 과정은 `malloc-free`에서 다룬다.

---

## 3. malloc_state와 bin

### 3.1 malloc_state의 관련 필드

이전에 살펴본 `malloc_state` 구조체에는 free chunk를 관리하기 위한 여러 필드가 존재한다.

glibc 2.31의 `malloc.c`에서 관련 부분만 가져오면 다음과 같다.

```c
struct malloc_state
{
  /* Set if the fastbin chunks contain recently inserted free blocks. */
  int have_fastchunks;

  /* Fastbins */
  mfastbinptr fastbinsY[NFASTBINS];

  /* Base of the topmost chunk -- not otherwise kept in a bin */
  mchunkptr top;

  /* The remainder from the most recent split of a small request */
  mchunkptr last_remainder;

  /* Normal bins packed as described above */
  mchunkptr bins[NBINS * 2 - 2];

  /* Bitmap of bins */
  unsigned int binmap[BINMAPSIZE];

  /* ... */
};
```

각 필드는 다음과 같은 역할을 한다.

| 필드 | 역할 |
|---|---|
| `have_fastchunks` | fastbin에 최근 삽입된 chunk가 존재할 가능성을 나타내는 상태값 |
| `fastbinsY` | fastbin 연결 리스트의 head를 저장하는 배열 |
| `top` | top chunk를 가리키는 포인터 |
| `last_remainder` | small request 처리 과정에서 발생한 remainder와 관련된 포인터 |
| `bins` | unsorted bin, smallbin, largebin을 관리하는 배열 |
| `binmap` | 일반 bin 탐색을 최적화하기 위한 비트맵 |

여기서 `fastbinsY`와 `bins`는 별도의 배열로 존재한다.

또한 `top`, `last_remainder`는 일반적인 bin 배열과 구분되는 포인터이다.

### 3.2 top chunk

`top`은 현재 arena의 top chunk를 가리킨다.

```c
mchunkptr top;
```

top chunk는 arena의 끝부분에 존재하는 가용 메모리 영역이다.

```text
arena
  |
  | top
  v
+---------------------------+
|         top chunk         |
+---------------------------+
```

allocator는 적절한 free chunk를 찾지 못했을 때 top chunk를 분할하여 새로운 chunk를 할당할 수 있다.

```text
Before

+---------------------------+
|         top chunk         |
+---------------------------+


After

+------------+--------------+
| allocated  |   new top    |
+------------+--------------+
             ^
             |
            top
```

top chunk는 재사용 가능한 공간이지만 일반적인 bin에 포함되지 않는다.

### 3.3 last_remainder

```c
mchunkptr last_remainder;
```

`last_remainder`는 작은 메모리 요청을 처리하면서 chunk를 분할했을 때 남은 remainder와 관련된 포인터이다.

특정한 분할 과정에서 생성된 remainder를 추적하여 이후 작은 요청에 재사용할 수 있도록 한다.

단, 모든 chunk 분할이 `last_remainder`를 갱신하는 것은 아니다.

구체적인 사용 조건은 `_int_malloc()`의 동작을 분석할 때 살펴본다.

---

## 4. Fastbin과 일반 bin

### 4.1 fastbinsY

```c
mfastbinptr fastbinsY[NFASTBINS];
```

`fastbinsY`는 fastbin을 관리하기 위한 배열이다.

각 원소는 특정 크기 클래스에 해당하는 fastbin 연결 리스트의 head 역할을 한다.

fastbin은 단일 연결 리스트를 사용하며, chunk 내부의 `fd` 필드로 다음 chunk를 연결한다.

```text
fastbinsY[index]
       |
       v
   chunk C
       |
       | fd
       v
   chunk B
       |
       | fd
       v
   chunk A
       |
       v
      NULL
```

fastbin은 LIFO(Last In, First Out) 방식으로 chunk를 관리한다.

따라서 가장 나중에 삽입한 chunk를 먼저 꺼내 재사용하는 구조이다.

또한 fastbin에 chunk를 삽입할 때는 일반적인 인접 chunk 병합을 즉시 수행하지 않는다.

이러한 방식은 작은 chunk의 해제와 재사용에 필요한 처리 비용을 줄이는 데 도움이 된다.

### 4.2 have_fastchunks

```c
int have_fastchunks;
```

`have_fastchunks`는 fastbin에 최근 삽입된 chunk가 존재할 가능성을 나타내는 상태값이다.

이 값은 fastbin에 들어 있는 chunk의 개수를 나타내지 않는다.

또한 정확한 개수나 목록을 저장하는 필드도 아니다.

allocator는 이 값을 이용해 fastbin에 대한 consolidation 처리가 필요할 가능성을 판단할 수 있다.

여기서 consolidation은 인접한 free chunk를 병합하는 작업을 의미한다.

### 4.3 일반 bin

```c
mchunkptr bins[NBINS * 2 - 2];
```

`bins`는 unsorted bin, smallbin, largebin을 관리하는 배열이다.

fastbin과 달리 일반 bin은 기본적으로 `fd`, `bk`를 사용하는 원형 이중 연결 리스트로 구성된다.

```text
           fd 방향
              →
bin head <-> chunk A <-> chunk B
    ↑                       |
    └───────────────────────┘
```

리스트의 각 노드는 heap에 존재하는 free chunk이다.

`bins[]`는 이러한 리스트의 head를 표현하기 위한 공간으로 사용된다.

---

## 5. bins 배열의 구조

### 5.1 bins 배열의 크기

glibc 2.31에서는 다음과 같이 정의되어 있다.

```c
#define NBINS 128
```

따라서 `bins` 배열은 다음 크기를 가진다.

```c
mchunkptr bins[NBINS * 2 - 2];
```

```text
128 * 2 - 2 = 254
```

즉, 254개의 포인터 원소를 가진 배열이다.

하지만 254개의 독립적인 bin이 존재한다는 의미는 아니다.

일반 bin은 `fd`, `bk` 포인터 쌍을 이용해 관리되기 때문이다.

논리적으로는 다음과 같이 구성된다.

```text
bins[0]   → bin 1의 fd
bins[1]   → bin 1의 bk

bins[2]   → bin 2의 fd
bins[3]   → bin 2의 bk

bins[4]   → bin 3의 fd
bins[5]   → bin 3의 bk

...

bins[252] → bin 127의 fd
bins[253] → bin 127의 bk
```

따라서 배열 전체는 127개의 논리적 bin head에 해당한다.

bin 번호 0은 사용하지 않으므로 포인터 쌍이 존재하지 않는다.

### 5.2 Bin 번호와 종류

glibc 2.31의 x86-64 환경에서 일반 bin의 논리적 번호는 다음과 같이 구분된다.

| Bin 번호 | 종류 |
|---|---|
| 0 | 사용하지 않음 |
| 1 | unsorted bin |
| 2–63 | smallbin 영역 |
| 64–127 | largebin 영역 |

smallbin 영역에는 예약된 크기 클래스가 포함되므로 모든 번호가 일반적인 요청 크기에 대응하는 것은 아니다.

각 bin의 구체적인 크기 범위와 인덱스 계산 방식은 이후 개별 bin 분석에서 다룬다.

### 5.3 Bin head

`bins[]` 배열에 들어 있는 포인터 쌍은 원형 이중 연결 리스트의 head를 표현한다.

예를 들어 어떤 bin에 두 개의 chunk가 연결되어 있다고 하자.

```text
bin head
   |
   | fd
   v
chunk A
   |
   | fd
   v
chunk B
   |
   | fd
   v
bin head
```

반대 방향으로는 `bk`가 연결된다.

```text
bin head
   |
   | bk
   v
chunk B
   |
   | bk
   v
chunk A
   |
   | bk
   v
bin head
```

따라서 해당 bin head의 `fd`는 첫 번째 chunk를, `bk`는 마지막 chunk를 가리킨다.

bin이 비어 있을 때는 두 포인터 모두 bin head 자신을 가리킨다.

```text
empty bin

bin head
   |
   +-- fd → bin head
   |
   +-- bk → bin head
```

즉, 일반 bin의 빈 리스트는 단순히 `NULL`로 표현되는 것이 아니다.

### 5.4 bin_at 매크로

glibc는 `bins[]`의 포인터 쌍을 가상의 `malloc_chunk` 구조체에 있는 `fd`, `bk` 필드처럼 다룬다.

이를 위한 매크로가 `bin_at()`이다.

```c
#define bin_at(m, i) \
  (mbinptr) (((char *) &((m)->bins[((i) - 1) * 2])) \
             - offsetof (struct malloc_chunk, fd))
```

여기서 `offsetof(struct malloc_chunk, fd)`는 구조체 시작 주소에서 `fd` 필드까지의 오프셋을 의미한다.

x86-64 환경에서 해당 오프셋은 `0x10`이다.

따라서 `bin_at()`은 `bins[]`의 해당 포인터 쌍을 `malloc_chunk`의 `fd`, `bk` 필드처럼 접근할 수 있는 주소를 만들어 낸다.

이는 별도의 실제 heap chunk를 생성한다는 의미가 아니다.

**`malloc_state` 내부의 포인터 쌍을 bin head로 사용하는 구현 방식이다.**

---

## 6. Free chunk와 연결 리스트

### 6.1 malloc_chunk

이전에 살펴본 `malloc_chunk` 구조체는 다음과 같다.

```c
struct malloc_chunk {
    INTERNAL_SIZE_T mchunk_prev_size;
    INTERNAL_SIZE_T mchunk_size;

    struct malloc_chunk* fd;
    struct malloc_chunk* bk;

    struct malloc_chunk* fd_nextsize;
    struct malloc_chunk* bk_nextsize;
};
```

chunk가 할당되어 있을 때 `fd`, `bk`가 위치하는 영역은 사용자 데이터로 사용할 수 있다.

하지만 chunk가 일반 bin에서 관리되는 free chunk가 되면 해당 영역에 연결 리스트 포인터가 기록된다.

```text
Allocated chunk             Free chunk (일반 bin)

+------------------+        +------------------+
| prev_size        |        | prev_size        |
+------------------+        +------------------+
| size             |        | size             |
+------------------+        +------------------+
| user data        |        | fd               |
+------------------+        +------------------+
| user data        |        | bk               |
+------------------+        +------------------+
| ...              |        | ...              |
+------------------+        +------------------+
```

즉, 별도의 연결 리스트 노드를 새롭게 할당하지 않고 기존 chunk의 메모리를 노드로 사용한다.

이러한 자료구조를 **intrusive linked list**라고 한다.

### 6.2 Bin 종류에 따른 차이

모든 bin이 동일한 연결 리스트 구조를 사용하는 것은 아니다.

| Bin | 연결 방식 |
|---|---|
| tcache | `next`를 사용하는 단일 연결 리스트 |
| fastbin | `fd`를 사용하는 단일 연결 리스트 |
| unsorted bin | `fd`, `bk`를 사용하는 이중 연결 리스트 |
| smallbin | `fd`, `bk`를 사용하는 이중 연결 리스트 |
| largebin | `fd`, `bk` 및 크기별 연결을 위한 `fd_nextsize`, `bk_nextsize` |

특히 largebin은 서로 다른 크기의 chunk를 관리하기 위해 추가적인 포인터를 사용할 수 있다.

구체적인 연결 구조는 이후 largebin 파트에서 다룬다.

---

## 7. Tcache

### 7.1 tcache의 위치

지금까지 살펴본 `fastbinsY`, `bins`는 `malloc_state`에 포함된 필드이다.

반면 **tcache는 `malloc_state` 내부에 존재하지 않는다.**

tcache는 스레드별로 관리되는 캐시이기 때문이다.

```text
Thread A
   |
   +-- tcache A

Thread B
   |
   +-- tcache B


Arena
   |
   +-- fastbinsY
   |
   +-- bins
```

일반 bin과 fastbin은 arena의 관리 구조에 속하지만, tcache는 각 스레드가 별도의 캐시를 사용하도록 설계되어 있다.

이를 통해 자주 사용하는 작은 chunk를 arena의 공유 자료구조에 매번 접근하지 않고 재사용할 수 있다.

### 7.2 tcache_perthread_struct

glibc 2.31에서는 다음 구조체를 사용한다.

```c
typedef struct tcache_perthread_struct
{
  char counts[TCACHE_MAX_BINS];
  tcache_entry *entries[TCACHE_MAX_BINS];
} tcache_perthread_struct;
```

`counts`는 각 tcache bin에 저장된 chunk의 개수를 관리한다.

`entries`는 각 tcache bin의 연결 리스트 head를 관리한다.

tcache는 fastbin과 마찬가지로 단일 연결 리스트를 사용하며 LIFO 방식으로 chunk를 재사용한다.

하지만 fastbin과 달리 스레드별 캐시이므로 관리 범위와 동기화 특성이 다르다.

구체적인 메모리 구조와 삽입·제거 과정은 tcache 파트에서 다룬다.

---

## 8. Bin 관리 방식 비교

지금까지 살펴본 bin들을 정리하면 다음과 같다.

| 구조 | 관리 단위 | 연결 방식 | 주요 특징 |
|---|---|---|---|
| tcache | Thread | 단일 연결 | 빠른 재사용, arena lock 경합 감소 |
| fastbin | Arena | 단일 연결 | 작은 chunk를 즉시 병합하지 않음 |
| unsorted bin | Arena | 이중 연결 | 크기별 bin 분류 전 재사용 기회 제공 |
| smallbin | Arena | 이중 연결 | 동일 크기의 chunk 관리 |
| largebin | Arena | 이중 연결 및 크기별 연결 | 다양한 큰 크기의 chunk 관리 |

이러한 구조들은 서로 완전히 독립된 메모리 영역이 아니다.

동일한 heap 영역에 존재하는 free chunk라도 allocator의 처리 과정에 따라 서로 다른 관리 구조에 속할 수 있다.

또한 free chunk가 항상 하나의 고정된 bin에 영구적으로 저장되는 것은 아니다.

allocator는 요청 크기와 내부 상태에 따라 chunk를 재사용하거나 다른 bin으로 이동시키거나 인접한 chunk와 병합할 수 있다.

---

## 9. 정리

이번 문서에서는 glibc malloc이 free chunk를 관리하는 이유와 bin의 기본 구조를 살펴보았다.

핵심 내용은 다음과 같다.

1. `free()`된 chunk는 allocator가 이후 요청에서 재사용할 수 있다.
2. free list와 bin은 이러한 chunk를 관리하기 위한 자료구조이다.
3. glibc는 할당 속도, 탐색 효율, 단편화, lock 경합 등을 고려하여 여러 관리 구조를 사용한다.
4. `malloc_state`의 `fastbinsY`와 `bins`는 서로 다른 종류의 bin을 관리한다.
5. `bins[NBINS * 2 - 2]`는 127개의 일반 bin head를 표현하기 위한 포인터 배열이다.
6. 실제 연결 리스트의 노드는 heap에 존재하는 free chunk이며, chunk 내부의 포인터 필드를 사용해 연결된다.
7. tcache는 `malloc_state`에 포함되지 않는 스레드별 캐시이다.
8. top chunk는 일반적인 bin에서 관리되지 않는 별도의 가용 메모리 공간이다.

이제 bin의 개념과 기본적인 관리 구조를 이해했으므로, 다음 문서에서는 실제 `malloc()`과 `free()`가 이러한 구조를 어떻게 사용하는지 살펴본다.

주요 분석 대상은 다음과 같다.

- `__libc_malloc()`
- `_int_malloc()`
- `__libc_free()`
- `_int_free()`

각 bin의 구체적인 삽입·제거 과정과 내부 자료구조는 이후 개별 bin 파트에서 자세히 다룬다.
