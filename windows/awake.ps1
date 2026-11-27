# Keeps Windows awake while a runner manager runs: no idle sleep, and closing the lid does
# nothing. Both need SYSTEM (the lid action is a machine power setting), so a SYSTEM task
# runs this file from an Administrator-only copy. It reads only the manager's PID record,
# or the state of the WSL hold task, and restores the owner's lid setting when the manager
# stops, however it stopped.
#   -Action Run      -Name <task> (-Record <manager.json> | -HoldTask <WSL task>)
#   -Action Release  -Name <task>     give the setting back now (uninstall, prevent_sleep off)
#   -Action Prepare                   create the Administrator-only store (installer)
param(
    [ValidateSet('Run','Release','Prepare','Library')][string]$Action = 'Run',
    [string]$Name,
    [string]$Record,
    [string]$HoldTask,
    [string]$StateDir = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'github-runner\awake'),
    [double]$Interval = 5
)
$ErrorActionPreference = 'Stop'
$script:Owners = Join-Path $StateDir 'owners'
$script:Saved = Join-Path $StateDir 'lid.json'
function Assert-AwakeName([string]$Value) {
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'A task name is required.' }
}
# Administrators and SYSTEM own the store; users may read it for ghr status. A directory
# that someone else created first is moved aside instead of trusted.
function Initialize-AwakeStore {
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    if (Test-Path -LiteralPath $StateDir) {
        $owner = (Get-Acl -LiteralPath $StateDir).GetOwner([Security.Principal.SecurityIdentifier])
        if ($owner -ne $admins -and $owner -ne $system) { Rename-Item -LiteralPath $StateDir -NewName ('awake.untrusted-' + [Guid]::NewGuid().ToString('N')) }
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($admins,$system)) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))) }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $StateDir -AclObject $acl
    New-Item -ItemType Directory -Force -Path $script:Owners,(Join-Path $StateDir 'bin') | Out-Null
}
function Invoke-PowerCfg([string[]]$Arguments) {
    $output = & (Join-Path $env:SystemRoot 'System32\powercfg.exe') @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($Arguments -join ' ') failed." }
    return $output
}
# Labels are localized; the scheme is the GUID and the AC/DC indexes are the last two hex values.
function Get-LidAction {
    $scheme = [regex]::Match(((Invoke-PowerCfg @('/getactivescheme')) -join ' '), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    if (-not $scheme) { throw 'No active power scheme.' }
    $values = @(Invoke-PowerCfg @('/query',$scheme,'SUB_BUTTONS','LIDACTION') | ForEach-Object { [regex]::Match("$_", '0x([0-9a-fA-F]{8})\s*$') } | Where-Object Success | ForEach-Object { [Convert]::ToInt32($_.Groups[1].Value, 16) })
    if ($values.Count -lt 2) { throw 'This power scheme has no lid action.' }
    return @{scheme=$scheme; ac=$values[$values.Count - 2]; dc=$values[$values.Count - 1]}
}
function Set-LidAction([string]$Scheme, [int]$Ac, [int]$Dc) {
    $null = Invoke-PowerCfg @('/setacvalueindex',$Scheme,'SUB_BUTTONS','LIDACTION',"$Ac")
    $null = Invoke-PowerCfg @('/setdcvalueindex',$Scheme,'SUB_BUTTONS','LIDACTION',"$Dc")
    $null = Invoke-PowerCfg @('/setactive',$Scheme)
}
function Set-ExecutionState([bool]$Awake) {
    if (-not ('GitHubRunner.Power' -as [type])) {
        Add-Type -Namespace GitHubRunner -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'
    }
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED; ES_CONTINUOUS alone clears it. Exiting also clears it.
    $flags = if ($Awake) { [uint32]2147483649 } else { [uint32]2147483648 }
    $null = [GitHubRunner.Power]::SetThreadExecutionState($flags)
}
function Test-Owned { return @(Get-ChildItem -LiteralPath $script:Owners -Force -ErrorAction SilentlyContinue).Count -gt 0 }
# The first installation to hold records the owner's lid setting; the last one to let go
# restores it, so several installations never hand each other a changed setting.
function Enter-Awake([string]$Task) {
    $mark = Join-Path $script:Owners $Task
    if (-not (Test-Path -LiteralPath $mark)) {
        if (-not (Test-Owned) -and -not (Test-Path -LiteralPath $script:Saved)) {
            try { $lid = Get-LidAction; [IO.File]::WriteAllText($script:Saved, (ConvertTo-Json $lid -Compress)) } catch { }
        }
        New-Item -ItemType Directory -Force -Path $script:Owners | Out-Null
        [IO.File]::WriteAllText($mark, '')
        if (Test-Path -LiteralPath $script:Saved) {
            $lid = Get-Content -Raw -LiteralPath $script:Saved | ConvertFrom-Json
            Set-LidAction $lid.scheme 0 0
        }
    }
    Set-ExecutionState $true
}
function Exit-Awake([string]$Task) {
    Set-ExecutionState $false
    $mark = Join-Path $script:Owners $Task
    if (-not (Test-Path -LiteralPath $mark)) { return }
    Remove-Item -LiteralPath $mark -Force
    if ((Test-Owned) -or -not (Test-Path -LiteralPath $script:Saved)) { return }
    $lid = Get-Content -Raw -LiteralPath $script:Saved | ConvertFrom-Json
    Set-LidAction $lid.scheme ([int]$lid.ac) ([int]$lid.dc)
    Remove-Item -LiteralPath $script:Saved -Force
}
function Test-ManagerAlive {
    if ($HoldTask) {
        $task = Get-ScheduledTask -TaskName $HoldTask -ErrorAction SilentlyContinue
        return ($task -and "$($task.State)" -eq 'Running')
    }
    try {
        $entry = Get-Content -Raw -LiteralPath $Record | ConvertFrom-Json
        $process = [Diagnostics.Process]::GetProcessById([int]$entry.process_id)
        return (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$entry.started)
    } catch { return $false }
}
# The WSL setup cannot remove a SYSTEM task without elevation, so its guard removes
# itself once the hold task is gone.
function Remove-OrphanGuard([string]$Task) {
    Exit-Awake $Task
    Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path (Join-Path $StateDir 'bin') "$Task.ps1") -Force -ErrorAction SilentlyContinue
}
function Invoke-AwakeGuard {
    while ($true) {
        try {
            if ($HoldTask -and -not (Get-ScheduledTask -TaskName $HoldTask -ErrorAction SilentlyContinue)) { Remove-OrphanGuard $Name; return }
            if (Test-ManagerAlive) { Enter-Awake $Name } else { Exit-Awake $Name }
        } catch { }
        Start-Sleep -Milliseconds ([int]($Interval * 1000))
    }
}
switch ($Action) {
    'Library' { }
    'Prepare' { Initialize-AwakeStore }
    'Release' { Assert-AwakeName $Name; Exit-Awake $Name }
    'Run' {
        Assert-AwakeName $Name
        if (-not $Record -and -not $HoldTask) { throw 'Record or HoldTask is required.' }
        Invoke-AwakeGuard
    }
}
