# chunk-layout

glibc malloc이 관리하는 메모리의 기본 단위인 **heap chunk**의 구조를 알아본다.

지난 장에서는 `malloc()`이 반환한 포인터의 `0x10`바이트 앞에서 `prev_size`와 `size` 필드를 관찰했다.

이번 장에서는 glibc 2.31의 `malloc/malloc.c`를 기준으로 실제 chunk 구조와 각 필드의 의미를 살펴보고, chunk를 관리하는 상위 구조인 arena에 대해서도 간단히 알아본다.

본 문서의 기준 환경은 다음과 같다.

* Ubuntu 20.04
* glibc 2.31
* x86-64
* 64bit

---

## 1. malloc chunk

glibc malloc은 힙 메모리를 여러 개의 **chunk** 단위로 나누어 관리한다.

`malloc.c`에서는 chunk를 다음 구조체로 표현한다.

```c
struct malloc_chunk {

  INTERNAL_SIZE_T      mchunk_prev_size;
  INTERNAL_SIZE_T      mchunk_size;

  struct malloc_chunk* fd;
  struct malloc_chunk* bk;

  struct malloc_chunk* fd_nextsize;
  struct malloc_chunk* bk_nextsize;
};
```

각 필드는 다음과 같은 용도로 사용된다.

* `mchunk_prev_size`

  * 물리적으로 바로 앞에 위치한 chunk의 크기를 저장한다.
  * 이전 chunk가 free 상태일 때 의미가 있다.

* `mchunk_size`

  * 현재 chunk의 크기를 저장한다.
  * 단순한 크기뿐만 아니라 chunk의 상태와 관련된 flag도 함께 저장한다.

* `fd`, `bk`

  * free chunk를 연결 리스트로 관리할 때 사용한다.

* `fd_nextsize`, `bk_nextsize`

  * 큰 크기의 free chunk를 관리할 때 추가로 사용한다.

모든 필드가 항상 동일한 의미로 사용되는 것은 아니다.

특히 chunk가 할당된 상태인지 free 상태인지에 따라 `fd`, `bk` 등이 위치한 영역의 의미가 달라진다.


### 1.1 할당된 chunk

64bit 환경에서 할당된 chunk는 대략 다음과 같은 형태로 볼 수 있다.

```text
chunk
 ↓
+--------------------------+
| mchunk_prev_size         |  8 bytes
+--------------------------+
| mchunk_size              |  8 bytes
+--------------------------+ ← mem
|                          |
| user data                |
|                          |
+--------------------------+ ← next chunk
```

`chunk`는 allocator 내부에서 사용하는 chunk의 시작 주소이고, `mem`은 `malloc()`이 사용자에게 반환하는 주소이다.

64bit 환경에서는 `mchunk_prev_size`와 `mchunk_size`가 각각 8바이트이므로 두 주소 사이에는 `0x10`바이트의 차이가 있다.

```text
mem = chunk + 0x10
```

반대로 `malloc()`이 반환한 포인터를 알고 있다면 chunk의 시작 주소를 다음과 같이 계산할 수 있다.

```text
chunk = mem - 0x10
```

따라서 gdb에서는 다음과 같이 chunk header를 확인할 수 있다.

```gdb
x/2gx ptr-0x10
```

### 1.2 free chunk

chunk가 free 상태가 되면 allocator는 더 이상 해당 영역을 사용자 데이터로 보존할 필요가 없다.

따라서 user data 영역의 일부를 free chunk 관리용 정보로 사용할 수 있다.

일반적인 free chunk는 다음과 같은 형태로 볼 수 있다.

```text
chunk
 ↓
+--------------------------+
| mchunk_prev_size         |
+--------------------------+
| mchunk_size              |
+--------------------------+ ← mem
| fd                       |
+--------------------------+
| bk                       |
+--------------------------+
| ...                      |
+--------------------------+
```

`fd`와 `bk`는 free chunk들을 연결 리스트로 관리하기 위한 포인터이다.

따라서 `free()` 이후 이전까지 user data가 저장되어 있던 영역의 내용이 변경될 수 있다.

단, 모든 free chunk가 항상 `fd`, `bk`를 동일한 방식으로 사용하는 것은 아니다.

