param([ValidateSet('auto','x64','arm64')][string]$Architecture = 'auto')
$ErrorActionPreference = 'Stop'
function Get-NativeArchitecture {
    # The machine environment reports native ARM64 even in an emulated x64 shell.
    $native = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
    switch ($native) { 'AMD64' { return 'x64' } 'ARM64' { return 'arm64' } default { throw 'Windows x64 or ARM64 is required.' } }
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
$existingCommand = Get-Command ghr.cmd -ErrorAction SilentlyContinue
if (-not $env:LOCAL_RUNNER_HOME -and $existingCommand) {
    $knownRoot = Split-Path (Split-Path $existingCommand.Source -Parent) -Parent
    if (Test-Path (Join-Path $knownRoot 'conf\settings.json')) { $installRoot = $knownRoot }
}
if (-not $env:LOCAL_RUNNER_HOME -and -not [Console]::IsInputRedirected -and [Environment]::GetCommandLineArgs() -notcontains '-NonInteractive') {
    $selectedRoot = Read-Host "安装目录（维护bin和conf）[$installRoot]"
    if ($selectedRoot) { $installRoot = $selectedRoot }
}
$taskName = "LocalGitHubRunner-$arch"
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
$installRoot = (Resolve-Path -LiteralPath $installRoot).Path
$settingsFile = Join-Path $installRoot 'conf\settings.json'
if (Test-Path $settingsFile) {
    if ((Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsFile | ConvertFrom-Json).platform -ne 'windows') { throw 'Installation configuration belongs to a different platform.' }
} else {
    foreach ($part in @('bin','conf')) { if (Test-Path (Join-Path $installRoot $part)) { throw "Refusing to reuse unrelated directory $installRoot\$part; choose another installation directory." } }
}
$bin = Join-Path $installRoot 'bin'; $state = Join-Path $installRoot 'conf'
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
    if (@($task.Actions).Count -ne 1 -or @($task.Actions)[0].Arguments.IndexOf(('"' + (Join-Path $bin 'service.ps1') + '"'), [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'Another installation owns this task name.' }
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Stop-ScheduledTask -TaskName $taskName
    for ($attempt = 0; $attempt -lt 30 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running'; $attempt++) { Start-Sleep -Milliseconds 200 }
}
function Get-SourceFile([string]$Source, [string]$Destination) {
    if ($env:LOCAL_RUNNER_SOURCE_DIR) { Copy-Item -LiteralPath (Join-Path $env:LOCAL_RUNNER_SOURCE_DIR $Source) -Destination "$Destination.new" -Force }
    else { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 "$base/$Source" -OutFile "$Destination.new" }
    Move-Item -LiteralPath "$Destination.new" -Destination $Destination -Force
}
# Stop existing processes with the new script from an Administrator-only location, so a
# broken installed copy cannot block the upgrade.
if (Test-Path -LiteralPath $state) {
    $stopScript = Join-Path ([IO.Path]::GetTempPath()) ('local-github-runner-stop-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Get-SourceFile 'windows/service.ps1' $stopScript
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $stopScript -Mode Stop -Root $installRoot
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop existing runner processes; installation left unchanged.' }
    } finally { Remove-Item -LiteralPath $stopScript -Force -ErrorAction SilentlyContinue }
}
Initialize-InstallSettings $installRoot $arch
# Re-running the installer usually repairs credentials or configuration, so every
# organization is retried at once instead of after its backoff (up to an hour).
Remove-Item -Path (Join-Path $installRoot 'conf\backoff\*') -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $bin, $state, (Join-Path $bin 'tools'), (Join-Path $bin '.cache') | Out-Null
Protect-AdminFile (Join-Path $state 'settings.json')
foreach ($writable in @($state, (Join-Path $bin '.cache'))) { Grant-ServiceWrite $writable }
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
# Classic OAuth tokens report their scopes; other token kinds (fine-grained, GitHub App)
# do not, and are left to the API itself.
function Test-AdminOrgScope([string]$Token) {
    $previousToken = $env:GH_TOKEN; $env:GH_TOKEN = $Token
    try { $headers = & $ghPath api --hostname github.com -i user 2>$null } catch { $headers = $null } finally { $env:GH_TOKEN = $previousToken }
    $scopes = @($headers | Where-Object { $_ -match '^X-Oauth-Scopes:' } | Select-Object -First 1)
    if (-not $scopes.Count) { return $true }
    return (@(($scopes[0] -replace '^X-Oauth-Scopes:\s*','').Split(',') | ForEach-Object { $_.Trim() }) -contains 'admin:org')
}
# An existing gh login may predate this installer and lack admin:org, which runner
# registration requires. Ask gh to add it before the token is saved for the service.
if (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN -and -not (Test-AdminOrgScope (& $ghPath auth token --hostname github.com))) {
    Write-Host 'The current GitHub login lacks the admin:org scope required to register organization runners. Authorize the additional scope:'
    & $ghPath auth refresh --hostname github.com --scopes admin:org,repo
    if ($LASTEXITCODE -ne 0) { throw 'GitHub authorization failed.' }
}
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { & $ghPath auth token --hostname github.com }
if (-not $token) { throw 'No GitHub credential available.' }
if (-not (Test-AdminOrgScope $token.Trim())) { throw 'The GitHub token lacks the admin:org scope required to register organization runners. Use a token with admin:org and run the installer again.' }
[IO.File]::WriteAllText((Join-Path $state 'github-token'), $token.Trim(), (New-Object Text.UTF8Encoding($false)))
$settingsPath = Join-Path $state 'settings.json'
$settings = @{}
$defaultWork = (Get-Location).ProviderPath
if (Test-Path $settingsPath) {
    $defaultWork = $installRoot
    $previous = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
    foreach ($property in $previous.PSObject.Properties) { $settings[$property.Name] = $property.Value }
}
$settings.platform = 'windows'; $settings.arch = $arch
if (-not $settings.ContainsKey('work_dir')) { $settings.work_dir = $defaultWork }
if (-not $settings.ContainsKey('poll_seconds')) { $settings.poll_seconds = 300 }
if (-not $settings.ContainsKey('restart_seconds')) { $settings.restart_seconds = 30 }
if (-not $settings.ContainsKey('organizations')) { $settings.organizations = @() }
# Keeping Windows awake (also with the lid closed) while the manager runs is on by default;
# LOCAL_RUNNER_PREVENT_SLEEP=no turns it off, and a re-run keeps the choice.
switch -Regex ("$env:LOCAL_RUNNER_PREVENT_SLEEP") {
    '^(yes|true|1)$' { $settings.prevent_sleep = $true; break }
    '^(no|false|0)$' { $settings.prevent_sleep = $false; break }
    '^$' { $settings.prevent_sleep = -not ($settings.ContainsKey('prevent_sleep') -and $settings.prevent_sleep -eq $false); break }
    default { throw 'LOCAL_RUNNER_PREVENT_SLEEP must be yes or no.' }
}
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
foreach ($trusted in @('github-token','settings.json')) { Protect-AdminFile (Join-Path $state $trusted) }
Get-SourceFile 'windows/install.ps1' (Join-Path $bin 'install.ps1')
Get-SourceFile 'windows/service.ps1' (Join-Path $bin 'service.ps1')
Get-SourceFile 'windows/ghr.ps1' (Join-Path $bin 'ghr.ps1')
Get-SourceFile 'windows/runner.ps1' (Join-Path $bin 'runner.ps1')
Get-SourceFile 'windows/awake.ps1' (Join-Path $bin 'awake.ps1')
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'service.ps1') -Mode Prepare
if ($LASTEXITCODE -ne 0) { throw 'Runner preparation failed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'ghr.ps1') install-command
if ($LASTEXITCODE -ne 0) { throw 'Management command setup failed.' }
$env:Path = "$bin;$env:Path"
$action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bin\service.ps1`"" -WorkingDirectory $installRoot
$boot = New-ScheduledTaskTrigger -AtStartup
# Indefinite repetition also recovers clean exits; IgnoreNew keeps only one manager.
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -Priority 4
$taskSettings.Enabled = -not (Test-Path (Join-Path $state 'stopped'))
$localService = (New-Object Security.Principal.SecurityIdentifier('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $localService -LogonType ServiceAccount
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($boot,$watchdog) -Settings $taskSettings -Principal $taskPrincipal -Force | Out-Null
if (Test-Path (Join-Path $state 'stopped')) { Disable-ScheduledTask -TaskName $taskName | Out-Null }
else { Enable-ScheduledTask -TaskName $taskName | Out-Null; Start-ScheduledTask -TaskName $taskName }
# A SYSTEM task keeps the machine awake while the manager runs (windows/awake.ps1). It runs
# from an Administrator-only copy, also while the runner is stopped, so ghr start needs nothing else.
$awakeTask = "$taskName-Awake"; $awakeStore = if ($env:LOCAL_RUNNER_AWAKE_STORE) { $env:LOCAL_RUNNER_AWAKE_STORE } else { Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'github-runner\awake' }
$awakeScript = Join-Path (Join-Path $awakeStore 'bin') "$awakeTask.ps1"
if (Get-ScheduledTask -TaskName $awakeTask -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $awakeTask -ErrorAction SilentlyContinue }
if ($settings.prevent_sleep) {
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'awake.ps1') -Action Prepare
    if ($LASTEXITCODE -ne 0) { throw 'Sleep prevention setup failed.' }
    Copy-Item -LiteralPath (Join-Path $bin 'awake.ps1') -Destination $awakeScript -Force
    $awakeAction = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$awakeScript`" -Name $awakeTask -Record `"$(Join-Path $state 'manager.json')`""
    $awakeSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd
    $awakePrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $awakeTask -Action $awakeAction -Trigger @($boot,$watchdog) -Settings $awakeSettings -Principal $awakePrincipal -Force | Out-Null
    Start-ScheduledTask -TaskName $awakeTask
    Write-Host 'Sleep prevention: on; Windows stays awake, also with the lid closed, while the runner service runs.'
} else {
    Unregister-ScheduledTask -TaskName $awakeTask -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $awakeScript) { & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $awakeScript -Action Release -Name $awakeTask; Remove-Item -LiteralPath $awakeScript -Force }
}
Write-Host "Installed $taskName in $installRoot"
Write-Host "Work directory (jobs, runners, logs): $($settings.work_dir)"
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'ghr.ps1') help
Write-Host 'If ghr is not found in an existing terminal, open a new terminal.'
