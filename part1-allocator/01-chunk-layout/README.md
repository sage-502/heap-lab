# chunk-layout

glibc malloc이 관리하는 메모리의 기본 단위인 **heap chunk**의 구조를 알아본다.

지난 장에서는 `malloc()`이 반환한 포인터의 `0x10`바이트 앞에서 `prev_size`와 `size` 필드를 관찰했다.

이번 장에서는 glibc 2.31의 `malloc/malloc.c`를 기준으로 실제 chunk 구조와 각 필드의 의미를 살펴본다.

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

  * 이전 chunk가 free 상태일 때, 그 chunk의 크기를 저장한다.

* `mchunk_size`

  * 현재 chunk의 전체 크기를 저장한다.
  * 하위 비트 일부에는 chunk와 관련된 flag도 함께 저장한다.

* `fd`, `bk`

  * free chunk를 연결 리스트로 관리할 때 사용한다.

* `fd_nextsize`, `bk_nextsize`

  * 큰 크기의 free chunk를 관리할 때 추가로 사용한다.

모든 필드가 항상 같은 용도로 사용되는 것은 아니다.

특히 chunk가 사용 중인지 free 상태인지에 따라 `fd`, `bk` 등이 위치한 영역의 의미가 달라진다.

---

## 2. chunk의 형태

### 2.1 allocated chunk

64bit 환경에서 할당된 chunk는 대략 다음과 같이 볼 수 있다.

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

`chunk`는 allocator 내부에서 사용하는 chunk의 시작 주소이다.

반면 `mem`은 `malloc()`이 사용자에게 반환하는 주소이다.

64bit 환경에서는 `mchunk_prev_size`와 `mchunk_size`가 각각 8바이트이므로 두 주소는 `0x10`바이트 차이가 난다.

```text
mem = chunk + 0x10
```

반대로 `malloc()`이 반환한 포인터를 알고 있다면 chunk 시작 주소는 다음과 같이 계산할 수 있다.

```text
chunk = mem - 0x10
```

예를 들어 `malloc()`이 반환한 주소가 다음과 같다고 하자.

```text
0x5555555592a0
```

chunk의 시작 주소는 다음과 같다.

```text
0x5555555592a0 - 0x10
= 0x555555559290
```

따라서 gdb에서는 다음과 같이 chunk header를 확인할 수 있다.

```gdb
x/2gx ptr-0x10
```

### 2.2 free chunk

chunk가 free되면 해당 메모리는 더 이상 사용자의 데이터 영역으로 보존될 필요가 없다.

따라서 allocator는 기존 user data 영역 일부를 자신의 관리 정보 저장용으로 사용할 수 있다.

일반적인 free chunk는 다음과 같이 볼 수 있다.

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

`fd`와 `bk`는 free chunk들을 연결 리스트로 관리할 때 사용하는 포인터이다.

따라서 `free()` 이후에는 이전까지 user data가 있던 영역의 일부가 allocator의 관리 정보로 바뀔 수 있다.

단, 모든 free chunk가 항상 `fd`, `bk`를 같은 방식으로 사용하는 것은 아니다.

fastbin이나 tcache 등은 다른 방식으로 free chunk를 관리하며, 이에 대해서는 이후 장에서 다룬다.

---

## 3. `mchunk_size`

`mchunk_size`에는 현재 chunk의 크기가 저장된다.

하지만 이 값을 그대로 chunk 크기로 사용하지는 않는다.

`mchunk_size`의 하위 비트에는 다음 세 가지 flag가 함께 저장된다.

```text
A M P
```

각각의 의미는 다음과 같다.

```text
A : NON_MAIN_ARENA
M : IS_MMAPPED
P : PREV_INUSE
```

중요한 점은 이 flag들이 **현재 chunk가 단순히 allocated인지 free인지를 직접 나타내는 값은 아니라는 것**이다.


### 3.1 PREV_INUSE

`PREV_INUSE`는 `0x1` 비트를 사용한다.

```text
P = 1
```

이면 현재 chunk의 바로 이전 chunk가 사용 중이라는 뜻이다.

```text
P = 0
```

이면 이전 chunk가 free 상태라는 뜻이다.

즉 `PREV_INUSE`는 현재 chunk 자신의 상태가 아니라 **이전 chunk의 상태**를 나타낸다.

```text
chunk A             chunk B

+---------+         +---------+
|         |         |         |
|         |         | size B  |
+---------+         +---------+
                         ↑
                    PREV_INUSE
```

이 경우 chunk B의 `PREV_INUSE` 값은 chunk A의 상태를 나타낸다.


### 3.2 IS_MMAPPED

`IS_MMAPPED`는 `0x2` 비트를 사용한다.

이 비트가 설정되어 있으면 해당 chunk가 `mmap()`을 통해 별도로 할당된 메모리임을 나타낸다.

```text
M = 0 : 일반적인 heap chunk
M = 1 : mmap으로 할당된 chunk
```

