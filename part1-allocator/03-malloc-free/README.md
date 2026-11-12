# malloc-free

## 1. malloc

### 1.1 `__libc_malloc()`

#### 1) `__libc_malloc()` 시작

``` c
void *
__libc_malloc (size_t bytes)
{
  mstate ar_ptr;
  void *victim;

  _Static_assert (PTRDIFF_MAX <= SIZE_MAX / 2,
                  "PTRDIFF_MAX is not more than half of SIZE_MAX");
```

`__libc_malloc`은 사용자가 요청한 크기를 `bytes`로 인자로 받는다. 그리고 할당에 성공하면 사용자 데이터 영역의 주소, 실패하면 `NULL`을 반환한다. 

선언된 지역변수는 다음과 같다.

- `ar_ptr` : 메모리 할당에 사용할 arena를 가리키는 포인터.
- `victim` : `_int_malloc()`이 반환한 할당 결과를 저장할 포인터.

이때 `victim`이 담는 주소는 chunk의 시작 주소가 아닌 사용자 데이터 영역의 주소이다.

`_Static_assert()`는 C11에서 제공하는 컴파일 시점의 조건 검사이다. 여기에서는 `ptrdiff_t`와 `size_t`의 표현 가능한 값의 범위가 조건을 만족하는지 검사한다. 이는 glibc의 allocator가 요청 크기를 계산할 때 헤더 크기나 정렬을 위한 값을 더하는 등의 연산을 수행하기 때문이다. 이때 정수 오버플로가 발생하지 않도록 주의해야 하기 때문에, glibc의 크기 검증 로직이 전제로 삼는 자료형의 표현 범위가 컴파일 대상에서도 성립하는지 확인한다.

#### 2) malloc hook 확인

``` c
void *(*hook) (size_t, const void *)
  = atomic_forced_read (__malloc_hook);

if (__builtin_expect (hook != NULL, 0))
  return (*hook)(bytes, RETURN_ADDRESS (0));
```

malloc hook이 설정되어 있는지 확인하고, 설정되어 있다면 해당 함수를 대신 실행하는 부분이다. 

