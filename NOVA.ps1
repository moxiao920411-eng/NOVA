param(
    [switch]$Cli,
    [string]$Text,
    [switch]$Server,
    [int]$Port = 24808,
    [switch]$VoiceWorker,
    [int]$CallbackPort = 0,
    [string]$Source = 'text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NovaRoot = Join-Path $env:LOCALAPPDATA 'NOVA'
$script:ConfigPath = Join-Path $script:NovaRoot 'config.json'
$script:EventsPath = Join-Path $script:NovaRoot 'events.jsonl'
$script:MemoryPath = Join-Path $script:NovaRoot 'memory.json'
$script:NovaVoiceEngine = $null
$script:NovaVoiceSynth = $null
$script:NovaReplySynth = $null
$script:NovaVoiceRecognizedHandler = $null
$script:NovaVoiceCompletedHandler = $null
$script:NovaVoiceRejectedHandler = $null
$script:NovaVoiceDetectedHandler = $null
$script:NovaVoiceAudioProblemHandler = $null
$script:NovaWhisperProcess = $null
$script:NovaWhisperOutputHandler = $null
$script:NovaWhisperErrorHandler = $null
$script:NovaWhisperExitedHandler = $null
$script:NovaVoiceCommandProcess = $null
$script:NovaServerMode = $false
$script:NovaVoiceOnText = $null
$script:NovaVoiceOnStatus = $null
$script:NovaWakeUntil = [datetime]::MinValue
$script:NovaLastVoiceCommandKey = ''
$script:NovaLastVoiceCommandAt = [datetime]::MinValue
$script:NovaListenPort = 24808
$script:OllamaHealthUntil = [datetime]::MinValue
$script:OllamaAvailable = $false
$script:PendingWhitelistTarget = ''
$script:NovaCubeAngle = 0.0
$script:NovaCubeTimer = $null
$script:NovaCubeListening = $false
$script:NovaUiEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

function ConvertTo-NovaObject {
    param([hashtable]$Value)
    return [pscustomobject]$Value
}

function Initialize-NovaStore {
    if (-not (Test-Path -LiteralPath $script:NovaRoot)) {
        New-Item -ItemType Directory -Path $script:NovaRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        $default = @{
            HomeAssistant = @{
                Enabled = $false
                BaseUrl = 'http://homeassistant.local:8123'
                Token = ''
            }
            Ollama = @{
                Enabled = $true
                BaseUrl = 'http://127.0.0.1:11434'
                Model = 'deepseek-r1:8b'
                TimeoutSec = 20
            }
            Security = @{
                PassphraseHash = ''
                FileSearchConsent = $null
                FileSearchConsentAsked = $false
                PendingWhitelistTarget = ''
            }
            MemoryAliases = @{}
            Devices = @(
                @{
                    Name = '客廳燈'
                    Aliases = @('客廳燈', '大廳燈')
                    EntityId = 'light.living_room'
                    Domain = 'light'
                }
            )
            AllowedApps = @{
                '記事本' = 'notepad.exe'
                '計算機' = 'calc.exe'
                '小畫家' = 'mspaint.exe'
                '檔案總管' = 'explorer.exe'
                '設定' = 'ms-settings:'
            }
        }
        $default | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath $script:EventsPath)) {
        New-Item -ItemType File -Path $script:EventsPath -Force | Out-Null
    }
}

function Get-NovaConfig {
    Initialize-NovaStore
    try {
        $config = (Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        if ($null -eq $config.PSObject.Properties['Ollama']) {
            $config | Add-Member -NotePropertyName Ollama -NotePropertyValue ([pscustomobject]@{
                Enabled = $true; BaseUrl = 'http://127.0.0.1:11434'; Model = 'deepseek-r1:8b'; TimeoutSec = 20
            })
        }
        if ($null -eq $config.PSObject.Properties['Security']) {
            $config | Add-Member -NotePropertyName Security -NotePropertyValue ([pscustomobject]@{ PassphraseHash = ''; FileSearchConsent = $null; FileSearchConsentAsked = $false; PendingWhitelistTarget = '' })
        } else {
            if ($null -eq $config.Security.PSObject.Properties['FileSearchConsent']) { $config.Security | Add-Member -NotePropertyName FileSearchConsent -NotePropertyValue $null }
            if ($null -eq $config.Security.PSObject.Properties['FileSearchConsentAsked']) { $config.Security | Add-Member -NotePropertyName FileSearchConsentAsked -NotePropertyValue $false }
            if ($null -eq $config.Security.PSObject.Properties['PendingWhitelistTarget']) { $config.Security | Add-Member -NotePropertyName PendingWhitelistTarget -NotePropertyValue '' }
        }
        if ([string]::IsNullOrWhiteSpace($script:PendingWhitelistTarget) -and -not [string]::IsNullOrWhiteSpace([string]$config.Security.PendingWhitelistTarget)) {
            $script:PendingWhitelistTarget = [string]$config.Security.PendingWhitelistTarget
        }
        if ($null -eq $config.PSObject.Properties['MemoryAliases']) {
            $config | Add-Member -NotePropertyName MemoryAliases -NotePropertyValue ([pscustomobject]@{})
        }
        if ($null -eq $config.AllowedApps.PSObject.Properties['設定']) {
            $config.AllowedApps | Add-Member -NotePropertyName '設定' -NotePropertyValue 'ms-settings:'
        }
        if (-not (Test-Path -LiteralPath $script:MemoryPath)) {
            Export-NovaMemory -Config $config | Out-Null
        }
        return $config
    } catch {
        throw "設定檔格式錯誤：$script:ConfigPath。請檢查 JSON。"
    }
}

function Add-NovaEvent {
    param(
        [string]$Kind,
        [string]$Text,
        [string]$Intent = '',
        [string]$Target = '',
        [string]$Result = '',
        [string]$Source = 'text'
    )
    $event = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        Kind = $Kind
        Text = $Text
        Intent = $Intent
        Target = $Target
        Result = $Result
        Source = $Source
    }
    $line = $event | ConvertTo-Json -Compress
    $mutex = $null
    $locked = $false
    try {
        # Voice commands run in a separate PowerShell process. A named mutex
        # keeps their event writes atomic and lets us cap the audit log.
        $mutex = New-Object System.Threading.Mutex($false, 'Local\NOVA.Events')
        $locked = $mutex.WaitOne(3000)
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        if ($locked) {
            [System.IO.File]::AppendAllText($script:EventsPath, $line + [Environment]::NewLine, $utf8)
            $file = Get-Item -LiteralPath $script:EventsPath -ErrorAction SilentlyContinue
            if ($null -ne $file -and $file.Length -gt 5242880) {
                $tail = @(Get-Content -LiteralPath $script:EventsPath -Encoding UTF8 -Tail 5000)
                [System.IO.File]::WriteAllText($script:EventsPath, (($tail -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)
            }
        } else {
            Add-Content -LiteralPath $script:EventsPath -Value $line -Encoding UTF8
        }
    } catch {
        try { Add-Content -LiteralPath $script:EventsPath -Value $line -Encoding UTF8 } catch { }
    } finally {
        if ($locked -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Normalize-NovaPhrase {
    param([string]$Phrase)
    $normalized = $Phrase.ToLowerInvariant()
    $digitMap = @{
        '零'='0'; '〇'='0'; '一'='1'; '二'='2'; '兩'='2'; '三'='3'; '四'='4'; '五'='5';
        '六'='6'; '七'='7'; '八'='8'; '九'='9'
    }
    foreach ($digit in $digitMap.Keys) { $normalized = $normalized.Replace($digit, $digitMap[$digit]) }
    return ($normalized -replace '[\s\p{P}\p{S}]', '')
}

function Get-NovaPhraseHash {
    param([string]$Phrase)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Normalize-NovaPhrase -Phrase $Phrase))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Test-NovaPassphrase {
    param([object]$Config, [string]$Phrase)
    $stored = [string]$Config.Security.PassphraseHash
    if ([string]::IsNullOrWhiteSpace($stored)) { return $false }
    return ((Get-NovaPhraseHash -Phrase $Phrase) -eq $stored.ToLowerInvariant())
}

function Save-NovaConfig {
    param([object]$Config)
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Export-NovaMemory {
    param([object]$Config)
    Initialize-NovaStore
    $aliases = [ordered]@{}
    if ($null -ne $Config.MemoryAliases) {
        foreach ($property in $Config.MemoryAliases.PSObject.Properties) {
            $aliases[[string]$property.Name] = [string]$property.Value
        }
    }
    $memory = [ordered]@{
        schemaVersion = 1
        updatedAt = (Get-Date).ToString('o')
        aliases = $aliases
        facts = @()
        preferences = [ordered]@{}
    }
    $memory | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:MemoryPath -Encoding UTF8
    return [pscustomobject]$memory
}

function Get-NovaMemoryJson {
    param([object]$Config)
    if (Test-Path -LiteralPath $script:MemoryPath) {
        try {
            $raw = Get-Content -LiteralPath $script:MemoryPath -Raw -Encoding UTF8
            $null = $raw | ConvertFrom-Json
            return $raw
        } catch { }
    }
    return ((Export-NovaMemory -Config $Config) | ConvertTo-Json -Depth 12)
}

function Reset-NovaMemoryData {
    param([string]$Code)
    if ($Code -ne '789') {
        return [pscustomobject]@{ Ok = $false; Message = '重置驗證碼不正確，沒有清除任何資料。' }
    }
    $config = Get-NovaConfig
    $config.MemoryAliases = [pscustomobject]@{}
    $config.Security.PassphraseHash = ''
    $config.Security.PendingWhitelistTarget = ''
    Save-NovaConfig -Config $config
    $emptyMemory = [ordered]@{
        schemaVersion = 1
        updatedAt = (Get-Date).ToString('o')
        aliases = [ordered]@{}
        facts = @()
        preferences = [ordered]@{}
    }
    $emptyMemory | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:MemoryPath -Encoding UTF8
    Set-Content -LiteralPath $script:EventsPath -Value '' -Encoding UTF8
    $script:PendingWhitelistTarget = ''
    try { $script:NovaUiEvents.Clear() } catch { }
    return [pscustomobject]@{ Ok = $true; Message = '測試重置完成：長期記憶、習慣紀錄與白名單密語已清除。' }
}

function Set-NovaPassphraseFromValues {
    param(
        [string]$Current,
        [string]$First,
        [string]$Second
    )
    if ([string]::IsNullOrWhiteSpace($First) -or $First -ne $Second) {
        return [pscustomobject]@{ Ok = $false; Message = '密語不可為空，且兩次輸入必須相同。' }
    }
    $config = Get-NovaConfig
    $existingHash = [string]$config.Security.PassphraseHash
    if (-not [string]::IsNullOrWhiteSpace($existingHash) -and -not (Test-NovaPassphrase -Config $config -Phrase $Current)) {
        return [pscustomobject]@{ Ok = $false; Message = '前次密語不正確，密語未變更。' }
    }
    $config.Security.PassphraseHash = Get-NovaPhraseHash -Phrase $First
    Save-NovaConfig -Config $config
    $message = if ([string]::IsNullOrWhiteSpace($existingHash)) { '白名單密語已設定。之後新增程式時，請說出相同密語確認。' } else { '白名單密語已更新。之後新增程式時，請說出新密語確認。' }
    return [pscustomobject]@{ Ok = $true; Message = $message }
}

function Resolve-NovaExecutable {
    param([string]$Target)
    $candidate = $Target.Trim().Trim('"')
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if ([IO.Path]::GetExtension($resolved).ToLowerInvariant() -eq '.exe') { return $resolved }
    }
    try {
        $command = Get-Command $candidate -CommandType Application -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $command -and [IO.Path]::GetExtension($command.Source).ToLowerInvariant() -eq '.exe') { return $command.Source }
    } catch { }

    # Many Windows desktop apps (including LINE) are not added to PATH. Look
    # up an exact-name Start Menu shortcut and use only its real .exe target.
    # This keeps the whitelist path-based while allowing natural commands such
    # as "開啟 LINE" after the passphrase has been confirmed.
    $candidateKey = Normalize-NovaPhrase -Phrase ([IO.Path]::GetFileNameWithoutExtension($candidate))
    if (-not [string]::IsNullOrWhiteSpace($candidateKey)) {
        $shortcutRoots = @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
        $shell = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            foreach ($root in $shortcutRoots) {
                foreach ($shortcut in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
                    $shortcutKey = Normalize-NovaPhrase -Phrase ([IO.Path]::GetFileNameWithoutExtension($shortcut.Name))
                    if ($shortcutKey -ne $candidateKey) { continue }
                    try {
                        $shortcutTarget = [string]$shell.CreateShortcut($shortcut.FullName).TargetPath
                        if (-not [string]::IsNullOrWhiteSpace($shortcutTarget) -and (Test-Path -LiteralPath $shortcutTarget -PathType Leaf) -and [IO.Path]::GetExtension($shortcutTarget).ToLowerInvariant() -eq '.exe') {
                            return (Resolve-Path -LiteralPath $shortcutTarget).Path
                        }
                    } catch { }
                }
            }
        } catch { }
        finally {
            if ($null -ne $shell) {
                try { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
            }
        }
    }

    # Also support apps registered through App Paths, without scanning the
    # whole disk or trusting an unverified registry value.
    $appPathKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\' + $candidate + '.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\' + $candidate + '.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\' + $candidate + '.exe'
    )
    foreach ($appPathKey in $appPathKeys) {
        try {
            $registered = [string](Get-ItemProperty -LiteralPath $appPathKey -Name '(default)' -ErrorAction Stop).'(default)'
            $registered = $registered.Trim().Trim('"')
            if ((Test-Path -LiteralPath $registered -PathType Leaf) -and [IO.Path]::GetExtension($registered).ToLowerInvariant() -eq '.exe') {
                return (Resolve-Path -LiteralPath $registered).Path
            }
        } catch { }
    }
    return $null
}

function Get-NovaAliasKey {
    param([string]$Text)
    return (Normalize-NovaPhrase -Phrase ($Text -replace '^\s*代號\s*', ''))
}

function Find-NovaMemoryAlias {
    param([object]$Config, [string]$InputText)
    $key = Get-NovaAliasKey -Text $InputText
    foreach ($property in $Config.MemoryAliases.PSObject.Properties) {
        if ((Normalize-NovaPhrase -Phrase ([string]$property.Name)) -eq $key) {
            return [pscustomobject]@{ Key = [string]$property.Name; Command = [string]$property.Value }
        }
    }
    return $null
}

function Complete-NovaWhitelist {
    param([object]$Config, [string]$Target)
    $path = Resolve-NovaExecutable -Target $Target
    if ($null -eq $path) {
        # Do not leave the confirmation gate armed forever when the requested
        # application cannot be resolved. The user can issue the open request
        # again after correcting the name or path.
        $script:PendingWhitelistTarget = ''
        $Config.Security.PendingWhitelistTarget = ''
        Save-NovaConfig -Config $Config
        return "密語確認成功，但找不到可加入白名單的 .exe：$Target。請改用完整的 exe 路徑，例如 C:\\Apps\\Example\\Example.exe。"
    }
    $targetText = $Target.Trim().Trim('"')
    $targetName = [IO.Path]::GetFileNameWithoutExtension($targetText)
    # A Start Menu display name can differ from the executable name (LINE's
    # shortcut currently launches LineLauncher.exe). Keep the spoken name as
    # the whitelist key when the request was a bare app name; full paths still
    # use the executable file name.
    $key = if (-not [string]::IsNullOrWhiteSpace($targetName) -and $targetText -notmatch '[\\/:]') { $targetName } else { [IO.Path]::GetFileNameWithoutExtension($path) }
    $Config.AllowedApps | Add-Member -NotePropertyName $key -NotePropertyValue $path -Force
    $Config.Security.PendingWhitelistTarget = ''
    Save-NovaConfig -Config $Config
    $script:PendingWhitelistTarget = ''
    try {
        Start-Process -FilePath $path | Out-Null
        return "密語確認成功，已將 $key 加入白名單並開啟。"
    } catch { return "已加入白名單，但開啟失敗：$($_.Exception.Message)" }
}

function Close-NovaAllowedApp {
    param([object]$Config, [string]$AppKey)
    $command = [string]$Config.AllowedApps.PSObject.Properties[$AppKey].Value
    $processName = [IO.Path]::GetFileNameWithoutExtension($command)
    $processes = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    $closed = $false
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) {
            try {
                [void]$process.CloseMainWindow()
                $closed = $true
            } catch { }
        }
    }
    if ($closed) { return "已幫您關閉$AppKey" }
    return "${AppKey}目前沒有可關閉的視窗。"
}

