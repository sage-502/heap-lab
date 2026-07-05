# heap-lab

힙 익스플로잇 공부 기록 모음집

이 레포는 glibc malloc 기반 heap allocator의 동작을 코드, 컴파일, gdb 디버깅을 통해 관찰하고, </br>
이후 heap 취약점과 익스플로잇 기법으로 확장하는 것을 목표로 한다.

기존 stack-lab이 스택 기반 취약점과 익스플로잇을 다뤘다면, </br>
heap-lab은 익스플로잇보다 먼저 malloc/free의 동작, chunk 구조, free list, bin, tcache 등 allocator 내부 구조를 이해하는 데 집중한다.

※ 가상머신 또는 Docker 환경에서만 사용할 것을 추천.

---

## 목표

* heap chunk 구조 이해
* malloc/free 동작 관찰
* tcache, fastbin, unsorted bin 등 free list 구조 분석
* glibc 버전별 allocator 차이 비교
* UAF, double free, heap overflow 등 heap 취약점 실습
* tcache poisoning, fastbin dup 등 기본 heap exploit 기법 실습
* 최신 glibc에서 기존 기법이 실패하는 이유 분석

---

## 기준 환경

메인 실습 환경:

* Ubuntu 20.04
* glibc 2.31
* 64bit
* Docker 기반

비교 실습 환경:

* Ubuntu 24.04
* glibc 2.39

---

## 구성

1부, 2부, 번외로 구성했다.

```text
heap-lab/
├── README.md
├── docker-compose.yml
├── docker/
├── env.md
├── memo.md
├── images/
│
├── part1-allocator/
│   ├── 00-heap-intro/
│   ├── 01-chunk-layout/
│   ├── 02-malloc-free/
│   ├── 03-tcache-basic/
│   ├── 04-fastbin-basic/
│   ├── 05-unsorted-bin-basic/
│   └── 06-allocator-flow/
│
├── part2-vulnerability/
│   ├── 00-uaf-basic/
│   ├── 01-double-free-basic/
│   └── 02-heap-overflow-basic/
│
├── part3-exploitation/
│   ├── 00-tcache-poisoning/
│   └── 01-fastbin-dup/
│
└── appendix-version-diff/
    ├── 00-safe-linking/
    └── 01-glibc-2.31-vs-2.39/
```

## 실습 원칙

1. 익스플로잇보다 관찰을 먼저 한다.
2. 각 실습은 가능한 한 작은 C 코드로 구성한다.
3. gdb, pwndbg, x/gx, heap 명령어로 직접 확인한다.
4. 주소, offset, chunk size는 직접 계산한다.
5. glibc 버전에 따라 결과가 다를 수 있음을 명시한다.

---

## 개별 디렉터리 구성

```text
example-topic/
├── README.md
├── vuln.c
├── build.sh
├── exploit.py
└── fix.c
```

초반 allocator 관찰 실습은 exploit.py 또는 fix.c가 없을 수 있다.

```text
chunk-layout/
├── README.md
├── sample.c
└── build.sh
```

---

## 사용법

### 1. Docker 환경 실행

```bash
docker compose run --rm glibc231
```

비교 환경 실행:

```bash
docker compose run --rm glibc239
```

### 2. 실습 빌드

```bash
cd chunk-layout
bash build.sh
```

### 3. gdb 분석

```bash
gdb ./sample
```

또는

```bash
gdb ./vuln
```
