#!/bin/bash
set -e

# 1. SSH host key 생성
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
    echo "[jupyter-dummy] host key created"
fi

# 2. user .ssh directory
mkdir -p /home/user/.ssh
chmod 700 /home/user/.ssh

# 3. authorized_keys mount check
if [ ! -f /tmp/authorized_keys ]; then
    echo "[jupyter-dummy] Error: authorized_keys not found"
    exit 1
fi

# 4. authorized_keys 복사
cp /tmp/authorized_keys /home/user/.ssh/authorized_keys
chmod 600 /home/user/.ssh/authorized_keys
chown -R user:user /home/user/.ssh

# 5. Jupyter Server 백그라운드 실행 (127.0.0.1 바인딩)
su - user -c "jupyter notebook \
    --ip=127.0.0.1 \
    --port=8888 \
    --no-browser \
    --ServerApp.token='' \
    --ServerApp.password='' \
    --ServerApp.disable_check_xsrf=True \
    &"

echo "[jupyter-dummy] 시작 완료 — sshd 실행 중"
exec /usr/sbin/sshd -D -e