$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms

$appRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$serverFile = Join-Path $appRoot 'server.py'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'KEIVO'
$stateFile = Join-Path $stateRoot 'keivo-state.json'

function Show-StopMessage {
    param([string]$Text, [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information)
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'KEIVO', [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}

try {
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        Show-StopMessage 'KEIVO is already stopped.'
        exit 0
    }

    $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
    $process = Get-Process -Id ([int]$state.processId) -ErrorAction Stop
    $expectedExecutable = [IO.Path]::GetFullPath([string]$state.executable)
    if (-not [string]::Equals($process.Path, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The saved process is not KEIVO. Nothing was stopped.'
    }
    if ($process.StartTime.ToUniversalTime().Ticks -ne [Int64]$state.startTimeUtcTicks) {
        throw 'The saved process is not KEIVO. Nothing was stopped.'
    }

    Stop-Process -Id $process.Id -Force -ErrorAction Stop
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    Show-StopMessage 'KEIVO has stopped. Ollama was left running for your other local apps.'
}
catch {
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    Show-StopMessage $_.Exception.Message ([System.Windows.Forms.MessageBoxIcon]::Warning)
    exit 1
}

exit 0
