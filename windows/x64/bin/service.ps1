param(
    [ValidateSet('Serve','Worker','Prepare','Status','Stop','Once','Library')][string]$Mode = 'Serve',
    [string]$OrgId,
    [string]$Root = $(if ($env:LOCAL_RUNNER_ROOT) { $env:LOCAL_RUNNER_ROOT } else { Split-Path $PSScriptRoot -Parent })
)
$ErrorActionPreference = 'Stop'
$script:Root = $Root
$script:Secrets = @('GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','GH_CONFIG_DIR')
$script:PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Write-AtomicText([string]$Path, [string]$Text) {
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}
function Write-Json([string]$Path, $Value) { Write-AtomicText $Path ($Value | ConvertTo-Json -Depth 30) }
function Read-Json([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json) }
    return $null
}
function Write-Log([string]$Message) {
    $path = Join-Path $script:Root 'logs\service.log'
    if ((Test-Path $path) -and (Get-Item $path).Length -gt 5MB) {
        foreach ($number in @(2,1)) { if (Test-Path "$path.$number") { Move-Item "$path.$number" "$path.$($number+1)" -Force } }
        Move-Item $path "$path.1" -Force
    }
    Add-Content -Encoding UTF8 -LiteralPath $path -Value "$([DateTime]::UtcNow.ToString('o')) $Message"
}
function Get-State {
    $state = @{}
    $raw = Read-Json (Join-Path $script:Root '.state\organizations.json')
    if ($null -ne $raw) { foreach ($property in $raw.PSObject.Properties) { $state[$property.Name] = $property.Value } }
    return $state
}
function Save-State($State) { Write-Json (Join-Path $script:Root '.state\organizations.json') $State }
function Initialize-Manager {
    $script:Settings = Read-Json (Join-Path $script:Root '.state\settings.json')
    if ($script:Settings.arch -notin @('x64','arm64')) { throw 'Unsupported architecture.' }
    $script:Name = 'local-windows-' + $script:Settings.arch
    $script:Gh = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root '.state\gh-path')).Trim()
    $script:PollSeconds = [Math]::Max(10, $(if ($script:Settings.poll_seconds) { $script:Settings.poll_seconds } else { 300 }))
    $script:RestartSeconds = [Math]::Max(1, $(if ($script:Settings.restart_seconds) { $script:Settings.restart_seconds } else { 30 }))
    foreach ($directory in @('logs','data','.state\workers','.state\children','.state\paused','.state\retry')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Root $directory) | Out-Null
    }
    if (-not (Test-Path (Join-Path $script:Root '.state\organizations.json'))) { Save-State @{} }
}
function Quote-Argument([string]$Value) {
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function New-ProcessInfo([string]$Executable, [string[]]$Arguments, [string]$Directory = $script:Root) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.WorkingDirectory = $Directory
    foreach ($name in $script:Secrets) { $info.EnvironmentVariables.Remove($name) }
    return $info
}
function Invoke-Native([string]$Executable, [string[]]$Arguments, [int]$Timeout = 90, [switch]$Authentication, [string]$Directory = $script:Root) {
    $info = New-ProcessInfo $Executable $Arguments $Directory
    if ($Authentication) {
        $info.EnvironmentVariables['GH_TOKEN'] = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root '.state\github-token')).Trim()
        $info.EnvironmentVariables['GH_HOST'] = 'github.com'
        $info.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
    }
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($Timeout * 1000)) {
        & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
        $process.Dispose(); throw 'Native command timed out.'
    }
    $code = $process.ExitCode
    $text = $output.GetAwaiter().GetResult(); $null = $errors.GetAwaiter().GetResult()
    $process.Dispose()
    if ($code -ne 0) { throw "Native command failed (exit $code)." }
    return $text
}
function Invoke-GitHubApi([string]$Endpoint, [string]$Method = 'GET', [switch]$Paginate) {
    $arguments = @('api','--hostname','github.com',$Endpoint,'--method',$Method)
    if ($Paginate) { $arguments += @('--paginate','--slurp') }
    $text = Invoke-Native $script:Gh $arguments -Authentication
    if ($text.Trim()) { return ,($text | ConvertFrom-Json) }
    return $null
}
function Test-Organization([string]$Login) { return $Login -cmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$' }
function Record-Process([string]$Path, $Process) {
    try { Write-Json $Path @{ process_id=$Process.Id; started=$Process.StartTime.ToUniversalTime().Ticks } } catch { }
}
function Get-RecordedProcess([string]$Path) {
    $record = Read-Json $Path
    if ($null -eq $record) { return $null }
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$record.process_id)
        if (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$record.started) { return $process }
    } catch { }
    return $null
}
function Stop-Record([string]$Path) {
    $process = Get-RecordedProcess $Path
    if ($null -ne $process -and $process.Id -ne $PID) { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}
function Stop-Worker([string]$Id) {
    Stop-Record (Join-Path $script:Root ".state\workers\$Id.json")
    Stop-Record (Join-Path $script:Root ".state\children\$Id.json")
}
function Write-RunnerWrapper([string]$Id, [string]$Login) {
    $directory = Join-Path $script:Root "bin\$Login"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $wrapper = "& (Join-Path (Split-Path `$PSScriptRoot -Parent) 'service.ps1') -Mode Worker -OrgId '$Id'`nexit `$LASTEXITCODE`n"
    Write-AtomicText (Join-Path $directory 'runner.ps1') $wrapper
    Write-AtomicText (Join-Path $directory 'listener.ps1') "Set-Location (Join-Path `$PSScriptRoot 'runner')`n& .\run.cmd`nexit `$LASTEXITCODE`n"
}
function Start-Worker([string]$Id, [string]$Login) {
    if (Test-Path (Join-Path $script:Root ".state\paused\$Id")) { return }
    if (-not (Test-Path (Join-Path $script:Root "bin\$Login\runner\.runner"))) { return }
    $record = Join-Path $script:Root ".state\workers\$Id.json"
    if ($null -ne (Get-RecordedProcess $record)) { return }
    $retry = Read-Json (Join-Path $script:Root ".state\retry\$Id.json")
    if ($null -ne $retry -and [DateTime]::UtcNow.Ticks -lt [long]$retry.after) { return }
    Stop-Worker $Id
    Write-RunnerWrapper $Id $Login
    $info = New-ProcessInfo $script:PowerShell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Root "bin\$Login\runner.ps1"))
    $process = [Diagnostics.Process]::Start($info)
    Record-Process $record $process
    Write-Json (Join-Path $script:Root ".state\retry\$Id.json") @{ after=[DateTime]::UtcNow.AddSeconds($script:RestartSeconds).Ticks }
    Write-Log "Started $script:Name for $Login (pid $($process.Id))"
}
function Ensure-Workers {
    $state = Get-State
    foreach ($id in @($state.Keys)) { if ($id -match '^\d+$' -and (Test-Organization $state[$id].login)) { Start-Worker $id $state[$id].login } }
}
function Invoke-Worker([string]$Id) {
    if ($Id -notmatch '^\d+$') { throw 'Invalid organization ID.' }
    $login = (Get-State)[$Id].login
    if (-not (Test-Organization $login)) { throw 'Invalid organization.' }
    $record = Join-Path $script:Root ".state\children\$Id.json"
    $lock = [IO.File]::Open((Join-Path $script:Root ".state\worker-$Id.lock"), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Stop-Record $record
        while ($true) {
            $info = New-ProcessInfo $script:PowerShell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Root "bin\$login\listener.ps1"))
            $process = [Diagnostics.Process]::Start($info)
            Record-Process $record $process
            $process.WaitForExit(); $process.Dispose()
            Remove-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds $script:RestartSeconds
        }
    } finally { Stop-Record $record; $lock.Dispose() }
}
function Ensure-Package {
    $script:Package = Join-Path $script:Root '.state\package'
    $complete = Join-Path $script:Package '.complete'
    if ((Test-Path $complete) -and (Get-Item $complete).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-1)) { return }
    $release = Invoke-GitHubApi 'repos/actions/runner/releases/latest'
    $version = $release.tag_name.TrimStart('v')
    $name = "actions-runner-win-$($script:Settings.arch)-$version.zip"
    $asset = @($release.assets | Where-Object name -eq $name)[0]
    if ($asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Runner release has no SHA-256 digest.' }
    $temporary = Join-Path $script:Root ('.state\download-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $archive = Join-Path $temporary 'runner.zip'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 $asset.browser_download_url -OutFile $archive
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.digest.Substring(7).ToLowerInvariant()) { throw 'Runner SHA-256 mismatch.' }
        $unpacked = Join-Path $temporary 'package'
        Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
        Write-AtomicText (Join-Path $unpacked '.complete') $version
        if (Test-Path $script:Package) { Remove-Item $script:Package -Recurse -Force }
        Move-Item -LiteralPath $unpacked -Destination $script:Package
    } finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
    Write-Log "Downloaded official Runner $version"
}
function Register-Runner([string]$Login) {
    Ensure-Package
    $directory = Join-Path $script:Root "bin\$Login\runner"
    if (-not (Test-Path (Join-Path $directory 'run.cmd'))) {
        if (Test-Path "$directory.staging") { Remove-Item "$directory.staging" -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Split-Path $directory -Parent) | Out-Null
        Copy-Item $script:Package "$directory.staging" -Recurse
        if (Test-Path $directory) { Remove-Item $directory -Recurse -Force }
        Move-Item "$directory.staging" $directory
    }
    $work = Join-Path $script:Root "data\$Login"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $token = (Invoke-GitHubApi "orgs/$Login/actions/runners/registration-token" -Method POST).token
    $wrapper = Join-Path $directory 'configure.ps1'
    Write-AtomicText $wrapper "& (Join-Path `$PSScriptRoot 'config.cmd') @args`nexit `$LASTEXITCODE`n"
    $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapper,'--unattended','--url',"https://github.com/$Login",'--token',$token,'--name',$script:Name,'--labels',$script:Name,'--work',$work)
    $null = Invoke-Native $script:PowerShell $arguments -Timeout 180 -Directory $directory
    return (Read-Json (Join-Path $directory '.runner')).agentId
}
function Reconcile-Organization([string]$Id, [string]$Login) {
    if ($Id -notmatch '^\d+$' -or -not (Test-Organization $Login)) { throw 'Invalid organization.' }
    $pages = Invoke-GitHubApi "orgs/$Login/actions/runners?per_page=100" -Paginate
    $remote = @($pages | ForEach-Object { $_.runners })
    $state = Get-State; $entry = $state[$Id]
    $registered = @($remote | Where-Object { $null -ne $entry -and $_.id -eq $entry.runner_id }) | Select-Object -First 1
    $directory = Join-Path $script:Root "bin\$Login\runner"
    $pause = Join-Path $script:Root ".state\paused\$Id"
    if ($null -ne $entry -and ($entry.login -ne $Login -or $null -eq $registered -or -not (Test-Path (Join-Path $directory '.runner')))) {
        if ($null -ne $registered -and $registered.busy) { return }
        Write-AtomicText $pause 'paused'; Stop-Worker $Id
        if ($null -ne $registered) {
            $null = Invoke-GitHubApi "orgs/$Login/actions/runners/$($registered.id)" -Method DELETE
            $remote = @($remote | Where-Object id -ne $registered.id)
        }
        $registered = $null
    }
    if ($null -ne $registered -and (Test-Path (Join-Path $directory '.runner'))) { Remove-Item $pause -Force -ErrorAction SilentlyContinue; return }
    $local = Read-Json (Join-Path $directory '.runner')
    $recovered = @($remote | Where-Object { $null -ne $local -and $_.id -eq $local.agentId -and $_.name -eq $script:Name })
    if ($recovered.Count) { $runnerId = $local.agentId }
    else {
        if (@($remote | Where-Object name -eq $script:Name).Count) { throw "Runner $script:Name already belongs to another installation." }
        New-Item -ItemType Directory -Force -Path (Split-Path $directory -Parent) | Out-Null
        foreach ($name in @('.runner','.credentials','.credentials_rsaparams')) { Remove-Item (Join-Path $directory $name) -Force -ErrorAction SilentlyContinue }
        $runnerId = Register-Runner $Login
    }
    if ("$runnerId" -notmatch '^\d+$') { throw 'Invalid registration ID.' }
    $state[$Id] = @{ login=$Login; runner_id=$runnerId }
    Save-State $state
    Remove-Item $pause -Force -ErrorAction SilentlyContinue
}
function Invoke-Reconcile {
    # API failure must not be interpreted as an empty membership list.
    $pages = Invoke-GitHubApi 'user/memberships/orgs?state=active&per_page=100' -Paginate
    $desired = @{}
    foreach ($page in @($pages)) {
        foreach ($member in @($page)) {
            if ($member.state -ne 'active') { continue }
            $login = $member.organization.login
            if (@($script:Settings.organizations).Count -and $login -notin $script:Settings.organizations) { continue }
            $desired["$($member.organization.id)"] = $login
        }
    }
    foreach ($id in @($desired.Keys)) {
        try { Reconcile-Organization $id $desired[$id] } catch { Write-Log "Organization $($desired[$id]): $($_.Exception.Message)" }
    }
    $state = Get-State
    foreach ($id in @($state.Keys)) {
        if (-not $desired.ContainsKey($id)) {
            Stop-Worker $id; $state.Remove($id); Save-State $state
            Write-Log "Stopped organization $id; local data retained"
        }
    }
}
function Invoke-Supervisor {
    $lock = [IO.File]::Open((Join-Path $script:Root '.state\service.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        foreach ($folder in @('workers','children')) { Get-ChildItem (Join-Path $script:Root ".state\$folder") -Filter *.json | ForEach-Object { Stop-Record $_.FullName } }
        Write-Log "Started PowerShell supervisor $script:Name"
        $next = [DateTime]::MinValue
        while ($true) {
            Ensure-Workers
            if ([DateTime]::UtcNow -ge $next) {
                try { Invoke-Reconcile } catch { Write-Log "Discovery failed; retaining current runners: $($_.Exception.Message)" }
                $next = [DateTime]::UtcNow.AddSeconds($script:PollSeconds)
            }
            Ensure-Workers
            Start-Sleep -Seconds 5
        }
    } finally {
        foreach ($folder in @('workers','children')) { Get-ChildItem (Join-Path $script:Root ".state\$folder") -Filter *.json | ForEach-Object { Stop-Record $_.FullName } }
        $lock.Dispose()
    }
}
if ($Mode -ne 'Library') {
    Initialize-Manager
    switch ($Mode) {
        'Serve' { Invoke-Supervisor }
        'Worker' { Invoke-Worker $OrgId }
        'Prepare' { Ensure-Package }
        'Once' { Invoke-Reconcile }
        'Stop' {
            $lock = [IO.File]::Open((Join-Path $script:Root '.state\service.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            try {
                foreach ($folder in @('workers','children')) { Get-ChildItem (Join-Path $script:Root ".state\$folder") -Filter *.json | ForEach-Object { Stop-Record $_.FullName } }
            } finally { $lock.Dispose() }
        }
        'Status' {
            $state = Get-State
            foreach ($entry in $state.Values) {
                $pages = Invoke-GitHubApi "orgs/$($entry.login)/actions/runners?per_page=100" -Paginate
                $runner = @($pages | ForEach-Object { $_.runners } | Where-Object id -eq $entry.runner_id) | Select-Object -First 1
                "$($entry.login): $($runner | ConvertTo-Json -Compress)"
            }
        }
    }
}
