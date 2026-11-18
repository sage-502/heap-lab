# malloc-free

## 1. malloc

### 1.1 `__libc_malloc()`

`__libc_malloc()`은 사용자가 `malloc()`으로 요청한 메모리 크기를 전달받아 할당을 처리하는 함수이다.

먼저 malloc hook과 tcache를 확인하고, tcache에서 요청을 처리할 수 없다면 arena를 선택하여 `_int_malloc()`을 호출한다.

#### 1) 초기화 및 malloc hook 확인

```c
void *
__libc_malloc (size_t bytes)
{
  mstate ar_ptr;
  void *victim;

  _Static_assert (PTRDIFF_MAX <= SIZE_MAX / 2,
                  "PTRDIFF_MAX is not more than half of SIZE_MAX");
```

`bytes`는 사용자가 요청한 메모리 크기이며, 할당에 성공하면 사용자 데이터 영역의 주소를 반환하고 실패하면 `NULL`을 반환한다.

지역 변수의 역할은 다음과 같다.

- `ar_ptr`: 할당에 사용할 arena를 가리키는 포인터
- `victim`: `_int_malloc()`이 반환한 사용자 데이터 영역의 주소를 저장할 포인터

`_Static_assert()`는 컴파일 시점에 allocator의 크기 계산 로직이 전제로 하는 자료형의 표현 범위가 유효한지 검사한다.

이후 `__malloc_hook`을 확인한다.

```c
void *(*hook) (size_t, const void *)
  = atomic_forced_read (__malloc_hook);

if (__builtin_expect (hook != NULL, 0))
  return (*hook)(bytes, RETURN_ADDRESS (0));
```

malloc hook이 설정되어 있으면 해당 함수를 호출하고 결과를 반환한다. 이 경우 이후의 일반적인 malloc 처리 과정은 실행되지 않는다.

malloc hook은 과거 메모리 할당 추적과 디버깅 등에 사용되었지만, 보안 및 유지보수 등의 문제로 glibc 2.34부터 일반적인 malloc 동작에서 제거되었다.

#### 2) 요청 크기 계산 및 tcache 확인

malloc hook이 설정되어 있지 않다면 tcache를 확인하기 위한 준비 작업을 수행한다.

```c
#if USE_TCACHE
  size_t tbytes;

  if (!checked_request2size (bytes, &tbytes))
    {
      __set_errno (ENOMEM);
      return NULL;
    }

  size_t tc_idx = csize2tidx (tbytes);

  MAYBE_INIT_TCACHE ();
```

`checked_request2size()`는 사용자가 요청한 크기 `bytes`를 검증하고, 정렬과 chunk 메타데이터 등을 고려하여 내부 chunk 크기인 `tbytes`를 계산한다. 유효하지 않은 크기라면 `ENOMEM`을 설정하고 `NULL`을 반환한다.

예를 들어 x86-64 glibc 2.31 환경에서 `malloc(0x20)`을 요청하면 내부 chunk 크기는 `0x30`이 된다.

`csize2tidx()`는 계산된 chunk 크기에 대응하는 tcache bin의 인덱스를 구한다.

`MAYBE_INIT_TCACHE()`는 현재 스레드의 tcache 관리 구조체가 존재하지 않을 경우, 이를 위한 메모리를 할당하고 초기화한다. 이미 초기화되어 있다면 별도의 작업을 수행하지 않는다.

이후 해당 tcache bin에 재사용 가능한 chunk가 있는지 확인한다.

```c
if (tc_idx < mp_.tcache_bins
    && tcache
    && tcache->counts[tc_idx] > 0)
  {
    return tcache_get (tc_idx);
  }
```

조건은 다음과 같다.

- `tc_idx < mp_.tcache_bins`: 계산한 인덱스가 사용 가능한 tcache bin 범위에 포함되는가?
- `tcache`: 현재 스레드의 tcache가 존재하는가?
- `tcache->counts[tc_idx] > 0`: 해당 bin에 저장된 chunk가 있는가?

모든 조건을 만족하면 `tcache_get()`으로 chunk를 꺼내 사용자에게 반환한다.

따라서 tcache에서 요청을 처리할 수 있다면 arena를 선택하거나 `_int_malloc()`을 호출하지 않고 할당을 마칠 수 있다.

#### 3) Arena 선택 및 `_int_malloc()` 호출

tcache에서 요청을 처리하지 못했다면 `_int_malloc()`을 호출한다.

이때 단일 스레드와 멀티스레드 환경에 따라 사용하는 arena를 결정하는 방식이 달라진다.

먼저 단일 스레드인 경우이다.

```c
if (SINGLE_THREAD_P)
  {
    victim = _int_malloc (&main_arena, bytes);
    // ...
    return victim;
  }
```

`SINGLE_THREAD_P`는 현재 프로세스가 단일 스레드 상태인지 확인한다.

