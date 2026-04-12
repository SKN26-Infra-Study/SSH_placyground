#!/bin/bash
set -e

# 1. SSH host key 생성
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
    echo "[jumpserver] host key create"
fi

# 2. jump user .ssh directory
mkdir -p /home/jump/.ssh
chmod 700 /home/jump/.ssh

# 3. authorized_keys mount check
if [ ! -f /tmp/authorized_keys ]; then
    echo "[jumpserver] Error: authorized_keys not found"
    exit 1
fi

# 4. authorized_keys 복사
cp /tmp/authorized_keys /home/jump/.ssh/authorized_keys
chmod 600 /home/jump/.ssh/authorized_keys

# 5. 소유권 정리
chown -R jump:jump /home/jump/.ssh

echo "[jumpserver] 시작 완료 — sshd 실행 중"
exec /usr/sbin/sshd -D -e