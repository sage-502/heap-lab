# malloc-arena

이 파트에서는 glibc malloc의 **arena**와 arena의 상태를 표현하는 `malloc_state` 구조체에 대해 알아본다.

arena는 glibc malloc의 메모리 관리 단위이다.  
각 arena는 자신에게 속한 heap 영역의 chunk들과 top chunk, free list 등의 allocator 상태를 관리한다.

멀티스레드 환경에서는 여러 개의 arena가 존재할 수 있으며, 스레드는 메모리를 할당할 때 자신이 연결된 arena를 사용한다.

본 문서의 기준 환경은 다음과 같다.

- Ubuntu 20.04
- glibc 2.31
- x86-64
- 64bit

---

## 1. 배경

멀티스레드 환경에서는 여러 스레드가 동시에 `malloc()`이나 `free()`를 호출할 수 있다.

allocator의 상태가 하나뿐이라면 여러 스레드가 같은 자료구조를 동시에 수정하지 못하도록 lock을 사용해야 한다.

예를 들어 하나의 allocator 상태만 존재한다고 가정하면 다음과 같다.

```text
Thread A ─┐
Thread B ─┼──> allocator state
Thread C ─┘
              ↑
            mutex
```

한 스레드가 allocator의 상태를 변경하는 동안 다른 스레드는 lock이 해제될 때까지 기다려야 한다.

스레드 수가 증가하면 하나의 lock을 여러 스레드가 경쟁하면서 경합이 발생할 수 있다.

### 1.1 여러 arena를 사용하는 경우

glibc malloc은 이러한 경합을 줄이기 위해 여러 개의 arena를 사용할 수 있다.

```text
Thread A ──> arena A

Thread B ──> arena B

Thread C ──> arena C
```

서로 다른 arena를 사용하는 스레드들은 서로 다른 allocator 상태를 사용하므로 하나의 arena를 두고 경쟁하는 경우보다 lock contention을 줄일 수 있다.

이를 계산대에 비유하면 다음과 같다.

```text
arena 1개
→ 계산대 1개
→ 여러 스레드가 하나의 줄에서 대기

arena 여러 개
→ 계산대 여러 개
→ 여러 줄로 분산 가능
```

단, **스레드마다 arena가 반드시 하나씩 존재하는 것은 아니다.**

arena의 개수에는 제한이 있으며 여러 스레드가 하나의 arena를 공유할 수도 있다.

```text
Thread A ─┐
Thread B ─┼──> arena A
          │
Thread C ─┘

Thread D ─────> arena B
```

따라서 arena는 thread-local 구조가 아니라, 여러 스레드가 사용할 수 있는 allocator의 관리 단위라고 볼 수 있다.

---

## 2. arena

### 2.1 arena란?

arena는 glibc malloc이 heap 메모리를 관리하기 위한 **논리적인 관리 단위**이다.

arena는 실제 사용자 데이터가 저장되는 메모리 블록 자체가 아니다.

각 arena는 자신에게 속한 chunk들을 관리하기 위한 여러 상태를 가지고 있다.

대표적으로 다음과 같은 정보가 있다.

```text
arena
│
├── mutex
│
├── top
│     └── top chunk
│
├── fastbins
│
├── bins
│
├── 다른 arena와의 연결 정보
│
└── 시스템에서 확보한 메모리 크기
```

glibc에서는 이러한 arena의 상태를 `struct malloc_state` 구조체로 표현한다.

따라서 개념적으로는 다음과 같이 볼 수 있다.

```text
arena
  ↓
glibc에서 상태를 표현
  ↓
struct malloc_state
  ↓
실제 malloc_state 인스턴스
```

하나의 `malloc_state` 인스턴스가 하나의 arena를 대표한다고 볼 수 있다.

---

### 2.2 main arena

glibc에는 기본 arena인 **main arena**가 존재한다.

main arena의 상태를 표현하는 실제 객체가 `main_arena`이다.

```text
main_arena
    ↓
struct malloc_state 인스턴스
```

`main_arena`는 heap 영역 내부에 존재하는 것이 아니다.

glibc의 전역 상태로 정의되어 있으며, 프로세스 실행 시 libc가 가상 메모리에 매핑되면 `main_arena` 역시 libc의 writable mapping 안에 존재하게 된다.

개념적으로는 다음과 같다.

```text
프로세스 가상 메모리

libc mapping
+---------------------------+
|                           |
| main_arena                |
|   top --------------------|-----+
|                           |     |
+---------------------------+     |
                                  |
                                  v
[heap]
+---------------------------+
| allocated chunk           |
+---------------------------+
| allocated chunk           |
+---------------------------+
| top chunk                 |
+---------------------------+
```

즉 `main_arena`라는 관리 구조체와 실제 chunk들이 존재하는 `[heap]` 영역은 서로 다른 곳에 존재하며 포인터를 통해 연결된다.

---

### 2.3 non-main arena

멀티스레드 환경에서 추가적인 arena가 필요해지면 **non-main arena**가 생성될 수 있다.

