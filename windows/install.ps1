param([ValidateSet('auto','x64','arm64')][string]$Architecture = 'auto')
$ErrorActionPreference = 'Stop'
function Get-NativeArchitecture {
    # The machine environment reports native ARM64 even in an emulated x64 shell.
    $native = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
    switch ($native) { 'AMD64' { return 'x64' } 'ARM64' { return 'arm64' } default { throw 'Windows x64 or ARM64 is required.' } }
}
function Move-PreviousLayout([string]$InstallRoot, [string]$Arch) {
    $legacy = Join-Path $InstallRoot $Arch
    if ((Test-Path (Join-Path $legacy '.state\settings.json')) -or (Test-Path (Join-Path $legacy 'conf\settings.json'))) {
        foreach ($part in @('bin','data','logs','conf')) { if (Test-Path (Join-Path $InstallRoot $part)) { throw 'Both installation layouts exist; resolve them before upgrading.' } }
        foreach ($part in @('bin','data','logs')) { $source = Join-Path $legacy $part; if (Test-Path $source) { Move-Item -LiteralPath $source -Destination (Join-Path $InstallRoot $part) } }
        $oldState = if (Test-Path (Join-Path $legacy '.state')) { Join-Path $legacy '.state' } else { Join-Path $legacy 'conf' }
        Move-Item -LiteralPath $oldState -Destination (Join-Path $InstallRoot 'conf')
        if (-not @(Get-ChildItem -LiteralPath $legacy -Force).Count) { Remove-Item -LiteralPath $legacy }
    }
    if (Test-Path (Join-Path $InstallRoot '.state')) {
        if (Test-Path (Join-Path $InstallRoot 'conf')) { throw 'Both .state and conf exist; resolve them before upgrading.' }
        Move-Item -LiteralPath (Join-Path $InstallRoot '.state') -Destination (Join-Path $InstallRoot 'conf')
    }
    foreach ($pair in @(@('conf\package','bin\.cache\package'),@('conf\tools','bin\tools'))) {
        $source = Join-Path $InstallRoot $pair[0]; $destination = Join-Path $InstallRoot $pair[1]
        if (Test-Path $source) {
            if (Test-Path $destination) { throw 'Both cache/tool directories exist.' }
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Move-Item -LiteralPath $source -Destination $destination
        }
    }
    $oldBin = Join-Path $InstallRoot 'bin'
    if (Test-Path $oldBin) {
        foreach ($org in @(Get-ChildItem -Directory -LiteralPath $oldBin)) {
            if (Test-Path (Join-Path $org.FullName 'runner\.runner')) {
                $destination = Join-Path $InstallRoot "runner\$($org.Name)"
                if (Test-Path $destination) { throw 'Both organization runner layouts exist.' }
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Move-Item -LiteralPath (Join-Path $org.FullName 'runner') -Destination (Join-Path $destination 'app')
                foreach ($wrapper in @('runner.ps1','listener.ps1')) { Remove-Item (Join-Path $org.FullName $wrapper) -Force -ErrorAction SilentlyContinue }
                if (-not @(Get-ChildItem -LiteralPath $org.FullName -Force).Count) { Remove-Item -LiteralPath $org.FullName }
            }
        }
    }
}
function Grant-ServiceWrite([string]$Directory) {
    $item = Get-Item -LiteralPath $Directory
    $acl = $item.GetAccessControl('Access')
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-19')), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    $item.SetAccessControl($acl)
}
function Initialize-InstallSettings([string]$InstallRoot, [string]$Arch) {
    $path = Join-Path $InstallRoot 'conf\settings.json'
    if (Test-Path -LiteralPath $path) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    # Persist ownership and the original data directory before download/login can fail.
    $settings = @{platform='windows'; arch=$Arch; work_dir=(Get-Location).ProviderPath}
    $temporary = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($settings | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Move($temporary, $path)
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}
function Protect-AdminFile([string]$Path) {
    # Keep the inherited owners, but LocalService may only read this file.
    $item = Get-Item -LiteralPath $Path
    $acl = $item.GetAccessControl('Access')
    $acl.SetAccessRuleProtection($true, $true)
    $item.SetAccessControl($acl)
    $acl = $item.GetAccessControl('Access')
    $service = New-Object Security.Principal.SecurityIdentifier('S-1-5-19')
    $acl.PurgeAccessRules($service)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($service, 'ReadAndExecute', 'Allow')))
    $item.SetAccessControl($acl)
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Use an Administrator PowerShell window.' }
$arch = Get-NativeArchitecture
if ($Architecture -ne 'auto' -and $Architecture -ne $arch) { throw "Architecture mismatch: requested $Architecture, host $arch" }
$base = if ($env:LOCAL_RUNNER_BASE_URL) { $env:LOCAL_RUNNER_BASE_URL } else { 'https://raw.githubusercontent.com/suminwell/github-runner/main' }
$installHome = if ($env:LOCAL_RUNNER_HOME) { $env:LOCAL_RUNNER_HOME } else { Join-Path $env:ProgramData 'local-github-runner' }
$installRoot = Join-Path $installHome 'windows'
$previousRoot = Join-Path $env:ProgramData 'local-github-runner\windows'
if (-not $env:LOCAL_RUNNER_HOME -and ((Test-Path (Join-Path $previousRoot '.state')) -or (Test-Path (Join-Path $previousRoot "$arch\.state")))) { $installRoot = $previousRoot }
$existingCommand = Get-Command ghr.cmd -ErrorAction SilentlyContinue
if (-not $env:LOCAL_RUNNER_HOME -and $existingCommand) {
    $knownRoot = Split-Path (Split-Path $existingCommand.Source -Parent) -Parent
    if (Test-Path (Join-Path $knownRoot 'conf\settings.json')) { $installRoot = $knownRoot }
}
if (-not $env:LOCAL_RUNNER_HOME -and -not [Console]::IsInputRedirected -and [Environment]::GetCommandLineArgs() -notcontains '-NonInteractive') {
    $selectedRoot = Read-Host "安装目录（维护bin和conf）[$installRoot]"
    if ($selectedRoot) { $installRoot = $selectedRoot }
}
$bin = Join-Path $installRoot 'bin'; $state = Join-Path $installRoot 'conf'; $taskName = "LocalGitHubRunner-$arch"
$legacy = Join-Path $installRoot $arch
$otherArch = if ($arch -eq 'x64') { 'arm64' } else { 'x64' }
if ((Test-Path (Join-Path $installRoot "$otherArch\.state\settings.json")) -or (Test-Path (Join-Path $installRoot "$otherArch\conf\settings.json"))) { throw 'An installation for another architecture exists; stop it and move it aside before upgrading.' }
$migrate = (Test-Path (Join-Path $legacy '.state\settings.json')) -or (Test-Path (Join-Path $legacy 'conf\settings.json'))
if ($migrate) {
    foreach ($part in @('bin','data','logs','.state')) {
        if (Test-Path (Join-Path $installRoot $part)) { throw "Both layouts exist at $installRoot; resolve them before upgrading." }
    }
}
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
$installRoot = (Resolve-Path -LiteralPath $installRoot).Path
$knownInstallation = $false
foreach ($relative in @('conf\settings.json','.state\settings.json',"$arch\.state\settings.json","$arch\conf\settings.json")) {
    $settingsFile = Join-Path $installRoot $relative
    if (Test-Path $settingsFile) {
        $existingSettings = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsFile | ConvertFrom-Json
        if ($existingSettings.platform -ne 'windows') { throw 'Installation configuration belongs to a different platform.' }
        $knownInstallation = $true
    }
}
if (-not $knownInstallation) {
    foreach ($part in @('bin','conf','runner')) { if (Test-Path (Join-Path $installRoot $part)) { throw "Refusing to reuse unrelated directory $installRoot\$part; choose another installation directory." } }
}
$bin = Join-Path $installRoot 'bin'; $state = Join-Path $installRoot 'conf'; $legacy = Join-Path $installRoot $arch
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Jobs run as LocalService, while Administrator commands execute bin\ and trust conf\ settings.
# LocalService may read the whole tree but writes only runtime state (granted below).
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544',$identity.User.Value)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
$rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-19')), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $installRoot -AclObject $acl
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    $owned = $false
    foreach ($expected in @((Join-Path $installRoot 'bin\service.ps1'), (Join-Path $installRoot 'service.ps1'), (Join-Path $legacy 'bin\service.ps1'))) {
        if (@($task.Actions).Count -eq 1 -and @($task.Actions)[0].Arguments.IndexOf(('"' + $expected + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { $owned = $true }
    }
    if (-not $owned) { throw 'Another installation owns this task name.' }
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Stop-ScheduledTask -TaskName $taskName
    for ($attempt = 0; $attempt -lt 30 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running'; $attempt++) { Start-Sleep -Milliseconds 200 }
}
# Upgrade the previous native service only when it belongs to this installation.
$oldService = Get-CimInstance Win32_Service -Filter "Name='$taskName'"
if ($oldService) {
    if ($oldService.PathName.Trim('"') -notin @((Join-Path $bin 'LocalGitHubRunner.exe'), (Join-Path $legacy 'bin\LocalGitHubRunner.exe'))) { throw 'Another installation owns this service name.' }
    Stop-Service -Name $taskName
    & sc.exe delete $taskName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove the previous service host.' }
}
function Get-SourceFile([string]$Source, [string]$Destination) {
    if ($env:LOCAL_RUNNER_SOURCE_DIR) { Copy-Item -LiteralPath (Join-Path $env:LOCAL_RUNNER_SOURCE_DIR $Source) -Destination "$Destination.new" -Force }
    else { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 "$base/$Source" -OutFile "$Destination.new" }
    Move-Item -LiteralPath "$Destination.new" -Destination $Destination -Force
}
# Earlier releases let LocalService modify bin\, so never execute the installed copy as
# Administrator: stop existing processes with the new script from an admin-only location.
$stateDirectories = @((Join-Path $installRoot 'conf'), (Join-Path $installRoot '.state'), (Join-Path $legacy 'conf'), (Join-Path $legacy '.state')) | Where-Object { Test-Path -LiteralPath $_ }
if (@($stateDirectories).Count) {
    $stopScript = Join-Path ([IO.Path]::GetTempPath()) ('local-github-runner-stop-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Get-SourceFile 'windows/service.ps1' $stopScript
        foreach ($stateDirectory in $stateDirectories) {
            & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $stopScript -Mode Stop -Root $installRoot -StateDir $stateDirectory
            if ($LASTEXITCODE -ne 0) { throw 'Could not stop existing runner processes; installation left unchanged.' }
        }
    } finally { Remove-Item -LiteralPath $stopScript -Force -ErrorAction SilentlyContinue }
}
Move-PreviousLayout $installRoot $arch
Initialize-InstallSettings $installRoot $arch
# Re-running the installer usually repairs credentials or configuration, so every
# organization is retried at once instead of after its backoff (up to an hour).
Remove-Item -Path (Join-Path $installRoot 'conf\backoff\*') -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $bin, $state, (Join-Path $bin 'tools'), (Join-Path $bin '.cache'), (Join-Path $installRoot 'runner') | Out-Null
Protect-AdminFile (Join-Path $state 'settings.json')
foreach ($writable in @($state, (Join-Path $bin '.cache'), (Join-Path $installRoot 'runner'))) { Grant-ServiceWrite $writable }
$ghPath = Join-Path $bin 'tools\gh.exe'
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
    $temporary = Join-Path (Join-Path $bin '.cache') ('gh-' + [Guid]::NewGuid().ToString('N'))
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
# The service always runs bin\tools\gh.exe; a path stored in writable state is no longer trusted.
Remove-Item (Join-Path $state 'gh-path') -Force -ErrorAction SilentlyContinue
$settingsPath = Join-Path $state 'settings.json'
$settings = @{}
$defaultWork = (Get-Location).ProviderPath
if (Test-Path $settingsPath) {
    $defaultWork = $installRoot
    $previous = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
    foreach ($property in $previous.PSObject.Properties) { $settings[$property.Name] = $property.Value }
}
$settings.platform = 'windows'; $settings.arch = $arch; $settings.gh = $ghPath; $settings.Remove('python')
if (-not $settings.ContainsKey('work_dir')) { $settings.work_dir = $defaultWork }
if (-not $settings.ContainsKey('poll_seconds')) { $settings.poll_seconds = 300 }
if (-not $settings.ContainsKey('restart_seconds')) { $settings.restart_seconds = 30 }
if (-not $settings.ContainsKey('organizations')) { $settings.organizations = @() }
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
foreach ($trusted in @('github-token','settings.json')) { Protect-AdminFile (Join-Path $state $trusted) }
Get-SourceFile 'windows/install.ps1' (Join-Path $bin 'install.ps1')
Get-SourceFile 'windows/service.ps1' (Join-Path $bin 'service.ps1')
Get-SourceFile 'windows/ghr.ps1' (Join-Path $bin 'ghr.ps1')
Get-SourceFile 'windows/runner.ps1' (Join-Path $bin 'runner.ps1')
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'service.ps1') -Mode Prepare
if ($LASTEXITCODE -ne 0) { throw 'Runner preparation failed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'ghr.ps1') install-command
if ($LASTEXITCODE -ne 0) { throw 'Management command setup failed.' }
$env:Path = "$bin;$env:Path"
$action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bin\service.ps1`"" -WorkingDirectory $installRoot
$boot = New-ScheduledTaskTrigger -AtStartup
# Indefinite repetition also recovers clean exits; IgnoreNew keeps only one manager.
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$taskSettings.Enabled = -not (Test-Path (Join-Path $state 'stopped'))
$localService = (New-Object Security.Principal.SecurityIdentifier('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $localService -LogonType ServiceAccount
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($boot,$watchdog) -Settings $taskSettings -Principal $taskPrincipal -Force | Out-Null
if (Test-Path (Join-Path $state 'stopped')) { Disable-ScheduledTask -TaskName $taskName | Out-Null }
else { Enable-ScheduledTask -TaskName $taskName | Out-Null; Start-ScheduledTask -TaskName $taskName }
foreach ($old in @('manager.py','windows-service.cs','LocalGitHubRunner.exe')) { Remove-Item (Join-Path $bin $old) -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $state 'python') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($file in @('install.ps1','service.ps1','ghr.ps1')) { Remove-Item (Join-Path $installRoot $file) -Force -ErrorAction SilentlyContinue }
Write-Host "Installed $taskName in $installRoot"
Write-Host "Data/logs directory: $($settings.work_dir)"
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'ghr.ps1') help
Write-Host 'If ghr is not found in an existing terminal, open a new terminal.'
