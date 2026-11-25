$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = if ($env:LOCAL_RUNNER_BASE_URL) { $env:LOCAL_RUNNER_BASE_URL } else { 'https://raw.githubusercontent.com/suminwell/github-runner/main' }
$setup = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName() + '.ps1')
try {
    if ($env:LOCAL_RUNNER_SOURCE_DIR) {
        Copy-Item -LiteralPath (Join-Path $env:LOCAL_RUNNER_SOURCE_DIR 'windows/install.ps1') -Destination $setup
    } else {
        Invoke-WebRequest -UseBasicParsing "$base/windows/install.ps1" -OutFile $setup
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Architecture arm64
    if ($LASTEXITCODE -ne 0) { throw 'Installation failed.' }
} finally {
    if (Test-Path -LiteralPath $setup) { Remove-Item -LiteralPath $setup }
}