non-main arena는 기존 `[heap]` 영역을 여러 조각으로 나누어 사용하는 방식이 아니다.

추가 arena는 별도의 메모리 영역을 확보하여 자신에게 속한 chunk들을 관리한다.

단순화하면 다음과 같다.

```text
main_arena
    |
    v
[main heap]
+------------------+
| chunks           |
| top chunk        |
+------------------+


arena #2
    |
    v
[mmap 기반 heap]
+------------------+
| heap_info        |
| malloc_state     |
| chunks           |
| top chunk        |
+------------------+


arena #3
    |
    v
[mmap 기반 heap]
+------------------+
| heap_info        |
| malloc_state     |
| chunks           |
| top chunk        |
+------------------+
```

따라서 다음과 같이 이해하면 안 된다.

```text
하나의 거대한 heap

+---------------------------------+
| arena A | arena B | arena C     |
+---------------------------------+
```

arena는 하나의 기존 heap을 논리적으로 잘라 가진 영역이 아니다.

각 arena는 자신에게 속한 heap 영역과 그 안의 chunk들을 관리한다.

---

### 2.4 thread와 arena

스레드는 메모리를 할당할 때 자신이 연결된 arena를 이용한다.

```text
Thread
   |
   v
arena
   |
   ├── top
   ├── fastbins
   ├── bins
   └── ...
```

서로 다른 thread가 서로 다른 arena를 사용할 수도 있다.

```text
Thread A ──> arena A

Thread B ──> arena B
```

반대로 여러 thread가 같은 arena를 공유할 수도 있다.

```text
Thread A ─┐
          ├──> arena A
Thread B ─┘
```

따라서 다음과 같은 표현은 정확하지 않다.

```text
thread마다 arena가 하나씩 존재한다.
```

보다 정확하게는 다음과 같이 표현할 수 있다.

> 각 스레드는 메모리 할당 시 특정 arena를 사용하지만, 스레드마다 독립적인 arena가 반드시 하나씩 존재하는 것은 아니다.

---

## 3. arena와 heap

### 3.1 arena와 heap은 같은 것이 아니다

arena와 heap은 서로 다른 개념이다.

**arena**는 allocator의 관리 상태이고, **heap**은 실제 chunk들이 배치되는 메모리 영역이다.

```text
arena
  |
  | 관리
  v
heap
├── allocated chunk
├── free chunk
├── allocated chunk
└── top chunk
```

arena는 `top`, `bins`, `fastbins` 등의 정보를 통해 자신에게 속한 chunk들을 관리한다.

---

### 3.2 top chunk

arena가 관리하는 heap을 처음 단순화해서 보면 대부분의 사용 가능한 공간이 하나의 큰 **top chunk**로 존재한다고 볼 수 있다.

```text
arena
  |
  | top
  v
+-----------------------------+
|                             |
|          top chunk          |
|                             |
+-----------------------------+
```

다른 곳에서 재사용 가능한 chunk를 찾지 못한 상태에서 `malloc()` 요청이 들어오면 top chunk의 앞부분을 잘라 새로운 chunk를 만들 수 있다.

```text
malloc 전

+-----------------------------+
|          top chunk          |
+-----------------------------+
^
|
top
```

일부를 할당하면:

```text
malloc 후

+-------------+---------------+
| allocated   |   top chunk   |
| chunk       |               |
+-------------+---------------+
              ^
              |
             top
```

기존 top chunk의 앞부분이 할당되고, 남은 영역이 새로운 top chunk가 된다.

따라서 arena의 `top` 포인터 역시 새로운 top chunk를 가리키도록 변경된다.

현재 top chunk가 요청을 처리하기에 부족하면 allocator는 시스템으로부터 추가 메모리를 확보할 수 있다.

따라서 arena가 관리하는 범위를 **처음 만들어진 top chunk의 크기로 고정된 영역**이라고 생각하면 안 된다.

---

### 3.3 main arena와 main heap

main arena는 일반적으로 main heap과 연결된다.

```text
main_arena
    |
    | top
    v
[heap]
+-----------------------+
| allocated chunks      |
+-----------------------+
| free chunks           |
+-----------------------+
| top chunk             |
+-----------------------+
```

main arena는 heap 영역에 있는 것이 아니라 libc 쪽에 존재하고, 내부의 여러 포인터를 통해 heap의 chunk들을 관리한다.

---

### 3.4 non-main arena와 heap

non-main arena는 main arena가 사용하는 `[heap]` 영역을 나누어 사용하는 것이 아니라, 별도의 메모리 영역을 확보하여 자신에게 속한 chunk들을 관리한다.

단순화하면 다음과 같다.

```text
non-main arena
      |
      v
mmap 기반 heap
+----------------------+
| heap metadata        |
| allocator metadata   |
| chunks               |
| top chunk            |
+----------------------+
```

이때 non-main arena가 사용하는 각 heap 영역에는 해당 heap에 대한 정보를 저장하기 위한 `heap_info` 구조체가 존재한다.

---

### 3.5 멀티스레드 프로세스의 가상 메모리

