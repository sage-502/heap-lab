#!/bin/bash
set -e

echo "[*] heap-lab setup start"

# ---------------------------
# 1. 기본 패키지 설치
# ---------------------------
echo "[*] 기본 패키지 설치 시작"
apt update
apt install -y \
    gcc gdb make \
    git vim \
    checksec \
    file \
    binutils \
    elfutils \
    strace ltrace \
    libc6-dbg \
    python3 python3-pip python3-venv
echo "[+] 기본 패키지 설치 완료"

# ---------------------------
# 2. pwntools 설치 (exploit.py용)
# ---------------------------
echo "[*] pwntools 설치 시작"
pip3 install --break-system-packages pwntools 2>/dev/null || pip3 install pwntools
echo "[+] pwntools 설치 완료"

# ---------------------------
# 3. pwndbg 설치 (heap 관찰용 gdb 확장)
#    heap, bins, tcache, vis_heap_chunks 등 명령어 제공
# ---------------------------
echo "[*] pwndbg 설치 시작"
if [ -d "/opt/pwndbg" ]; then
    echo "[+] pwndbg already installed"
else
    git clone https://github.com/pwndbg/pwndbg /opt/pwndbg
    cd /opt/pwndbg
    ./setup.sh
    cd -
fi
echo "[+] pwndbg 설치 완료"

# ---------------------------
# 4. 분석용 계정 생성 (최소 권한)
# ---------------------------
echo "[*] baby 유저 생성 시작"
if id "baby" &>/dev/null; then
    echo "[+] user 'baby' already exists"
else
    echo "[*] baby 계정 생성..."
    adduser --disabled-password --gecos "" baby
fi

# sudo 그룹에서 제거
deluser baby sudo &>/dev/null || true
echo "[+] baby 유저 생성 완료"

# ---------------------------
# 5. glibc 버전 확인 (컨테이너별 기준 확인용)
# ---------------------------
echo "[*] 현재 glibc 버전:"
ldd --version | head -n 1

# ---------------------------
# 6. ASLR 상태 안내
# ---------------------------
echo "[*] ASLR 현재 상태:"
cat /proc/sys/kernel/randomize_va_space

echo
echo "[!] ASLR on/off은 실습별로 직접 제어하세요."
echo "    예: echo 0 | sudo tee /proc/sys/kernel/randomize_va_space"

echo "[+] setup complete
