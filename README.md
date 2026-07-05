# heap-lab

힙 익스플로잇 공부 기록 모음집

이 레포는 glibc malloc 기반 heap allocator의 동작을 코드, 컴파일, gdb 디버깅을 통해 관찰하고, 이후 heap 취약점과 익스플로잇 기법으로 확장하는 것을 목표로 한다.

기존 stack-lab이 스택 기반 취약점과 익스플로잇을 다뤘다면, heap-lab은 익스플로잇보다 먼저 malloc/free의 동작, chunk 구조, free list, bin, tcache 등 allocator 내부 구조를 이해하는 데 집중한다.

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

glibc 2.31을 메인으로 사용하는 이유는 tcache가 존재하지만 safe-linking이 없어 heap allocator 동작과 tcache 기반 기법을 처음 관찰하기 좋기 때문이다.

glibc 2.39는 최신 환경에서 동일한 코드 또는 payload가 왜 다르게 동작하는지 비교하기 위한 환경으로 사용한다.

---

## 구성

```text
heap-lab/
├── README.md
├── docker-compose.yml
├── docker/
│   ├── glibc-2.31/
│   │   └── Dockerfile
│   └── glibc-2.39/
│       └── Dockerfile
│
├── env.md
├── memo.md
├── images/
│
│   # 1부
├── heap-intro/
├── chunk-layout/
├── malloc-free/
├── tcache-basic/
├── fastbin-basic/
├── unsorted-bin-basic/
├── allocator-flow/
│
│   # 2부
├── uaf-basic/
├── double-free-basic/
├── heap-overflow-basic/
├── tcache-poisoning/
├── fastbin-dup/
│
│   # 번외
└── version-diff/
    ├── safe-linking/
    └── glibc-2.31-vs-2.39/
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