단일 스레드 프로세스의 가상 메모리를 매우 단순화하면 다음과 같이 표현할 수 있다.

```text
높은 주소

+----------------------+
| stack                |
+----------------------+
|                      |
+----------------------+
| heap                 |
+----------------------+
| data / bss           |
+----------------------+
| text                 |
+----------------------+

낮은 주소
```

멀티스레드 환경에서는 각 스레드가 자신의 stack을 가지지만, 프로세스의 가상 주소 공간 자체는 공유한다.

malloc arena까지 포함하여 단순화하면 다음과 같이 나타낼 수 있다.

```text
프로세스 가상 메모리

+----------------------------------+
| Thread 1 stack                   |
+----------------------------------+
| Thread 2 stack                   |
+----------------------------------+
| Thread 3 stack                   |
+----------------------------------+
|                                  |
| mmap region                      |
|  +----------------------------+  |
|  | arena #2 heap              |  |
|  | heap_info                  |  |
|  | malloc_state               |  |
|  | chunks                     |  |
|  +----------------------------+  |
|                                  |
| mmap region                      |
|  +----------------------------+  |
|  | arena #3 heap              |  |
|  | heap_info                  |  |
|  | malloc_state               |  |
|  | chunks                     |  |
|  +----------------------------+  |
|                                  |
| libc mapping                     |
|   └── main_arena                 |
|                                  |
+----------------------------------+
| [heap]                           |
|   chunks                         |
|   top chunk                      |
|        ↑                         |
|        └── main_arena가 관리     |
+----------------------------------+
| data / bss                       |
+----------------------------------+
| text                             |
+----------------------------------+
```

위 그림은 개념을 설명하기 위해 단순화한 것이다.

중요한 점은 다음과 같다.

- 여러 thread는 하나의 프로세스 가상 주소 공간을 공유한다.
- 각 thread는 자신의 stack을 가진다.
- main arena는 main heap을 관리한다.
- 추가 arena는 별도의 heap 영역을 사용할 수 있다.
- arena와 thread는 1:1 관계가 아니다.

---

## 4. `malloc_state`

glibc에서는 arena의 상태를 `struct malloc_state` 구조체로 표현한다.

glibc 2.31의 `malloc.c`에서는 다음과 같은 형태로 정의되어 있다.

```c
struct malloc_state
{
  /* Serialize access.  */
  __libc_lock_define (, mutex);

  /* Flags (formerly in max_fast).  */
  int flags;

  /* Set if the fastbin chunks contain recently inserted free blocks.  */
  /* Note this is a bool but not all targets support atomics on booleans.  */
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

  /* Linked list */
  struct malloc_state *next;

  /* Linked list for free arenas.  Access to this field is serialized
     by free_list_lock in arena.c.  */
  struct malloc_state *next_free;

  /* Number of threads attached to this arena.  0 if the arena is on
     the free list.  Access to this field is serialized by
     free_list_lock in arena.c.  */
  INTERNAL_SIZE_T attached_threads;

  /* Memory allocated from the system in this arena.  */
  INTERNAL_SIZE_T system_mem;
  INTERNAL_SIZE_T max_system_mem;
};
```

각 필드의 의미를 간단히 살펴본다.

---

### 4.1 `mutex`

```c
__libc_lock_define (, mutex);
```

해당 arena에 대한 동시 접근을 제어하기 위한 lock이다.

하나의 arena를 여러 thread가 공유할 수 있기 때문에 두 thread가 동시에 `top`, `bins` 등의 allocator 상태를 수정하면 문제가 발생할 수 있다.

```text
Thread A ─┐
          ├──> arena
Thread B ─┘
             ↑
           mutex
```

arena에 대한 주요 상태 변경은 이러한 동기화를 통해 보호된다.

여러 arena를 사용하는 이유 역시 하나의 arena의 mutex에 모든 thread가 몰리는 상황을 줄이기 위함이다.

---

### 4.2 `top`

```c
mchunkptr top;
```

현재 arena의 **top chunk를 가리키는 포인터**이다.

```text
malloc_state
     |
     | top
     v
+--------------------+
|     top chunk      |
+--------------------+
```

top chunk는 일반적인 bin에 들어가 있지 않은 heap 끝부분의 사용 가능한 chunk이다.

malloc이 top chunk를 분할하면 `top`은 남은 새로운 top chunk를 가리킨다.

```text
before

top
 |
 v
+---------------------------+
|         top chunk         |
+---------------------------+


after

+------------+--------------+
| allocated  |   new top    |
+------------+--------------+
              ^
              |
             top
```

---

### 4.3 `next`

```c
struct malloc_state *next;
```

존재하는 arena들을 연결하기 위한 포인터이다.

arena들은 `next`를 통해 서로 연결된다.

```text
main_arena
    |
   next
    v
arena #2
    |
   next
    v
arena #3
    |
    +----------> main_arena
```

즉 일반적인 `NULL`로 끝나는 linked list가 아니라 다시 `main_arena`로 돌아오는 형태로 연결된다.

`main_arena`는 이 arena 리스트를 순회할 때 기준점 역할을 한다.