function Set-NovaPassphraseInteractive {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $config = Get-NovaConfig
    $hasExistingPassphrase = -not [string]::IsNullOrWhiteSpace([string]$config.Security.PassphraseHash)
    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = '設定 NOVA 白名單密語'
    $dialog.Size = New-Object System.Drawing.Size(440, (if ($hasExistingPassphrase) { 290 } else { 230 }))
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $label = [System.Windows.Forms.Label]::new()
    $label.Text = '密語會只以 SHA-256 雜湊儲存。語音辨識需盡量說出相同文字。'
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $label.Size = New-Object System.Drawing.Size(390, 40)
    [void]$dialog.Controls.Add($label)
    $currentLabel = New-Object System.Windows.Forms.Label
    $currentLabel.Text = '前次密語'
    $currentLabel.Location = New-Object System.Drawing.Point(20, 65)
    $currentLabel.Size = New-Object System.Drawing.Size(380, 20)
    $dialog.Controls.Add($currentLabel)
    $current = New-Object System.Windows.Forms.TextBox
    $current.Location = New-Object System.Drawing.Point(20, 85)
    $current.Size = New-Object System.Drawing.Size(380, 25)
    $current.UseSystemPasswordChar = $true
    [void]$dialog.Controls.Add($current)
    if (-not $hasExistingPassphrase) {
        $currentLabel.Visible = $false
        $current.Visible = $false
    }
    $firstY = if ($hasExistingPassphrase) { 125 } else { 75 }
    $first = [System.Windows.Forms.TextBox]::new()
    $first.Location = New-Object System.Drawing.Point(20, $firstY)
    $first.Size = New-Object System.Drawing.Size(380, 25)
    $first.UseSystemPasswordChar = $true
    [void]$dialog.Controls.Add($first)
    $second = [System.Windows.Forms.TextBox]::new()
    $second.Location = New-Object System.Drawing.Point(20, ($firstY + 35))
    $second.Size = New-Object System.Drawing.Size(380, 25)
    $second.UseSystemPasswordChar = $true
    [void]$dialog.Controls.Add($second)
    $ok = [System.Windows.Forms.Button]::new()
    $ok.Text = '儲存密語'
    $ok.Location = New-Object System.Drawing.Point(220, ($firstY + 75))
    $ok.Size = New-Object System.Drawing.Size(85, 30)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    [void]$dialog.Controls.Add($ok)
    $cancel = [System.Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(315, ($firstY + 75))
    $cancel.Size = New-Object System.Drawing.Size(85, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    [void]$dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    $dialog.Tag = $null
    $ok.Add_Click({
        $currentValue = [string]$current.Text
        $firstValue = [string]$first.Text
        $secondValue = [string]$second.Text
        $dialog.Tag = [pscustomobject]@{ Current = $currentValue; First = $firstValue; Second = $secondValue }
        if ([string]::IsNullOrWhiteSpace($firstValue) -or $firstValue -ne $secondValue) {
            [System.Windows.Forms.MessageBox]::Show($dialog, '密語不可為空，且兩次輸入必須相同。', '密語設定', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::None
        }
    }.GetNewClosure())
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return '已取消密語設定。' }
    if ($null -eq $dialog.Tag -or [string]::IsNullOrWhiteSpace([string]$dialog.Tag.First) -or [string]$dialog.Tag.First -ne [string]$dialog.Tag.Second) { return '密語不可為空，且兩次輸入必須相同。' }
    $result = Set-NovaPassphraseFromValues -Current ([string]$dialog.Tag.Current) -First ([string]$dialog.Tag.First) -Second ([string]$dialog.Tag.Second)
    return [string]$result.Message
}

function Get-NovaEvents {
    param([int]$Limit = 2000)
    Initialize-NovaStore
    $limit = [Math]::Max(1, [Math]::Min(5000, $Limit))
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in @(Get-Content -LiteralPath $script:EventsPath -Encoding UTF8 -Tail $limit)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $items.Add(($line | ConvertFrom-Json)) } catch { }
    }
    return $items.ToArray()
}

function Find-AppKey {
    param([object]$Config, [string]$InputText)
    # PowerShell's -match is already case-insensitive, but comparing a
    # normalized key as well makes names such as "Notepad", "notepad.exe",
    # and "開啟 notepad" resolve to the same whitelisted application. It also
    # tolerates spaces and punctuation differences in spoken commands.
    $inputKey = Normalize-NovaPhrase -Phrase ([string]$InputText)
    $best = $null
    $bestScore = 0
    foreach ($property in $Config.AllowedApps.PSObject.Properties) {
        $name = [string]$property.Name
        $path = [string]$property.Value
        $nameKey = Normalize-NovaPhrase -Phrase $name
        $pathKey = ''
        try { $pathKey = Normalize-NovaPhrase -Phrase ([IO.Path]::GetFileNameWithoutExtension($path)) } catch { }
        foreach ($candidate in @($nameKey, $pathKey)) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Length -lt 2) { continue }
            if ($inputKey.Contains($candidate)) {
                if ($candidate.Length -gt $bestScore) {
                    $best = $name
                    $bestScore = $candidate.Length
                }
            }
        }
    }
    $aliases = @{
        '記事本' = '記事本'; '記事本子' = '記事本'; 'calculator' = '計算機'; 'calc' = '計算機'
        'paint' = '小畫家'; 'explorer' = '檔案總管'; '檔案管理員' = '檔案總管'
    }
    foreach ($alias in $aliases.Keys) {
        $aliasKey = Normalize-NovaPhrase -Phrase $alias
        if ($inputKey.Contains($aliasKey)) {
            $mapped = [string]$aliases[$alias]
            if ($null -ne $Config.AllowedApps.PSObject.Properties[$mapped]) { return $mapped }
        }
    }
    return $best
}

function Find-Device {
    param([object]$Config, [string]$InputText)
    foreach ($device in @($Config.Devices)) {
        if ($InputText -match [regex]::Escape([string]$device.Name)) { return $device }
        foreach ($alias in @($device.Aliases)) {
            if ($InputText -match [regex]::Escape([string]$alias)) { return $device }
        }
    }
    return $null
}

function Get-NovaRuleIntent {
    param([object]$Config, [string]$InputText)
    $text = $InputText.Trim()
    if ($text -match '^\s*(設定|記住|學習|新增)\s*(?:代號|別名)\s*([A-Za-z0-9\u4e00-\u9fff_-]+)\s*(?:是|為|代表)\s*(.+)$') {
        return [pscustomobject]@{ Name = 'remember_alias'; Target = (Get-NovaAliasKey -Text $matches[2]); Command = $matches[3].Trim(); Risk = 'medium'; Description = "記住代號 $($matches[2])" }
    }
    if ($text -match '^(幫助|說明|help|你能做什麼)') {
        return [pscustomobject]@{ Name = 'help'; Target = ''; Risk = 'low'; Description = '顯示可用功能' }
    }
    if ($text -match '(習慣|偏好|學到|自動化建議|routine)') {
        return [pscustomobject]@{ Name = 'habits'; Target = ''; Risk = 'low'; Description = '分析本機互動記錄' }
    }
    if ($text -match '(天氣|氣象|溫度|降雨|預報|weather|temperature)') {
        return [pscustomobject]@{ Name = 'search_web'; Target = $text; Risk = 'low'; Description = "在網路搜尋：$text" }
    }
    if ($text -match '(開啟|打開|啟動|open|launch|start).*(預設)?\s*(瀏覽器|browser|網頁瀏覽器)') {
        return [pscustomobject]@{ Name = 'open_browser'; Target = 'default'; Risk = 'low'; Description = '開啟預設瀏覽器' }
    }
    if ($text -match '^\s*(到|去|前往|進入)?\s*(預設)?\s*(瀏覽器|browser|網頁瀏覽器)\s*$') {
        return [pscustomobject]@{ Name = 'open_browser'; Target = 'default'; Risk = 'low'; Description = '開啟預設瀏覽器' }
    }
    if ($text -match '(關閉|關掉|退出|close|quit|exit).*(預設)?\s*(瀏覽器|browser|網頁瀏覽器)') {
        return [pscustomobject]@{ Name = 'close_browser'; Target = 'default'; Risk = 'medium'; Description = '關閉預設瀏覽器' }
    }
    if (($text -match '(youtube|油管|優兔)') -and ($text -notmatch '(播放|播|聽|play)')) {
        return [pscustomobject]@{ Name = 'open_web'; Target = 'youtube'; Risk = 'low'; Description = '用預設瀏覽器搜尋 YouTube' }
    }
    if ($text -match '(播放|播|聽|play)\s*(.+)$') {
        $query = $matches[2].Trim()
        if (-not [string]::IsNullOrWhiteSpace($query)) {
            return [pscustomobject]@{ Name = 'play_youtube'; Target = $query; Risk = 'low'; Description = "在 YouTube 搜尋並播放：$query" }
        }
    }
    if ($text -match '(搜尋|找|查找)\s*(?:所有)?\s*(?:檔案|資料夾)?\s*(.+)$') {
        return [pscustomobject]@{ Name = 'search_files'; Target = $matches[2].Trim(); Risk = 'medium'; Description = "搜尋檔案：$($matches[2].Trim())" }
    }
    $app = Find-AppKey -Config $Config -InputText $text
    if ($app -and $text -match '(關閉|關掉|停止|close|quit|exit)') {
        return [pscustomobject]@{ Name = 'close_app'; Target = $app; Risk = 'medium'; Description = "關閉 $app" }
    }
    if ($app -and $text -match '(開啟|打開|啟動|open|launch)') {
        return [pscustomobject]@{ Name = 'open_app'; Target = $app; Risk = 'medium'; Description = "開啟 $app" }
    }
    if ($text -match '^(?:請|幫我)?\s*(開啟|打開|啟動|open|launch)\s*(.+)$') {
        $candidate = $matches[2].Trim().Trim('"')
        return [pscustomobject]@{ Name = 'request_whitelist'; Target = $candidate; Risk = 'high'; Description = "新增白名單：$candidate" }
    }
    $device = Find-Device -Config $Config -InputText $text
    if ($device -and $text -match '(關閉|關掉|關燈|turn off|off)') {
        return [pscustomobject]@{ Name = 'device_off'; Target = [string]$device.Name; Device = $device; Risk = 'medium'; Description = "關閉 $($device.Name)" }
    }
    if ($device -and $text -match '(開啟|打開|開燈|turn on|on)') {
        return [pscustomobject]@{ Name = 'device_on'; Target = [string]$device.Name; Device = $device; Risk = 'medium'; Description = "開啟 $($device.Name)" }
    }
    if ($text -match '(關機|重開機|刪除|格式化|shutdown|restart|delete)') {
        return [pscustomobject]@{ Name = 'dangerous'; Target = $text; Risk = 'high'; Description = '高風險系統動作' }
    }
    return [pscustomobject]@{ Name = 'unknown'; Target = ''; Risk = 'low'; Description = '' }
}

