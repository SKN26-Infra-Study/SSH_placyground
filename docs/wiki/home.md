# SSH Playground Wiki

> RAG 기반 이력서 피드백 서비스 — SSH 인프라 검증 프로젝트 문서

---

## 목차

| 문서 | 내용 |
|---|---|
| [설계 결정 사항](#설계-결정-사항) | ProxyJump 채택 이유, Alpine 선택, 트래픽 분리 원칙 |
| [SSH 접속 흐름](#ssh-접속-흐름) | 개발자 PC → Jumpserver → RunPod 흐름 |
| [Agent Forwarding vs ProxyJump](#agent-forwarding-vs-proxyjump) | 보안 비교 및 채택 이유 |
| [파일별 상세 설명](#파일별-상세-설명) | Dockerfile, sshd_config, entrypoint.sh, docker-compose.yml |
| [키 발급 원리](#키-발급-원리) | 하드웨어 기반 passphrase 생성 방식 |
| [ngrok 터널 설정](#ngrok-터널-설정) | ngrok TCP 터널 구성 및 자동 접속 |
| [클라이언트 설정](#클라이언트-설정) | ~/.ssh/config 및 auto_connect.ps1 |
| [트러블슈팅 기록](#트러블슈팅-기록) | 발생한 오류 및 해결 방법 |
| [검증 완료 항목](#검증-완료-항목) | 현재까지 검증된 항목 체크리스트 |

---

## 설계 결정 사항

### ProxyJump 채택

Agent Forwarding은 Jumpserver가 침해될 경우 공격자가 agent 소켓을 통해 RunPod에 무단 접근할 수 있습니다. ProxyJump는 클라이언트가 직접 두 번 핸드셰이크를 처리하므로 Jumpserver에 개인키가 노출되지 않습니다.

> **ForceCommand 방식 폐기 이유**: jumpserver 내부에 `id_ed25519_jump` 개인키를 보관해야 하고, Windows OpenSSH 클라이언트에서 PTY 할당 실패 문제가 발생합니다. ProxyJump 방식으로 전환하여 jumpserver에 private key를 완전히 제거했습니다.

### Alpine 3.23 선택

| 버전 | 지원 종료 | 지원 수준 | 선택 |
|---|---|---|---|
| v3.21 | 2026-11 | main + community | - |
| v3.22 | 2027-05 | main only | - |
| **v3.23** | **2027-11** | **main + community** | **✅** |

### 서비스 트래픽 분리 원칙

```
Training Line:  개발자 PC → SSH → Jumpserver → RunPod
Service Line:   FastAPI   → HTTPS → RunPod vLLM API
```

FastAPI / Chainlit 컨테이너에는 SSH 키가 존재하지 않습니다.

### 키 분리 원칙

| 위치 | 보관 키 |
|---|---|
| 개발자 PC | 본인 `id_ed25519_A` 개인키만 |
| Jumpserver | `authorized_keys` (팀원 공개키)만 — private key 없음 |
| FastAPI / Chainlit | SSH 키 없음 — API Key만 |
| RunPod | `id_ed25519_A` 공개키만 (ProxyJump 직접 인증) |

---

## SSH 접속 흐름

```
개발자 PC
  └─(id_ed25519_A)─→ ngrok TCP 터널
                         └─→ jumpserver:2222 (relay only)
                                  └─(ProxyJump)─→ jupyter-dummy:2222
                                                       └─ Jupyter Server:8888
                                                            ↑
                                     SSH -L 8888:127.0.0.1:8888
```

---

## Agent Forwarding vs ProxyJump

```
# sshd_config 핵심 설정
AllowAgentForwarding no      # Agent Forwarding 명시적 차단
AllowTcpForwarding local     # ProxyJump에 필요한 포트 포워딩만 허용
PermitTTY no                 # 쉘 접근 차단
```

| 항목 | Agent Forwarding | ProxyJump |
|---|---|---|
| Jumpserver private key | 불필요 | 불필요 |
| Jumpserver 침해 시 | agent 소켓 탈취 위험 | 영향 없음 |
| Windows 호환성 | 제한적 | ✅ |
| 구조 복잡도 | 낮음 | 낮음 |

---

## 파일별 상세 설명

### jumpserver/Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk add --no-cache openssh bash

# jump 전용 유저 생성 + 패스워드 잠금 해제
RUN adduser -D -s /bin/bash jump && \
    passwd -u jump

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r//' /entrypoint.sh && \
    chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
```

### jumpserver/sshd_config

```
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /home/jump/.ssh/authorized_keys
AllowUsers jump
AllowTcpForwarding local
AllowAgentForwarding no
GatewayPorts no
X11Forwarding no
PermitTTY no
PermitUserRC no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 3
```

### jumpserver/entrypoint.sh

```bash
#!/bin/bash
set -e

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
    echo "[jumpserver] host key create"
fi

mkdir -p /home/jump/.ssh
chmod 700 /home/jump/.ssh

if [ ! -f /tmp/authorized_keys ]; then
    echo "[jumpserver] Error: authorized_keys not found"
    exit 1
fi

cp /tmp/authorized_keys /home/jump/.ssh/authorized_keys
chmod 600 /home/jump/.ssh/authorized_keys
chown -R jump:jump /home/jump/.ssh

echo "[jumpserver] 시작 완료 — sshd 실행 중"
exec /usr/sbin/sshd -D -e
```

### jumpserver/authorized_keys 등록 형식

```
restrict,port-forwarding,permitopen="jupyter-dummy:2222" ssh-ed25519 AAAA... WIN_PC이름_식별자
```

### jupyter-dummy/Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk add --no-cache openssh bash python3 py3-pip

RUN adduser -D -s /bin/bash user && \
    passwd -u user

RUN pip3 install --no-cache-dir --break-system-packages \
    notebook \
    ipykernel

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r//' /entrypoint.sh && \
    chmod +x /entrypoint.sh

EXPOSE 2222
ENTRYPOINT ["/entrypoint.sh"]
```

### jupyter-dummy/sshd_config

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /home/user/.ssh/authorized_keys
AllowUsers user
AllowTcpForwarding yes
X11Forwarding no
PermitTTY yes
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 3
```

### jupyter-dummy/entrypoint.sh

```bash
#!/bin/bash
set -e

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
    echo "[jupyter-dummy] host key created"
fi

mkdir -p /home/user/.ssh
chmod 700 /home/user/.ssh

if [ ! -f /tmp/authorized_keys ]; then
    echo "[jupyter-dummy] Error: authorized_keys not found"
    exit 1
fi

cp /tmp/authorized_keys /home/user/.ssh/authorized_keys
chmod 600 /home/user/.ssh/authorized_keys
chown -R user:user /home/user/.ssh

# Jupyter Notebook 백그라운드 실행 (127.0.0.1 바인딩)
su - user -c "jupyter notebook \
    --ip=127.0.0.1 \
    --port=8888 \
    --no-browser \
    --NotebookApp.token='' \
    --NotebookApp.password='' \
    &"

echo "[jupyter-dummy] 시작 완료 — sshd 실행 중"
exec /usr/sbin/sshd -D -e
```

### docker-compose.yml

```yaml
name: ssh_playground

services:
  jumpserver:
    build:
      context: ./jumpserver
      dockerfile: Dockerfile
    container_name: jumpserver
    restart: unless-stopped
    ports:
      - "2222:22"
    volumes:
      - ./jumpserver/authorized_keys:/tmp/authorized_keys:ro
    networks:
      - jump-net

  jupyter-dummy:
    build:
      context: ./jupyter-dummy
      dockerfile: Dockerfile
    container_name: jupyter-dummy
    restart: unless-stopped
    volumes:
      - ./jupyter-dummy/authorized_keys:/tmp/authorized_keys:ro
    networks:
      - jump-net

  ngrok:
    image: ngrok/ngrok:latest
    container_name: ngrok
    restart: unless-stopped
    environment:
      - NGROK_AUTHTOKEN=${NGROK_AUTHTOKEN}
    command: tcp jumpserver:22
    ports:
      - "4040:4040"
    networks:
      - jump-net
    depends_on:
      - jumpserver

networks:
  jump-net:
    driver: bridge
```

---

## 키 발급 원리

### Passphrase 생성 방식

```
UUID (Win32_ComputerSystemProduct) + MAC 주소 (활성 어댑터 첫 번째)
    ↓ SHA256
32자리 hex 문자열 → Passphrase
```

같은 키 파일을 다른 PC에 복사해도 Passphrase가 달라 사용 불가 → 하드웨어 바인딩 효과

### 키 식별자 형식

```
WIN_{PC이름}_{UUID앞8자리}
예) WIN_DESKTOP-GILDONG_1a2b3c4d
```

### Passphrase 재확인 (PowerShell)

```powershell
$HW_UUID  = (Get-WmiObject -Class Win32_ComputerSystemProduct).UUID
$MAC_ADDR = (Get-NetAdapter | Where-Object { $_.Status -eq "Up" } |
             Sort-Object -Property InterfaceIndex |
             Select-Object -First 1).MacAddress
$HW_ID     = "$HW_UUID$MAC_ADDR"
$SHA256    = [System.Security.Cryptography.SHA256]::Create()
$HashBytes = $SHA256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($HW_ID))
$PASSPHRASE = ([BitConverter]::ToString($HashBytes) -replace '-', '').Substring(0, 32).ToLower()
Write-Host "Passphrase: $PASSPHRASE"
```

---

## ngrok 터널 설정

### ngrok.yml (프로젝트 루트)

```yaml
version: "2"

tunnels:
  jumpserver:
    proto: tcp
    addr: 2222
```

### 터널 실행

```powershell
# 프로젝트별 config 병합 실행
ngrok start jumpserver --config $env:USERPROFILE\AppData\Local\ngrok\ngrok.yml --config .\ngrok.yml
```

### 터널 주소 확인

```powershell
Invoke-RestMethod http://localhost:4040/api/tunnels
```

---

## 클라이언트 설정

### ~/.ssh/config

```
Host jump
    HostName <ngrok-host>
    Port <ngrok-port>
    User jump
    IdentityFile ~/.ssh/id_ed25519_A
    IdentitiesOnly yes

Host jupyter-dummy
    HostName jupyter-dummy
    Port 2222
    User user
    ProxyJump jump
    IdentityFile ~/.ssh/id_ed25519_A
    IdentitiesOnly yes
```

### auto_connect.ps1 사용법

```powershell
# ngrok 자동 감지
.\auto_connect.ps1

# 수동 입력
.\auto_connect.ps1 -NgrokHost 0.tcp.jp.ngrok.io -NgrokPort 15951

# Jupyter 터널 없이
.\auto_connect.ps1 -NoJupyter

# Jupyter 포트 변경
.\auto_connect.ps1 -LocalPort 9999
```

### Jupyter LocalForward

```powershell
# 백그라운드 실행
ssh -fN -L 8888:127.0.0.1:8888 jupyter-dummy

# 브라우저 접속
# http://localhost:8888
```

---

## 트러블슈팅 기록

### chmod: Read-only file system

**증상**
```
chmod: /home/jump/.ssh/authorized_keys: Read-only file system
```
**원인** `authorized_keys`를 `/home/jump/.ssh/`에 직접 `:ro` 마운트 후 `chmod` 시도  
**해결** 마운트 경로를 `/tmp/authorized_keys`로 변경, entrypoint에서 복사 후 권한 설정

---

### authorized_keys not found

**증상**
```
[jumpserver] Error: authorized_keys not found
```
**원인** `docker-compose.yml` 마운트 경로와 `entrypoint.sh` 체크 경로 불일치  
**해결** 두 파일 경로를 `/tmp/authorized_keys`로 통일

---

### account is locked

**증상**
```
User jump not allowed because account is locked
```
**원인** Alpine `adduser -D`로 생성한 계정은 기본 잠금 상태  
**해결** `Dockerfile`에 `passwd -u jump` 추가

---

### Too many authentication failures

**증상**
```
Received disconnect from ::1 port 2222:2: Too many authentication failures
```
**원인** 클라이언트에 여러 키가 등록되어 자동 시도하다 MaxAuthTries 초과  
**해결** 접속 시 `-o IdentitiesOnly=yes` 옵션 추가
```powershell
ssh -p 2222 -i ~/.ssh/id_ed25519_A -o IdentitiesOnly=yes jump@localhost
```

---

### REMOTE HOST IDENTIFICATION HAS CHANGED

**증상**
```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```
**원인** 컨테이너 재빌드로 호스트 키 변경  
**해결**
```powershell
ssh-keygen -R "[localhost]:2222"
```

---

### entrypoint.sh: no such file or directory

**증상**
```
exec /entrypoint.sh: no such file or directory
```
**원인** Windows에서 파일 저장 시 CRLF 줄바꿈 → Alpine에서 인식 불가  
**해결** Dockerfile에 CRLF → LF 변환 추가
```dockerfile
RUN sed -i 's/\r//' /entrypoint.sh
```

---

### PTY allocation request failed (ForceCommand 방식)

**증상**
```
PTY allocation request failed on channel 0
```
**원인** Windows OpenSSH 클라이언트에서 ForceCommand 환경의 PTY 할당 제한  
**해결** ForceCommand 방식 폐기 → ProxyJump 방식으로 전환

---

### Load key: error in libcrypto

**증상**
```
Load key "/home/jump/.ssh/id_ed25519_jump": error in libcrypto
```
**원인** Windows에서 개인키 파일 저장 시 인코딩 손상  
**해결** ForceCommand 방식 폐기 → ProxyJump 방식으로 전환 (jumpserver에 private key 불필요)

---

## 검증 완료 항목

| 항목 | 상태 | 날짜 |
|---|---|---|
| Alpine 3.23 Jumpserver 빌드 | ✅ | 2026-04-05 |
| authorized_keys 마운트 및 복사 | ✅ | 2026-04-05 |
| 하드웨어 기반 ED25519 키 인증 | ✅ | 2026-04-05 |
| PermitTTY no (쉘 차단) | ✅ | 2026-04-05 |
| 공개키 인증 로그 확인 | ✅ | 2026-04-05 |
| ForceCommand → ProxyJump 전환 | ✅ | 2026-04-12 |
| ngrok TCP 터널 외부 접속 | ✅ | 2026-04-12 |
| jupyter-dummy ProxyJump + LocalForward | ✅ | 2026-04-12 |
| 브라우저 Jupyter 접속 확인 | ✅ | 2026-04-12 |
| auto_connect.ps1 자동화 | ⬜ | - |
| RunPod 실제 연동 | ⬜ | - |