단일 스레드라면 `main_arena`를 이용하여 `_int_malloc()`을 호출하고 결과를 반환한다.

반면 멀티스레드 환경에서는 사용할 arena를 확보해야 한다.

```c
arena_get (ar_ptr, bytes);

victim = _int_malloc (ar_ptr, bytes);
```

`arena_get()`은 현재 스레드에서 사용할 arena를 확보하고, 필요한 경우 해당 arena의 mutex를 잠근다.

이후 확보한 arena를 전달하여 `_int_malloc()`을 호출한다.

`_int_malloc()`은 fastbin, 일반 bin, top chunk 등을 이용하여 실제 메모리 할당을 처리하는 내부 함수이며, 다음 절에서 자세히 살펴본다.

#### 4) 할당 실패 시 재시도 및 반환

멀티스레드 경로에서 `_int_malloc()`이 할당에 실패하면 다른 arena를 이용하여 재시도할 수 있다.

```c
if (!victim && ar_ptr != NULL)
  {
    LIBC_PROBE (memory_malloc_retry, 1, bytes);
    ar_ptr = arena_get_retry (ar_ptr, bytes);
    victim = _int_malloc (ar_ptr, bytes);
  }
```

`victim`이 `NULL`이고 기존에 사용할 수 있는 arena가 있었다면, `arena_get_retry()`를 통해 다른 arena에서 재시도를 수행한다.

이후 arena의 mutex를 해제하고 할당 결과를 반환한다.

```c
if (ar_ptr != NULL)
  __libc_lock_unlock (ar_ptr->mutex);

// assert(...);
return victim;
```

실제 코드에는 반환할 chunk가 올바른 arena에 속하는지 확인하는 `assert()`도 존재한다. 단, `mmap`으로 할당된 chunk는 별도로 허용한다.

#### 전체 흐름

지금까지 살펴본 `__libc_malloc()`의 실행 흐름은 다음과 같다.

```text
__libc_malloc(bytes)
    ↓
malloc hook 확인
    ├─ 존재 → hook 호출 → 반환
    ↓
요청 크기 검사 및 tcache index 계산
    ↓
tcache 초기화 및 탐색
    ├─ chunk 존재 → tcache_get() → 반환
    ↓
SINGLE_THREAD_P 확인
    ├─ 단일 스레드
    │     ↓
    │  _int_malloc(&main_arena, bytes)
    │     ↓
    │    반환
    │
    └─ 멀티스레드
          ↓
       arena_get()
          ↓
       _int_malloc()
          ↓
       실패 시 다른 arena에서 재시도
          ↓
       mutex 해제
          ↓
         반환
```

위 흐름에서 tcache 관련 처리는 `USE_TCACHE`가 활성화된 경우에 해당한다.

`__libc_malloc()`은 직접 모든 free list를 탐색하는 함수가 아니다. 먼저 tcache에서 재사용 가능한 chunk를 확인하고, 이를 통해 할당할 수 없다면 적절한 arena를 선택하여 `_int_malloc()`에 실제 할당 처리를 맡긴다.

다음 절에서는 `_int_malloc()`이 free chunk와 top chunk를 이용하여 메모리를 할당하는 과정을 살펴본다.

---

### 1.2 `_int_malloc()`

`_int_malloc()`은 전달받은 arena에서 재사용 가능한 chunk를 탐색하고, 적절한 chunk가 없다면 top chunk를 분할하거나 시스템에서 추가 메모리를 확보하여 할당을 처리하는 함수이다.

주요 처리 과정은 요청 크기 계산, bin 탐색, top chunk 사용, 추가 메모리 확보로 구분할 수 있다.

#### 1) 요청 크기 계산

```c
static void *
_int_malloc (mstate av, size_t bytes)
{
  INTERNAL_SIZE_T nb;

  checked_request2size (bytes, nb);
```

`av`는 할당에 사용할 arena를 가리키고, `bytes`는 사용자가 요청한 메모리 크기이다.

`checked_request2size()`를 통해 요청 크기를 검증하고, 정렬과 메타데이터 등을 고려한 내부 chunk 크기 `nb`를 계산한다.

이후 `av`가 `NULL`이라면 `sysmalloc()`을 호출하여 메모리 할당을 시도한다.

#### 2) Fastbin 및 smallbin 확인

먼저 요청 크기가 fastbin에서 관리할 수 있는 크기인지 확인한다.

```c
if ((unsigned long) (nb) <= (unsigned long) (get_max_fast ()))
{
    // 해당 fastbin에서 chunk 탐색
}
```

조건을 만족하고 해당 fastbin에 재사용 가능한 chunk가 있다면 이를 꺼내 할당에 사용한다.

fastbin에서는 동일한 크기 클래스의 chunk를 빠르게 재사용할 수 있으며, LIFO 방식으로 관리한다.

다음으로 요청 크기가 smallbin 범위에 포함되는지 확인한다.