function Test-NovaOllama {
    param([object]$Config)
    $ollama = $Config.Ollama
    if (-not [bool]$ollama.Enabled) { return $false }
    if ((Get-Date) -lt $script:OllamaHealthUntil) { return $script:OllamaAvailable }
    $script:OllamaHealthUntil = (Get-Date).AddSeconds(30)
    $script:OllamaAvailable = $false
    try {
        $tags = Invoke-RestMethod -Method Get -Uri ("{0}/api/tags" -f ([string]$ollama.BaseUrl).TrimEnd('/')) -TimeoutSec 2
        $modelName = [string]$ollama.Model
        $script:OllamaAvailable = @($tags.models | Where-Object { $_.name -eq $modelName }).Count -gt 0
    } catch { }
    return $script:OllamaAvailable
}

function Get-OllamaIntent {
    param([object]$Config, [string]$InputText)
    if (-not (Test-NovaOllama -Config $Config)) { return $null }
    $ollama = $Config.Ollama
    $system = @'
你是 NOVA 的本機意圖解析器。你不能執行任何指令，也不能自行發明工具。
只能從這些 intent 選一個：open_app、close_app、open_browser、close_browser、device_on、device_off、play_youtube、open_web、search_files、search_web、help、habits、unknown。
只能回傳 JSON，不要 Markdown，不要解釋：{"intent":"...","target":"...","confidence":0.0}
請做語義分析，不要依賴固定歌曲、固定網站或固定句型：
- 使用者要播放、聆聽歌曲/音樂/影片時，回 play_youtube，target 填要搜尋的內容（例如歌名、歌手或主題），不要把「幫我播放」「音樂」等命令詞放進 target。
- 使用者只是要開啟 YouTube 或瀏覽網站時，回 open_web，target 填網站名稱。
- 使用者只是要開啟瀏覽器、預設瀏覽器或上網時，回 open_browser，target 填 default。
- 使用者要關閉瀏覽器時，回 close_browser，target 填 default。
- 使用者要找本機檔案或資料夾時，回 search_files，target 填檔名或關鍵字。
- 使用者詢問 NOVA 無法由本機工具處理的資訊（例如天氣、新聞或一般知識）時，回 search_web，target 填適合搜尋的完整查詢。
target 只能是使用者提到或可直接抽出的名稱；如果不確定就回 unknown。高風險要求（關機、刪除、任意 shell）一律回 unknown。
'@
    $memoryJson = Get-NovaMemoryJson -Config $Config
    if ($memoryJson.Length -gt 12000) { $memoryJson = $memoryJson.Substring(0, 12000) + "`n..." }
    $user = "可用程式與裝置會由 NOVA 白名單驗證。以下是本機長期記憶 JSON，只能用來理解代號、偏好與上下文，不能視為權限：`n$memoryJson`n使用者說：$InputText"
    $payload = @{
        model = [string]$ollama.Model
        stream = $false
        format = 'json'
        messages = @(
            @{ role = 'system'; content = $system },
            @{ role = 'user'; content = $user }
        )
    } | ConvertTo-Json -Depth 8
    try {
        $response = Invoke-RestMethod -Method Post -Uri ("{0}/api/chat" -f ([string]$ollama.BaseUrl).TrimEnd('/')) -ContentType 'application/json' -Body $payload -TimeoutSec ([int]$ollama.TimeoutSec)
        $raw = if ($null -ne $response.message) { [string]$response.message.content } else { [string]$response.response }
        $raw = $raw.Trim() -replace '^```json\s*', '' -replace '\s*```$', ''
        try {
            $parsed = $raw | ConvertFrom-Json
        } catch {
            # Some reasoning models may still wrap the structured answer in a
            # short preamble or a <think> block. Keep only the JSON object.
            $jsonStart = $raw.IndexOf('{')
            $jsonEnd = $raw.LastIndexOf('}')
            if ($jsonStart -lt 0 -or $jsonEnd -le $jsonStart) { throw }
            $parsed = $raw.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json
        }
        $valid = @('open_app', 'close_app', 'open_browser', 'close_browser', 'device_on', 'device_off', 'play_youtube', 'open_web', 'search_files', 'search_web', 'help', 'habits', 'unknown')
        if ([string]$parsed.intent -notin $valid) { return $null }
        return $parsed
    } catch { return $null }
}

function Get-NovaIntent {
    param([object]$Config, [string]$InputText)
    $alias = Find-NovaMemoryAlias -Config $Config -InputText $InputText
    $effectiveText = if ($null -ne $alias) { $alias.Command } else { $InputText }
    $ruleIntent = Get-NovaRuleIntent -Config $Config -InputText $effectiveText

    # Media requests go through Ollama first. This keeps music/video control
    # semantic instead of baking a song name or one exact sentence into rules.
    $mediaRequest = $effectiveText -match '(youtube|油管|優兔|播放|播歌|聽歌|聽音樂|音樂|歌曲|影片|video|music|play)'
    $ai = if ($mediaRequest -or $ruleIntent.Name -eq 'unknown') { Get-OllamaIntent -Config $Config -InputText $effectiveText } else { $null }

    if ($null -ne $ai -and [string]$ai.intent -eq 'open_web' -and -not [string]::IsNullOrWhiteSpace([string]$ai.target)) {
        $site = [string]$ai.target
        if ($site -match '(youtube|油管|優兔|yt)') {
            return [pscustomobject]@{ Name = 'open_web'; Target = 'youtube'; Risk = 'low'; Description = '用預設瀏覽器搜尋 YouTube' }
        }
    }
    if ($null -ne $ai -and [string]$ai.intent -eq 'play_youtube' -and -not [string]::IsNullOrWhiteSpace([string]$ai.target)) {
        return [pscustomobject]@{ Name = 'play_youtube'; Target = [string]$ai.target; Risk = 'low'; Description = "在 YouTube 搜尋並播放：$($ai.target)" }
    }

    if ($ruleIntent.Name -ne 'unknown') { return $ruleIntent }
    if ($null -eq $ai -or [string]$ai.intent -eq 'unknown') { return $ruleIntent }
    if ([string]$ai.intent -eq 'help') { return [pscustomobject]@{ Name = 'help'; Target = ''; Risk = 'low'; Description = '顯示可用功能' } }
    if ([string]$ai.intent -eq 'habits') { return [pscustomobject]@{ Name = 'habits'; Target = ''; Risk = 'low'; Description = '分析本機互動記錄' } }
    if ([string]$ai.intent -eq 'open_app') {
        $appKey = Find-AppKey -Config $Config -InputText ([string]$ai.target)
        if ($null -ne $appKey) { return [pscustomobject]@{ Name = 'open_app'; Target = $appKey; Risk = 'medium'; Description = "開啟 $appKey" } }
    }
    if ([string]$ai.intent -eq 'close_app') {
        $appKey = Find-AppKey -Config $Config -InputText ([string]$ai.target)
        if ($null -ne $appKey) { return [pscustomobject]@{ Name = 'close_app'; Target = $appKey; Risk = 'medium'; Description = "關閉 $appKey" } }
    }
    if ([string]$ai.intent -eq 'open_browser') {
        return [pscustomobject]@{ Name = 'open_browser'; Target = 'default'; Risk = 'low'; Description = '開啟預設瀏覽器' }
    }
    if ([string]$ai.intent -eq 'close_browser') {
        return [pscustomobject]@{ Name = 'close_browser'; Target = 'default'; Risk = 'medium'; Description = '關閉預設瀏覽器' }
    }
    if ([string]$ai.intent -eq 'open_web' -and [string]$ai.target -match '(youtube|油管|優兔|yt)') {
        return [pscustomobject]@{ Name = 'open_web'; Target = 'youtube'; Risk = 'low'; Description = '用預設瀏覽器搜尋 YouTube' }
    }
    if ([string]$ai.intent -eq 'search_files' -and -not [string]::IsNullOrWhiteSpace([string]$ai.target)) {
        return [pscustomobject]@{ Name = 'search_files'; Target = [string]$ai.target; Risk = 'medium'; Description = "搜尋檔案：$($ai.target)" }
    }
    if ([string]$ai.intent -eq 'search_web' -and -not [string]::IsNullOrWhiteSpace([string]$ai.target)) {
        return [pscustomobject]@{ Name = 'search_web'; Target = [string]$ai.target; Risk = 'low'; Description = "在網路搜尋：$($ai.target)" }
    }
    if ([string]$ai.intent -in @('device_on', 'device_off')) {
        $device = Find-Device -Config $Config -InputText ([string]$ai.target)
        if ($null -ne $device) {
            return [pscustomobject]@{ Name = [string]$ai.intent; Target = [string]$device.Name; Device = $device; Risk = 'medium'; Description = if ([string]$ai.intent -eq 'device_on') { "開啟 $($device.Name)" } else { "關閉 $($device.Name)" } }
        }
    }
    return $ruleIntent
}

function Invoke-HomeAssistantDevice {
    param([object]$Config, [object]$Intent)
    $ha = $Config.HomeAssistant
    if (-not [bool]$ha.Enabled -or [string]::IsNullOrWhiteSpace([string]$ha.Token)) {
        return "尚未執行：請先在 $script:ConfigPath 設定 Home Assistant Enabled、BaseUrl 與 Token。"
    }
    $domain = [string]$Intent.Device.Domain
    if ([string]::IsNullOrWhiteSpace($domain)) { $domain = ([string]$Intent.Device.EntityId).Split('.')[0] }
    $service = if ($Intent.Name -eq 'device_on') { 'turn_on' } else { 'turn_off' }
    $uri = "{0}/api/services/{1}/{2}" -f ([string]$ha.BaseUrl).TrimEnd('/'), $domain, $service
    $body = @{ entity_id = [string]$Intent.Device.EntityId } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $($ha.Token)" } -ContentType 'application/json' -Body $body | Out-Null
        return "已送出 Home Assistant 指令：$($Intent.Description)"
    } catch {
        return "家電控制失敗：$($_.Exception.Message)"
    }
}