큰 크기의 메모리 요청은 상황에 따라 `mmap()`을 통해 처리될 수 있다.


### 3.3 NON_MAIN_ARENA

`NON_MAIN_ARENA`는 `0x4` 비트를 사용한다.

이 비트는 해당 chunk가 main arena가 아닌 다른 arena에 속해 있는지를 나타낸다.

```text
A = 0 : main arena
A = 1 : non-main arena
```

arena의 구조와 동작은 다음 장에서 다룬다.

---

## 4. 실제 chunk size 계산

예를 들어 `mchunk_size` 값이 다음과 같다고 하자.

```text
0x31
```

이 값을 그대로 `0x31`바이트짜리 chunk라고 해석하면 안 된다.

하위 비트에 flag가 포함되어 있기 때문이다.

```text
0x31
│ │
│ └─ PREV_INUSE = 1
│
└── chunk size = 0x30
```

따라서 실제 chunk 크기는 다음과 같다.

```text
0x30
```

glibc에서는 flag 비트를 한 번에 제거하기 위해 다음과 같은 값을 사용한다.

```c
#define SIZE_BITS (PREV_INUSE | IS_MMAPPED | NON_MAIN_ARENA)
```

그리고 `chunksize()` 매크로를 통해 실제 chunk 크기를 얻는다.

```c
#define chunksize(p) (chunksize_nomask (p) & ~(SIZE_BITS))
```

즉 개념적으로는 다음과 같다.

```text
실제 chunk size
= mchunk_size에서 A, M, P 비트를 제거한 값
```

---

## 5. 다음 chunk 찾기

현재 chunk의 시작 주소와 실제 chunk 크기를 알고 있다면 다음 chunk의 위치를 계산할 수 있다.

```text
next chunk
= current chunk + current chunk size
```

예를 들어 현재 chunk의 시작 주소가 다음과 같고:

```text
0x555555559290
```

실제 chunk 크기가 `0x30`이라면:

```text
0x555555559290 + 0x30
= 0x5555555592c0
```

따라서 다음 chunk는 `0x5555555592c0`에서 시작한다.

```text
                 +0x30
chunk A ------------------------> chunk B

0x555555559290                   0x5555555592c0
```

이 관계를 이용하면 gdb에서 allocator 플러그인 없이도 인접한 chunk를 직접 찾아갈 수 있다.

---

## 6. `mchunk_prev_size`

`mchunk_prev_size`는 이전 chunk의 크기를 저장하는 필드이다.

하지만 이 값은 항상 사용되는 것은 아니다.

현재 chunk의 `PREV_INUSE`가 `0`일 때, 즉 바로 이전 chunk가 free 상태일 때 의미를 가진다.

```text
previous chunk                 current chunk

+-------------------+         +-------------------+
|                   |         | prev_size         |
|    free chunk     |         +-------------------+
|                   |         | size        P = 0 |
+-------------------+         +-------------------+
```

현재 chunk는 `prev_size`를 통해 이전 chunk의 크기를 알 수 있다.

따라서 이전 chunk의 시작 주소도 계산할 수 있다.

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
0x5000 - 0x40
= 0x4fc0
```

이므로 이전 chunk는 `0x4fc0`에서 시작한다.

---

## 7. prev_size는 왜 필요한가

`prev_size`가 필요한 가장 중요한 이유 중 하나는 **인접한 free chunk를 찾기 위해서**이다.

예를 들어 다음과 같이 두 chunk가 붙어 있다고 하자.

```text
[ previous free chunk ][ current chunk ]
```

현재 chunk의 `PREV_INUSE`가 `0`이라면 allocator는 다음 사실을 알 수 있다.

```text
"내 바로 앞 chunk는 free 상태다."
```

그리고 `prev_size` 값을 이용하면 이전 chunk의 시작 주소를 바로 계산할 수 있다.

```text
previous chunk
= current chunk - prev_size
```

즉 heap 전체를 처음부터 탐색할 필요가 없다.

이처럼 인접한 chunk의 크기 정보를 이용해 이전 또는 다음 chunk를 찾을 수 있도록 하는 방식을 **boundary tag** 방식이라고 한다.

---

## 8. chunk 병합

메모리를 여러 번 할당하고 해제하다 보면 서로 붙어 있는 free chunk들이 생길 수 있다.

예를 들어:

```text
[used][ free A ][ free B ][used]
```

free A와 free B가 서로 인접해 있다면 allocator는 이 두 chunk를 하나의 큰 free chunk로 합칠 수 있다.

```text
[used][      free A+B      ][used]
```

이 작업을 **consolidation**이라고 한다.

`PREV_INUSE`와 `prev_size`는 이러한 병합 과정에서 이전 chunk의 상태와 위치를 알아내는 데 사용된다.

구체적인 `free()`의 병합 과정은 이후 allocator 동작을 다루는 장에서 살펴본다.

---

## 9. 실습

