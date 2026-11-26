param(
    [ValidateSet('Serve','Worker','Prepare','Stop','Once','Library')][string]$Mode = 'Serve',
    [string]$OrgId,
    [string]$StateDir,
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
    $path = Join-Path $script:LogDir 'service.log'
    if ((Test-Path $path) -and (Get-Item $path).Length -gt 5MB) {
        foreach ($number in @(2,1)) { if (Test-Path "$path.$number") { Move-Item "$path.$number" "$path.$($number+1)" -Force } }
        Move-Item $path "$path.1" -Force
    }
    # Windows PowerShell Add-Content can deny a concurrent log reader's access.
    $stream = [IO.File]::Open($path, 'Append', 'Write', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
    try { $writer.WriteLine("$([DateTime]::UtcNow.ToString('o')) $Message") } finally { $writer.Dispose() }
}
function Get-State {
    $state = @{}
    $raw = Read-Json (Join-Path $script:Root 'conf\organizations.json')
    if ($null -ne $raw) { foreach ($property in $raw.PSObject.Properties) { $state[$property.Name] = $property.Value } }
    return $state
}
function Save-State($State) { Write-Json (Join-Path $script:Root 'conf\organizations.json') $State }
function Initialize-Manager([switch]$Control) {
    $script:Settings = Read-Json (Join-Path $script:Root 'conf\settings.json')
    if ($script:Settings.arch -notin @('x64','arm64')) { throw 'Unsupported architecture.' }
    $script:Prefix = 'local-windows-' + $script:Settings.arch
    $script:WorkDir = if ($script:Settings.work_dir) { $script:Settings.work_dir } else { $script:Root }
    $script:DataDir = Join-Path $script:WorkDir 'data'; $script:LogDir = Join-Path $script:WorkDir 'logs'
    if (-not $Control) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
    # Administrator commands run this binary, so it must come from read-only bin\, not writable conf\.
    $script:Gh = Join-Path $script:Root 'bin\tools\gh.exe'
    $script:PollSeconds = [Math]::Max(10, $(if ($script:Settings.poll_seconds) { $script:Settings.poll_seconds } else { 300 }))
    $script:RestartSeconds = [Math]::Max(1, $(if ($script:Settings.restart_seconds) { $script:Settings.restart_seconds } else { 30 }))
    foreach ($directory in @('bin\.cache','conf\workers','conf\children','conf\paused','conf\retry','conf\backoff')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Root $directory) | Out-Null
    }
    if (-not (Test-Path (Join-Path $script:Root 'conf\organizations.json'))) { Save-State @{} }
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
function Invoke-Native([string]$Executable, [string[]]$Arguments, [int]$Timeout = 90, [switch]$Authentication, [string]$Directory = $script:Root, [string[]]$Redact = @()) {
    $info = New-ProcessInfo $Executable $Arguments $Directory
    if ($Authentication) {
        $info.EnvironmentVariables['GH_TOKEN'] = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'conf\github-token')).Trim()
        $Redact += $info.EnvironmentVariables['GH_TOKEN']
        $info.EnvironmentVariables['GH_HOST'] = 'github.com'
        $info.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
    }
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($Timeout * 1000)
        $remaining = [int][Math]::Max(0, $Timeout * 1000 - $timer.ElapsedMilliseconds)
        # A descendant may inherit the output handles after the executable exits.
        # Bound pipe draining by the same deadline instead of waiting for EOF forever.
        if (-not $exited -or -not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($output,$errors), $remaining)) {
            if (-not $process.HasExited) { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null }
            if ($exited) { throw 'Native command timed out. Output streams remained open after the process exited.' }
            throw 'Native command timed out.'
        }
        $code = $process.ExitCode
        $text = $output.GetAwaiter().GetResult(); $errorText = $errors.GetAwaiter().GetResult()
    } finally {
        $process.StandardOutput.Dispose(); $process.StandardError.Dispose()
        $process.Dispose()
    }
    if ($code -ne 0) {
        # Keep the last diagnostic line so the log says why; never echo secrets.
        $detail = @(("$errorText`n$text") -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 1
        foreach ($secret in $Redact) { if ($secret) { $detail = "$detail".Replace($secret, '***') } }
        if ($detail) { $detail = "$detail".Trim(); if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) } }
        throw "Native command failed (exit $code): $detail"
    }
    return $text
}
function Invoke-GitHubApi([string]$Endpoint, [string]$Method = 'GET', [switch]$Paginate) {
    $arguments = @('api','--hostname','github.com',$Endpoint,'--method',$Method)
    if ($Paginate) { $arguments += @('--paginate','--slurp') }
    $text = Invoke-Native $script:Gh $arguments -Timeout 120 -Authentication
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
function Test-StoppableProcess([int]$ProcessId) {
    # PID records are writable by LocalService (the job identity); an Administrator command
    # must not be steered into killing another account's process.
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $true }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction SilentlyContinue
    if ($null -eq $owner -or -not $owner.Sid) { return $false }
    # The installed task always uses LocalService. Including the administrator who
    # invokes ghr would let a job forge records targeting that administrator's apps.
    return ($owner.Sid -eq 'S-1-5-19')
}
function Stop-Record([string]$Path) {
    $process = Get-RecordedProcess $Path
    if ($null -ne $process -and $process.Id -ne $PID -and (Test-StoppableProcess $process.Id)) { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}
function Open-ServiceLock([string]$Path, [int]$Seconds = 15) {
    # A manager that was just terminated can hold the lock for a moment.
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        try { return [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] { if ([DateTime]::UtcNow -ge $deadline) { throw } ; Start-Sleep -Milliseconds 250 }
    }
}
function Stop-StateProcesses([string]$Directory) {
    $lock = Open-ServiceLock (Join-Path $Directory 'service.lock')
    try {
        foreach ($folder in @('workers','children')) { Get-ChildItem (Join-Path $Directory $folder) -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { Stop-Record $_.FullName } }
    } finally { $lock.Dispose() }
}
function Stop-Worker([string]$Id) {
    Stop-Record (Join-Path $script:Root "conf\workers\$Id.json")
    Stop-Record (Join-Path $script:Root "conf\children\$Id.json")
}
function Write-RunnerWrapper([string]$Id, [string]$Login) {
    $directory = Join-Path $script:Root "runner\$Login"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:Root 'bin\runner.ps1') -Destination (Join-Path $directory 'runner.ps1') -Force
    Write-AtomicText (Join-Path $directory 'listener.ps1') "Set-Location (Join-Path `$PSScriptRoot 'app')`n& .\run.cmd`nexit `$LASTEXITCODE`n"
}
function Start-Worker([string]$Id, [string]$Login) {
    $entry = (Get-State)[$Id]
    if ($entry.active -eq $false -or $entry.relocated -or -not (Test-IndexedName $entry.runner_name) -or (Test-Path (Join-Path $script:Root 'conf\stopped'))) { return }
    if (Test-Path (Join-Path $script:Root "conf\paused\$Id")) { return }
    if (-not (Test-Path (Join-Path $script:Root "runner\$Login\app\.runner"))) { return }
    $record = Join-Path $script:Root "conf\workers\$Id.json"
    if ($null -ne (Get-RecordedProcess $record)) { return }
    $retry = Read-Json (Join-Path $script:Root "conf\retry\$Id.json")
    if ($null -ne $retry -and [DateTime]::UtcNow.Ticks -lt [long]$retry.after) { return }
    Stop-Worker $Id
    Set-RunnerWorkspace $Login
    Write-RunnerWrapper $Id $Login
    $info = New-ProcessInfo $script:PowerShell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Root "runner\$Login\runner.ps1"),'-Root',$script:Root,'-OrgId',$Id)
    $process = [Diagnostics.Process]::Start($info)
    Record-Process $record $process
    Write-Json (Join-Path $script:Root "conf\retry\$Id.json") @{ after=[DateTime]::UtcNow.AddSeconds($script:RestartSeconds).Ticks }
    Write-Log "Started $((Get-State)[$Id].runner_name) for $Login (pid $($process.Id))"
}
function Ensure-Workers {
    $state = Get-State
    foreach ($id in @($state.Keys)) { if ($id -match '^\d+$' -and (Test-Organization $state[$id].login)) { Start-Worker $id $state[$id].login } }
}
function Ensure-Package {
    $script:Package = Join-Path $script:Root 'bin\.cache\package'
    $complete = Join-Path $script:Package '.complete'
    if ((Test-Path $complete) -and (Get-Item $complete).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-1)) { return }
    $release = Invoke-GitHubApi 'repos/actions/runner/releases/latest'
    $version = $release.tag_name.TrimStart('v')
    $name = "actions-runner-win-$($script:Settings.arch)-$version.zip"
    $asset = @($release.assets | Where-Object name -eq $name)[0]
    if ($asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Runner release has no SHA-256 digest.' }
    $temporary = Join-Path $script:Root ('bin\.cache\download-' + [Guid]::NewGuid().ToString('N'))
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
function Set-RunnerWorkspace([string]$Login) {
    if (-not (Test-Organization $Login)) { throw 'Invalid organization.' }
    $work = Join-Path $script:DataDir $Login
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $configuration = Join-Path $script:Root "runner\$Login\app\.runner"
    $runner = Read-Json $configuration
    $runner | Add-Member -NotePropertyName workFolder -NotePropertyValue $work -Force
    Write-Json $configuration $runner
}
function Register-Runner([string]$Login, [string]$Name) {
    Ensure-Package
    $directory = Join-Path $script:Root "runner\$Login\app"
    if (-not (Test-Path (Join-Path $directory 'run.cmd'))) {
        if (Test-Path "$directory.staging") { Remove-Item "$directory.staging" -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Split-Path $directory -Parent) | Out-Null
        Copy-Item $script:Package "$directory.staging" -Recurse
        if (Test-Path $directory) { Remove-Item $directory -Recurse -Force }
        Move-Item "$directory.staging" $directory
    }
    $work = Join-Path $script:DataDir $Login
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $token = (Invoke-GitHubApi "orgs/$Login/actions/runners/registration-token" -Method POST).token
    $wrapper = Join-Path $directory 'configure.ps1'
    Write-AtomicText $wrapper "& (Join-Path `$PSScriptRoot 'config.cmd') @args`nexit `$LASTEXITCODE`n"
    $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapper,'--unattended','--url',"https://github.com/$Login",'--token',$token,'--name',$Name,'--labels',"$script:Prefix,$Name",'--work',$work)
    $null = Invoke-Native $script:PowerShell $arguments -Timeout 180 -Directory $directory -Redact @($token)
    return (Read-Json (Join-Path $directory '.runner')).agentId
}
function Get-RemoteRunners([string]$Login) {
    $pages = Invoke-GitHubApi "orgs/$Login/actions/runners?per_page=100" -Paginate
    return @($pages | ForEach-Object { $_.runners })
}
function Test-IndexedName([string]$Name) { return $Name -cmatch ('^' + [regex]::Escape($script:Prefix) + '-[1-9][0-9]*$') }
function Get-NextName($Remote) {
    $maximum = 0L
    foreach ($runner in @($Remote)) {
        if ($runner.name -match ('^' + [regex]::Escape($script:Prefix) + '-([1-9][0-9]*)$')) {
            $index = [long]$Matches[1]
            if ($index -ge 9007199254740991) { throw 'Runner index exhausted.' }
            $maximum = [Math]::Max($maximum, $index)
        }
    }
    return "$script:Prefix-$($maximum+1)"
}
function Reconcile-Organization([string]$Id, [string]$Login) {
    if ($Id -notmatch '^\d+$' -or -not (Test-Organization $Login)) { throw 'Invalid organization.' }
    $remote = @(Get-RemoteRunners $Login)
    $state = Get-State; $entry = $state[$Id]
    $directory = Join-Path $script:Root "runner\$Login\app"
    $local = Read-Json (Join-Path $directory '.runner')
    # Recover ownership when registration succeeded before state was saved.
    if ($null -eq $entry -and $null -ne $local) {
        $owned = $remote | Where-Object { $_.id -eq $local.agentId -and ($_.name -ceq $script:Prefix -or (Test-IndexedName $_.name)) } | Select-Object -First 1
        if ($null -ne $owned) { $entry = @{login=$Login;runner_id=$owned.id;runner_name=$owned.name} }
    }
    $registered = @($remote | Where-Object { $null -ne $entry -and $_.id -eq $entry.runner_id }) | Select-Object -First 1
    $preferred = $entry.runner_name
    if ($null -ne $registered -and (Test-IndexedName $registered.name)) { $preferred = $registered.name }
    $pause = Join-Path $script:Root "conf\paused\$Id"
    if ($null -ne $entry -and ($entry.login -cne $Login -or $null -eq $registered -or $local.agentId -ne $entry.runner_id -or -not (Test-IndexedName $registered.name) -or $entry.relocated)) {
        if ($null -ne $registered -and $registered.busy) { return }
        Write-AtomicText $pause 'paused'; Stop-Worker $Id
        if ($null -ne $registered) {
            $null = Invoke-GitHubApi "orgs/$Login/actions/runners/$($registered.id)" -Method DELETE
            $remote = @($remote | Where-Object id -ne $registered.id)
        }
        # A renamed organization keeps its program directory; old work data stays in place.
        $oldDirectory = Join-Path $script:Root "runner\$($entry.login)"
        $newDirectory = Join-Path $script:Root "runner\$Login"
        if ($entry.login -cne $Login -and (Test-Organization $entry.login) -and (Test-Path -LiteralPath $oldDirectory) -and -not (Test-Path -LiteralPath $newDirectory)) {
            Move-Item -LiteralPath $oldDirectory -Destination $newDirectory
            Write-Log "Moved runner directory of $($entry.login) to $Login"
        }
        $registered = $null
    }
    if ($null -ne $registered) { $runnerId = $registered.id; $name = $registered.name }
    else {
        $runnerId = $null
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            $name = if ((Test-IndexedName $preferred) -and -not @($remote | Where-Object name -eq $preferred).Count) { $preferred } else { Get-NextName $remote }
            New-Item -ItemType Directory -Force -Path (Split-Path $directory -Parent) | Out-Null
            foreach ($file in @('.runner','.credentials','.credentials_rsaparams')) { Remove-Item (Join-Path $directory $file) -Force -ErrorAction SilentlyContinue }
            try { $runnerId = Register-Runner $Login $name; break }
            catch {
                # Refresh after a collision; never replace another machine's runner.
                $failure = $_
                $remote = @(Get-RemoteRunners $Login)
                $local = Read-Json (Join-Path $directory '.runner')
                if (@($remote | Where-Object { $null -ne $local -and $_.id -eq $local.agentId -and $_.name -ceq $name }).Count) { $runnerId = $local.agentId; break }
                if (-not @($remote | Where-Object name -eq $name).Count) { throw $failure }
            }
        }
    }
    if ("$runnerId" -notmatch '^\d+$') { throw 'Invalid registration ID.' }
    $state[$Id] = @{ login=$Login; runner_id=$runnerId; runner_name=$name }
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
        $backoff = Join-Path $script:Root "conf\backoff\$id.json"
        $previous = Read-Json $backoff
        if ($null -ne $previous -and [DateTime]::UtcNow.Ticks -lt [long]$previous.after) { continue }
        try {
            Reconcile-Organization $id $desired[$id]
            if ($null -ne $previous) { Remove-Item -LiteralPath $backoff -Force; Write-Log "Organization $($desired[$id]): reconciliation recovered" }
        } catch {
            # Organizations without runner permission (or with persistent errors) back off
            # exponentially from poll_seconds to one hour instead of failing every poll.
            $count = if ($null -ne $previous) { [int]$previous.count + 1 } else { 1 }
            $delay = [Math]::Min(3600, $script:PollSeconds * [Math]::Pow(2, [Math]::Min($count - 1, 12)))
            Write-Json $backoff @{ after=[DateTime]::UtcNow.AddSeconds($delay).Ticks; count=$count }
            Write-Log "Organization $($desired[$id]): $($_.Exception.Message) (attempt $count; next retry in $([int]$delay)s)"
        }
    }
    $state = Get-State
    foreach ($id in @($state.Keys)) {
        if (-not $desired.ContainsKey($id)) {
            # Already deactivated: nothing to stop and nothing new to log.
            if ($state[$id].active -eq $false) { continue }
            Remove-Item -LiteralPath (Join-Path $script:Root "conf\backoff\$id.json") -Force -ErrorAction SilentlyContinue
            Stop-Worker $id
            $state[$id] | Add-Member -NotePropertyName active -NotePropertyValue $false -Force
            Save-State $state
            Write-Log "Stopped organization $id; local data retained"
        }
    }
}
function Invoke-Supervisor {
    if (Test-Path (Join-Path $script:Root 'conf\stopped')) { return }
    $lock = [IO.File]::Open((Join-Path $script:Root 'conf\service.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Record-Process (Join-Path $script:Root 'conf\manager.json') ([Diagnostics.Process]::GetCurrentProcess())
        Write-AtomicText (Join-Path $script:Root 'conf\active-work-dir') $script:WorkDir
        foreach ($folder in @('workers','children')) { Get-ChildItem (Join-Path $script:Root "conf\$folder") -Filter *.json | ForEach-Object { Stop-Record $_.FullName } }
        Write-Log "Started PowerShell supervisor $script:Prefix"
        $next = [DateTime]::MinValue
        while (-not (Test-Path (Join-Path $script:Root 'conf\stopped'))) {
            Ensure-Workers
            if ([DateTime]::UtcNow -ge $next) {
                try { Invoke-Reconcile } catch { Write-Log "Discovery failed; retaining current runners: $($_.Exception.Message)" }
                $next = [DateTime]::UtcNow.AddSeconds($script:PollSeconds)
            }
            Ensure-Workers
            Start-Sleep -Seconds 5
        }
    } finally {
        foreach ($folder in @('workers','children')) { Get-ChildItem (Join-Path $script:Root "conf\$folder") -Filter *.json | ForEach-Object { Stop-Record $_.FullName } }
        $lock.Dispose()
        Remove-Item (Join-Path $script:Root 'conf\manager.json') -Force -ErrorAction SilentlyContinue
    }
}
if ($Mode -eq 'Stop') {
    # Needs only the PID records, so the installer can stop any earlier state layout with
    # this (trusted) script instead of executing the previously installed copy.
    Stop-StateProcesses $(if ($StateDir) { $StateDir } else { Join-Path $script:Root 'conf' })
} elseif ($Mode -ne 'Library') {
    Initialize-Manager
    switch ($Mode) {
        'Serve' { Invoke-Supervisor }
        'Worker' { & (Join-Path $script:Root 'bin\runner.ps1') -Root $script:Root -OrgId $OrgId }
        'Prepare' { Ensure-Package }
        'Once' { Invoke-Reconcile }
    }
}