---

### 4.4 `next_free`

```c
struct malloc_state *next_free;
```

`next`와는 목적이 다르다.

`next`가 존재하는 arena 전체를 연결한다면, `next_free`는 현재 특정 thread에 붙어 있지 않아 재사용할 수 있는 arena들을 연결하는 데 사용된다.

```text
전체 arena

main_arena → arena A → arena B → main_arena
        next를 이용


사용 가능한 arena

free_list → arena B → arena C → ...
                  next_free를 이용
```

여기서 `free`는 arena 구조체 자체가 해제되었다는 의미가 아니다.

현재 사용하는 thread가 없어 다른 thread가 다시 사용할 수 있는 arena라는 의미이다.

---

### 4.5 `attached_threads`

```c
INTERNAL_SIZE_T attached_threads;
```

현재 해당 arena에 연결된 thread 수를 나타낸다.

예를 들어:

```text
Thread A ─┐
Thread B ─┼──> arena
Thread C ─┘
```

라면 개념적으로:

```text
attached_threads = 3
```

이 된다.

해당 arena에 연결된 thread가 하나도 없으면:

```text
attached_threads = 0
```

이 될 수 있으며, 이러한 arena는 재사용 가능한 arena 목록에 들어갈 수 있다.

---

### 4.6 `system_mem`, `max_system_mem`

```c
INTERNAL_SIZE_T system_mem;
INTERNAL_SIZE_T max_system_mem;
```

`system_mem`은 해당 arena가 시스템으로부터 확보한 메모리 양을 나타내는 상태값이다.

이 값은 현재 사용 중인 chunk의 크기를 단순히 모두 더한 값과는 다르다.

arena가 확보한 메모리에는 다음과 같은 영역이 모두 포함될 수 있다.

```text
arena가 확보한 메모리

+---------------------+
| allocated chunk     |
+---------------------+
| free chunk          |
+---------------------+
| allocated chunk     |
+---------------------+
| top chunk           |
+---------------------+
```

`max_system_mem`은 `system_mem`이 지금까지 도달했던 최대 크기를 기록한다.

---

### 4.7 `fastbinsY`, `bins`, `binmap`

```c
mfastbinptr fastbinsY[NFASTBINS];

mchunkptr bins[NBINS * 2 - 2];

unsigned int binmap[BINMAPSIZE];
```

이 필드들은 해제된 chunk를 관리하기 위한 free list와 관련되어 있다.

`fastbinsY`는 fastbin들을 관리하고, `bins`는 unsorted bin, small bin, large bin 등의 관리에 사용된다.

`binmap`은 특정 bin을 탐색할 때 불필요한 검색을 줄이기 위한 bitmap이다.

각 bin의 구조와 실제 동작은 이후 장에서 자세히 다룬다.

---

### 4.8 기타 필드

#### `flags`

```c
int flags;
```

해당 arena의 여러 상태를 나타내는 flag 값을 저장한다.

#### `have_fastchunks`

```c
int have_fastchunks;
```

fastbin에 최근 삽입된 free chunk가 존재할 가능성을 나타내는 상태값이다.

#### `last_remainder`

```c
mchunkptr last_remainder;
```

small request를 처리하면서 chunk를 분할했을 때 남은 remainder와 관련된 포인터이다.

구체적인 동작은 이후 allocator의 chunk 재사용 과정을 살펴보면서 다시 다룬다.

---

### 4.9 정리

| 필드 | 역할 |
|---|---|
| `mutex` | arena 접근 동기화 |
| `flags` | arena 상태 flag |
| `have_fastchunks` | fastbin 관련 상태 |
| `fastbinsY` | fastbin 리스트 관리 |
| `top` | top chunk 포인터 |
| `last_remainder` | 최근 split에서 남은 remainder |
| `bins` | unsorted/small/large bin 관리 |
| `binmap` | bin 검색 최적화용 bitmap |
| `next` | 전체 arena 연결 |
| `next_free` | 재사용 가능한 arena 연결 |
| `attached_threads` | 해당 arena에 연결된 thread 수 |
| `system_mem` | 시스템에서 확보한 메모리 양 |
| `max_system_mem` | 과거 최대 `system_mem` |

---

## 5. `heap_info`

`heap_info`는 non-main arena가 사용하는 **개별 heap 영역의 정보를 저장하는 구조체**이다.

`malloc_state`가 arena 자체의 allocator 상태를 저장한다면, `heap_info`는 해당 heap 영역이 어느 arena에 속하는지와 heap의 크기 등의 정보를 저장한다.

개념적으로 둘의 역할은 다음과 같이 구분할 수 있다.

```text
malloc_state
→ arena의 상태
→ top, bins, fastbins, mutex 등

heap_info
→ 개별 heap 영역의 상태
→ 어느 arena 소속인지
→ heap의 크기
→ 이전 heap 영역
```

#### `typedef struct _heap_info`

glibc 2.31에서 `heap_info`는 다음과 같은 형태를 가진다.

