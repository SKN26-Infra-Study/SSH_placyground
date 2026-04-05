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
| [트러블슈팅 기록](#트러블슈팅-기록) | 발생한 오류 및 해결 방법 |
| [검증 완료 항목](#검증-완료-항목) | 현재까지 검증된 항목 체크리스트 |

---

## 설계 결정 사항

### ProxyJump 채택

Agent Forwarding은 Jumpserver가 침해될 경우 공격자가 agent 소켓을 통해 RunPod에 무단 접근할 수 있습니다. ProxyJump는 클라이언트가 직접 두 번 핸드셰이크를 처리하므로 Jumpserver에 개인키가 노출되지 않습니다.

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
| Jumpserver | `authorized_keys` (팀원 공개키) + `id_ed25519_jump` |
| FastAPI / Chainlit | SSH 키 없음 — API Key만 |
| RunPod | `id_ed25519_jump` 공개키만 |

---

## SSH 접속 흐름

![SSH 접속 흐름](https://raw.githubusercontent.com/SKN26-Infra-Study/SSH_placyground/main/docs/image/ssh_flow.png)

---

## Agent Forwarding vs ProxyJump

![Agent Forwarding vs ProxyJump](https://raw.githubusercontent.com/SKN26-Infra-Study/SSH_placyground/main/docs/image/af_vs_proxyjump.png)

```
# sshd_config 핵심 설정
AllowAgentForwarding no   # Agent Forwarding 명시적 차단
AllowTcpForwarding yes    # ProxyJump에 필요한 포트 포워딩만 허용
PermitTTY no              # 쉘 접근 차단
```

---

## 파일별 상세 설명

### Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk add --no-cache openssh bash

# jump 전용 유저 생성 + 패스워드 잠금 해제
# adduser -D 로 생성한 계정은 기본 잠금 상태 → passwd -u 로 해제 필요
RUN adduser -D -s /bin/bash jump && \
    passwd -u jump

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
```

### sshd_config

```
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /home/jump/.ssh/authorized_keys
AllowUsers jump
AllowTcpForwarding yes
AllowAgentForwarding no
GatewayPorts no
X11Forwarding no
PermitTTY no
StrictModes no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 3
```

> `StrictModes no`: `/tmp`에서 복사한 `authorized_keys`의 소유권 체크를 우회합니다.

### entrypoint.sh

```bash
#!/bin/bash
set -e

# 1. SSH 호스트 키 생성 (최초 1회만)
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
    echo "[jumpserver] host key create"
fi

# 2. jump 유저 .ssh 디렉토리 설정
mkdir -p /home/jump/.ssh
chmod 700 /home/jump/.ssh

# 3. /tmp/authorized_keys 마운트 확인
if [ ! -f /tmp/authorized_keys ]; then
    echo "[jumpserver] Error: authorized_keys not found"
    exit 1
fi

# 4. 복사 후 권한 설정
cp /tmp/authorized_keys /home/jump/.ssh/authorized_keys
chmod 600 /home/jump/.ssh/authorized_keys
chown -R jump:jump /home/jump/.ssh

echo "[jumpserver] 시작 완료 — sshd 실행 중"
exec /usr/sbin/sshd -D -e
```

> `authorized_keys`를 `/tmp`에 마운트하는 이유: `:ro` 마운트된 경로에서는 `chmod` / `chown`이 불가하므로 `/tmp`에 마운트 후 복사합니다.

### docker-compose.yml

```yaml
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

### authorized_keys 등록 형식

```
restrict,port-forwarding ssh-ed25519 AAAA... WIN_DESKTOP-이름_식별자
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

## 검증 완료 항목

| 항목 | 상태 | 날짜 |
|---|---|---|
| Alpine 3.23 Jumpserver 빌드 | ✅ | 2026-04-05 |
| authorized_keys 마운트 및 복사 | ✅ | 2026-04-05 |
| 하드웨어 기반 ED25519 키 인증 | ✅ | 2026-04-05 |
| PermitTTY no (쉘 차단) | ✅ | 2026-04-05 |
| 공개키 인증 로그 확인 | ✅ | 2026-04-05 |
| 터널 서비스 외부 접속 | ⬜ | - |
| Jupyter ProxyJump + LocalForward | ⬜ | - |
| RunPod 실제 연동 | ⬜ | - |