function Get-HabitReport {
    $allCommands = @(Get-NovaEvents | Where-Object { $_.Kind -eq 'command' })
    if ($allCommands.Count -eq 0) { return "目前還沒有指令紀錄。多使用幾次 NOVA，我會在本機觀察重複模式。" }
    $actionEvents = @($allCommands | Where-Object { $_.Intent -notin @('unknown', 'habits', 'help', 'request_whitelist', 'dangerous') })
    $lines = @('本機習慣紀錄（來源：本機 events.jsonl；只產生建議，不會自行執行）：')
    if ($actionEvents.Count -gt 0) {
        $groups = $actionEvents | Group-Object -Property { "{0}|{1}" -f $_.Intent, $_.Target } | Sort-Object Count -Descending
        $lines += '重複操作摘要：'
        $summaryCount = 0
        foreach ($group in @($groups | Select-Object -First 8)) {
            if ($group.Count -lt 2) { continue }
            $sample = @($group.Group)[0]
            $hours = @($group.Group | ForEach-Object { try { ([datetime]$_.Timestamp).Hour } catch { 0 } })
            $hour = ($hours | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
            $timeText = if ($null -ne $hour) { "約 $hour 點" } else { '固定時段' }
            $lines += "- $($sample.Text)：已出現 $($group.Count) 次，常在$timeText；可考慮建立 routine。"
            $summaryCount++
        }
        if ($summaryCount -eq 0) { $lines += '- 目前只有零散的成功操作，繼續使用後才會形成穩定建議。' }
    } else {
        $lines += '目前尚無可分析的成功操作。'
    }
    $lines += ''
    $lines += '最近實際輸入：'
    foreach ($event in @($allCommands | Select-Object -Last 8)) {
        try { $time = ([datetime]$event.Timestamp).ToString('MM-dd HH:mm:ss') } catch { $time = '時間未知' }
        $source = if ([string]$event.Source -eq 'voice') { '語音' } else { '文字' }
        $lines += "- [$time][$source] $($event.Text) → $($event.Intent)"
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-NovaHelp {
    return @"
你可以試試：
  開啟記事本
  打開計算機
  開啟客廳燈 / 關掉客廳燈（需設定 Home Assistant）
  顯示習慣
  開啟瀏覽器
  關閉瀏覽器
  開啟 YouTube
  搜尋檔案 報告
  幫助

安全原則：程式只使用白名單；家電走設定好的連線；高風險動作不會直接執行。
"@
}

function Ensure-NovaFileSearchConsent {
    param([object]$Owner)
    $config = Get-NovaConfig
    if ([bool]$config.Security.FileSearchConsentAsked) { return }
    $message = "NOVA 第一次啟動設定`r`n`r`n是否允許 NOVA 搜尋本機固定磁碟中的檔案與資料夾？`r`n`r`nNOVA 只使用目前 Windows 使用者權限，不會繞過系統 ACL；搜尋結果只留在本機。"
    $answer = [System.Windows.Forms.MessageBox]::Show($Owner, $message, 'NOVA 本機檔案搜尋權限', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    $config.Security.FileSearchConsentAsked = $true
    $config.Security.FileSearchConsent = ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
    Save-NovaConfig -Config $config
}

function Search-NovaFiles {
    param([object]$Config, [string]$Query)
    if (-not [bool]$Config.Security.FileSearchConsent) {
        return '尚未允許本機檔案搜尋。請重新啟動 NOVA，在第一次啟動權限詢問中選擇「是」。'
    }
    $needle = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($needle)) { return '請告訴我要搜尋的檔名或關鍵字。' }
    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
        try {
            Get-ChildItem -LiteralPath $drive.Root -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$needle*" -or $_.FullName -like "*$needle*" } |
                Select-Object -First 20 -ExpandProperty FullName |
                ForEach-Object { if ($matches.Count -lt 20) { $matches.Add([string]$_) } }
        } catch { }
        if ($matches.Count -ge 20) { break }
    }
    if ($matches.Count -eq 0) { return "找不到包含「$needle」的檔案或資料夾。" }
    return ("找到 $($matches.Count) 個結果：" + [Environment]::NewLine + (($matches | ForEach-Object { "- $_" }) -join [Environment]::NewLine))
}

function Open-NovaYouTube {
    param([string]$Query, [switch]$Play)
    $encoded = [System.Uri]::EscapeDataString($Query.Trim())
    $url = "https://www.youtube.com/results?search_query=$encoded"
    try {
        if ($Play) {
            $node = Get-Command node -ErrorAction SilentlyContinue
            $agent = Join-Path $PSScriptRoot 'browser-agent.js'
            if ($null -ne $node -and (Test-Path -LiteralPath $agent)) {
                $raw = (& $node.Source $agent $Query 2>$null | Out-String).Trim()
                try {
                    $automation = $raw | ConvertFrom-Json
                    if ([bool]$automation.ok) {
                        if ([bool]$automation.playing) { return "已開啟 YouTube，找到「$Query」並點擊播放。" }
                        return "已開啟「$Query」影片並點擊播放；瀏覽器目前仍顯示暫停，請確認音量或播放權限。"
                    }
                } catch { }
            }
        }
        Start-Process -FilePath $url | Out-Null
        if ($Play) { return "已開啟 YouTube 並搜尋「$Query」。若瀏覽器阻止自動播放，請點選第一個結果播放。" }
        return '已開啟預設瀏覽器並搜尋 YouTube。'
    } catch { return "開啟 YouTube 失敗：$($_.Exception.Message)" }
}

function Get-NovaDefaultBrowserRegistration {
    $progId = ''
    try {
        $choice = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -Name ProgId -ErrorAction Stop
        $progId = [string]$choice.ProgId
    } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($progId)) { return $null }
    foreach ($keyPath in @("HKCU:\Software\Classes\$progId\shell\open\command", "HKLM:\Software\Classes\$progId\shell\open\command")) {
        try {
            $commandLine = [string](Get-Item -LiteralPath $keyPath -ErrorAction Stop).GetValue('')
            $match = [regex]::Match($commandLine, '^\s*"(?<quoted>[^"]+\.exe)"|^\s*(?<plain>[^\s]+\.exe)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                $executable = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
                if (Test-Path -LiteralPath $executable -PathType Leaf) {
                    return [pscustomobject]@{ ProgId = $progId; Executable = $executable }
                }
            }
        } catch { }
    }
    return $null
}

function Open-NovaDefaultBrowser {
    $url = 'http://127.0.0.1:24808/'
    try {
        $registration = Get-NovaDefaultBrowserRegistration
        if ($null -ne $registration) {
            $newWindowArgument = if ([string]$registration.ProgId -match 'Firefox') { '-new-window' } else { '--new-window' }
            Start-Process -FilePath ([string]$registration.Executable) -ArgumentList @($newWindowArgument, $url) | Out-Null
            return '已用 Windows 預設瀏覽器開啟新視窗。'
        }
        # Fallback still uses Windows HTTP association, never a hardcoded
        # browser. An HTTP URL avoids the about: protocol Store association.
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $url
        $startInfo.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($startInfo) | Out-Null
        return '已用 Windows 預設瀏覽器開啟新視窗。'
    } catch { return "開啟預設瀏覽器失敗：$($_.Exception.Message)" }
}

function Open-NovaWebSearch {
    param([string]$Query)
    $needle = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($needle)) { return '請提供要搜尋的內容。' }
    $encoded = [System.Uri]::EscapeDataString($needle)
    $url = "https://www.google.com/search?q=$encoded"
    try {
        Start-Process -FilePath $url | Out-Null
        return "已用 Windows 預設瀏覽器搜尋「$needle」。"
    } catch { return "開啟網路搜尋失敗：$($_.Exception.Message)" }
}

function Close-NovaDefaultBrowser {
    $progId = ''
    try {
        $choice = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -Name ProgId -ErrorAction Stop
        $progId = [string]$choice.ProgId
    } catch { }
    $processNames = switch -Regex ($progId) {
        'Chrome' { @('chrome'); break }
        'MSEdge|Edge' { @('msedge'); break }
        'Firefox' { @('firefox'); break }
        'Brave' { @('brave'); break }
        'Opera' { @('opera'); break }
        'Vivaldi' { @('vivaldi'); break }
        default { @() }
    }
    if ($processNames.Count -eq 0) { return '無法判定 Windows 預設瀏覽器，未關閉任何視窗。' }
    $closed = 0
    foreach ($name in $processNames) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($process.MainWindowHandle -eq 0) { continue }
            try {
                if ($process.CloseMainWindow()) { $closed++ }
            } catch { }
        }
    }
    if ($closed -gt 0) { return '已送出關閉預設瀏覽器視窗的指令。' }
    return '目前沒有可關閉的預設瀏覽器視窗。'
}

function Get-NovaSuggestions {
    param([object]$Config, [string]$InputText)
    $text = $InputText.Trim()
    $suggestions = New-Object System.Collections.Generic.List[string]
    if ($text -match '(燈|家電|設備|插座|空調|冷氣)') {
        foreach ($device in @($Config.Devices)) {
            $suggestions.Add("開啟$($device.Name)")
            $suggestions.Add("關掉$($device.Name)")
        }
    }
    if ($text -match '(開|打|程式|軟體|應用)') {
        foreach ($property in $Config.AllowedApps.PSObject.Properties) {
            $suggestions.Add("開啟$($property.Name)")
        }
    }
    if ($suggestions.Count -eq 0) {
        $suggestions.Add('開啟記事本')
        $suggestions.Add('顯示習慣')
        $suggestions.Add('幫助')
    }
    return @($suggestions | Select-Object -Unique -First 6)
}

function Get-NovaTtsText {
    param([string]$Text)
    $compact = ($Text -replace "`r?`n", '；').Trim()
    if ($compact.Length -gt 220) { return $compact.Substring(0, 220) + '。詳細內容請看畫面。' }
    return $compact
}