fastbin이나 tcache 등은 별도의 관리 방식을 사용하며 이에 대해서는 이후 장에서 다룬다.

---

## 2. chunk size

`mchunk_size`에는 현재 chunk의 크기가 저장된다.

하지만 값 전체를 그대로 chunk 크기로 사용하는 것은 아니다.

크기와 함께 하위 비트에 상태 flag가 저장된다.

glibc에서는 다음 세 가지 flag를 사용한다.

```text
A M P
```

각각 다음을 의미한다.

```text
A : NON_MAIN_ARENA
M : IS_MMAPPED
P : PREV_INUSE
```

### 2.1 PREV_INUSE

`PREV_INUSE`는 가장 낮은 비트인 `0x1`을 사용한다.

```text
P = 1
```

이면 현재 chunk의 **바로 이전 chunk가 사용 중**임을 의미한다.

```text
P = 0
```

이면 이전 chunk가 free 상태임을 의미한다.

중요한 점은 이 비트가 현재 chunk 자신의 상태를 나타내는 것이 아니라 이전 chunk의 상태를 나타낸다는 것이다.

예를 들어 chunk A가 chunk B의 이전 chunk라고 하면:

```text
chunk A             chunk B
+---------+         +---------+
|         |         |         |
|         |         | size B  |
+---------+         +---------+
                         ↑
                    PREV_INUSE
```

chunk B의 `PREV_INUSE`는 chunk A의 상태를 나타낸다.


### 2.2 IS_MMAPPED

`IS_MMAPPED`는 `0x2` 비트를 사용한다.

이 bit가 설정되어 있으면 해당 chunk가 일반적인 heap 영역에서 관리되는 chunk가 아니라 `mmap()`을 통해 별도로 할당된 메모리임을 나타낸다.

```text
M = 0 : 일반적인 heap chunk
M = 1 : mmap으로 할당된 chunk
```

큰 크기의 메모리 요청은 상황에 따라 `mmap()`을 통해 처리될 수 있다.


### 2.3 NON_MAIN_ARENA

`NON_MAIN_ARENA`는 `0x4` 비트를 사용한다.

해당 chunk가 main arena가 아닌 다른 arena에 속해 있는지를 나타낸다.

```text
A = 0 : main arena
A = 1 : non-main arena
```

arena에 대해서는 뒤에서 다시 살펴본다.


### 2.4 실제 chunk size

예를 들어 `mchunk_size`에 다음 값이 들어 있다고 하자.

```text
0x31
```

이 값을 그대로 `0x31`바이트짜리 chunk라고 해석하지 않는다.

하위 bit에는 flag가 포함되어 있기 때문이다.

```text
0x31
│ │
│ └─ PREV_INUSE = 1
│
└── 실제 chunk size = 0x30
```

따라서 이 경우 실제 chunk의 크기는:

```text
0x30
```

이다.

glibc 코드에서는 이러한 flag를 제외한 실제 chunk 크기를 얻기 위해 `chunksize()` 등의 매크로를 사용한다.


### 2.5 인접 chunk 찾기

chunk의 실제 크기를 알고 있다면 물리적으로 다음에 위치한 chunk를 계산할 수 있다.

```text
next chunk
= current chunk + current chunk size
```

예를 들어 현재 chunk 시작 주소가:

```text
0x555555559290
```

이고 실제 chunk size가:

```text
0x30
```

이라면 다음 chunk는:

```text
0x555555559290 + 0x30
= 0x5555555592c0
```

에서 시작한다.

즉 heap에서 chunk들은 다음과 같이 이어진다.

```text
                 +0x30
chunk A ------------------------> chunk B

0x555555559290                   0x5555555592c0
```

이 관계를 이용하면 gdb에서 allocator 플러그인 없이도 다음 chunk를 직접 찾아갈 수 있다.

---

## 3. prev_size

`mchunk_prev_size`에는 이전 chunk의 크기가 저장될 수 있다.

하지만 이 값은 항상 의미가 있는 것은 아니다.

현재 chunk의 `PREV_INUSE`가 0일 때, 즉 이전 chunk가 free 상태일 때 사용된다.

