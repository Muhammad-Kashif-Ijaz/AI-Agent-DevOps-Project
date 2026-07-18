[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8000,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms

$appRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$venvRoot = Join-Path $appRoot '.venv'
$venvPython = Join-Path $venvRoot 'Scripts\python.exe'
$venvPythonw = Join-Path $venvRoot 'Scripts\pythonw.exe'
$requirementsFile = Join-Path $appRoot 'requirements.txt'
$requirementsMarker = Join-Path $venvRoot '.requirements.sha256'
$serverFile = Join-Path $appRoot 'server.py'
$envFile = Join-Path $appRoot '.env'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'KEIVO'
$stateFile = Join-Path $stateRoot 'keivo-state.json'
$legacyPidFile = Join-Path $appRoot '.keivo.pid'
$stdoutLog = Join-Path $stateRoot 'keivo-server.log'
$stderrLog = Join-Path $stateRoot 'keivo-server-error.log'

function Show-KeivoMessage {
    param(
        [string]$Text,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )
    [void][System.Windows.Forms.MessageBox]::Show(
        $Text,
        'KEIVO',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    )
}

function New-KeivoProgressWindow {
    param([string]$Model)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'KEIVO'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(430, 142)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Preparing local intelligence'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $form.Controls.Add($title)

    $detail = New-Object System.Windows.Forms.Label
    $detail.Text = "Downloading $Model once. This can take several minutes."
    $detail.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $detail.AutoSize = $true
    $detail.Location = New-Object System.Drawing.Point(26, 54)
    $form.Controls.Add($detail)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progress.MarqueeAnimationSpeed = 28
    $progress.Location = New-Object System.Drawing.Point(28, 91)
    $progress.Size = New-Object System.Drawing.Size(374, 12)
    $form.Controls.Add($progress)

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return $form
}

function Get-DotEnvValue {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($envFile)) {
        if ($line -match ('^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*?)\s*$')) {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Resolve-BootstrapPython {
    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($null -ne $py) { return @($py.Source, '-3') }
    $python = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($null -ne $python) { return @($python.Source) }
    throw 'Python 3.11 or newer is required. Install it from https://www.python.org/downloads/ and start KEIVO again.'
}

function Resolve-Ollama {
    $command = Get-Command 'ollama.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-Ollama {
    param([string]$BaseUrl)
    try {
        $null = Invoke-RestMethod -Uri ($BaseUrl + '/api/tags') -Method Get -TimeoutSec 2
        return $true
    }
    catch { return $false }
}

function Test-OllamaModel {
    param([string]$BaseUrl, [string]$Model)
    try {
        $response = Invoke-RestMethod -Uri ($BaseUrl + '/api/tags') -Method Get -TimeoutSec 5
        foreach ($entry in @($response.models)) {
            $name = if ($null -ne $entry.model) { [string]$entry.model } else { [string]$entry.name }
            if ($name -eq $Model -or $name -eq ($Model + ':latest')) { return $true }
        }
    }
    catch { }
    return $false
}

function Test-KeivoApi {
    param([int]$ApiPort)
    try {
        $response = Invoke-RestMethod -Uri ("http://127.0.0.1:$ApiPort/api/status") -Method Get -TimeoutSec 2
        return $null -ne $response.configured
    }
    catch { return $false }
}

function Read-KeivoState {
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($stateFile) | ConvertFrom-Json) }
    catch { return $null }
}

function Get-KeivoProcess {
    param($State)
    if ($null -eq $State) { return $null }
    try {
        $process = Get-Process -Id ([int]$State.processId) -ErrorAction Stop
        $expectedExecutable = [IO.Path]::GetFullPath([string]$State.executable)
        if (-not [string]::Equals($process.Path, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $expectedStart = [Int64]$State.startTimeUtcTicks
        if ($process.StartTime.ToUniversalTime().Ticks -ne $expectedStart) { return $null }
        return $process
    }
    catch { return $null }
}

function Get-LegacyKeivoProcess {
    if (-not (Test-Path -LiteralPath $legacyPidFile -PathType Leaf)) { return $null }
    try {
        $legacyId = [int]([IO.File]::ReadAllText($legacyPidFile).Trim())
        $process = Get-Process -Id $legacyId -ErrorAction Stop
        $allowedExecutables = @($venvPython, $venvPythonw) | ForEach-Object { [IO.Path]::GetFullPath($_) }
        if (-not ($allowedExecutables | Where-Object { [string]::Equals($_, $process.Path, [StringComparison]::OrdinalIgnoreCase) })) { return $null }
        $home = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 2
        if ($home.StatusCode -ne 200 -or $home.Content.IndexOf('KEIVO', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $null }
        return $process
    }
    catch { return $null }
}

$createdNew = $false
$launchMutex = [Threading.Mutex]::new($true, 'Local\KEIVO-Launcher', [ref]$createdNew)
if (-not $createdNew) {
    Show-KeivoMessage 'KEIVO is already starting. Its browser window will open automatically.'
    exit 0
}

try {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    Set-Location -LiteralPath $appRoot

    $state = Read-KeivoState
    $managedProcess = Get-KeivoProcess $state
    if ($null -ne $managedProcess) {
        $runningPort = [int]$state.port
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            if (Test-KeivoApi $runningPort) {
                if (-not $NoBrowser) { Start-Process ("http://127.0.0.1:$runningPort") }
                exit 0
            }
            if ($managedProcess.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
        Show-KeivoMessage 'KEIVO is still starting. Wait a moment, then open it again.'
        exit 0
    }
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }

    $legacyProcess = Get-LegacyKeivoProcess
    if ($null -ne $legacyProcess) {
        Stop-Process -Id $legacyProcess.Id -Force -ErrorAction Stop
        Remove-Item -LiteralPath $legacyPidFile -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }

    if (-not (Test-Path -LiteralPath $requirementsFile -PathType Leaf) -or -not (Test-Path -LiteralPath $serverFile -PathType Leaf)) {
        throw 'The KEIVO installation is incomplete. Keep all project files together and try again.'
    }

    $baseUrl = [Environment]::GetEnvironmentVariable('OLLAMA_BASE_URL', 'Process')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = Get-DotEnvValue 'OLLAMA_BASE_URL' }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = 'http://127.0.0.1:11434' }
    $baseUrl = $baseUrl.TrimEnd('/')

    $model = [Environment]::GetEnvironmentVariable('OLLAMA_MODEL', 'Process')
    if ([string]::IsNullOrWhiteSpace($model)) { $model = Get-DotEnvValue 'OLLAMA_MODEL' }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'qwen3:8b' }
    if ($model -notmatch '^[A-Za-z0-9._/-]+(?::[A-Za-z0-9._-]+)?$') { throw 'OLLAMA_MODEL contains unsupported characters.' }

    $env:OLLAMA_BASE_URL = $baseUrl
    $env:OLLAMA_MODEL = $model
    $ollamaUri = [Uri]$baseUrl
    $localOllama = $ollamaUri.Host -in @('127.0.0.1', 'localhost', '::1')
    $ollamaExecutable = Resolve-Ollama

    if (-not (Test-Ollama $baseUrl)) {
        if (-not $localOllama -or [string]::IsNullOrWhiteSpace($ollamaExecutable)) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "Ollama is required but was not found.`n`nInstall it, then double-click START-KEIVO again.`n`nOpen the Ollama download page now?",
                'KEIVO',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process 'https://ollama.com/download/windows' }
            exit 1
        }
        Start-Process -FilePath $ollamaExecutable -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
        for ($attempt = 0; $attempt -lt 60 -and -not (Test-Ollama $baseUrl); $attempt++) {
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Ollama $baseUrl)) { throw 'Ollama could not start. Open Ollama once, then start KEIVO again.' }
    }

    if (-not (Test-OllamaModel $baseUrl $model)) {
        $progressWindow = New-KeivoProgressWindow $model
        try {
            if ($localOllama -and -not [string]::IsNullOrWhiteSpace($ollamaExecutable) -and $baseUrl -eq 'http://127.0.0.1:11434') {
                $pullOutput = Join-Path $stateRoot 'ollama-pull.log'
                $pullError = Join-Path $stateRoot 'ollama-pull-error.log'
                $pullProcess = Start-Process -FilePath $ollamaExecutable -ArgumentList @('pull', $model) -WindowStyle Hidden -RedirectStandardOutput $pullOutput -RedirectStandardError $pullError -PassThru
                while (-not $pullProcess.HasExited) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 120
                }
                if ($pullProcess.ExitCode -ne 0) { throw 'Ollama could not download the model.' }
            }
            else {
                $payload = @{ model = $model; stream = $false } | ConvertTo-Json -Compress
                $null = Invoke-RestMethod -Uri ($baseUrl + '/api/pull') -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 7200
            }
        }
        catch { throw 'The local model could not be downloaded. Check your connection and available disk space, then start KEIVO again.' }
        finally {
            $progressWindow.Close()
            $progressWindow.Dispose()
        }
        if (-not (Test-OllamaModel $baseUrl $model)) { throw "Ollama did not make $model available after download." }
    }

    $needsPythonSetup = -not (Test-Path -LiteralPath $venvPython -PathType Leaf)
    if ($needsPythonSetup) {
        Show-KeivoMessage 'KEIVO is completing its one-time local setup. The browser will open automatically when it is ready.'
        $bootstrap = @(Resolve-BootstrapPython)
        $pythonCommand = $bootstrap[0]
        $pythonPrefix = if ($bootstrap.Count -gt 1) { @($bootstrap[1..($bootstrap.Count - 1)]) } else { @() }
        & $pythonCommand @pythonPrefix -m venv $venvRoot
        if ($LASTEXITCODE -ne 0) { throw 'Python could not create the private KEIVO environment.' }
    }

    $requirementsHash = (Get-FileHash -LiteralPath $requirementsFile -Algorithm SHA256).Hash
    $installedHash = if (Test-Path -LiteralPath $requirementsMarker) { [IO.File]::ReadAllText($requirementsMarker).Trim() } else { '' }
    if ($requirementsHash -ne $installedHash) {
        & $venvPython -m pip install --disable-pip-version-check --default-timeout 180 --retries 5 --requirement $requirementsFile
        if ($LASTEXITCODE -ne 0) { throw 'KEIVO components could not be installed. Check your internet connection and try again.' }
        [IO.File]::WriteAllText($requirementsMarker, $requirementsHash, [Text.UTF8Encoding]::new($false))
    }

    $serverExecutable = if (Test-Path -LiteralPath $venvPythonw -PathType Leaf) { $venvPythonw } else { $venvPython }
    $serverArguments = @('"' + $serverFile + '"', '--host', '127.0.0.1', '--port', $Port.ToString(), '--no-open')
    $serverProcess = Start-Process -FilePath $serverExecutable -ArgumentList $serverArguments -WorkingDirectory $appRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
    $stateData = [ordered]@{
        processId = $serverProcess.Id
        port = $Port
        executable = $serverExecutable
        server = $serverFile
        startTimeUtcTicks = $serverProcess.StartTime.ToUniversalTime().Ticks
    }
    [IO.File]::WriteAllText($stateFile, ($stateData | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if (Test-KeivoApi $Port) {
            if (-not $NoBrowser) { Start-Process ("http://127.0.0.1:$Port") }
            exit 0
        }
        if ($serverProcess.HasExited) { throw 'KEIVO could not start. See the KEIVO logs in your local application-data folder.' }
        Start-Sleep -Milliseconds 250
    }
    throw 'KEIVO took too long to start. Try opening it again.'
}
catch {
    Show-KeivoMessage $_.Exception.Message ([System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
finally {
    if ($createdNew) {
        try { $launchMutex.ReleaseMutex() } catch { }
    }
    $launchMutex.Dispose()
}