```c
if (in_smallbin_range (nb))
{
    // 해당 smallbin에서 chunk 탐색
}
```

smallbin은 동일한 크기의 free chunk를 관리하므로, 해당 bin에 chunk가 있다면 크기가 일치하는 chunk를 꺼내 사용할 수 있다.

이 과정에서 tcache에 여유 공간이 있으면 같은 크기의 다른 chunk들을 tcache로 옮길 수도 있다.

반면 요청 크기가 smallbin 범위를 벗어난 큰 요청이라면, 이 시점에 fastbin consolidation을 수행할 수 있다.

Fastbin과 smallbin에서 적절한 chunk를 확보했다면 이후 bin 탐색이나 top chunk 분할 없이 반환할 수 있다.

#### 3) Unsorted bin 처리

fastbin과 smallbin에서 요청을 처리하지 못했다면 unsorted bin을 확인한다.

``` c
for (;;)
{
    int iters = 0;

    while ((victim = unsorted_chunks(av)->bk)
           != unsorted_chunks(av))
    {
        // ...
    }
}
```

unsorted bin은 일반적인 해제나 chunk 분할 과정에서 발생한 free chunk들이 크기별 bin으로 분류되기 전에 거치는 공간이다.

allocator는 unsorted bin의 chunk를 확인하면서 다음과 같이 처리한다.

- 요청 크기에 정확히 맞는 chunk가 있다면 재사용할 수 있다.
- 특정 small request 조건에서는 `last_remainder`를 분할하여 사용할 수 있다.
- 바로 사용하지 않는 chunk는 크기에 따라 smallbin 또는 largebin으로 분류한다.

glibc 2.31에서는 이 과정에서도 조건에 따라 chunk를 tcache에 저장할 수 있다.

따라서 unsorted bin은 단순히 다른 bin으로 옮기기 위한 대기 공간만은 아니며, 크기별 bin으로 분류하기 전에 재사용할 기회를 제공하는 역할도 한다.

#### 4) Largebin 및 추가 bin 탐색

unsorted bin에서 요청을 처리하지 못했다면 일반 bin을 추가로 탐색한다.

큰 요청의 경우 해당 largebin에서 요청 크기를 만족하는 chunk를 찾는다.

``` c
if (!in_smallbin_range (nb))
{
    bin = bin_at (av, idx);

    // 현재 largebin에서 적합한 chunk 탐색
}
```

largebin은 서로 다른 크기의 chunk를 관리하므로, 요청을 만족하는 chunk 중 적절한 크기를 선택하는 과정이 필요하다.

이후에도 할당하지 못했다면 `binmap`을 이용해 다른 일반 bin들을 탐색한다.

``` c
++idx;
bin = bin_at (av, idx);
block = idx2block (idx);
map = av->binmap[block];
bit = idx2bit (idx);
```

`binmap`은 비어 있는 bin들을 빠르게 건너뛰기 위한 비트맵이다.

이 과정에서는 요청보다 큰 free chunk를 선택할 수 있으며, 필요한 경우 다음처럼 분할한다.

```text
기존 free chunk (0x100)
          ↓
[allocated 0x40][remainder 0xc0]
```

분할 후 남은 remainder는 크기와 처리 경로에 따라 unsorted bin 등에서 관리될 수 있다.

즉, 기존 free chunk를 재사용하더라도 요청 크기에 맞게 chunk를 분할하는 과정이 발생할 수 있다.

#### 5) Top chunk 및 추가 메모리 확보

일반 bin에서도 적절한 chunk를 확보하지 못했다면 arena의 top chunk를 확인한다.

```c
victim = av->top;
size = chunksize (victim);
```

top chunk에 요청을 처리할 만큼 충분한 공간이 있다면 앞부분을 분할하여 사용자에게 할당하고, 남은 공간을 새로운 top chunk로 설정한다.

```text
Before

[          top chunk          ]
              ↓
After

[allocated][   new top chunk   ]
```

이때 `av->top`은 분할 후 남은 새로운 top chunk를 가리키도록 변경된다.

반면 top chunk의 크기가 충분하지 않다면 추가 처리가 필요하다.

fastbin에 병합할 chunk가 남아 있을 가능성이 있다면 `malloc_consolidate()`로 병합한 뒤 할당 과정을 재시도할 수 있다.

그렇지 않거나 추가 메모리가 필요한 경우에는 `sysmalloc()`을 호출한다.

`sysmalloc()`은 `brk` 계열 또는 `mmap` 등을 이용해 시스템에서 메모리를 확보하는 역할을 한다.


#### 전체 흐름

