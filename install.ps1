param([ValidateSet('auto','x64','arm64')][string]$Architecture = 'auto')
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'On Linux/macOS, run install.sh.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$previousSource = $env:LOCAL_RUNNER_SOURCE_DIR
try {
    if (-not $env:LOCAL_RUNNER_SOURCE_DIR -and -not $env:LOCAL_RUNNER_BASE_URL -and $PSScriptRoot) {
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'windows\install.ps1')) { $env:LOCAL_RUNNER_SOURCE_DIR = $PSScriptRoot }
    }
    if ($env:LOCAL_RUNNER_SOURCE_DIR) {
        $env:LOCAL_RUNNER_SOURCE_DIR = (Resolve-Path -LiteralPath $env:LOCAL_RUNNER_SOURCE_DIR).Path
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $env:LOCAL_RUNNER_SOURCE_DIR 'windows\install.ps1')
    } else {
        $base = if ($env:LOCAL_RUNNER_BASE_URL) { $env:LOCAL_RUNNER_BASE_URL.TrimEnd('/') } else { 'https://raw.githubusercontent.com/suminwell/github-runner/main' }
        $content = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 "$base/windows/install.ps1").Content
    }
    # A script block also works with irm ... | iex under Restricted execution policy.
    & ([scriptblock]::Create($content)) -Architecture $Architecture
} finally {
    $env:LOCAL_RUNNER_SOURCE_DIR = $previousSource
}