```c
typedef struct _heap_info
{
    mstate ar_ptr;
    struct _heap_info *prev;
    size_t size;
    size_t mprotect_size;
    ...
} heap_info;
```

주요 필드는 다음과 같다.

- `ar_ptr`
  - 해당 heap을 관리하는 arena의 `malloc_state`를 가리킨다.
- `prev`
  - 같은 arena에 속한 이전 heap 영역을 가리킨다.
- `size`
  - 현재 heap 영역의 크기를 저장한다.
- `mprotect_size`
  - 현재 heap에서 접근 가능하도록 설정된 메모리 크기와 관련된 값이다.

특히 `ar_ptr`을 통해 heap에서 자신을 관리하는 arena를 찾을 수 있다.

```text
heap
 |
 | heap_info.ar_ptr
 v
malloc_state
 |
 v
arena
```

즉 `malloc_state`가 자신이 관리하는 heap의 시작 주소와 끝 주소를 직접 저장하는 방식이라기보다, non-main heap 쪽의 `heap_info`가 자신이 어느 arena에 속하는지를 나타낸다.

#### 예시

arena A가 heap #1와 heap #2를 관리한다고 하면 다음과 같은 형태로 나타날 수 있다. 

```text
                 arena A
                    |
          +---------+---------+
          |                   |
          v                   v

       heap #1             heap #2
+----------------+   +----------------+
| heap_info      |   | heap_info      |
| malloc_state   |   | chunks         |
| chunks         |   | top chunk      |
+----------------+   +----------------+
```

non-main arena의 최초 heap에는 해당 arena의 `malloc_state`가 함께 저장된다.

하지만 이후 추가된 heap마다 새로운 `malloc_state`가 만들어지는 것은 아니다. 
이미 heap #1에 arena A를 표현하는 `malloc_state` 인스턴스가 저장되어 있기 때문에 이를 중복으로 만들 필요가 없다. 

첫 haep 이후 추가되는 heap들은 `heap_info.ar_ptr`를 통해 그 arena의 `malloc_state`를 가리킨다.

```text
heap #1                         heap #2

heap_info                      heap_info
   |                              |
   | ar_ptr                       | ar_ptr
   +-------------+----------------+
                 |
                 v
             malloc_state
             (arena A)
```

또한 `heap_info.prev`를 이용하여 같은 arena에 속한 이전 heap 영역을 연결할 수 있다.

```text
heap #3
   |
  prev
   v
heap #2
   |
  prev
   v
heap #1
```

따라서 `malloc_state`와 `heap_info`의 관계는 다음과 같이 정리할 수 있다.

```text
malloc_state
= arena 하나의 allocator 상태
= arena당 하나

heap_info
= 개별 non-main heap 영역의 정보
= heap 영역마다 하나
```

---

## 6. arena의 생성과 생명주기

### 6.1 `main_arena`

`main_arena`는 필요할 때 동적으로 `malloc()`으로 생성되는 객체가 아니다.

glibc 내부에 미리 정의되어 있는 전역 `malloc_state` 인스턴스이다.

개념적으로는 다음과 같다.

```text
프로그램 시작
    |
    v
dynamic loader가 libc를 프로세스에 매핑
    |
    v
libc의 전역 데이터가 메모리에 존재
    |
    v
main_arena도 존재
```

따라서 main arena의 관리 구조체 자체는 첫 번째 `malloc()` 호출 이전에도 존재할 수 있다.

단, `main_arena` 구조체가 존재하는 것과 실제 heap 메모리가 확보되어 있는 것은 다른 문제이다.

```text
main_arena
→ 관리 객체

[heap]
→ 실제 chunk들이 존재할 메모리
```

allocator가 실제 메모리를 필요로 하면 시스템으로부터 메모리를 확보하고 이를 arena가 관리하게 된다.

---

### 6.2 non-main arena의 생성

추가 arena들은 처음부터 최대 개수만큼 모두 생성되어 있는 것이 아니다.

멀티스레드 환경에서 추가적인 arena가 필요할 경우 동적으로 생성될 수 있다.

```text
프로세스 시작

main_arena
    |
    v
존재


thread 증가 / allocator 사용

    |
    v

추가 arena 필요
    |
    v
arena #2 생성

    |
    v

필요하면 arena #3 생성
```

따라서 main arena와 non-main arena의 생성 방식은 서로 다르다.

---

### 6.3 thread 종료

thread가 종료되었다고 해서 해당 thread가 사용하던 arena 구조체가 즉시 사라지는 것은 아니다.

thread가 arena에서 분리되면 해당 arena의 `attached_threads`가 감소한다.

```text
Thread A
   |
   v
arena #2

attached_threads = 1
```

Thread A가 종료되어 더 이상 arena를 사용하지 않으면:

```text
arena #2

attached_threads = 0
```

이 될 수 있다.

이 경우 arena 자체를 제거하는 대신 재사용 가능한 arena로 관리할 수 있다.

---

### 6.4 arena 재사용

현재 연결된 thread가 없는 arena는 이후 다른 thread가 사용할 수 있다.

```text
Thread A 종료
    |
    v
arena #2

attached_threads = 0
    |
    v
재사용 가능한 arena
```