```text
_int_malloc(av, bytes)
    ↓
요청 크기 계산
    ↓
fastbin 확인 (크기 조건)
    ├─ 할당 가능 → 반환
    ↓
smallbin 확인 (크기 조건)
    ├─ 할당 가능 → 반환
    ↓
큰 요청의 fastbin consolidation
    (해당되는 경우)
    ↓
unsorted bin 처리
    ├─ 할당 가능 → 반환
    └─ 나머지 chunk 크기별 분류
    ↓
largebin 및 추가 bin 탐색
    ├─ 할당 가능 → 반환
    ↓
top chunk 확인
    ├─ 공간 충분 → 분할 후 반환
    ↓
필요 시 fastbin consolidation 및 재시도
    ↓
sysmalloc()로 추가 메모리 확보
    ↓
할당 결과 반환
```

위 흐름은 주요 처리 단계를 정리한 것이다. 실제로는 요청 크기와 allocator 상태에 따라 일부 단계를 건너뛰거나, tcache에 chunk를 저장한 후 반환하는 등의 분기가 존재한다.

`_int_malloc()`의 핵심은 기존에 확보된 free chunk를 우선 재사용하고, 적절한 chunk가 없으면 top chunk를 사용하거나 시스템에서 추가 메모리를 확보한다는 것이다.

이를 위해 fastbin, smallbin, unsorted bin, largebin 등 여러 관리 구조를 이용하며, 필요에 따라 chunk를 분할하거나 병합하기도 한다.

---

### 1.3 malloc 전체 흐름

지금까지 `__libc_malloc()`과 `_int_malloc()`의 동작을 살펴보았다.

`__libc_malloc()`은 malloc hook과 tcache를 확인하고, 필요하다면 arena를 선택하여 `_int_malloc()`을 호출한다.

`_int_malloc()`은 전달받은 arena에서 재사용 가능한 chunk를 탐색하고, 적절한 chunk가 없다면 top chunk를 사용하거나 시스템에서 추가 메모리를 확보한다.

두 함수의 전체적인 실행 흐름을 정리하면 다음과 같다.

```text
malloc(bytes)
    ↓
__libc_malloc()
    ↓
malloc hook 확인
    ├─ hook 존재 → hook 호출 → 반환
    ↓
요청 크기 검사 및 tcache index 계산
    ↓
tcache 확인
    ├─ chunk 존재 → tcache_get() → 반환
    ↓
arena 선택
    ├─ 단일 스레드 → main_arena
    └─ 멀티스레드 → arena_get()
    ↓
_int_malloc()
    ↓
요청 크기 계산
    ↓
fastbin 확인 (크기 조건)
    ├─ 할당 가능 → 반환
    ↓
smallbin 확인 (크기 조건)
    ├─ 할당 가능 → 반환
    ↓
큰 요청의 fastbin consolidation (필요 시)
    ↓
unsorted bin 처리
    ├─ 할당 가능 → 반환
    └─ 나머지 chunk를 크기별 bin에 분류
    ↓
largebin 및 추가 bin 탐색
    ├─ 할당 가능 → 반환
    ↓
top chunk 확인
    ├─ 공간 충분 → 분할 후 반환
    ↓
필요 시 fastbin consolidation 및 재시도
    ↓
sysmalloc()
    ↓
할당 결과 반환
```

위 흐름은 glibc 2.31의 주요 할당 경로를 단순화한 것이다. tcache 관련 코드는 `USE_TCACHE`가 활성화된 경우에 해당하며, 요청 크기와 allocator 상태에 따라 일부 단계는 생략되거나 반복될 수 있다.

실제 `_int_malloc()` 내부에서도 tcache를 채우거나 tcache에 저장된 chunk를 반환하는 등의 추가 분기가 존재한다.

또한 멀티스레드 환경에서는 `_int_malloc()`의 할당이 실패하면 `__libc_malloc()`에서 다른 arena를 이용해 재시도할 수 있다.

결과적으로 glibc malloc은 기존 free chunk의 재사용을 우선 시도하고, 적절한 chunk를 찾지 못하면 top chunk를 분할하거나 시스템에서 추가 메모리를 확보하는 방식으로 동작한다.

---

## 2. free 

### 2.1 `__libc_free()`

`__libc_free()`는 사용자가 `free()`에 전달한 메모리 주소를 받아 해제를 처리하는 함수이다.

먼저 free hook과 `NULL` 포인터를 확인하고, 사용자 포인터를 chunk 포인터로 변환한다. 이후 해당 chunk가 `mmap`으로 할당되었는지 확인하여 해제 방식을 결정한다.

#### 1) 초기화 및 free hook 확인

```c
void
__libc_free (void *mem)
{
  mstate ar_ptr;
  mchunkptr p;

  void (*hook) (void *, const void *)
    = atomic_forced_read (__free_hook);

  if (__builtin_expect (hook != NULL, 0))
    {
      (*hook)(mem, RETURN_ADDRESS (0));
      return;
    }
```

`mem`은 사용자가 `free()`에 전달한 포인터이며, 일반적으로 `malloc()`이 반환했던 사용자 데이터 영역의 주소이다.

