param([ValidateSet('status','start','stop','restart','logs','config','uninstall','help','install-command','library')][string]$Command = 'help')
$CommandOptions = @($args)
. (Join-Path $PSScriptRoot 'service.ps1') -Mode Library -Root (Split-Path $PSScriptRoot -Parent)
function Show-Usage {
    @'
ghr status: 获取runner状态
ghr start: 启动runner
ghr stop: 停止runner
ghr restart: 重启runner
ghr logs [-f]: 查询日志，-f是跟踪最新日志
ghr config --dir [<PATH>]: 设置data和logs的父目录，默认为当前目录，重启后生效（--dir 可简写为 -d）
ghr uninstall: 卸载runner
'@
}
function Assert-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Use an Administrator PowerShell window.' }
}
function Protect-AdminFile([string]$Path) {
    # Administrator commands trust settings.json; LocalService (job identity) may only read it.
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
function Get-CommandText {
    return "@echo off`r`nsetlocal`r`nset LOCAL_RUNNER_ROOT=`r`n`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0ghr.ps1`" %* & exit /b`r`n"
}
function Install-Command {
    $bin = Join-Path $script:Root 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $launcher = Join-Path $bin 'ghr.cmd'
    if ((Test-Path $launcher) -and (Get-Content -Raw -LiteralPath $launcher) -cne (Get-CommandText)) { throw 'Another command owns ghr.cmd.' }
    Write-AtomicText $launcher (Get-CommandText)
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    $present = @($userPath -split ';' | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -eq $bin.TrimEnd('\') }).Count -gt 0
    $added = $script:Settings.command_path_added -eq $true
    if (-not $present) {
        [Environment]::SetEnvironmentVariable('Path', ($bin + ';' + $userPath).TrimEnd(';'), 'User')
        $added = $true
    }
    if (-not @($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -eq $bin.TrimEnd('\') }).Count) { $env:Path = "$bin;$env:Path" }
    $script:Settings | Add-Member -NotePropertyName command_path_added -NotePropertyValue $added -Force
    Write-Json (Join-Path $script:Root 'conf\settings.json') $script:Settings
    Protect-AdminFile (Join-Path $script:Root 'conf\settings.json')
}
function Get-OwnedTask {
    $task = Get-ScheduledTask -TaskName "LocalGitHubRunner-$($script:Settings.arch)" -ErrorAction SilentlyContinue
    if ($task -and (@($task.Actions).Count -ne 1 -or @($task.Actions)[0].Arguments.IndexOf(('"' + (Join-Path $script:Root 'bin\service.ps1') + '"'), [StringComparison]::OrdinalIgnoreCase) -lt 0)) { throw 'Another installation owns this task name.' }
    return $task
}
function Stop-Installation {
    Assert-Administrator
    $task = Get-OwnedTask
    if ($task) {
        Disable-ScheduledTask -TaskName $task.TaskName | Out-Null
        Stop-ScheduledTask -TaskName $task.TaskName
    }
    Write-AtomicText (Join-Path $script:Root 'conf\stopped') 'stopped'
    Stop-Record (Join-Path $script:Root 'conf\manager.json')
    Stop-StateProcesses (Join-Path $script:Root 'conf')
    Write-Host 'Runner stopped; automatic startup disabled. Run ghr start to resume.'
}
function Start-Installation {
    Assert-Administrator
    if ($null -ne (Get-RecordedProcess (Join-Path $script:Root 'conf\manager.json'))) { Write-Host 'Runner already running. Use ghr restart to apply configuration.'; return }
    $task = Get-OwnedTask
    if (-not $task) { throw 'Scheduled task missing; re-run the installer.' }
    Remove-Item (Join-Path $script:Root 'conf\stopped') -Force -ErrorAction SilentlyContinue
    try { Enable-ScheduledTask -TaskName $task.TaskName | Out-Null; Start-ScheduledTask -TaskName $task.TaskName }
    catch { Write-AtomicText (Join-Path $script:Root 'conf\stopped') 'stopped'; throw }
    Write-Host 'Runner started; automatic startup enabled.'
}
function Show-Status {
    $manager = Get-RecordedProcess (Join-Path $script:Root 'conf\manager.json')
    # Three tables: the installation overview, the organizations and their runners, then the counts.
    $items = New-Object Collections.Generic.List[object]; $notes = @()
    $items.Add(@('Platform', "windows / $($script:Settings.arch)"))
    if ($manager) { $items.Add(@('Manager', "running (PID $($manager.Id))")) }
    elseif (Test-Path (Join-Path $script:Root 'conf\stopped')) { $items.Add(@('Manager', 'stopped (run ghr start to resume)')) }
    else { $items.Add(@('Manager', 'stopped')) }
    $items.Add(@('Install directory', $script:Root))
    $items.Add(@('Runner directory', (Join-Path $script:Root 'runner')))
    $work = $script:WorkDir; $directoryState = 'configured; not started yet'
    $active = Join-Path $script:Root 'conf\active-work-dir'
    if ((Test-Path $active) -and (Get-Item -LiteralPath $active).Length -gt 0) {
        $work = (Get-Content -Raw -Encoding UTF8 -LiteralPath $active).TrimEnd("`r","`n")
        $directoryState = if ($manager) { 'active' } else { 'last run; manager stopped' }
    }
    $items.Add(@('Work directory', "$work ($directoryState)"))
    $items.Add(@('Data directory', (Join-Path $work 'data')))
    $items.Add(@('Logs directory', (Join-Path $work 'logs')))
    $items.Add(@('Configured work directory', $script:WorkDir))
    if ($work -ne $script:WorkDir) {
        $items.Add(@('Configuration', "pending; next start uses $(Join-Path $script:WorkDir 'data') and $(Join-Path $script:WorkDir 'logs')"))
        $notes += 'Run ghr restart (or stop then start) to apply the pending directory change.'
    } else { $items.Add(@('Configuration', 'no pending directory change')) }
    Write-Host 'GitHub Runner status'; Write-Host ''
    Write-Host ('{0,-26} {1}' -f 'ITEM','VALUE')
    foreach ($item in $items) { Write-Host ('{0,-26} {1}' -f $item[0],$item[1]) }
    $items.Clear()
    $state = Get-State; $failed = $false
    $online = 0; $offline = 0; $missing = 0; $unknown = 0; $jobs = 0; $listening = 0; $restarting = 0
    $otherCount = 0; $otherOnline = 0; $otherOffline = 0; $otherJobs = 0
    # Explicit columns preserve full runner names even when PowerShell's host is narrow.
    # A tree: each organization, then its runners (this installation's first). Line characters
    # are built from code points, since Windows PowerShell reads BOM-less scripts as ANSI.
    $rowFormat = '{0} {1,-32} {2,-9} {3,-5} {4,-11} {5}'
    $line = [string][char]0x2500 * 2
    $middle = [string][char]0x251C + $line; $last = [string][char]0x2514 + $line
    Write-Host ''; Write-Host ('{0,-36} {1,-9} {2,-5} {3,-11} {4}' -f 'ORGANIZATION / RUNNER','GITHUB','BUSY','LOCAL','PID')
    foreach ($id in @($state.Keys | Sort-Object { $state[$_].login })) {
        $entry = $state[$id]; $runner = $null; $remoteStatus = 'missing'; $busy = '-'; $name = $entry.runner_name
        $listener = Get-RecordedProcess (Join-Path $script:Root "conf\children\$id.json")
        $worker = Get-RecordedProcess (Join-Path $script:Root "conf\workers\$id.json")
        $localStatus = 'stopped'; $localPid = '-'
        if ($listener) { $localStatus = 'running'; $localPid = $listener.Id; $listening++ }
        elseif ($worker) { $localStatus = 'restarting'; $localPid = $worker.Id; $restarting++ }
        elseif ($entry.active -eq $false -or (Test-Path (Join-Path $script:Root "conf\paused\$id"))) { $localStatus = 'paused' }
        $others = @()
        try {
            $remote = @(Get-RemoteRunners $entry.login)
            $runner = @($remote | Where-Object id -eq $entry.runner_id) | Select-Object -First 1
            # Every other runner of the organization: other machines, platforms or manual runners.
            $others = @($remote | Where-Object { $_.id -ne $entry.runner_id } | Sort-Object { "$($_.name)".ToLowerInvariant() })
            if ($runner) {
                if ($runner.name) { $name = $runner.name }
                $remoteStatus = $runner.status
                $busy = if ($null -eq $runner.busy) { '?' } else { "$($runner.busy)".ToLowerInvariant() }
            }
        } catch { $remoteStatus = 'unknown'; $busy = '?'; $failed = $true }
        switch ($remoteStatus) {
            'online' { $online++ }; 'offline' { $offline++ }; 'missing' { $missing++ }
            default { $remoteStatus = 'unknown'; $busy = '?'; $unknown++; $failed = $true }
        }
        if ($busy -eq 'true') { $jobs++ }
        Write-Host $entry.login
        $branch = if ($others.Count) { $middle } else { $last }
        Write-Host ($rowFormat -f $branch,$name,$remoteStatus,$busy,$localStatus,$localPid)
        $remaining = $others.Count
        foreach ($other in $others) {
            $remaining--
            $branch = if ($remaining) { $middle } else { $last }
            $otherStatus = if ($other.status) { $other.status } else { 'unknown' }
            $otherBusy = if ($null -eq $other.busy) { '?' } else { "$($other.busy)".ToLowerInvariant() }
            $otherCount++
            if ($otherStatus -eq 'online') { $otherOnline++ } elseif ($otherStatus -eq 'offline') { $otherOffline++ }
            if ($otherBusy -eq 'true') { $otherJobs++ }
            Write-Host ($rowFormat -f $branch,$other.name,$otherStatus,$otherBusy,'other','-')
        }
    }
    if (-not $state.Count) { Write-Host 'No runners registered yet. Use ghr logs to check discovery and registration.' }
    $items.Add(@('Organizations', "$($state.Count)"))
    $items.Add(@('GitHub', "$online online, $offline offline, $missing missing, $unknown unknown; $jobs busy"))
    if ($otherCount) { $items.Add(@('Other runners', "$otherCount ($otherOnline online, $otherOffline offline); $otherJobs busy")) }
    $items.Add(@('Local', "$listening running, $restarting restarting, $($state.Count - $listening - $restarting) stopped/paused"))
    if ($restarting) { $notes += 'restarting: organization worker is alive; listener is not running yet.' }
    Write-Host ''; Write-Host ('{0,-26} {1}' -f 'SUMMARY','VALUE')
    foreach ($item in $items) { Write-Host ('{0,-26} {1}' -f $item[0],$item[1]) }
    if ($notes.Count -or $failed) { Write-Host '' }
    foreach ($note in $notes) { Write-Host $note }
    if ($failed) { throw 'Some GitHub statuses could not be queried; unknown does not mean offline.' }
}
function Show-Logs([switch]$Track) {
    $active = Join-Path $script:Root 'conf\active-work-dir'
    $work = if (Test-Path $active) { (Get-Content -Raw -Encoding UTF8 $active).Trim() } else { $script:WorkDir }
    $file = Join-Path $work 'logs\service.log'
    if (-not $Track) {
        if (Test-Path $file) { Get-Content -Encoding UTF8 -LiteralPath $file -Tail 200 } else { Write-Host 'No logs yet.' }
        return
    }
    $reader = $null; $identity = $null; $first = $true
    try {
        while ($true) {
            if (Test-Path $file) {
                $info = Get-Item -LiteralPath $file
                if ($null -eq $reader -or $identity -ne $info.CreationTimeUtc.Ticks -or $info.Length -lt $reader.BaseStream.Position) {
                    if ($reader) { $reader.Dispose() }
                    $stream = [IO.File]::Open($file, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
                    $identity = $info.CreationTimeUtc.Ticks
                    if ($first) {
                        $lines = $reader.ReadToEnd() -split '\r?\n'; $lines | Select-Object -Last 200 | Where-Object { $_ -ne '' }
                        $first = $false
                    }
                }
                while ($null -ne ($line = $reader.ReadLine())) { Write-Output $line }
            }
            Start-Sleep -Milliseconds 200
        }
    } finally { if ($reader) { $reader.Dispose() } }
}
function Grant-DataDirectory([string]$Directory) {
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $acl = Get-Acl -LiteralPath $Directory
    $sid = New-Object Security.Principal.SecurityIdentifier('S-1-5-19')
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
function Set-WorkDirectory([string]$Directory) {
    Assert-Administrator
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = '.' }
    if (-not [IO.Path]::IsPathRooted($Directory)) { $Directory = Join-Path (Get-Location).ProviderPath $Directory }
    $absolute = [IO.Path]::GetFullPath($Directory)
    if ($absolute.Length -gt [IO.Path]::GetPathRoot($absolute).Length) { $absolute = $absolute.TrimEnd([IO.Path]::DirectorySeparatorChar) }
    foreach ($reserved in @((Join-Path $script:Root 'bin'), (Join-Path $script:Root 'conf'), (Join-Path $script:Root 'runner'))) {
        if ($absolute -eq $reserved -or ($reserved -ne $script:Root -and $absolute.StartsWith($reserved + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'Data must be outside the program and state directories.' }
    }
    Grant-DataDirectory (Join-Path $absolute 'data')
    Grant-DataDirectory (Join-Path $absolute 'logs')
    $settings = Read-Json (Join-Path $script:Root 'conf\settings.json')
    $settings | Add-Member -NotePropertyName work_dir -NotePropertyValue $absolute -Force
    Write-Json (Join-Path $script:Root 'conf\settings.json') $settings
    Protect-AdminFile (Join-Path $script:Root 'conf\settings.json')
    Write-Host "Work directory saved: $absolute"
    Write-Host 'Run ghr restart (or stop then start) to apply. Existing data and logs are not moved.'
}
function Unregister-UntrackedRunners($State) {
    # Keep official .runner evidence until all cleanup succeeds, so interrupted
    # registration and failed DELETE requests remain retryable without guessing names.
    $raw = Read-Json (Join-Path $script:Root 'conf\organizations.json')
    if ($null -eq $raw -or $raw -isnot [pscustomobject]) { throw 'Invalid registration state; retained installation for repair.' }
    foreach ($id in $State.Keys) {
        $entry = $State[$id]
        if ($id -notmatch '^[1-9][0-9]*$' -or "$($entry.runner_id)" -notmatch '^[1-9][0-9]*$' -or -not (Test-Organization $entry.login)) { throw 'Invalid registration state; retained installation for repair.' }
    }
    $targets = @{}
    $runners = Join-Path $script:Root 'runner'
    if (-not (Test-Path -LiteralPath $runners)) { return }
    if ((Get-Item -Force -LiteralPath $runners).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing registration recovery through a linked runner directory.' }
    foreach ($directory in @(Get-ChildItem -Force -LiteralPath $runners | Where-Object PSIsContainer)) {
        $app = Join-Path $directory.FullName 'app'
        $path = Join-Path $app '.runner'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($item in @($directory, (Get-Item -Force -LiteralPath $app), (Get-Item -Force -LiteralPath $path))) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing registration recovery through linked metadata.' }
        }
        $local = Read-Json $path
        if ($null -eq $local -or "$($local.agentId)" -notmatch '^[1-9][0-9]*$') { throw 'Invalid local registration; retained metadata for repair.' }
        # Existing directory/state pairs support older metadata, but an ID alone
        # never identifies a registration in another organization.
        if ($null -eq $local.gitHubUrl -and @($State.Values | Where-Object { $_.runner_id -eq $local.agentId -and $_.login -ceq $directory.Name }).Count) { continue }
        if ($local.agentName -cne $script:Prefix -and -not (Test-IndexedName $local.agentName)) { throw 'Local runner name does not identify this installation.' }
        if ($local.gitHubUrl -notmatch '^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/?$') { throw 'Local registration does not identify a GitHub organization URL.' }
        $organization = Invoke-GitHubApi "orgs/$($Matches[1])"
        if ("$($organization.id)" -notmatch '^[1-9][0-9]*$' -or -not (Test-Organization $organization.login)) { throw 'Invalid organization identity.' }
        $login = $organization.login
        if ($State.ContainsKey("$($organization.id)") -and $State["$($organization.id)"].runner_id -eq $local.agentId) { continue }
        $remote = @(Get-RemoteRunners $login | Where-Object id -eq $local.agentId)
        if (-not $remote.Count) { continue }
        if ($remote.Count -ne 1 -or $remote[0].name -cne $local.agentName) { throw 'Local and remote runner identities disagree; retained metadata for repair.' }
        $targets["$login/$($local.agentId)"] = @{login=$login;runner_id=$local.agentId}
    }
    foreach ($target in $targets.Values) { $null = Invoke-GitHubApi "orgs/$($target.login)/actions/runners/$($target.runner_id)" -Method DELETE }
}
function Unregister-Runners {
    $state = Get-State; $failed = $false
    Unregister-UntrackedRunners $state
    foreach ($id in @($state.Keys)) {
        $entry = $state[$id]
        try {
            if ($id -notmatch '^\d+$' -or "$($entry.runner_id)" -notmatch '^\d+$') { throw 'Invalid registration identity.' }
            $organization = Invoke-GitHubApi "organizations/$id"
            if ("$($organization.id)" -ne $id -or -not (Test-Organization $organization.login)) { throw 'Organization identity mismatch.' }
            $login = $organization.login
            if (@(Get-RemoteRunners $login | Where-Object id -eq $entry.runner_id).Count) { $null = Invoke-GitHubApi "orgs/$login/actions/runners/$($entry.runner_id)" -Method DELETE }
            $state.Remove($id); Save-State $state
        } catch { Write-Warning "Cannot unregister $($entry.login)/$($entry.runner_id); retained state for retry."; $failed = $true }
    }
    if ($failed) { throw 'Uninstall incomplete. State and credentials retained; run ghr uninstall again.' }
}
function Remove-InstallationTree([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $item = Get-Item -Force -LiteralPath $Directory
    if ($item.PSIsContainer) {
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Get-ChildItem -Force -LiteralPath $Directory | ForEach-Object { Remove-InstallationTree $_.FullName } }
        [IO.Directory]::Delete($Directory)
    } else { Remove-Item -LiteralPath $Directory -Force }
}
function Uninstall-Runner {
    Stop-Installation
    Unregister-Runners
    $task = Get-OwnedTask
    if ($task) { Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false }
    $bin = Join-Path $script:Root 'bin'; $launcher = Join-Path $bin 'ghr.cmd'
    if ((Test-Path $launcher) -and (Get-Content -Raw -LiteralPath $launcher) -cne (Get-CommandText)) { throw 'Command ownership changed; refusing removal.' }
    if ($script:Settings.command_path_added) {
        $userPath = [Environment]::GetEnvironmentVariable('Path','User')
        $remaining = @($userPath -split ';' | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ne $bin.TrimEnd('\') }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $remaining, 'User')
    }
    Remove-InstallationTree (Join-Path $script:Root 'runner')
    Remove-InstallationTree $bin
    Remove-InstallationTree (Join-Path $script:Root 'conf')
    foreach ($file in @('install.ps1','service.ps1','ghr.ps1')) { Remove-Item (Join-Path $script:Root $file) -Force -ErrorAction SilentlyContinue }
    Write-Host "Runner uninstalled. Work data retained: $script:DataDir"
    Write-Host 'Data and logs remain in their original directories.'
}
if ($Command -ne 'library') {
    Initialize-Manager -Control
    if ($Command -eq 'config') {
        if ($CommandOptions.Count -eq 0) { $directory = '.' }
        elseif ($CommandOptions.Count -le 2 -and ($CommandOptions[0] -ceq '--dir' -or $CommandOptions[0] -ceq '-d')) {
            $directory = if ($CommandOptions.Count -eq 2) { $CommandOptions[1] } else { '.' }
        }
        else { throw 'Usage: ghr config [--dir [<PATH>] | -d [<PATH>]]' }
    } elseif ($Command -eq 'logs') {
        if ($CommandOptions.Count -gt 1 -or ($CommandOptions.Count -eq 1 -and $CommandOptions[0] -ne '-f')) { throw 'Usage: ghr logs [-f]' }
    } elseif ($CommandOptions.Count) { throw 'Invalid arguments. Run ghr help.' }
    switch ($Command) {
        'status' { Show-Status }
        'start' { Start-Installation }
        'stop' { Stop-Installation }
        'restart' { Stop-Installation; Start-Installation }
        'logs' { Show-Logs -Track:($CommandOptions.Count -eq 1) }
        'config' { Set-WorkDirectory $directory }
        'uninstall' { Uninstall-Runner }
        'install-command' { Install-Command; Grant-DataDirectory $script:DataDir; Grant-DataDirectory $script:LogDir }
        'help' { Show-Usage }
    }
}
