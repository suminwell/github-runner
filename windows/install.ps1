param([ValidateSet('auto','x64','arm64')][string]$Architecture = 'auto')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Use an Administrator PowerShell window.' }
$nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($nativeArch) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { throw 'Windows x64 or ARM64 is required.' } }
if ($Architecture -ne 'auto' -and $Architecture -ne $arch) { throw "Architecture mismatch: requested $Architecture, host $arch" }
$base = if ($env:LOCAL_RUNNER_BASE_URL) { $env:LOCAL_RUNNER_BASE_URL } else { 'https://raw.githubusercontent.com/suminwell/github-runner/main' }
$installHome = if ($env:LOCAL_RUNNER_HOME) { $env:LOCAL_RUNNER_HOME } else { Join-Path $env:ProgramData 'local-github-runner' }
$installRoot = Join-Path (Join-Path $installHome 'windows') $arch
$bin = Join-Path $installRoot 'bin'; $state = Join-Path $installRoot '.state'; $taskName = "LocalGitHubRunner-$arch"
New-Item -ItemType Directory -Force -Path $bin, $state, (Join-Path $state 'tools'), (Join-Path $installRoot 'logs') | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544',$identity.User.Value)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
$rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-19')), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $installRoot -AclObject $acl
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.Actions.Arguments -notlike ('*' + (Join-Path $bin 'service.ps1') + '*')) { throw 'Another installation owns this task name.' }
    Stop-ScheduledTask -TaskName $taskName
}
# Upgrade the previous native service only when it belongs to this installation.
$oldService = Get-CimInstance Win32_Service -Filter "Name='$taskName'"
if ($oldService) {
    if ($oldService.PathName.Trim('"') -ne (Join-Path $bin 'LocalGitHubRunner.exe')) { throw 'Another installation owns this service name.' }
    Stop-Service -Name $taskName
    & sc.exe delete $taskName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove the previous service host.' }
}
function Get-SourceFile([string]$Source, [string]$Destination) {
    if ($env:LOCAL_RUNNER_SOURCE_DIR) { Copy-Item -LiteralPath (Join-Path $env:LOCAL_RUNNER_SOURCE_DIR $Source) -Destination "$Destination.new" -Force }
    else { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 "$base/$Source" -OutFile "$Destination.new" }
    Move-Item -LiteralPath "$Destination.new" -Destination $Destination -Force
}
$ghPath = Join-Path $state 'tools\gh.exe'
$existing = Get-Command gh -ErrorAction SilentlyContinue
$usable = $false
if ($existing) {
    $versionText = (& $existing.Source --version | Select-Object -First 1)
    if ($versionText -match 'gh version (\d+\.\d+\.\d+)') { $usable = [version]$Matches[1] -ge [version]'2.62.0' }
}
if ($usable) {
    if ($existing.Source -ne $ghPath) { Copy-Item -LiteralPath $existing.Source -Destination $ghPath -Force }
} else {
    $release = Invoke-RestMethod -TimeoutSec 120 https://api.github.com/repos/cli/cli/releases/latest
    $cliArch = if ($arch -eq 'x64') { 'amd64' } else { 'arm64' }
    $assetName = "gh_$($release.tag_name.TrimStart('v'))_windows_$cliArch.zip"
    $asset = @($release.assets | Where-Object name -eq $assetName)[0]
    if ($asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Missing gh asset digest.' }
    $temporary = Join-Path $state ('gh-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $archive = Join-Path $temporary 'gh.zip'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 $asset.browser_download_url -OutFile $archive
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.digest.Substring(7).ToLowerInvariant()) { throw 'gh SHA-256 mismatch.' }
        Expand-Archive $archive (Join-Path $temporary 'unpacked')
        $downloaded = Get-ChildItem (Join-Path $temporary 'unpacked') -Recurse -Filter gh.exe | Select-Object -First 1
        Copy-Item $downloaded.FullName $ghPath -Force
    } finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
& $ghPath auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    & $ghPath auth login --hostname github.com --web --scopes admin:org,repo
    if ($LASTEXITCODE -ne 0) { throw 'GitHub login failed.' }
}
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { & $ghPath auth token --hostname github.com }
if (-not $token) { throw 'No GitHub credential available.' }
[IO.File]::WriteAllText((Join-Path $state 'github-token'), $token.Trim(), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $state 'gh-path'), $ghPath, (New-Object Text.UTF8Encoding($false)))
$settingsPath = Join-Path $state 'settings.json'
$settings = @{}
if (Test-Path $settingsPath) {
    $previous = Get-Content -Raw $settingsPath | ConvertFrom-Json
    foreach ($property in $previous.PSObject.Properties) { $settings[$property.Name] = $property.Value }
}
$settings.platform = 'windows'; $settings.arch = $arch; $settings.gh = $ghPath; $settings.Remove('python')
if (-not $settings.ContainsKey('poll_seconds')) { $settings.poll_seconds = 300 }
if (-not $settings.ContainsKey('restart_seconds')) { $settings.restart_seconds = 30 }
if (-not $settings.ContainsKey('organizations')) { $settings.organizations = @() }
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
Get-SourceFile "windows/$arch/bin/install.ps1" (Join-Path $bin 'install.ps1')
Get-SourceFile "windows/$arch/bin/service.ps1" (Join-Path $bin 'service.ps1')
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'service.ps1') -Mode Prepare
if ($LASTEXITCODE -ne 0) { throw 'Runner preparation failed.' }
$action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bin\service.ps1`"" -WorkingDirectory $installRoot
$boot = New-ScheduledTaskTrigger -AtStartup
# Indefinite repetition also recovers clean exits; IgnoreNew keeps only one manager.
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$localService = (New-Object Security.Principal.SecurityIdentifier('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $localService -LogonType ServiceAccount
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($boot,$watchdog) -Settings $taskSettings -Principal $taskPrincipal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
foreach ($old in @('manager.py','windows-service.cs','LocalGitHubRunner.exe')) { Remove-Item (Join-Path $bin $old) -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $state 'python') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Installed $taskName in $installRoot"
Write-Host "Task: Get-ScheduledTask '$taskName'"
Write-Host "Runner status: & '$bin\service.ps1' -Mode Status"