지역 변수의 역할은 다음과 같다.

- `ar_ptr`: 해제할 chunk가 속한 arena를 가리키는 포인터
- `p`: 사용자 포인터 `mem`에 대응하는 chunk의 시작 주소를 저장할 포인터

이후 `__free_hook`에 별도의 함수가 등록되어 있는지 확인한다.

hook이 설정되어 있다면 해당 함수를 호출하고 반환하며, 일반적인 free 처리 과정은 실행하지 않는다.

이는 앞서 살펴본 `__malloc_hook`과 유사한 방식이다. `__free_hook` 역시 glibc 2.34부터 일반적인 free 동작에서 제거되었다.

#### 2) NULL 검사 및 chunk 포인터 변환

```c
if (mem == 0)
  return;

p = mem2chunk (mem);
```

`mem`이 `NULL`이라면 아무 작업도 수행하지 않고 반환한다. C에서 `free(NULL)`은 허용되는 동작이다.

`mem`이 유효하다면 `mem2chunk()`를 이용하여 사용자 데이터 영역의 주소를 chunk 시작 주소로 변환한다.

x86-64 glibc 2.31에서 해당 매크로는 다음과 같다.

```c
#define mem2chunk(mem) \
  ((mchunkptr)((char*)(mem) - 2*SIZE_SZ))
```

`SIZE_SZ`는 8바이트이므로 사용자 포인터에서 `0x10`을 빼면 chunk의 시작 주소가 된다.

```text
chunk 시작 주소
+------------------+
| prev_size        |  8 bytes
+------------------+
| size             |  8 bytes
+------------------+ ← mem
| user data        |
+------------------+
```

이 과정을 통해 allocator는 chunk header에 접근할 수 있게 된다.

#### 3) mmap chunk 확인

chunk 포인터로 변환한 이후에는 해당 chunk가 `mmap()`으로 할당되었는지 확인한다.

```c
if (chunk_is_mmapped (p))
  {
    // mmap 관련 임계값 조정
    munmap_chunk (p);
    return;
  }
```

`chunk_is_mmapped()`는 chunk의 `IS_MMAPPED` 플래그를 확인하는 매크로이다.

이 플래그가 설정되어 있다면 해당 chunk는 일반적인 arena의 bin에서 관리되는 chunk가 아니라, `mmap()`을 통해 별도로 확보된 메모리에 해당한다.

따라서 `munmap_chunk()`를 호출하여 해당 메모리 매핑을 해제하고 반환한다.

실제 코드에는 메모리 할당 정책에 사용되는 `mmap_threshold`, `trim_threshold` 등의 값을 조건에 따라 조정하는 처리도 존재한다.

하지만 이는 해제 경로를 이해하는 데 필수적인 내용은 아니므로 여기서는 생략한다.

mmap chunk는 일반적인 tcache, fastbin, unsorted bin에 삽입되지 않고 별도의 경로로 해제된다.

#### 4) Tcache 초기화 및 `_int_free()` 호출

mmap chunk가 아니라면 일반적인 arena chunk의 해제 과정으로 넘어간다.

```c
MAYBE_INIT_TCACHE ();

ar_ptr = arena_for_chunk (p);
_int_free (ar_ptr, p, 0);
```

`MAYBE_INIT_TCACHE()`는 malloc에서와 마찬가지로 현재 스레드의 tcache가 초기화되어 있지 않다면 초기화를 시도한다. 

이어서 `arena_for_chunk()`를 사용하여 해당 chunk가 속한 arena를 찾는다.

여기서 `__libc_malloc()`과의 차이가 나타난다.

- `malloc()`은 메모리를 할당할 arena를 선택한다.
- `free()`는 이미 할당된 chunk가 속한 arena를 찾아야 한다.

마지막으로 `_int_free()`를 호출하여 실제 chunk 해제를 처리한다.

```c
_int_free (ar_ptr, p, 0);
```

전달되는 인자의 의미는 다음과 같다.

- `ar_ptr`: 해제할 chunk가 속한 arena
- `p`: 해제할 chunk의 시작 주소
- `0`: 호출자가 arena lock을 미리 확보하지 않았음을 나타내는 값

`_int_free()`에서는 chunk의 유효성을 검사한 후, 크기와 allocator 상태에 따라 tcache, fastbin 또는 일반 free 처리 경로를 선택한다.

구체적인 해제 및 병합 과정은 다음 절에서 살펴본다.

#### 전체 흐름

```text
free(mem)
    ↓
__libc_free(mem)
    ↓
free hook 확인
    ├─ hook 존재 → hook 호출 → 반환
    ↓
NULL 포인터 검사
    ├─ mem == NULL → 반환
    ↓
mem2chunk(mem)
    ↓
mmap chunk 확인
    ├─ mmap chunk
    │     ↓
    │  필요 시 mmap 관련 임계값 조정
    │     ↓
    │  munmap_chunk()
    │     ↓
    │    반환
    ↓
MAYBE_INIT_TCACHE()
    ↓
arena_for_chunk(p)
    ↓
_int_free(ar_ptr, p, 0)
    ↓
해제 처리 완료
```