이후 새로운 thread가 arena를 필요로 하면:

```text
Thread B
    |
    v
기존 arena #2 재사용
```

할 수 있다.

즉 arena는 thread가 생성되고 종료될 때마다 반드시 새로 만들고 파괴하는 객체가 아니다.

---

### 6.5 프로세스 종료

`main_arena`는 프로세스 실행 동안 존재한다.

추가 arena 역시 일반적인 동작에서는 thread가 종료되었다는 이유만으로 즉시 제거되는 것이 아니라 재사용될 수 있는 상태로 남을 수 있다.

최종적으로 프로세스가 종료되면 프로세스가 사용하던 가상 주소 공간 자체가 운영체제에 의해 정리된다.

따라서 그 안에 존재하던 `main_arena` 및 추가 arena의 `malloc_state` 인스턴스 역시 함께 사라진다.

개념적으로 정리하면 다음과 같다.

```text
프로세스 시작
│
├── main_arena 존재
│
├── thread에서 추가 arena 필요
│      └── arena #2 생성
│
├── 추가 arena 필요
│      └── arena #3 생성
│
├── thread 종료
│      └── arena #2 재사용 가능
│
├── 새로운 thread
│      └── arena #2 재사용 가능
│
└── 프로세스 종료
       └── 프로세스 가상 주소 공간과 함께 arena들도 사라짐
```

---

## 7. 실습

이번 실습에서는 두 개의 thread에서 반복적으로 `malloc()`을 호출하여 main arena와 non-main arena를 생성하고, gdb를 이용해 실제 `malloc_state` 구조체와 heap의 관계를 확인한다.

관찰할 내용은 다음과 같다.

- main arena와 non-main arena의 생성 여부
- arena들이 `next`를 통해 연결되는 구조
- 각 arena의 `top`, `attached_threads`, `system_mem`
- main arena와 non-main arena가 위치한 메모리 영역
- non-main heap의 `heap_info`
- `heap_info`와 `malloc_state`의 연결 관계

---

### 7.1 실습 코드와 실행 준비

실습 코드는 다음과 같다.

```c
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
```

main thread와 worker thread가 barrier 이후 동시에 `malloc(0x100)`을 반복적으로 호출하도록 구성하였다.

멀티스레드 프로그램이라고 해서 항상 non-main arena가 생성되는 것은 아니다.

따라서 이번 실습에서는 두 thread가 동시에 allocator를 사용하도록 하여 arena에 대한 경합이 발생하도록 한다.

먼저 `main()`의 어셈블리를 확인한다.

```gdb
(gdb) disas main
```

main thread에서 반복적으로 호출되는 `malloc(0x100)`은 다음과 같이 나타난다.

```text
0x0000000000001308 <+99>:   mov    edi,0x100
0x000000000000130d <+104>:  call   0x10f0 <malloc@plt>
0x0000000000001312 <+109>:  mov    QWORD PTR [rbp-0x10],rax
```

worker thread 역시 동일한 크기의 메모리를 반복적으로 할당한다.

```gdb
(gdb) disas worker
```

```text
0x000000000000124e <+37>:   mov    edi,0x100
0x0000000000001253 <+42>:   call   0x10f0 <malloc@plt>
0x0000000000001258 <+47>:   mov    QWORD PTR [rbp-0x8],rax
```

이번 실습에서는 반복 할당이 끝난 뒤 arena 상태를 확인하기 위해 main thread의 두 번째 barrier 직전에 breakpoint를 설정하였다.

```gdb
(gdb) b *main+167
Breakpoint 1 at 0x134c: file sample.c, line 47.

(gdb) r
```

실행 후 다음과 같이 breakpoint에 도달하였다.

```text
main last chunk   = 0x5555557f13b0

Thread 1 "sample231" hit Breakpoint 1, main () at sample.c:47
47	    pthread_barrier_wait(&barrier);
```

현재 존재하는 thread도 확인한다.

```gdb
(gdb) info threads
```

```text
  Id   Target Id                                  Frame
* 1    Thread 0x7ffff7da9740 (LWP 23) "sample231" main () at sample.c:47
  2    Thread 0x7ffff7da8700 (LWP 27) "sample231" ...
```

main thread와 worker thread 두 개가 존재하는 것을 확인할 수 있다.

---

### 7.2 main arena와 non-main arena 확인

먼저 `main_arena`의 주소를 확인한다.

```gdb
(gdb) p/x &main_arena
$1 = 0x7ffff7f98b80
```

다음으로 `main_arena.next`를 확인한다.

```gdb
(gdb) p/x main_arena.next
$2 = 0x7ffff0000020
```

`main_arena` 자신의 주소와 다른 값이 나오므로 추가 arena가 생성되었음을 알 수 있다.

다음 arena의 `next`를 다시 따라가 본다.

```gdb
(gdb) p/x main_arena.next->next
$3 = 0x7ffff7f98b80
```

이 값은 처음 확인한 `&main_arena`와 같다.

따라서 현재 arena들은 다음과 같은 원형 연결 구조를 가진다.