function Speak-NovaText {
    param([string]$Text)
    $speechText = Get-NovaTtsText -Text $Text
    if ([string]::IsNullOrWhiteSpace($speechText)) { return $false }
    try {
        Add-Type -AssemblyName System.Speech
        if ($null -eq $script:NovaReplySynth) {
            $script:NovaReplySynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $voice = @($script:NovaReplySynth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -in @('zh-TW', 'zh-CN', 'en-US') } | Select-Object -First 1)
            if ($voice.Count -gt 0) { $script:NovaReplySynth.SelectVoice($voice[0].VoiceInfo.Name) }
        }
        $script:NovaReplySynth.SpeakAsyncCancelAll()
        $script:NovaReplySynth.SpeakAsync($speechText) | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Invoke-NovaText {
    param([string]$InputText, [string]$Source = 'text', [switch]$SkipConfirmation)
    $config = Get-NovaConfig

    if (-not [string]::IsNullOrWhiteSpace($script:PendingWhitelistTarget)) {
        if (Test-NovaPassphrase -Config $config -Phrase $InputText) {
            $target = $script:PendingWhitelistTarget
            Add-NovaEvent -Kind 'passphrase_verified' -Text '[REDACTED]' -Intent 'whitelist' -Target $target -Result 'verified' -Source $Source
            return (Complete-NovaWhitelist -Config $config -Target $target)
        }
        if ([string]::IsNullOrWhiteSpace([string]$config.Security.PassphraseHash)) {
            return '尚未設定白名單密語。請先按「設定密語」，再說出密語確認。'
        }
        return '密語不正確，白名單未變更。請重新說出已設定的密語。'
    }

    if (Test-NovaPassphrase -Config $config -Phrase $InputText) {
        Add-NovaEvent -Kind 'passphrase_verified' -Text '[REDACTED]' -Intent 'whitelist' -Target '' -Result 'no_pending_request' -Source $Source
        return '密語已驗證，但目前沒有等待確認的白名單新增請求。'
    }

    if ($InputText -match '(youtube|油管|優兔|播放|播歌|聽歌|聽音樂|音樂|歌曲|影片|video|music|play)' -and (Test-NovaOllama -Config $config)) {
        Add-NovaUiEvent -Type 'status' -Message '正在使用 Ollama 分析播放意圖…' -Source 'ollama'
    }
    $intent = Get-NovaIntent -Config $config -InputText $InputText
    Add-NovaEvent -Kind 'command' -Text $InputText -Intent $intent.Name -Target $intent.Target -Source $Source
    switch ($intent.Name) {
        'help' { return Get-NovaHelp }
        'habits' { return Get-HabitReport }
        'remember_alias' {
            $config.MemoryAliases | Add-Member -NotePropertyName $intent.Target -NotePropertyValue $intent.Command -Force
            Save-NovaConfig -Config $config
            Export-NovaMemory -Config $config | Out-Null
            $result = "已記住代號 $($intent.Target)：$($intent.Command)。下次說「$($intent.Target)」即可套用。"
            Add-NovaEvent -Kind 'memory_saved' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'open_web' {
            $query = if ([string]::IsNullOrWhiteSpace([string]$intent.Target)) { 'youtube' } else { [string]$intent.Target }
            $result = Open-NovaYouTube -Query $query
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'open_browser' {
            $result = Open-NovaDefaultBrowser
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'close_browser' {
            $result = Close-NovaDefaultBrowser
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'play_youtube' {
            $result = Open-NovaYouTube -Query $intent.Target -Play
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'search_files' {
            $result = Search-NovaFiles -Config $config -Query $intent.Target
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'search_web' {
            $query = if ([string]::IsNullOrWhiteSpace([string]$intent.Target)) { $InputText } else { [string]$intent.Target }
            $result = Open-NovaWebSearch -Query $query
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $query -Result $result -Source $Source
            return $result
        }
        'open_app' {
            try {
                $command = [string]$config.AllowedApps.PSObject.Properties[$intent.Target].Value
                Start-Process -FilePath $command | Out-Null
                $result = "已開啟 $($intent.Target)。"
            } catch { $result = "開啟失敗：$($_.Exception.Message)" }
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'close_app' {
            $result = Close-NovaAllowedApp -Config $config -AppKey $intent.Target
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source
            return $result
        }
        'request_whitelist' {
            $script:PendingWhitelistTarget = $intent.Target
            $config.Security.PendingWhitelistTarget = $intent.Target
            Save-NovaConfig -Config $config
            Add-NovaEvent -Kind 'whitelist_pending' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result 'awaiting_passphrase' -Source $Source
            if ([string]::IsNullOrWhiteSpace([string]$config.Security.PassphraseHash)) {
                return "這個程式尚未在白名單：$($intent.Target)。請先按「設定密語」，然後重新說一次開啟指令；接著我會要求你說出密語確認。"
            }
            return "這個程式尚未在白名單：$($intent.Target)。請說出已設定的密語，確認後我會只加入這個 .exe 並開啟。"
        }
        'device_on' { $result = Invoke-HomeAssistantDevice -Config $config -Intent $intent; Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source; return $result }
        'device_off' { $result = Invoke-HomeAssistantDevice -Config $config -Intent $intent; Add-NovaEvent -Kind 'result' -Text $InputText -Intent $intent.Name -Target $intent.Target -Result $result -Source $Source; return $result }
        'dangerous' { return "這個請求涉及高風險系統動作。MVP 尚未提供任意關機、刪除或 shell 執行工具。" }
        default {
            $result = Open-NovaWebSearch -Query $InputText
            Add-NovaEvent -Kind 'result' -Text $InputText -Intent 'search_web' -Target $InputText -Result $result -Source $Source
            return "我目前無法直接處理這項操作，已開啟預設瀏覽器並搜尋「$InputText」。"
        }
    }
}

function Start-NovaWindowsSpeechVoice {
    param(
        [scriptblock]$OnText,
        [scriptblock]$OnStatus
    )
    if ($null -ne $script:NovaVoiceEngine) { return 'voice_already_running' }
    try {
        Add-Type -AssemblyName System.Speech
        $recognizers = @([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers())
        if ($recognizers.Count -eq 0) { throw '找不到 Windows 語音辨識器。請在 Windows 語言設定安裝語音套件。' }
        $preferred = @($recognizers | Where-Object { $_.Culture.Name -in @('zh-TW', 'zh-CN', 'en-US') } | Select-Object -First 1)
        $info = if ($preferred.Count -gt 0) { $preferred[0] } else { $recognizers[0] }
        $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($info)
        $dictation = New-Object System.Speech.Recognition.DictationGrammar
        $dictation.Name = 'NOVA command dictation'
        $engine.LoadGrammar($dictation)
        # A dedicated grammar makes the mixed Chinese/English wake phrase much
        # easier for the installed zh-TW recognizer to catch than dictation alone.
        $wakeChoices = New-Object System.Speech.Recognition.Choices
        foreach ($wakePhrase in @(
            '嘿 NOVA', '嘿NOVA', '嘿 諾瓦', '嘿諾瓦', '嘿 挪瓦', '嘿挪瓦', '嘿 諾娃', '嘿諾娃', '嘿挪娃', '嘿諾哇', '嘿挪哇', '嘿 no va',
            '黑 NOVA', '黑NOVA', '黑 諾瓦', '黑諾瓦', '黑挪瓦', '黑諾娃',
            '嗨 NOVA', '嗨NOVA', '嗨 諾瓦', '嗨諾瓦', '嗨挪瓦', '嗨諾娃', 'hey nova'
        )) {
            [void]$wakeChoices.Add($wakePhrase)
        }
        $wakeBuilder = New-Object System.Speech.Recognition.GrammarBuilder
        $wakeBuilder.Culture = $info.Culture
        [void]$wakeBuilder.Append($wakeChoices)
        $wakeGrammar = New-Object System.Speech.Recognition.Grammar($wakeBuilder)
        $wakeGrammar.Name = 'NOVA wake phrase'
        $engine.LoadGrammar($wakeGrammar)
        $engine.SetInputToDefaultAudioDevice()
        $engine.InitialSilenceTimeout = [TimeSpan]::FromSeconds(4)
        $engine.BabbleTimeout = [TimeSpan]::FromSeconds(2)
        $engine.EndSilenceTimeout = [TimeSpan]::FromSeconds(0.8)
        $script:NovaVoiceEngine = $engine
        $script:NovaVoiceSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        try {
            $script:NovaVoiceSynth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet, [System.Speech.Synthesis.VoiceAge]::NotSet, 0, $info.Culture)
        } catch { }
        $script:NovaWakeUntil = [datetime]::MinValue
        $script:NovaVoiceOnText = $OnText
        $script:NovaVoiceOnStatus = $OnStatus

        $handler = {
            param($sender, $eventArgs)
            try {
                if ($null -eq $eventArgs -or $null -eq $eventArgs.Result) { return }
                $textProperty = $eventArgs.Result.PSObject.Properties['Text']
                if ($null -eq $textProperty) { return }
                $heard = ([string]$textProperty.Value).Trim()
                if ([string]::IsNullOrWhiteSpace($heard)) { return }
                $voiceLogText = $heard
                try {
                    $voiceConfig = Get-NovaConfig
                    if (Test-NovaPassphrase -Config $voiceConfig -Phrase $heard) { $voiceLogText = '[REDACTED]' }
                } catch { }
                Add-NovaEvent -Kind 'voice_heard' -Text $voiceLogText -Intent 'voice' -Target '' -Result 'recognized' -Source 'voice'
                $wakeProbe = $heard.Normalize([System.Text.NormalizationForm]::FormKC).ToLowerInvariant() -replace '[\s\p{P}\p{S}]', ''
                $wakeMatch = [regex]::Match($wakeProbe, '^(嘿|黑|嗨|hey)(nova|諾瓦|挪瓦|諾娃|挪娃|諾哇|挪哇|no[wv]a)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($wakeMatch.Success) {
                    $wakeOriginalMatch = [regex]::Match($heard, '^\s*(嘿|黑|嗨|hey)[\s\p{P}\p{S}]*(n[\s\p{P}\p{S}]*o[\s\p{P}\p{S}]*v[\s\p{P}\p{S}]*a|諾瓦|挪瓦|諾娃|挪娃|諾哇|挪哇)\s*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    $remainder = if ($wakeOriginalMatch.Success) { $heard.Substring($wakeOriginalMatch.Length).Trim() } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($remainder)) {
                        $script:NovaWakeUntil = [datetime]::MinValue
                        & $script:NovaVoiceOnStatus "已喚醒，辨識到：$remainder"
                        try {
                            $answer = & $script:NovaVoiceOnText $remainder
                            $script:NovaVoiceSynth.SpeakAsync((Get-NovaTtsText -Text $answer)) | Out-Null
                        } catch {
                            $answer = "執行失敗：$($_.Exception.Message)"
                            $script:NovaVoiceSynth.SpeakAsync($answer) | Out-Null
                        }
                        return
                    }
                    $script:NovaWakeUntil = (Get-Date).AddSeconds(10)
                    $script:NovaVoiceSynth.SpeakAsync('我在。') | Out-Null
                    & $script:NovaVoiceOnStatus '已喚醒，請在 10 秒內說出指令。'
                    return
                }
                if ((Get-Date) -le $script:NovaWakeUntil) {
                    $script:NovaWakeUntil = [datetime]::MinValue
                    & $script:NovaVoiceOnStatus "辨識到：$heard"
                    try {
                        $answer = & $script:NovaVoiceOnText $heard
                        $script:NovaVoiceSynth.SpeakAsync((Get-NovaTtsText -Text $answer)) | Out-Null
                    } catch {
                        $answer = "執行失敗：$($_.Exception.Message)"
                        $script:NovaVoiceSynth.SpeakAsync($answer) | Out-Null
                    }
                    & $script:NovaVoiceOnStatus '持續監聽中，等待「嘿 NOVA」。'
                }
            } catch {
                try { Add-NovaEvent -Kind 'voice_error' -Text '[REDACTED]' -Intent 'voice' -Target '' -Result $_.Exception.Message -Source 'voice' } catch { }
            }
        }.GetNewClosure()
        $rejectedHandler = {
            param($sender, $eventArgs)
            try { & $script:NovaVoiceOnStatus '未辨識到清楚語音，仍在等待「嘿 NOVA」。' } catch { }
        }.GetNewClosure()
        $detectedHandler = {
            param($sender, $eventArgs)
            try { & $script:NovaVoiceOnStatus '正在收音…' } catch { }
        }.GetNewClosure()
        $audioProblemHandler = {
            param($sender, $eventArgs)
            try {
                $problem = if ($null -ne $eventArgs -and $null -ne $eventArgs.AudioSignalProblem) { [string]$eventArgs.AudioSignalProblem } else { '未知問題' }
                Add-NovaEvent -Kind 'voice_error' -Text '[REDACTED]' -Intent 'voice' -Target '' -Result "麥克風訊號問題：$problem" -Source 'voice'
                & $script:NovaVoiceOnStatus "麥克風訊號問題：$problem"
            } catch { }
        }.GetNewClosure()
        $completedHandler = {
            param($sender, $eventArgs)
            try {
                if ($null -ne $eventArgs.Error) {
                    & $script:NovaVoiceOnStatus "語音引擎錯誤：$($eventArgs.Error.Message)"
                } elseif ([bool]$eventArgs.InitialSilenceTimeout -or [bool]$eventArgs.InputStreamEnded) {
                    & $script:NovaVoiceOnStatus '語音仍在等待「嘿 NOVA」。'
                }
            } catch { }
        }.GetNewClosure()
        $script:NovaVoiceRecognizedHandler = $handler
        $engine.add_SpeechRecognized($handler)
        $script:NovaVoiceCompletedHandler = $completedHandler
        $engine.add_RecognizeCompleted($completedHandler)
        $script:NovaVoiceRejectedHandler = $rejectedHandler
        $engine.add_SpeechRecognitionRejected($rejectedHandler)
        $script:NovaVoiceDetectedHandler = $detectedHandler
        $engine.add_SpeechDetected($detectedHandler)
        $script:NovaVoiceAudioProblemHandler = $audioProblemHandler
        $engine.add_AudioSignalProblemOccurred($audioProblemHandler)
        $engine.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
        & $OnStatus "語音已啟動（$($info.Culture.Name)），等待「嘿 NOVA」。"
        return 'voice_started'
    } catch {
        $script:NovaVoiceEngine = $null
        if ($null -ne $script:NovaVoiceSynth) { $script:NovaVoiceSynth.Dispose(); $script:NovaVoiceSynth = $null }
        & $OnStatus "語音啟動失敗：$($_.Exception.Message)"
        return 'voice_failed'
    }
}

function Get-NovaPythonPath {
    $candidates = @(
        (Join-Path $PSScriptRoot 'runtime\python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path ${env:ProgramFiles} 'Python312\python.exe'),
        (Join-Path ${env:ProgramFiles} 'Python311\python.exe')
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    try {
        $command = Get-Command python.exe -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $command -and $command.Source -notmatch '\\WindowsApps\\') { return $command.Source }
    } catch { }
    return $null
}

function Speak-NovaVoiceReply {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    try {
        if ($null -ne $script:NovaVoiceSynth) {
            $script:NovaVoiceSynth.SpeakAsyncCancelAll()
            $script:NovaVoiceSynth.SpeakAsync((Get-NovaTtsText -Text $Text)) | Out-Null
        }
    } catch { }
}

function Invoke-NovaWhisperCommand {
    param([string]$CommandText)
    $command = ([string]$CommandText).Trim()
    if ([string]::IsNullOrWhiteSpace($command)) { return }
    $key = Normalize-NovaPhrase -Phrase $command
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    # Microphone recognition can repeat one segment while the user is still
    # speaking. Do not open an app/browser repeatedly for the same voice text.
    if ($key -eq $script:NovaLastVoiceCommandKey -and ((Get-Date) - $script:NovaLastVoiceCommandAt).TotalSeconds -lt 8) {
        try { & $script:NovaVoiceOnStatus '已忽略重複語音，避免重複執行。' } catch { }
        return
    }
    $script:NovaLastVoiceCommandKey = $key
    $script:NovaLastVoiceCommandAt = Get-Date
    try { & $script:NovaVoiceOnStatus "辨識到：$command" } catch { }
    Add-NovaUiEvent -Type 'user' -Message $command -Source 'voice'
    if ($script:NovaServerMode) {
        try {
            $existing = $script:NovaVoiceCommandProcess
            if ($null -ne $existing -and -not $existing.HasExited) {
                & $script:NovaVoiceOnStatus '上一個語音指令仍在執行，已忽略新的語音。'
                return
            }
        } catch { }
        try {
            $workerPath = Join-Path $PSScriptRoot 'NOVA.ps1'
            $workerPowerShell = Join-Path $PSHOME 'powershell.exe'
            if (-not (Test-Path -LiteralPath $workerPowerShell -PathType Leaf)) {
                $workerPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
            }
            $safePath = $workerPath.Replace("'", "''")
            $safeText = $command.Replace("'", "''")
            $workerCode = "& '$safePath' -VoiceWorker -Text '$safeText' -CallbackPort $script:NovaListenPort -Source 'voice'"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCode))
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $workerPowerShell
            $psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
            $psi.WorkingDirectory = $PSScriptRoot
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            if (-not $process.Start()) { throw '無法啟動語音指令工作程序。' }
            $script:NovaVoiceCommandProcess = $process
            & $script:NovaVoiceOnStatus '語音指令已送出，正在執行…'
        } catch {
            Add-NovaUiEvent -Type 'assistant' -Message "語音指令啟動失敗：$($_.Exception.Message)" -Source 'backend'
            try { & $script:NovaVoiceOnStatus "語音指令啟動失敗：$($_.Exception.Message)" } catch { }
        }
        return
    }
    try {
        $answer = & $script:NovaVoiceOnText $command
        Speak-NovaVoiceReply -Text ([string]$answer)
    } catch {
        $answer = "執行失敗：$($_.Exception.Message)"
        Speak-NovaVoiceReply -Text $answer
    }
}

function Invoke-NovaWhisperHeard {
    param([string]$Heard)
    $heard = ([string]$Heard).Trim()
    if ([string]::IsNullOrWhiteSpace($heard)) { return }
    $meaningful = ($heard.Normalize([System.Text.NormalizationForm]::FormKC) -replace '[\s\p{P}\p{S}]', '')
    if ([string]::IsNullOrWhiteSpace($meaningful)) { return }
    $voiceLogText = $heard
    try {
        $voiceConfig = Get-NovaConfig
        if (Test-NovaPassphrase -Config $voiceConfig -Phrase $heard) { $voiceLogText = '[REDACTED]' }
    } catch { }
    Add-NovaEvent -Kind 'voice_heard' -Text $voiceLogText -Intent 'voice' -Target '' -Result 'recognized' -Source 'voice'
    $wakeProbe = $heard.Normalize([System.Text.NormalizationForm]::FormKC).ToLowerInvariant() -replace '[\s\p{P}\p{S}]', ''
    $wakeMatch = [regex]::Match($wakeProbe, '^(嘿|黑|嗨|hey)(nova|諾瓦|挪瓦|諾娃|挪娃|諾哇|挪哇|no[wv]a)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $wakeOnlyPattern = '^((嘿|黑|嗨|hey)(nova|諾瓦|挪瓦|諾娃|挪娃|諾哇|挪哇|no[wv]a))+$'
    if ($wakeProbe -match $wakeOnlyPattern) {
        if ((Get-Date) -gt $script:NovaWakeUntil) {
            $script:NovaWakeUntil = (Get-Date).AddSeconds(10)
            Speak-NovaVoiceReply -Text '我在。'
            try { & $script:NovaVoiceOnStatus '已喚醒，請在 10 秒內說出指令。' } catch { }
        } else {
            try { & $script:NovaVoiceOnStatus '已忽略重複喚醒，避免誤執行。' } catch { }
        }
        return
    }
    if ($wakeMatch.Success) {
        $wakeOriginalMatch = [regex]::Match($heard, '^\s*[\s\p{P}\p{S}]*(嘿|黑|嗨|hey)[\s\p{P}\p{S}]*(n[\s\p{P}\p{S}]*o[\s\p{P}\p{S}]*v[\s\p{P}\p{S}]*a|諾瓦|挪瓦|諾娃|挪娃|諾哇|挪哇)\s*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $remainder = if ($wakeOriginalMatch.Success) { $heard.Substring($wakeOriginalMatch.Length).Trim() } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($remainder)) {
            $script:NovaWakeUntil = [datetime]::MinValue
            Invoke-NovaWhisperCommand -CommandText $remainder
            return
        }
        $script:NovaWakeUntil = (Get-Date).AddSeconds(10)
        Speak-NovaVoiceReply -Text '我在。'
        & $script:NovaVoiceOnStatus '已喚醒，請在 10 秒內說出指令。'
        return
    }
    if ((Get-Date) -le $script:NovaWakeUntil) {
        $script:NovaWakeUntil = [datetime]::MinValue
        Invoke-NovaWhisperCommand -CommandText $heard
        & $script:NovaVoiceOnStatus '持續監聽中，等待「嘿 NOVA」。'
    }
}

function Invoke-NovaWhisperMessage {
    param([object]$Message)
    if ($null -eq $Message) { return }
    $type = [string]$Message.type
    switch ($type) {
        'status' { & $script:NovaVoiceOnStatus ([string]$Message.message) }
        'ready' { & $script:NovaVoiceOnStatus ([string]$Message.message) }
        'speech_start' { & $script:NovaVoiceOnStatus '正在收音…' }
        'transcribing' { & $script:NovaVoiceOnStatus '正在辨識語音…' }
        'text' { Invoke-NovaWhisperHeard -Heard ([string]$Message.text) }
        'audio_status' { & $script:NovaVoiceOnStatus "音訊狀態：$([string]$Message.message)" }
        'error' {
            Add-NovaEvent -Kind 'voice_error' -Text '[REDACTED]' -Intent 'voice' -Target '' -Result ([string]$Message.message) -Source 'voice'
            & $script:NovaVoiceOnStatus ([string]$Message.message)
        }
    }
}

function Start-NovaWhisperVoice {
    param(
        [scriptblock]$OnText,
        [scriptblock]$OnStatus
    )
    if ($null -ne $script:NovaVoiceEngine) { return 'voice_already_running' }
    if ($null -ne $script:NovaWhisperProcess) {
        try { if (-not $script:NovaWhisperProcess.HasExited) { return 'voice_already_running' } } catch { }
    }
    $python = Get-NovaPythonPath
    $listener = Join-Path $PSScriptRoot 'whisper_listener.py'
    if ($null -eq $python) {
        & $OnStatus '語音啟動失敗：找不到 Python。請先安裝 Python 3.12 與 Whisper 套件。'
        return 'voice_failed'
    }
    if (-not (Test-Path -LiteralPath $listener -PathType Leaf)) {
        & $OnStatus '語音啟動失敗：找不到 whisper_listener.py。'
        return 'voice_failed'
    }
    try {
        Add-Type -AssemblyName System.Speech
        $script:NovaVoiceSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        try { $script:NovaVoiceSynth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet, [System.Speech.Synthesis.VoiceAge]::NotSet, 0, [Globalization.CultureInfo]::GetCultureInfo('zh-TW')) } catch { }
        $script:NovaVoiceOnText = $OnText
        $script:NovaVoiceOnStatus = $OnStatus
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $python
        $psi.Arguments = '"' + $listener + '"'
        $psi.WorkingDirectory = $PSScriptRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # Whisper reports status/text through the local API endpoint. Keeping
        # stdout out of PowerShell's asynchronous event system prevents a
        # worker callback from taking down the long-running backend.
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $psi.EnvironmentVariables['NOVA_VOICE_ENDPOINT'] = "http://127.0.0.1:$script:NovaListenPort/api/voice/event"
        $psi.EnvironmentVariables['HF_HUB_DISABLE_XET'] = '1'
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $script:NovaWhisperProcess = $process
        if (-not $process.Start()) { throw '無法啟動 Whisper Python 程序。' }
        & $OnStatus 'Whisper small 啟動中，正在載入模型與麥克風…'
        return 'voice_started'
    } catch {
        try { if ($null -ne $process) { $process.Dispose() } } catch { }
        $script:NovaWhisperProcess = $null
        if ($null -ne $script:NovaVoiceSynth) { $script:NovaVoiceSynth.Dispose(); $script:NovaVoiceSynth = $null }
        & $OnStatus "語音啟動失敗：$($_.Exception.Message)"
        return 'voice_failed'
    }
}

function Start-NovaVoice {
    param(
        [scriptblock]$OnText,
        [scriptblock]$OnStatus
    )
    return (Start-NovaWhisperVoice -OnText $OnText -OnStatus $OnStatus)
}

function Stop-NovaVoice {
    $commandProcess = $script:NovaVoiceCommandProcess
    $script:NovaVoiceCommandProcess = $null
    try {
        if ($null -ne $commandProcess -and -not $commandProcess.HasExited) { $commandProcess.Kill() }
        if ($null -ne $commandProcess) { $commandProcess.Dispose() }
    } catch { }
    $whisper = $script:NovaWhisperProcess
    $whisperOutputHandler = $script:NovaWhisperOutputHandler
    $whisperErrorHandler = $script:NovaWhisperErrorHandler
    $whisperExitedHandler = $script:NovaWhisperExitedHandler
    $script:NovaWhisperProcess = $null
    $script:NovaWhisperOutputHandler = $null
    $script:NovaWhisperErrorHandler = $null
    $script:NovaWhisperExitedHandler = $null
    try {
        if ($null -ne $whisper) {
            if ($null -ne $whisperOutputHandler) { $whisper.remove_OutputDataReceived($whisperOutputHandler) }
            if ($null -ne $whisperErrorHandler) { $whisper.remove_ErrorDataReceived($whisperErrorHandler) }
            if ($null -ne $whisperExitedHandler) { $whisper.remove_Exited($whisperExitedHandler) }
            if (-not $whisper.HasExited) { $whisper.Kill() }
            $whisper.Dispose()
        }
    } catch { }

    $engine = $script:NovaVoiceEngine
    $voiceSynth = $script:NovaVoiceSynth
    $replySynth = $script:NovaReplySynth
    $recognizedHandler = $script:NovaVoiceRecognizedHandler
    $completedHandler = $script:NovaVoiceCompletedHandler
    $rejectedHandler = $script:NovaVoiceRejectedHandler
    $detectedHandler = $script:NovaVoiceDetectedHandler
    $audioProblemHandler = $script:NovaVoiceAudioProblemHandler
    $script:NovaVoiceEngine = $null
    $script:NovaVoiceSynth = $null
    $script:NovaReplySynth = $null
    $script:NovaVoiceRecognizedHandler = $null
    $script:NovaVoiceCompletedHandler = $null
    $script:NovaVoiceRejectedHandler = $null
    $script:NovaVoiceDetectedHandler = $null
    $script:NovaVoiceAudioProblemHandler = $null
    $script:NovaWakeUntil = [datetime]::MinValue
    $script:NovaLastVoiceCommandKey = ''
    $script:NovaLastVoiceCommandAt = [datetime]::MinValue
    try {
        if ($null -ne $engine) {
            if ($null -ne $recognizedHandler) { $engine.remove_SpeechRecognized($recognizedHandler) }
            if ($null -ne $completedHandler) { $engine.remove_RecognizeCompleted($completedHandler) }
            if ($null -ne $rejectedHandler) { $engine.remove_SpeechRecognitionRejected($rejectedHandler) }
            if ($null -ne $detectedHandler) { $engine.remove_SpeechDetected($detectedHandler) }
            if ($null -ne $audioProblemHandler) { $engine.remove_AudioSignalProblemOccurred($audioProblemHandler) }
            try { $engine.RecognizeAsyncCancel() } catch { }
            $engine.Dispose()
        }
        if ($null -ne $voiceSynth) { $voiceSynth.SpeakAsyncCancelAll(); $voiceSynth.Dispose() }
        if ($null -ne $replySynth) { $replySynth.SpeakAsyncCancelAll(); $replySynth.Dispose() }
    } catch { }
}

function Add-NovaUiEvent {
    param(
        [string]$Type,
        [string]$Message = '',
        [string]$Source = 'backend'
    )
    $script:NovaUiEvents.Enqueue([pscustomobject]@{
        Type = $Type
        Message = [string]$Message
        Source = $Source
        Timestamp = (Get-Date).ToString('o')
    }) | Out-Null
}

function Read-NovaHttpBody {
    param([System.Net.HttpListenerRequest]$Request)
    # fetch() sends JSON as UTF-8. HttpListener may report an unspecified or
    # legacy ContentEncoding, which corrupts Chinese commands if trusted here.
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Send-NovaHttpResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [string]$Body
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentEncoding = [System.Text.Encoding]::UTF8
    $response.ContentLength64 = $bytes.Length
    $response.Headers['Access-Control-Allow-Origin'] = '*'
    $response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
    $response.Headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-NovaHttpJson {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode = 200,
        [object]$Value
    )
    Send-NovaHttpResponse -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function Start-NovaServer {
    param([int]$ListenPort = 24801)
    $script:NovaListenPort = $ListenPort
    $script:NovaServerMode = $true
    # Voice is always opt-in. Starting/restarting the backend must never open
    # the microphone until the user presses the voice button or calls the
    # explicit /api/voice/start endpoint.
    Stop-NovaVoice
    Initialize-NovaStore
    $listener = New-Object System.Net.HttpListener
    $prefix = "http://127.0.0.1:$ListenPort/"
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    } catch {
        throw "NOVA 後端無法啟動 $prefix：$($_.Exception.Message)"
    }
    Write-Output "NOVA backend listening on $prefix"
    $stopRequested = $false
    try {
        while ($listener.IsListening -and -not $stopRequested) {
            $context = $null
            try { $context = $listener.GetContext() } catch { if ($listener.IsListening) { throw }; break }
            try {
                $request = $context.Request
                $path = $request.Url.AbsolutePath
                $method = $request.HttpMethod.ToUpperInvariant()
                if ($method -eq 'OPTIONS') {
                    Send-NovaHttpResponse -Context $context -StatusCode 204 -ContentType 'text/plain' -Body ''
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/') {
                    $htmlPath = Join-Path $PSScriptRoot 'NOVA.html'
                    if (-not (Test-Path -LiteralPath $htmlPath -PathType Leaf)) { throw '找不到 NOVA.html 前端檔案。' }
                    Send-NovaHttpResponse -Context $context -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8)
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/status') {
                    $config = Get-NovaConfig
                    $ollamaAvailable = $false
                    try { $ollamaAvailable = Test-NovaOllama -Config $config } catch { }
                    Send-NovaHttpJson -Context $context -Value @{
                        ok = $true
                        voiceRunning = ($null -ne $script:NovaVoiceEngine -or ($null -ne $script:NovaWhisperProcess -and -not $script:NovaWhisperProcess.HasExited))
                        pendingWhitelist = (-not [string]::IsNullOrWhiteSpace($script:PendingWhitelistTarget))
                        pendingWhitelistTarget = [string]$script:PendingWhitelistTarget
                        model = [string]$config.Ollama.Model
                        ollamaAvailable = [bool]$ollamaAvailable
                        configPath = $script:ConfigPath
                        dataPath = $script:NovaRoot
                        memoryPath = $script:MemoryPath
                        security = @{
                            fileSearchConsentAsked = [bool]$config.Security.FileSearchConsentAsked
                            fileSearchConsent = if ($null -eq $config.Security.FileSearchConsent) { $null } else { [bool]$config.Security.FileSearchConsent }
                            passphraseConfigured = (-not [string]::IsNullOrWhiteSpace([string]$config.Security.PassphraseHash))
                        }
                    }
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/habits') {
                    Send-NovaHttpJson -Context $context -Value @{ ok = $true; report = (Get-HabitReport) }
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/memory') {
                    $memoryConfig = Get-NovaConfig
                    $memoryJson = Get-NovaMemoryJson -Config $memoryConfig
                    Send-NovaHttpJson -Context $context -Value @{ ok = $true; path = $script:MemoryPath; memory = ($memoryJson | ConvertFrom-Json) }
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/events') {
                    $limit = 50
                    try { $limit = [Math]::Max(1, [Math]::Min(200, [int]$request.QueryString['limit'])) } catch { }
                    Send-NovaHttpJson -Context $context -Value @{ ok = $true; events = @(Get-NovaEvents | Select-Object -Last $limit) }
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/voice/events') {
                    $items = New-Object System.Collections.Generic.List[object]
                    $item = $null
                    while ($script:NovaUiEvents.TryDequeue([ref]$item)) {
                        $items.Add($item) | Out-Null
                        $item = $null
                    }
                    Send-NovaHttpJson -Context $context -Value @{ ok = $true; items = @($items.ToArray()) }
                    continue
                }
                if ($method -eq 'POST') {
                    $payload = $null
                    $rawBody = Read-NovaHttpBody -Request $request
                    if (-not [string]::IsNullOrWhiteSpace($rawBody)) { $payload = $rawBody | ConvertFrom-Json }
                    if ($path -eq '/api/command') {
                        $textProperty = if ($null -ne $payload) { $payload.PSObject.Properties['text'] } else { $null }
                        $commandText = if ($null -ne $textProperty) { ([string]$textProperty.Value).Trim() } else { '' }
                        if ([string]::IsNullOrWhiteSpace($commandText)) {
                            Send-NovaHttpJson -Context $context -StatusCode 400 -Value @{ ok = $false; message = '指令不可為空。' }
                            continue
                        }
                        $source = 'text'
                        $sourceProperty = if ($null -ne $payload) { $payload.PSObject.Properties['source'] } else { $null }
                        if ($null -ne $sourceProperty -and [string]$sourceProperty.Value -eq 'voice') { $source = 'voice' }
                        Add-NovaUiEvent -Type 'user' -Message $commandText -Source $source
                        try { $reply = Invoke-NovaText -InputText $commandText -Source $source }
                        catch { $reply = "執行失敗：$($_.Exception.Message)" }
                        if ($source -eq 'text') { [void](Speak-NovaText -Text $reply) }
                        Add-NovaUiEvent -Type 'assistant' -Message ([string]$reply) -Source 'backend'
                        $commandStatus = if ([string]::IsNullOrWhiteSpace($script:PendingWhitelistTarget)) { '執行完成。' } else { '等待密語確認：請輸入或說出密語。' }
                        Add-NovaUiEvent -Type 'status' -Message $commandStatus -Source 'backend'
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true; reply = [string]$reply }
                        continue
                    }
                    if ($path -eq '/api/security/passphrase') {
                        $firstProperty = if ($null -ne $payload) { $payload.PSObject.Properties['first'] } else { $null }
                        $secondProperty = if ($null -ne $payload) { $payload.PSObject.Properties['second'] } else { $null }
                        $firstValue = if ($null -ne $firstProperty) { [string]$firstProperty.Value } else { '' }
                        $secondValue = if ($null -ne $secondProperty) { [string]$secondProperty.Value } else { '' }
                        $currentProperty = if ($null -ne $payload) { $payload.PSObject.Properties['current'] } else { $null }
                        $currentValue = if ($null -ne $currentProperty) { [string]$currentProperty.Value } else { '' }
                        $passphraseResult = Set-NovaPassphraseFromValues -Current $currentValue -First $firstValue -Second $secondValue
                        Add-NovaUiEvent -Type 'status' -Message $passphraseResult.Message -Source 'backend'
                        Send-NovaHttpJson -Context $context -Value $passphraseResult
                        continue
                    }
                    if ($path -eq '/api/security/passphrase/verify') {
                        $currentProperty = if ($null -ne $payload) { $payload.PSObject.Properties['current'] } else { $null }
                        $currentValue = if ($null -ne $currentProperty) { [string]$currentProperty.Value } else { '' }
                        $verifyConfig = Get-NovaConfig
                        $configured = -not [string]::IsNullOrWhiteSpace([string]$verifyConfig.Security.PassphraseHash)
                        $verified = (-not $configured) -or (Test-NovaPassphrase -Config $verifyConfig -Phrase $currentValue)
                        $verifyMessage = if ($verified) { '前次密語驗證成功，請輸入新的密語。' } else { '前次密語不正確，無法進入修改。' }
                        if (-not $verified) { Add-NovaUiEvent -Type 'status' -Message $verifyMessage -Source 'backend' }
                        Send-NovaHttpJson -Context $context -StatusCode $(if ($verified) { 200 } else { 401 }) -Value @{ ok = $verified; verified = $verified; message = $verifyMessage }
                        continue
                    }
                    if ($path -eq '/api/tts') {
                        $textProperty = if ($null -ne $payload) { $payload.PSObject.Properties['text'] } else { $null }
                        $speechText = if ($null -ne $textProperty) { [string]$textProperty.Value } else { '' }
                        if ([string]::IsNullOrWhiteSpace($speechText)) {
                            Send-NovaHttpJson -Context $context -StatusCode 400 -Value @{ ok = $false; message = '語音文字不可為空。' }
                            continue
                        }
                        $spoken = Speak-NovaText -Text $speechText
                        $speechMessage = if ($spoken) { '已開始語音播報。' } else { '語音播報初始化失敗。' }
                        Send-NovaHttpJson -Context $context -StatusCode $(if ($spoken) { 200 } else { 500 }) -Value @{ ok = $spoken; message = $speechMessage }
                        continue
                    }
                    if ($path -eq '/api/memory/export') {
                        $memoryConfig = Get-NovaConfig
                        $memory = Export-NovaMemory -Config $memoryConfig
                        $message = "長期記憶已匯出至 $script:MemoryPath。"
                        Add-NovaUiEvent -Type 'status' -Message $message -Source 'backend'
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true; path = $script:MemoryPath; memory = $memory; message = $message }
                        continue
                    }
                    if ($path -eq '/api/test/reset-memory') {
                        $codeProperty = if ($null -ne $payload) { $payload.PSObject.Properties['code'] } else { $null }
                        $resetCode = if ($null -ne $codeProperty) { [string]$codeProperty.Value } else { '' }
                        $resetResult = Reset-NovaMemoryData -Code $resetCode
                        $resetStatus = if ($resetResult.Ok) { 200 } else { 403 }
                        if ($resetResult.Ok) { Add-NovaUiEvent -Type 'status' -Message $resetResult.Message -Source 'backend' }
                        Send-NovaHttpJson -Context $context -StatusCode $resetStatus -Value $resetResult
                        continue
                    }
                    if ($path -eq '/api/security/file-search-consent') {
                        $allowedProperty = if ($null -ne $payload) { $payload.PSObject.Properties['allowed'] } else { $null }
                        $config = Get-NovaConfig
                        $config.Security.FileSearchConsentAsked = $true
                        $config.Security.FileSearchConsent = ($null -ne $allowedProperty -and [bool]$allowedProperty.Value)
                        Save-NovaConfig -Config $config
                        $message = if ([bool]$config.Security.FileSearchConsent) { '已允許本機檔案搜尋。' } else { '已拒絕本機檔案搜尋。' }
                        Add-NovaUiEvent -Type 'status' -Message $message -Source 'backend'
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true; message = $message }
                        continue
                    }
                    if ($path -eq '/api/voice/event') {
                        Invoke-NovaWhisperMessage -Message $payload
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true }
                        continue
                    }
                    if ($path -eq '/api/voice/result') {
                        $replyProperty = if ($null -ne $payload) { $payload.PSObject.Properties['reply'] } else { $null }
                        $commandProperty = if ($null -ne $payload) { $payload.PSObject.Properties['text'] } else { $null }
                        $reply = if ($null -ne $replyProperty) { [string]$replyProperty.Value } else { '' }
                        $command = if ($null -ne $commandProperty) { [string]$commandProperty.Value } else { '' }
                        if (-not [string]::IsNullOrWhiteSpace($reply)) {
                            Add-NovaUiEvent -Type 'assistant' -Message $reply -Source 'backend'
                            [void](Speak-NovaText -Text $reply)
                        }
                        $script:NovaVoiceCommandProcess = $null
                        $resultConfig = Get-NovaConfig
                        $resultStatus = if ([string]::IsNullOrWhiteSpace([string]$resultConfig.Security.PendingWhitelistTarget)) { '持續監聽中，等待「嘿 NOVA」。' } else { '等待密語確認：請輸入或說出密語。' }
                        Add-NovaUiEvent -Type 'status' -Message $resultStatus -Source 'voice'
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true; reply = $reply; command = $command }
                        continue
                    }
                    if ($path -eq '/api/voice/start') {
                        $onStatus = { param($message) Add-NovaUiEvent -Type 'status' -Message ([string]$message) -Source 'voice' }.GetNewClosure()
                        $onText = {
                            param($message)
                            $heard = ([string]$message).Trim()
                            if ([string]::IsNullOrWhiteSpace($heard)) { return '' }
                            Add-NovaUiEvent -Type 'user' -Message $heard -Source 'voice'
                            try { $answer = Invoke-NovaText -InputText $heard -Source 'voice' }
                            catch { $answer = "執行失敗：$($_.Exception.Message)" }
                            Add-NovaUiEvent -Type 'assistant' -Message ([string]$answer) -Source 'backend'
                            Add-NovaUiEvent -Type 'status' -Message '持續監聽中，等待「嘿 NOVA」。' -Source 'voice'
                            return [string]$answer
                        }.GetNewClosure()
                        $voiceResult = Start-NovaVoice -OnText $onText -OnStatus $onStatus
                        Send-NovaHttpJson -Context $context -Value @{ ok = ($voiceResult -eq 'voice_started' -or $voiceResult -eq 'voice_already_running'); result = $voiceResult }
                        continue
                    }
                    if ($path -eq '/api/voice/stop') {
                        Stop-NovaVoice
                        Add-NovaUiEvent -Type 'status' -Message '語音已停止。' -Source 'voice'
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true; result = 'voice_stopped' }
                        continue
                    }
                    if ($path -eq '/api/open-data') {
                        Start-Process explorer.exe $script:NovaRoot | Out-Null
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true; path = $script:NovaRoot }
                        continue
                    }
                    if ($path -eq '/api/shutdown') {
                        Stop-NovaVoice
                        Add-NovaUiEvent -Type 'status' -Message 'NOVA 後端已停止。' -Source 'backend'
                        $stopRequested = $true
                        Send-NovaHttpJson -Context $context -Value @{ ok = $true }
                        continue
                    }
                }
                Send-NovaHttpJson -Context $context -StatusCode 404 -Value @{ ok = $false; message = 'NOVA API 路徑不存在。' }
            } catch {
                try { Send-NovaHttpJson -Context $context -StatusCode 500 -Value @{ ok = $false; message = $_.Exception.Message } } catch { }
            } finally {
                try { $context.Response.OutputStream.Close() } catch { }
            }
        }
    } finally {
        Stop-NovaVoice
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
}