`__libc_free()`는 사용자 포인터를 chunk 포인터로 변환하고, mmap chunk인지 일반적인 arena chunk인지 구분하여 적절한 해제 경로로 전달하는 역할을 한다.

실제 free list 삽입이나 인접 chunk 병합 등의 작업은 주로 `_int_free()`에서 처리한다.

따라서 다음 절에서는 `_int_free()`가 chunk를 검증하고, tcache와 fastbin을 확인하거나 인접한 free chunk를 병합하는 과정을 살펴본다.

---

### 2.2 `_int_free()`

`_int_free()`는 전달받은 chunk를 검사하고, 크기와 allocator 상태에 따라 적절한 해제 경로를 선택하는 함수이다.

먼저 chunk의 유효성을 검사한 다음 tcache와 fastbin을 확인한다. 두 경로에서 처리되지 않은 일반 chunk는 인접한 free chunk와 병합한 뒤 unsorted bin 또는 top chunk로 관리한다.

#### 1) Chunk 크기 및 유효성 검사

```c
static void
_int_free (mstate av, mchunkptr p, int have_lock)
{
  INTERNAL_SIZE_T size;

  // ...

  size = chunksize (p);
```

인자의 의미는 다음과 같다.

- `av`: 해제할 chunk가 속한 arena
- `p`: 해제할 chunk의 시작 주소
- `have_lock`: 호출자가 arena의 mutex를 이미 확보했는지 나타내는 값

`chunksize()`는 chunk header의 `mchunk_size`에서 flag 비트를 제외한 실제 chunk 크기를 계산한다.

이후 chunk의 주소, alignment, 크기 등이 유효한지 검사한다.

```c
if (__glibc_unlikely (size < MINSIZE || !aligned_OK (size)))
  malloc_printerr ("free(): invalid size");

check_inuse_chunk(av, p);
```

실제 코드에는 주소가 잘못되었는지 확인하는 검사도 존재한다.

검사에 실패하면 `malloc_printerr()`를 통해 오류를 보고하고 프로그램을 중단한다.

이러한 검사는 잘못된 포인터나 손상된 chunk metadata를 탐지하기 위한 것이지만, 모든 메모리 손상과 double free를 완벽하게 탐지하는 것은 아니다.

#### 2) Tcache 확인

chunk가 기본 검사를 통과하면 가장 먼저 tcache에 저장할 수 있는지 확인한다.

```c
#if USE_TCACHE
size_t tc_idx = csize2tidx (size);

if (tcache != NULL && tc_idx < mp_.tcache_bins)
{
    // double free 검사

    if (tcache->counts[tc_idx] < mp_.tcache_count)
    {
        tcache_put (p, tc_idx);
        return;
    }
}
#endif
```

`csize2tidx()`를 사용하여 chunk 크기에 해당하는 tcache bin 인덱스를 계산한다.

이후 다음 조건을 확인한다.

- 현재 스레드의 tcache가 존재하는가?
- 해당 chunk 크기가 tcache에서 관리하는 범위에 속하는가?
- 해당 tcache bin에 저장할 공간이 남아 있는가?

조건을 만족하면 `tcache_put()`으로 chunk를 tcache에 삽입하고 즉시 반환한다.

glibc 2.31에서는 tcache에 삽입하기 전에 `tcache_entry`의 `key`와 연결 리스트를 이용한 double free 검사도 수행한다.

tcache에 저장된 chunk는 이 시점에서 인접 chunk와 병합하지 않는다.

따라서 이전 `chunk-layout` 실습에서 `free(b)` 이후에도 다음 chunk의 `PREV_INUSE`가 그대로 유지되었던 것이다.

#### 3) Fastbin 확인

tcache에서 처리하지 못한 chunk는 fastbin에 들어갈 수 있는지 확인한다.

```c
if ((unsigned long)(size) <= (unsigned long)(get_max_fast ())
#if TRIM_FASTBINS
    && (chunk_at_offset(p, size) != av->top)
#endif
    )
{
    // fastbin 삽입
}
```

`get_max_fast()`는 fastbin에서 관리할 수 있는 최대 chunk 크기를 나타낸다.

요청 크기가 아니라 실제 chunk 크기 `size`를 기준으로 비교한다.

`TRIM_FASTBINS`가 활성화되어 있다면 top chunk와 인접한 chunk를 fastbin에 넣지 않는 조건도 적용된다.

fastbin에 삽입하는 핵심 코드는 다음과 같다.

```c
atomic_store_relaxed (&av->have_fastchunks, true);

unsigned int idx = fastbin_index(size);
fb = &fastbin (av, idx);
```