```text
main_arena
0x7ffff7f98b80
      |
      | next
      v
non-main arena
0x7ffff0000020
      |
      | next
      v
main_arena
```

즉 이번 실행에서는 main arena와 하나의 non-main arena가 존재한다.

각 arena의 주요 상태도 비교한다.

```gdb
(gdb) p/x main_arena.top
$4 = 0x5555557f18c0

(gdb) p/x main_arena.next->top
$5 = 0x7ffff01a7fb0
```

두 arena의 top chunk는 서로 다른 주소 영역에 존재한다.

```text
main_arena.top
= 0x5555557f18c0

non-main arena.top
= 0x7ffff01a7fb0
```

각 arena에 연결된 thread 수도 확인한다.

```gdb
(gdb) p main_arena.attached_threads
$6 = 1

(gdb) p main_arena.next->attached_threads
$7 = 1
```

이번 실행 시점에서는 두 arena 모두 하나의 thread가 연결되어 있다.

단, 일반적으로 thread와 arena가 항상 1:1 관계를 가지는 것은 아니다.

각 arena가 시스템으로부터 확보한 메모리 크기도 확인한다.

```gdb
(gdb) p/x main_arena.system_mem
$8 = 0x2b5000

(gdb) p/x main_arena.next->system_mem
$9 = 0x1a8000
```

main arena는 `0x2b5000`, non-main arena는 `0x1a8000`의 `system_mem` 값을 가지고 있다.

구조체 전체를 직접 출력할 수도 있다.

```gdb
(gdb) p main_arena
```

주요 필드는 다음과 같이 나타난다.

```text
mutex = 0
flags = 0
have_fastchunks = 0

top = 0x5555557f18c0

next = 0x7ffff0000020
next_free = 0x0

attached_threads = 1

system_mem = 2838528
max_system_mem = 2838528
```

실제 출력에서도 `top`, `next`, `attached_threads`, `system_mem` 등의 arena 상태를 확인할 수 있다.

non-main arena도 동일하게 확인한다.

```gdb
(gdb) p *main_arena.next
```

```text
mutex = 1
flags = 2
have_fastchunks = 0

top = 0x7ffff01a7fb0

next = 0x7ffff7f98b80 <main_arena>
next_free = 0x0

attached_threads = 1

system_mem = 1736704
max_system_mem = 1736704
```

non-main arena 역시 동일한 `malloc_state` 구조체를 사용하며, `next`를 통해 다시 main arena를 가리킨다.

이를 간단히 정리하면 다음과 같다.

```text
main_arena
├── top = 0x5555557f18c0
├── next = non-main arena
├── attached_threads = 1
└── system_mem = 0x2b5000


non-main arena
├── top = 0x7ffff01a7fb0
├── next = main_arena
├── attached_threads = 1
└── system_mem = 0x1a8000
```

---

### 7.3 메모리 mapping과 heap 위치 확인

앞에서 확인한 arena와 top chunk가 실제 프로세스의 가상 메모리 어디에 위치하는지 확인한다.

```gdb
(gdb) info proc mappings
```

main heap은 다음과 같이 나타난다.

```text
0x555555559000  0x55555580e000  0x2b5000  [heap]
```

앞에서 확인한 `main_arena.top`은:

```text
0x5555557f18c0
```

이므로 `[heap]` 영역 내부에 존재한다.

```text
[heap]

0x555555559000
       |
       | allocated chunks
       | ...
       v
0x5555557f18c0  ← main_arena.top
       |
       v
0x55555580e000
```

이번 실행에서는 `[heap]` mapping의 크기인 `0x2b5000`과 `main_arena.system_mem`의 값도 동일하게 나타났다.

`main_arena` 구조체 자체는 다음 주소에 존재한다.

```text
0x7ffff7f98b80
```

mapping을 확인하면 이 주소는 libc의 writable mapping 내부에 존재한다.

따라서 main arena는 다음과 같이 볼 수 있다.

```text
libc mapping
+---------------------------+
| main_arena                |
|                           |
| top ----------------------|------+
+---------------------------+      |
                                   v
[heap]
+---------------------------+
| allocated chunks          |
| ...                       |
| top chunk                 |
+---------------------------+
```

반면 non-main arena의 주소는:

```text
0x7ffff0000020
```

이며 다음 anonymous mapping 내부에 존재한다.

```text
0x7ffff0000000  0x7ffff01a9000  0x1a9000
```

non-main arena의 top 역시:

```text
0x7ffff01a7fb0
```

으로 같은 anonymous mapping 내부에 존재한다.

즉 main arena와 non-main arena의 메모리 배치는 다음과 같이 서로 다르다.

```text
main arena

malloc_state
→ libc mapping

top chunk
→ [heap]
```

```text
non-main arena

malloc_state
→ anonymous mmap 영역

top chunk
→ 같은 mmap 기반 heap 영역
```

---

### 7.4 non-main heap과 `heap_info` 확인

마지막으로 non-main arena가 사용하는 heap 영역의 시작 부분을 직접 확인한다.

