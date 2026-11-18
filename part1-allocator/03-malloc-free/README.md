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

`MAYBE_INIT_TCACHE()`는 현재 스레드의 tcache가 초기화되지 않았다면 초기화를 시도한다.

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

따라서 **tcache에서 요청을 처리할 수 있다면 arena를 선택하거나 `_int_malloc()`을 호출하지 않고 할당을 마칠 수 있다.**

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

---

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

---

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

`_int_malloc()`의 핵심은 **기존에 확보된 free chunk를 우선 재사용하고, 적절한 chunk가 없으면 top chunk를 사용하거나 시스템에서 추가 메모리를 확보한다는 것**이다.

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