`fastbin_index()`로 해당 크기의 fastbin 인덱스를 계산하고, `av->fastbinsY`의 연결 리스트에 chunk를 삽입한다.

fastbin은 단일 연결 리스트이며, 새 chunk를 리스트의 앞에 삽입하는 LIFO 방식을 사용한다.

이 과정에서도 일부 double free 검사와 인접 chunk의 크기 검사를 수행한다.

fastbin 역시 chunk를 삽입할 때 인접 chunk와 즉시 병합하지 않는다.

대신 `have_fastchunks`를 설정하여 이후 consolidation이 필요할 가능성을 기록한다.

#### 4) 일반 chunk 병합

tcache와 fastbin에서 처리되지 않은 일반 chunk는 인접한 free chunk와 병합할 수 있다.

먼저 필요한 경우 arena의 mutex를 확보하고, 다음 chunk의 위치와 상태를 확인한다.

```c
nextchunk = chunk_at_offset(p, size);

// chunk 유효성 검사
```

이후 이전 chunk가 free 상태인지 확인한다.

```c
if (!prev_inuse(p)) {
    prevsize = prev_size (p);
    size += prevsize;
    p = chunk_at_offset(p, -((long) prevsize));

    // 크기 검증
    unlink_chunk (av, p);
}
```

`prev_inuse(p)`가 0이라면 이전 chunk가 일반적인 병합 가능한 free 상태라는 의미이다.

`prev_size`를 이용하여 이전 chunk의 시작 주소를 구하고, 해당 chunk를 기존 bin에서 제거한 뒤 현재 chunk와 병합한다.

다음으로 뒤쪽 chunk도 확인한다.

```c
if (nextchunk != av->top) {
    nextinuse = inuse_bit_at_offset(nextchunk, nextsize);

    if (!nextinuse) {
        unlink_chunk (av, nextchunk);
        size += nextsize;
    } else
        clear_inuse_bit_at_offset(nextchunk, 0);

    // unsorted bin에 삽입
}
```

다음 chunk 역시 free 상태라면 해당 chunk를 bin에서 제거하고 크기를 합친다.

`clear_inuse_bit_at_offset(nextchunk, 0)`은 다음 chunk의 PREV_INUSE 비트를 0으로 설정하는 코드이다.

따라서 다음 chunk가 사용 중이라면 바로 다음 chunk의 `PREV_INUSE` 비트를 변경하여 현재 chunk가 free 상태임을 표시한다.

이처럼 일반 free 처리에서는 앞뒤의 인접한 free chunk를 병합하여 하나의 큰 chunk로 만들 수 있다.

```text
Before

[free A][chunk B][free C]
             ↓ free(B)

After

[     free A + B + C     ]
```

#### 5) Unsorted bin 또는 top chunk로 관리

병합을 마친 chunk의 다음 위치가 top chunk가 아니라면 unsorted bin에 삽입한다.

```c
bck = unsorted_chunks(av);
fwd = bck->fd;

// 이중 연결 리스트에 삽입

set_head(p, size | PREV_INUSE);
set_foot(p, size);
```

unsorted bin은 해제된 chunk를 곧바로 smallbin이나 largebin으로 분류하지 않고, 이후 malloc 요청에서 재사용할 기회를 주기 위한 구조이다.

반면 해제된 chunk가 top chunk와 인접해 있다면 top chunk와 병합한다.

```c
else {
    size += nextsize;
    set_head(p, size | PREV_INUSE);
    av->top = p;
}
```

이 경우에는 unsorted bin에 삽입하지 않고, 병합된 chunk를 새로운 top chunk로 관리한다.

```text
Before

[allocated A][chunk B][top chunk]
                 ↓ free(B)

After

[allocated A][    new top chunk    ]
```

따라서 일반 free 처리에서 병합된 chunk가 반드시 unsorted bin에 들어가는 것은 아니다.

#### 6) 추가 consolidation 및 메모리 반환

일반 free 처리로 확보된 chunk의 크기가 충분히 크다면 추가적인 consolidation을 수행할 수 있다.

```c
if ((unsigned long)(size) >= FASTBIN_CONSOLIDATION_THRESHOLD) {
    if (atomic_load_relaxed (&av->have_fastchunks))
        malloc_consolidate(av);

    // 필요 시 메모리 반환 처리
}
```

`FASTBIN_CONSOLIDATION_THRESHOLD`는 큰 chunk의 해제를 계기로 fastbin에 남아 있는 chunk들을 병합할지 판단하는 기준이다.

`malloc_consolidate()`는 fastbin에 저장된 chunk들을 꺼내 병합하고, 결과를 unsorted bin이나 top chunk에서 관리하도록 처리한다.

또한 top chunk가 충분히 커졌다면 `systrim()` 또는 `heap_trim()` 등을 통해 일부 메모리를 시스템에 반환하려고 시도할 수 있다.