function Show-NovaWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'NOVA · 本機智慧助理'
    $form.Size = New-Object System.Drawing.Size(980, 700)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 560)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::FromArgb(18, 22, 32)
    $form.ForeColor = [System.Drawing.Color]::White

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'NOVA'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 24, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(92, 210, 255)
    $title.Location = New-Object System.Drawing.Point(28, 20)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = '本機優先 · 可控權限 · 逐步學習'
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(170, 182, 200)
    $subtitle.Location = New-Object System.Drawing.Point(32, 62)
    $subtitle.AutoSize = $true
    $form.Controls.Add($subtitle)

    $security = New-Object System.Windows.Forms.Button
    $security.Text = '設定密語'
    $security.Location = New-Object System.Drawing.Point(700, 28)
    $security.Size = New-Object System.Drawing.Size(120, 32)
    $security.BackColor = [System.Drawing.Color]::FromArgb(61, 72, 92)
    $security.ForeColor = [System.Drawing.Color]::White
    $security.FlatStyle = 'Flat'
    $form.Controls.Add($security)

    $chat = New-Object System.Windows.Forms.RichTextBox
    $chat.Location = New-Object System.Drawing.Point(28, 100)
    $chat.Size = New-Object System.Drawing.Size(650, 475)
    $chat.Anchor = 'Top,Bottom,Left,Right'
    $chat.Multiline = $true
    $chat.ReadOnly = $true
    $chat.ScrollBars = 'Vertical'
    $chat.WordWrap = $true
    $chat.HideSelection = $false
    $chat.BackColor = [System.Drawing.Color]::FromArgb(28, 34, 47)
    $chat.ForeColor = [System.Drawing.Color]::FromArgb(232, 237, 245)
    $chat.BorderStyle = 'None'
    $chat.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 11)
    $form.Controls.Add($chat)

    $side = New-Object System.Windows.Forms.Panel
    $side.Location = New-Object System.Drawing.Point(700, 100)
    $side.Size = New-Object System.Drawing.Size(245, 475)
    $side.Anchor = 'Top,Bottom,Right'
    $side.BackColor = [System.Drawing.Color]::FromArgb(24, 29, 41)
    $form.Controls.Add($side)

    $cubePanel = New-Object System.Windows.Forms.Panel
    $cubePanel.Location = New-Object System.Drawing.Point(18, 52)
    $cubePanel.Size = New-Object System.Drawing.Size(208, 160)
    $cubePanel.BackColor = [System.Drawing.Color]::FromArgb(18, 24, 37)
    $side.Controls.Add($cubePanel)

    $cubePanel.Add_Paint({
        param($sender, $paintArgs)
        $g = $paintArgs.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($sender.BackColor)
        $cx = $sender.ClientSize.Width / 2.0
        $cy = $sender.ClientSize.Height / 2.0
        $vertices = @(
            @(-1, -1, -1), @(1, -1, -1), @(1, 1, -1), @(-1, 1, -1),
            @(-1, -1, 1), @(1, -1, 1), @(1, 1, 1), @(-1, 1, 1)
        )
        $edges = @(
            @(0,1), @(1,2), @(2,3), @(3,0), @(4,5), @(5,6), @(6,7), @(7,4),
            @(0,4), @(1,5), @(2,6), @(3,7)
        )
        $projected = New-Object 'System.Drawing.PointF[]' 8
        $angleY = $script:NovaCubeAngle
        $angleX = $script:NovaCubeAngle * 0.63
        $sinY = [math]::Sin($angleY); $cosY = [math]::Cos($angleY)
        $sinX = [math]::Sin($angleX); $cosX = [math]::Cos($angleX)
        for ($i = 0; $i -lt $vertices.Count; $i++) {
            $x = [double]$vertices[$i][0]; $y = [double]$vertices[$i][1]; $z = [double]$vertices[$i][2]
            $rx = ($x * $cosY) - ($z * $sinY)
            $rz = ($x * $sinY) + ($z * $cosY)
            $ry = ($y * $cosX) - ($rz * $sinX)
            $rz2 = ($y * $sinX) + ($rz * $cosX)
            $scale = 54.0 / (3.8 + $rz2)
            $projected[$i] = New-Object System.Drawing.PointF([single]($cx + ($rx * $scale)), [single]($cy + ($ry * $scale)))
        }
        $color = if ($script:NovaCubeListening) { [System.Drawing.Color]::FromArgb(255, 184, 92) } else { [System.Drawing.Color]::FromArgb(92, 210, 255) }
        $pen = New-Object System.Drawing.Pen($color, 2.0)
        try {
            foreach ($edge in $edges) { $g.DrawLine($pen, $projected[$edge[0]], $projected[$edge[1]]) }
        } finally { $pen.Dispose() }
        $brush = New-Object System.Drawing.SolidBrush($color)
        try { $g.DrawString('NOVA', (New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)), $brush, 8, 8) } finally { $brush.Dispose() }
    })

    $script:NovaCubeAngle = 0.0
    $script:NovaCubeTimer = New-Object System.Windows.Forms.Timer
    $script:NovaCubeTimer.Interval = 33
    $script:NovaCubeTimer.Add_Tick({
        $script:NovaCubeAngle += 0.045
        $cubePanel.Invalidate()
    }.GetNewClosure())
    $script:NovaCubeTimer.Start()

    $sideTitle = New-Object System.Windows.Forms.Label
    $sideTitle.Text = '習慣觀察'
    $sideTitle.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $sideTitle.Location = New-Object System.Drawing.Point(18, 18)
    $sideTitle.AutoSize = $true
    $side.Controls.Add($sideTitle)

    $habit = New-Object System.Windows.Forms.TextBox
    $habit.Multiline = $true
    $habit.ReadOnly = $true
    $habit.ScrollBars = 'Vertical'
    $habit.Location = New-Object System.Drawing.Point(18, 220)
    $habit.Size = New-Object System.Drawing.Size(208, 135)
    $habit.BackColor = [System.Drawing.Color]::FromArgb(34, 40, 54)
    $habit.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 234)
    $habit.BorderStyle = 'None'
    $side.Controls.Add($habit)

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = '重新分析習慣'
    $refresh.Location = New-Object System.Drawing.Point(18, 365)
    $refresh.Size = New-Object System.Drawing.Size(208, 36)
    $refresh.FlatStyle = 'Flat'
    $refresh.ForeColor = [System.Drawing.Color]::White
    $refresh.BackColor = [System.Drawing.Color]::FromArgb(46, 88, 116)
    $side.Controls.Add($refresh)

    $openData = New-Object System.Windows.Forms.Button
    $openData.Text = '開啟本機資料夾'
    $openData.Location = New-Object System.Drawing.Point(18, 410)
    $openData.Size = New-Object System.Drawing.Size(208, 36)
    $openData.FlatStyle = 'Flat'
    $openData.ForeColor = [System.Drawing.Color]::White
    $openData.BackColor = [System.Drawing.Color]::FromArgb(56, 61, 77)
    $side.Controls.Add($openData)

    # Avoid the automatic PowerShell $input variable: event-handler closures can
    # resolve it as the pipeline enumerator instead of this TextBox control.
    $commandInput = New-Object System.Windows.Forms.TextBox
    $commandInput.Location = New-Object System.Drawing.Point(28, 600)
    $commandInput.Size = New-Object System.Drawing.Size(650, 34)
    $commandInput.Anchor = 'Bottom,Left,Right'
    $commandInput.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 11)
    $commandInput.BackColor = [System.Drawing.Color]::FromArgb(37, 44, 59)
    $commandInput.ForeColor = [System.Drawing.Color]::White
    $commandInput.BorderStyle = 'FixedSingle'
    $form.Controls.Add($commandInput)

    $send = New-Object System.Windows.Forms.Button
    $send.Text = '送出'
    $send.Location = New-Object System.Drawing.Point(700, 598)
    $send.Size = New-Object System.Drawing.Size(110, 38)
    $send.Anchor = 'Bottom,Right'
    $send.BackColor = [System.Drawing.Color]::FromArgb(47, 139, 164)
    $send.ForeColor = [System.Drawing.Color]::White
    $send.FlatStyle = 'Flat'
    $form.Controls.Add($send)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = "資料位置：$script:NovaRoot"
    $status.Location = New-Object System.Drawing.Point(28, 650)
    $status.Anchor = 'Bottom,Left'
    $status.ForeColor = [System.Drawing.Color]::FromArgb(130, 145, 165)
    $status.AutoSize = $true
    $form.Controls.Add($status)

    $voice = New-Object System.Windows.Forms.Button
    $voice.Text = '啟動語音'
    $voice.Location = New-Object System.Drawing.Point(830, 598)
    $voice.Size = New-Object System.Drawing.Size(115, 38)
    $voice.Anchor = 'Bottom,Right'
    $voice.BackColor = [System.Drawing.Color]::FromArgb(86, 67, 126)
    $voice.ForeColor = [System.Drawing.Color]::White
    $voice.FlatStyle = 'Flat'
    $form.Controls.Add($voice)

    $addChatLine = {
        param([string]$Speaker, [string]$Message)
        $chat.AppendText("[$Speaker] $Message`r`n`r`n")
        $chat.SelectionStart = $chat.TextLength
        $chat.ScrollToCaret()
    }.GetNewClosure()
    $refreshHabits = {
        $habit.Text = Get-HabitReport
    }.GetNewClosure()
    $setUiStatus = {
        param([string]$Message)
        if ($form.IsHandleCreated) {
            $action = [System.Action]{
                if ($Message -match '(已喚醒|辨識到：)') {
                    $script:NovaCubeListening = $true
                    if ($null -ne $script:NovaCubeTimer) { $script:NovaCubeTimer.Stop() }
                } elseif ($Message -match '(持續監聽中|語音已啟動|語音已停止)') {
                    $script:NovaCubeListening = $false
                    if ($null -ne $script:NovaCubeTimer -and $null -ne $script:NovaVoiceEngine) { $script:NovaCubeTimer.Start() }
                }
                $status.Text = $Message
                $cubePanel.Invalidate()
            }.GetNewClosure()
            try { $form.BeginInvoke($action) | Out-Null } catch { }
        }
    }.GetNewClosure()
    $addVoiceChat = {
        param([string]$Message)
        if ($form.IsHandleCreated) {
            $action = [System.Action]{
                $chat.AppendText("[語音] $Message`r`n`r`n")
                $chat.SelectionStart = $chat.TextLength
                $chat.ScrollToCaret()
                & $refreshHabits
            }.GetNewClosure()
            try { $form.BeginInvoke($action) | Out-Null } catch { }
        }
    }.GetNewClosure()
    $sendCurrentText = {
        $value = ([string]$commandInput.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return }
        $commandInput.Clear()
        & $addChatLine '你' $value
        try { $reply = Invoke-NovaText -InputText $value; & $addChatLine 'NOVA' $reply }
        catch { & $addChatLine 'NOVA' "發生錯誤：$($_.Exception.Message)" }
        & $refreshHabits
    }.GetNewClosure()
    $send.Add_Click({ & $sendCurrentText }.GetNewClosure())
    $commandInput.Add_KeyDown({ param($sender, $e); if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; & $sendCurrentText } }.GetNewClosure())
    $refresh.Add_Click({ & $refreshHabits }.GetNewClosure())
    $openData.Add_Click({ Start-Process explorer.exe $script:NovaRoot }.GetNewClosure())
    $security.Add_Click({
        try { & $setUiStatus (Set-NovaPassphraseInteractive) }
        catch { & $addChatLine 'NOVA' "密語設定失敗：$($_.Exception.Message)" }
    }.GetNewClosure())
    $voice.Add_Click({
        if ($null -eq $script:NovaVoiceEngine) {
            $voice.Text = '停止語音'
            $voice.BackColor = [System.Drawing.Color]::FromArgb(150, 73, 83)
            Start-NovaVoice -OnStatus { param($m) & $setUiStatus $m }.GetNewClosure() -OnText {
                param($m)
                & $addVoiceChat "你：$m"
                $reply = Invoke-NovaText -InputText $m -Source 'voice'
                & $addVoiceChat "NOVA：$reply"
                return $reply
            }.GetNewClosure() | Out-Null
        } else {
            Stop-NovaVoice
            $voice.Text = '啟動語音'
            $voice.BackColor = [System.Drawing.Color]::FromArgb(86, 67, 126)
            & $setUiStatus "語音已停止。資料位置：$script:NovaRoot"
        }
    }.GetNewClosure())
    $form.Add_FormClosing({ Stop-NovaVoice; if ($null -ne $script:NovaCubeTimer) { $script:NovaCubeTimer.Stop(); $script:NovaCubeTimer.Dispose() } }.GetNewClosure())

    Ensure-NovaFileSearchConsent -Owner $form
    & $addChatLine 'NOVA' "準備完成。資料只保存在本機。輸入「幫助」開始。"
    & $refreshHabits
    [void]$form.ShowDialog()
}

Initialize-NovaStore
if ($VoiceWorker) {
    $workerReply = ''
    try { $workerReply = [string](Invoke-NovaText -InputText $Text -Source $Source) }
    catch { $workerReply = "執行失敗：$($_.Exception.Message)" }
    if ($CallbackPort -gt 0) {
        try {
            $callbackBody = @{
                type = 'command_result'
                text = [string]$Text
                reply = $workerReply
                source = [string]$Source
            } | ConvertTo-Json -Depth 8 -Compress
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$CallbackPort/api/voice/result" -ContentType 'application/json; charset=utf-8' -Body $callbackBody -TimeoutSec 5 | Out-Null
        } catch { }
    }
} elseif ($Cli) {
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = Read-Host 'NOVA' }
    Write-Output (Invoke-NovaText -InputText $Text)
} else {
    Start-NovaServer -ListenPort $Port
}
