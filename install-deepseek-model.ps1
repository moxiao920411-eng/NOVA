param(
    [string]$ModelsRoot = 'D:\OllamaModels',
    [string]$OllamaExe = 'D:\Ollama\ollama.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$digest = 'e6a7edc1a4d7d9b2de136a221a57336b76316cfe53a252aeba814496c5ae439d'
$expectedSize = [int64]5225373760
$blobDir = Join-Path $ModelsRoot 'blobs'
$download = Join-Path $blobDir ("sha256-{0}-download" -f $digest)
$blob = Join-Path $blobDir ("sha256-{0}" -f $digest)
$log = Join-Path $ModelsRoot 'deepseek-install.log'
$url = 'https://registry.ollama.ai/v2/library/deepseek-r1/blobs/sha256:e6a7edc1a4d7d9b2de136a221a57336b76316cfe53a252aeba814496c5ae439d'

function Write-InstallLog {
    param([string]$Message)
    "$(Get-Date -Format o) $Message" | Add-Content -LiteralPath $log -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Path $blobDir -Force | Out-Null
    $curlRunning = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'curl.exe' -and $_.CommandLine -match [regex]::Escape($download)
    }).Count -gt 0
    if (-not $curlRunning -and ((-not (Test-Path -LiteralPath $download)) -or ((Get-Item -LiteralPath $download).Length -lt $expectedSize))) {
        $curlArgs = @('-L', '--fail', '--retry', '20', '--retry-all-errors', '--retry-delay', '5', '--connect-timeout', '30', '-C', '-', '--output', $download, $url)
        Start-Process -FilePath 'C:\Windows\System32\curl.exe' -WindowStyle Hidden -ArgumentList $curlArgs | Out-Null
        Write-InstallLog '已啟動可續傳的 curl 下載程序。'
    }
    Write-InstallLog '等待模型主 blob 下載完成。'
    while (-not (Test-Path -LiteralPath $download)) { Start-Sleep -Seconds 30 }
    while ((Get-Item -LiteralPath $download).Length -lt $expectedSize) { Start-Sleep -Seconds 30 }

    Write-InstallLog '下載大小完成，開始驗證 SHA-256。'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($download)
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
    if ($hash -ne $digest) {
        Write-InstallLog "SHA-256 驗證失敗：$hash"
        exit 2
    }
    Move-Item -LiteralPath $download -Destination $blob -Force
    Write-InstallLog '主 blob 驗證成功並已放入 Ollama blobs。'

    $env:OLLAMA_MODELS = $ModelsRoot
    & $OllamaExe pull 'deepseek-r1:8b' *>> $log
    if ($LASTEXITCODE -ne 0) {
        Write-InstallLog "Ollama pull 失敗，退出碼：$LASTEXITCODE"
        exit $LASTEXITCODE
    }
    Write-InstallLog 'deepseek-r1:8b 安裝完成。'
    exit 0
} catch {
    Write-InstallLog "安裝程序錯誤：$($_.Exception.Message)"
    exit 1
}