```text
previous chunk              current chunk

+-------------------+
|                   |
|    free chunk     |
|                   |
+-------------------+
                            +-------------------+
                            | prev_size         |
                            +-------------------+
                            | size        P = 0 |
                            +-------------------+
```

이 경우 현재 chunk의 `prev_size`를 이용하면 이전 chunk의 시작 주소를 계산할 수 있다.

```text
previous chunk
= current chunk - prev_size
```

예를 들어:

```text
current chunk = 0x5000
prev_size     = 0x40
```

이라면:

```text
previous chunk
= 0x5000 - 0x40
= 0x4fc0
```

이다.

이 정보는 인접한 free chunk를 병합할 때 사용된다.

---

## 4. boundary tag와 chunk 병합

glibc malloc은 인접한 free chunk를 찾아 병합할 수 있도록 chunk의 경계에 크기 정보를 저장한다.

이러한 방식을 일반적으로 **boundary tag** 방식이라고 한다.

예를 들어 현재 chunk의 이전 chunk가 free 상태라면:

```text
[ previous free chunk ][ current chunk ]
                         ↑
                       prev_size
```

현재 chunk의 `prev_size`를 이용하여 바로 이전 chunk의 위치를 계산할 수 있다.

이를 통해 allocator는 메모리를 처음부터 탐색하지 않고도 인접한 이전 chunk를 찾을 수 있다.

여러 번의 `malloc()`과 `free()`로 인해 메모리가 작은 free chunk들로 나뉘면 큰 크기의 메모리 요청을 처리하기 어려워질 수 있는데, 
이때 서로 인접한 free chunk들을 하나로 합치는 작업을 **consolidation**이라고 한다.

```text
병합 전

[used][ free A ][ free B ][used]


병합 후

[used][      free A+B      ][used]
```

`prev_size`와 `PREV_INUSE`는 이러한 인접 chunk 탐색과 병합에 사용된다.

구체적인 `free()`의 병합 과정은 이후 allocator 동작을 다루는 장에서 살펴본다.

---

## 5. arena (여기서부터 수정)

glibc malloc은 chunk들을 관리하기 위해 **arena**라는 관리 단위를 사용한다.

arena 하나에는 free chunk를 관리하기 위한 여러 자료구조와 현재 사용할 수 있는 heap의 상태가 저장된다.

프로그램에는 기본적으로 `main_arena`가 존재한다.

멀티스레드 프로그램에서는 여러 스레드가 동시에 같은 allocator 자료구조에 접근하면서 발생할 수 있는 lock 경합을 줄이기 위해 추가적인 arena가 사용될 수 있다.

대략적으로 보면 다음과 같다.

```text
process

├─ main_arena
│   ├─ fastbins
│   ├─ bins
│   └─ top
│
├─ arena #2
│   ├─ fastbins
│   ├─ bins
│   └─ top
│
└─ arena #3
    ├─ fastbins
    ├─ bins
    └─ top
```

arena는 glibc malloc 내부의 관리 구조이다.

프로세스의 가상 메모리 자체가 스레드마다 독립적으로 존재한다는 의미는 아니다.



---

# 6. malloc_state

glibc에서 arena의 상태는 `struct malloc_state` 구조체로 표현된다.

```c
struct malloc_state
{
  __libc_lock_define (, mutex);

  int flags;
  int have_fastchunks;

  mfastbinptr fastbinsY[NFASTBINS];

  mchunkptr top;
  mchunkptr last_remainder;

  mchunkptr bins[NBINS * 2 - 2];
  unsigned int binmap[BINMAPSIZE];

  struct malloc_state *next;
  struct malloc_state *next_free;

  INTERNAL_SIZE_T attached_threads;

  INTERNAL_SIZE_T system_mem;
  INTERNAL_SIZE_T max_system_mem;
};
```

이번 장에서는 각 자료구조의 구체적인 동작보다는 arena가 어떤 정보를 가지고 있는지만 간단히 살펴본다.

주요 필드는 다음과 같다.

### `mutex`

해당 arena에 접근할 때 사용하는 lock이다.

멀티스레드 환경에서 여러 스레드가 동시에 arena의 내부 구조를 수정하는 것을 방지한다.

### `fastbinsY`

작은 크기의 free chunk들을 빠르게 재사용하기 위한 fastbin들을 관리한다.