단, 이러한 작업은 모든 free 호출에서 실행되는 것은 아니며, chunk 크기와 arena 상태 등의 조건에 따라 결정된다.

#### 전체 흐름

```text
_int_free(av, p, have_lock)
    ↓
chunk 크기 계산 및 유효성 검사
    ├─ 비정상 → 오류 처리
    ↓
tcache 확인
    ├─ 저장 가능 → tcache_put() → 종료
    ↓
fastbin 확인
    ├─ 저장 가능 → fastbin 삽입 → 종료
    ↓
일반 free 처리
    ↓
필요 시 arena lock 확보
    ↓
인접 chunk 상태 검사
    ↓
이전 free chunk와 병합 (가능한 경우)
    ↓
다음 free chunk와 병합 (가능한 경우)
    ↓
top chunk와 인접?
    ├─ Yes → top chunk와 병합
    └─ No  → unsorted bin 삽입
    ↓
큰 chunk라면 추가 consolidation 및 trimming 검토
    ↓
필요 시 mutex 해제
    ↓
해제 처리 완료
```

위 흐름은 glibc 2.31의 주요 해제 경로를 단순화한 것이다.

tcache와 fastbin은 해제 시 인접 chunk의 병합을 생략하여 빠르게 재사용할 수 있도록 관리한다. 반면 일반 free 처리에서는 인접한 free chunk를 병합하고, 결과를 unsorted bin이나 top chunk에서 관리한다.

또한 chunk 크기와 arena 상태에 따라 fastbin consolidation이나 시스템에 대한 메모리 반환이 추가로 발생할 수 있다.

즉, `_int_free()`의 핵심은 해제할 chunk를 가능한 한 빠르게 재사용 가능한 상태로 관리하면서, 필요한 경우 인접한 free chunk를 병합하여 메모리 단편화를 줄이는 것이다.

---

### 2.3 free 전체 흐름

지금까지 `__libc_free()`와 `_int_free()`의 동작을 살펴보았다.

`__libc_free()`는 사용자 포인터를 chunk 포인터로 변환하고, 해당 chunk가 `mmap`으로 할당되었는지 확인하여 해제 경로를 결정한다.

일반적인 arena chunk라면 `_int_free()`를 호출한다. `_int_free()`는 chunk의 유효성을 검사하고, 크기와 allocator 상태에 따라 tcache, fastbin 또는 일반 free 처리 경로를 선택한다.

두 함수의 전체적인 실행 흐름을 정리하면 다음과 같다.

```text
free(mem)
    ↓
__libc_free(mem)
    ↓
free hook 확인
    ├─ hook 존재 → hook 호출 → 종료
    ↓
NULL 포인터 검사
    ├─ mem == NULL → 종료
    ↓
mem2chunk(mem)
    ↓
mmap chunk 확인
    ├─ mmap chunk → munmap_chunk() → 종료
    ↓
MAYBE_INIT_TCACHE()
    ↓
arena_for_chunk(p)
    ↓
_int_free(ar_ptr, p, 0)
    ↓
chunk 크기 및 유효성 검사
    ├─ 비정상 → 오류 처리
    ↓
tcache 확인
    ├─ 저장 가능 → tcache_put() → 종료
    ↓
fastbin 확인
    ├─ 저장 가능 → fastbin 삽입 → 종료
    ↓
일반 free 처리
    ↓
필요 시 arena lock 확보
    ↓
이전 chunk가 free 상태인가?
    ├─ Yes → 이전 chunk와 병합
    ↓
다음 chunk가 top chunk인가?
    ├─ Yes → top chunk와 병합
    │          ↓
    │       av->top 갱신
    │
    └─ No → 다음 chunk가 free 상태인가?
               ├─ Yes → 다음 chunk와 병합
               ↓
            unsorted bin에 삽입
    ↓
필요 시 fastbin consolidation 및 trimming
    ↓
필요 시 mutex 해제
    ↓
해제 처리 완료
```

위 흐름은 glibc 2.31의 주요 해제 경로를 단순화한 것이다.

tcache 관련 처리는 `USE_TCACHE`가 활성화된 경우에 해당하며, chunk 크기와 allocator 상태에 따라 일부 단계가 생략될 수 있다.

tcache와 fastbin에서는 chunk를 해제할 때 인접 chunk와 즉시 병합하지 않는다. 반면 일반 free 처리에서는 인접한 free chunk를 병합할 수 있으며, 결과를 unsorted bin이나 top chunk에서 관리한다.

또한 일반 free 처리에서 chunk 크기가 일정 기준 이상이면 fastbin consolidation이나 시스템에 대한 메모리 반환이 추가로 수행될 수 있다.

결과적으로 glibc free는 **해제된 chunk를 재사용할 수 있도록 관리하면서, 처리 경로에 따라 빠른 재사용을 우선하거나 인접 chunk를 병합하는 방식**으로 동작한다.