```gdb
(gdb) x/16gx 0x7ffff0000000
```

```text
0x7ffff0000000:  0x00007ffff0000020  0x0000000000000000
0x7ffff0000010:  0x00000000001a8000  0x00000000001a8000
0x7ffff0000020:  0x0000000200000001  0x0000000000000000
...
```

첫 `0x20`바이트는 non-main heap의 `heap_info`에 해당한다.

64bit 환경에서 각 값을 대응시키면 다음과 같다.

```text
0x7ffff0000000
+-------------------------------+
| ar_ptr = 0x7ffff0000020       |
+-------------------------------+
| prev = 0x0                    |
+-------------------------------+
| size = 0x1a8000               |
+-------------------------------+
| mprotect_size = 0x1a8000      |
+-------------------------------+
0x7ffff0000020
```

특히 `ar_ptr`의 값이 중요하다.

```text
heap_info.ar_ptr
= 0x7ffff0000020
```

앞에서 확인한 non-main arena의 주소 역시:

```text
main_arena.next
= 0x7ffff0000020
```

이다.

따라서 실제 메모리에서 다음 관계를 확인할 수 있다.

```text
heap_info
0x7ffff0000000
    |
    | ar_ptr
    v
malloc_state
0x7ffff0000020
    |
    v
non-main arena
```

즉 non-main heap의 `heap_info`가 자신을 관리하는 arena의 `malloc_state`를 가리킨다.

non-main arena 주소부터 메모리를 다시 확인하면 다음과 같다.

```gdb
(gdb) x/16gx main_arena.next
```

```text
0x7ffff0000020:  0x0000000200000001  0x0000000000000000
...
0x7ffff0000080:  0x00007ffff01a7fb0  0x0000000000000000
0x7ffff0000090:  0x00007ffff0000080  0x00007ffff0000080
```

실제 non-main `malloc_state`는 `0x7ffff0000020`부터 시작한다.

따라서 이번 실습에서 확인한 non-main heap의 시작 부분은 다음과 같이 나타낼 수 있다.

```text
+-----------------------------+ 0x7ffff0000000
| heap_info                   |
|                             |
| ar_ptr = 0x7ffff0000020     |
| prev = NULL                 |
| size = 0x1a8000             |
| mprotect_size = 0x1a8000    |
+-----------------------------+ 0x7ffff0000020
|                             |
| struct malloc_state         |
|                             |
| mutex                       |
| flags                       |
| fastbinsY                   |
| top                         |
| bins                        |
| ...                         |
+-----------------------------+
|                             |
| allocated chunks            |
|                             |
+-----------------------------+
| top chunk                   |
| 0x7ffff01a7fb0              |
+-----------------------------+
```

이번 실행에서는 `heap_info.size`와 non-main arena의 `system_mem`이 모두 `0x1a8000`으로 나타났다.

```text
heap_info.size
= 0x1a8000

non-main arena.system_mem
= 0x1a8000
```

이를 통해 `malloc_state`가 자신이 관리하는 heap의 시작과 끝 범위를 직접 저장하는 것이 아니라, non-main heap의 `heap_info`가 `ar_ptr`을 통해 자신을 관리하는 arena를 가리키는 구조임을 확인할 수 있다.

---

## 8. 정리

이번 실습에서는 두 thread에서 반복적으로 `malloc()`을 호출하여 main arena와 non-main arena를 직접 관찰하였다.

`main_arena.next`를 따라가면서 두 arena가 원형 연결 리스트 형태로 연결되어 있음을 확인했다.

```text
main_arena
    |
   next
    v
non-main arena
    |
   next
    v
main_arena
```

main arena의 `malloc_state`는 libc mapping 내부에 존재했으며, `top`은 `[heap]` 영역을 가리켰다.

반면 non-main arena의 `malloc_state`와 `top`은 별도의 anonymous mmap 영역에 존재했다.

또한 non-main heap의 시작 주소에서 `heap_info`를 직접 확인하였다.

```text
heap_info.ar_ptr
      |
      v
malloc_state
      |
      v
non-main arena
```

이번 실습에서 확인한 전체 관계를 단순화하면 다음과 같다.

```text
                    libc mapping

                +------------------+
                | main_arena       |
                | malloc_state     |
                |                  |
                | top ----------+  |
                | next -----+   |  |
                +-----------|---|--+
                            |   |
                            |   v
                            | [heap]
                            | chunks
                            | top chunk
                            |
                            v

                anonymous mmap region

                +------------------+
                | heap_info        |
                | ar_ptr -------+  |
                +--------------|---+
                               |
                +--------------v---+
                | malloc_state     |
                | non-main arena   |
                |                  |
                | top ----------+  |
                | next ---------|--|---> main_arena
                +---------------|--+
                                |
                +---------------v-+
                | chunks          |
                | ...             |
                | top chunk       |
                +-----------------+
```

main arena와 non-main arena는 동일한 `malloc_state` 구조체를 사용하지만, 실제 구조체의 위치와 관리하는 heap의 형태에는 차이가 있음을 확인할 수 있었다.