구체적인 구조와 동작은 이후 fastbin 장에서 다룬다.

### `top`

현재 arena의 **top chunk**를 가리킨다.

top chunk는 아직 다른 chunk로 나뉘지 않은 heap 끝부분의 사용 가능한 공간이다.

```text
[chunk][chunk][chunk][          top chunk          ]
                                                 ↑
                                              heap 끝
```

allocator가 기존 free chunk에서 요청을 처리하지 못하면 top chunk의 일부를 잘라 새로운 chunk를 만들 수 있다.

### `bins`

free chunk를 크기와 상태에 따라 관리하기 위한 여러 bin의 연결 정보를 저장한다.

unsorted bin, smallbin, largebin 등이 이 배열을 이용한다.

각 bin의 구체적인 동작은 이후 장에서 다룬다.

### `binmap`

어떤 bin에 사용할 수 있는 chunk가 존재하는지 빠르게 확인하기 위한 비트맵이다.

### `next`

여러 arena들을 연결하기 위해 사용한다.

---

# 8. chunk와 arena의 관계

전체적인 관계를 간단하게 보면 다음과 같다.

```text
              malloc_state
                 (arena)
                    │
       ┌────────────┼────────────┐
       │            │            │
   fastbins       bins          top
       │            │            │
       ▼            ▼            ▼
   free chunk   free chunk    top chunk
```

arena는 여러 chunk를 직접 하나의 배열에 저장하는 구조가 아니다.

대신 free된 chunk들을 여러 종류의 자료구조를 통해 관리하고, heap의 마지막에는 top chunk를 유지한다.

할당 중인 chunk는 프로그램이 사용하고 있으며, free된 chunk들은 필요에 따라 allocator의 관리 구조에 들어가 다시 사용될 수 있다.

---

# 9. glibc 코드에서 확인할 항목

이론을 확인하기 위해 glibc 2.31의 `malloc/malloc.c`에서 다음 항목을 찾아본다.

```text
struct malloc_chunk

PREV_INUSE
IS_MMAPPED
NON_MAIN_ARENA
SIZE_BITS

prev_inuse()
chunksize()

chunk2mem()
mem2chunk()

struct malloc_state
```

특히 다음 관계를 코드와 함께 확인한다.

```text
chunk
  ↓
[ prev_size ]
[ size      ]
[ user data ] ← malloc 반환값
  ↑
 mem
```

64bit 환경에서는:

```text
mem = chunk + 0x10
```

이며, 반대로:

```text
chunk = mem - 0x10
```

이다.

이후 작은 프로그램을 작성하고 순수 gdb를 이용하여 실제 메모리에서도 동일한 구조가 나타나는지 확인한다.

---

# 10. 정리

이번 장에서는 glibc malloc이 관리하는 heap chunk의 기본 구조와 arena의 개념을 살펴보았다.

* glibc malloc은 heap 메모리를 chunk 단위로 관리한다.
* chunk header에는 `prev_size`와 `size`가 존재한다.
* 64bit 환경에서 `malloc()`이 반환하는 user data 주소는 chunk 시작 주소보다 `0x10`바이트 뒤에 있다.
* `mchunk_size`에는 실제 chunk 크기와 함께 `A`, `M`, `P` flag가 저장된다.
* `PREV_INUSE`는 현재 chunk가 아니라 바로 이전 chunk의 상태를 나타낸다.
* 이전 chunk가 free 상태라면 `prev_size`를 이용하여 이전 chunk의 위치를 계산할 수 있다.
* chunk의 시작 주소와 크기를 알고 있다면 다음 chunk의 주소를 직접 계산할 수 있다.
* free chunk의 user data 영역 일부는 allocator가 연결 정보를 저장하는 데 사용할 수 있다.
* arena는 여러 chunk와 free list, top chunk 등을 관리하는 allocator 내부의 관리 단위이다.
* glibc에서는 arena의 상태를 `struct malloc_state`로 표현한다.

다음으로 glibc 2.31의 실제 `malloc.c` 코드를 확인하고, 작은 테스트 프로그램을 작성하여 gdb에서 chunk header와 인접 chunk의 위치를 직접 관찰한다.
