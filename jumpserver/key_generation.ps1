# ============================================================
#  Jumpserver SSH 키 자동 발급 스크립트
#  - 하드웨어 정보 기반 passphrase 자동 생성
#  - 키 파일: %USERPROFILE%\.ssh\id_ed25519_A
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Jumpserver SSH Key Generator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. 하드웨어 정보 수집 ──────────────────────────────────
Write-Host "[1/4] 하드웨어 정보 수집 중..." -ForegroundColor Yellow

$HW_UUID   = (Get-WmiObject -Class Win32_ComputerSystemProduct).UUID
$MAC_ADDR  = (Get-NetAdapter | Where-Object { $_.Status -eq "Up" } |
              Sort-Object -Property InterfaceIndex |
              Select-Object -First 1).MacAddress
$PC_NAME   = $env:COMPUTERNAME

if (-not $HW_UUID -or -not $MAC_ADDR) {
    Write-Host "[ERROR] 하드웨어 정보를 가져올 수 없습니다. 관리자 권한으로 실행하세요." -ForegroundColor Red
    exit 1
}

Write-Host "  PC 이름  : $PC_NAME"
Write-Host "  UUID     : $HW_UUID"
Write-Host "  MAC 주소 : $MAC_ADDR"

# ── 2. Passphrase 생성 (SHA256) ────────────────────────────
Write-Host ""
Write-Host "[2/4] Passphrase 생성 중..." -ForegroundColor Yellow

$HW_ID     = "$HW_UUID$MAC_ADDR"
$SHA256    = [System.Security.Cryptography.SHA256]::Create()
$HashBytes = $SHA256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($HW_ID))
$PASSPHRASE = ([BitConverter]::ToString($HashBytes) -replace '-', '').Substring(0, 32).ToLower()
$SHORT_ID   = $HW_UUID.Substring(0, 8).ToLower()

Write-Host "  키 식별자: WIN_${PC_NAME}_${SHORT_ID}"

# ── 3. SSH 키 발급 ─────────────────────────────────────────
Write-Host ""
Write-Host "[3/4] SSH 키 발급 중..." -ForegroundColor Yellow

$SSH_DIR  = "$env:USERPROFILE\.ssh"
$KEY_PATH = "$SSH_DIR\id_ed25519_A"

# .ssh 디렉토리 없으면 생성
if (-not (Test-Path $SSH_DIR)) {
    New-Item -ItemType Directory -Path $SSH_DIR | Out-Null
    Write-Host "  .ssh 디렉토리 생성 완료"
}

# 기존 키 존재 시 확인
if (Test-Path $KEY_PATH) {
    Write-Host ""
    Write-Host "  [WARNING] 기존 키가 존재합니다: $KEY_PATH" -ForegroundColor Yellow
    $confirm = Read-Host "  덮어쓰시겠습니까? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "  취소되었습니다." -ForegroundColor Red
        exit 0
    }
    Remove-Item "$KEY_PATH", "$KEY_PATH.pub" -Force
}

# 키 생성
ssh-keygen -t ed25519 `
    -C "WIN_${PC_NAME}_${SHORT_ID}" `
    -N "$PASSPHRASE" `
    -f "$KEY_PATH" | Out-Null

Write-Host "  키 생성 완료"

# ── 4. 결과 출력 ───────────────────────────────────────────
Write-Host ""
Write-Host "[4/4] 발급 완료" -ForegroundColor Green
Write-Host ""
Write-Host "----------------------------------------"
Write-Host "  개인키 경로 : $KEY_PATH"
Write-Host "  공개키 경로 : $KEY_PATH.pub"
Write-Host "  키 식별자   : WIN_${PC_NAME}_${SHORT_ID}"
Write-Host "----------------------------------------"
Write-Host ""
Write-Host "[ authorized_keys 에 등록할 공개키 ]" -ForegroundColor Cyan
Write-Host ""

$PUB_KEY = Get-Content "$KEY_PATH.pub"
Write-Host "restrict,port-forwarding $PUB_KEY" -ForegroundColor White

Write-Host ""
Write-Host "----------------------------------------"
Write-Host "위 내용을 복사해서 authorized_keys 에 추가하세요." -ForegroundColor Yellow
Write-Host ""

# ── 5. Passphrase 출력 ─────────────────────────────────────
Write-Host ""
Write-Host "========================================"  -ForegroundColor Magenta
Write-Host "  [ SSH 접속 시 사용할 Passphrase ]"      -ForegroundColor Magenta
Write-Host "========================================"  -ForegroundColor Magenta
Write-Host ""
Write-Host "  $PASSPHRASE" -ForegroundColor Yellow
Write-Host ""
Write-Host "  ※ 이 값은 이 PC에서만 재생성 가능합니다." -ForegroundColor DarkGray
Write-Host "  ※ 타인에게 공유하지 마세요." -ForegroundColor DarkGray
Write-Host ""