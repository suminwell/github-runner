param(
    [ValidateSet('Install','Start','Stop','Remove','Status','Library')][string]$Action = 'Install',
    [string]$Distribution,
    [string]$LinuxUser,
    [string]$InstallRoot,
    [string]$ExpectedWindowsSid,
    [string]$ResultFile
)
$ErrorActionPreference = 'Stop'
function Get-WindowsOwner {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return @{Name=$identity.Name; Sid=$identity.User.Value}
}
function Test-HostAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Resolve-WindowsSid([string]$Account) {
    if ($Account -match '^S-1-') { return (New-Object Security.Principal.SecurityIdentifier($Account)).Value }
    return (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
}
function Quote-WslArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Initialize-WslHost {
    foreach ($value in @($Distribution,$LinuxUser,$InstallRoot)) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\x00-\x1f]') { throw 'Distribution, LinuxUser and InstallRoot are required and must not contain control characters.' }
    }
    if (-not $InstallRoot.StartsWith('/') -or $InstallRoot -eq '/') { throw 'InstallRoot must be the absolute Linux installation directory.' }
    $script:InstallRoot = $InstallRoot.TrimEnd('/')
    $script:Owner = Get-WindowsOwner
    if ($ExpectedWindowsSid -and $script:Owner.Sid -ne $ExpectedWindowsSid) { throw 'Elevation switched Windows accounts. Use the Windows account that owns this distribution.' }
    $script:WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $script:HostPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = $script:Owner.Sid + "`n" + $Distribution.ToLowerInvariant() + "`n" + $LinuxUser + "`n" + $script:InstallRoot
        $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','').Substring(0,20)
    } finally { $hash.Dispose() }
    $script:TaskName = "LocalGitHubRunner-WSL-$key"
    $script:TaskDescription = "github-runner WSL host: $key"
    $script:WslArguments = @('--distribution',$Distribution,'--user',$LinuxUser,'--exec','/bin/bash',"$script:InstallRoot/bin/wsl.sh")
    $script:HoldArguments = (($script:WslArguments + @('hold') | ForEach-Object { Quote-WslArgument $_ }) -join ' ')
}
function Invoke-WslHelper([string[]]$Arguments, [ValidateRange(1,120)][int]$TimeoutSeconds = 120) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:WslExe
    $info.Arguments = (($script:WslArguments + $Arguments | ForEach-Object { Quote-WslArgument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8; $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($info)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        $remaining = [int][Math]::Max(0, $TimeoutSeconds * 1000 - $timer.ElapsedMilliseconds)
        if (-not $exited -or -not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($output,$errors), $remaining)) {
            if (-not $process.HasExited) { $process.Kill() }
            if ($exited) { throw "WSL did not respond within $TimeoutSeconds seconds. Output streams remained open after the process exited." }
            throw "WSL did not respond within $TimeoutSeconds seconds. Check the distribution and retry."
        }
        $text = $output.GetAwaiter().GetResult(); $detail = $errors.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "WSL helper failed: $detail" }
        return $text
    } finally { $process.StandardOutput.Dispose(); $process.StandardError.Dispose(); $process.Dispose() }
}
function Get-OwnedWslTask {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $actions = @($task.Actions)
        if ($task.Description -cne $script:TaskDescription -or $actions.Count -ne 1 -or
            $actions[0].Execute -ine $script:WslExe -or $actions[0].Arguments -cne $script:HoldArguments) {
            throw 'Another task owns this name or its action was changed; refusing to modify it.'
        }
        $principalSid = Resolve-WindowsSid $task.Principal.UserId
        if ($principalSid -ne $script:Owner.Sid -or "$($task.Principal.LogonType)" -ne 'Password' -or "$($task.Principal.RunLevel)" -ne 'Limited') {
            throw 'The WSL task account or privilege level changed; refusing to modify it.'
        }
    }
    return $task
}
function Connect-WslScheduler {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    return $scheduler
}
function Get-WslTaskSddl {
    # The owning Windows account can manage this task from a normal WSL terminal.
    return 'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;' + $script:Owner.Sid + ')'
}
function New-WslTaskDefinition($Scheduler) {
    $definition = $Scheduler.NewTask(0)
    $definition.RegistrationInfo.Description = $script:TaskDescription
    $definition.Principal.UserId = $script:Owner.Name
    $definition.Principal.LogonType = 1 # TASK_LOGON_PASSWORD
    $definition.Principal.RunLevel = 0 # TASK_RUNLEVEL_LUA (ordinary user)
    $action = $definition.Actions.Create(0)
    $action.Path = $script:WslExe; $action.Arguments = $script:HoldArguments
    $boot = $definition.Triggers.Create(8); $boot.Enabled = $true
    $watchdog = $definition.Triggers.Create(1)
    $watchdog.StartBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
    $watchdog.Repetition.Interval = 'PT1M'; $watchdog.Enabled = $true
    $settings = $definition.Settings
    $settings.MultipleInstances = 2 # TASK_INSTANCES_IGNORE_NEW
    $settings.ExecutionTimeLimit = 'PT0S'
    $settings.RestartCount = 999; $settings.RestartInterval = 'PT1M'
    $settings.StartWhenAvailable = $true
    $settings.DisallowStartIfOnBatteries = $false; $settings.StopIfGoingOnBatteries = $false
    $settings.Priority = 4 # normal; the Task Scheduler default (7) slows builds down
    return $definition
}
function Get-AwakeStore { return (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'github-runner\awake') }
# A SYSTEM task (awake.ps1) keeps Windows awake, also with the lid closed, while the hold
# task runs. It removes itself, restoring the lid setting, once the hold task is gone.
function Register-WslAwake($Scheduler) {
    $name = "$script:TaskName-Awake"
    & $script:HostPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'awake.ps1') -Action Prepare
    if ($LASTEXITCODE -ne 0) { throw 'Sleep prevention setup failed.' }
    $copy = Join-Path (Join-Path (Get-AwakeStore) 'bin') "$name.ps1"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'awake.ps1') -Destination $copy -Force
    $definition = $Scheduler.NewTask(0)
    $definition.RegistrationInfo.Description = "$script:TaskDescription (sleep prevention)"
    $definition.Principal.UserId = 'S-1-5-18'
    $definition.Principal.LogonType = 5 # TASK_LOGON_SERVICE_ACCOUNT
    $definition.Principal.RunLevel = 1 # TASK_RUNLEVEL_HIGHEST
    $action = $definition.Actions.Create(0)
    $action.Path = $script:HostPowerShell
    $action.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $copy + '" -Name ' + $name + ' -HoldTask ' + $script:TaskName
    $boot = $definition.Triggers.Create(8); $boot.Enabled = $true
    $watchdog = $definition.Triggers.Create(1)
    $watchdog.StartBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
    $watchdog.Repetition.Interval = 'PT1M'; $watchdog.Enabled = $true
    $settings = $definition.Settings
    $settings.MultipleInstances = 2; $settings.ExecutionTimeLimit = 'PT0S'
    $settings.RestartCount = 999; $settings.RestartInterval = 'PT1M'; $settings.StartWhenAvailable = $true
    $settings.DisallowStartIfOnBatteries = $false; $settings.StopIfGoingOnBatteries = $false
    # The owning account may read the task for ghr status in WSL.
    $sddl = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;' + $script:Owner.Sid + ')'
    $null = $Scheduler.GetFolder('\').RegisterTaskDefinition($name, $definition, 6, 'SYSTEM', $null, 5, $sddl)
    Start-ScheduledTask -TaskName $name
}
function Unregister-WslAwake {
    $name = "$script:TaskName-Awake"; $copy = Join-Path (Join-Path (Get-AwakeStore) 'bin') "$name.ps1"
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $name; Unregister-ScheduledTask -TaskName $name -Confirm:$false }
    if (Test-Path -LiteralPath $copy) {
        & $script:HostPowerShell -NoProfile -ExecutionPolicy Bypass -File $copy -Action Release -Name $name
        Remove-Item -LiteralPath $copy -Force
    }
}
function Register-WslTask([pscredential]$Credential, [bool]$Stopped) {
    $scheduler = Connect-WslScheduler
    $definition = New-WslTaskDefinition $scheduler
    $definition.Settings.Enabled = -not $Stopped
    # COM avoids binding a plaintext -Password parameter to a PowerShell cmdlet,
    # where an enabled module-logging policy could record it in event 4103.
    $null = $scheduler.GetFolder('\').RegisterTaskDefinition($script:TaskName, $definition, 6, $Credential.UserName, $Credential.GetNetworkCredential().Password, 1, (Get-WslTaskSddl))
}
function Install-WslHost {
    if (-not (Test-HostAdministrator)) {
        # Enter from WSL; Windows UAC and account-password prompts stay on this machine.
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Action','Install','-Distribution',$Distribution,'-LinuxUser',$LinuxUser,'-InstallRoot',$script:InstallRoot,'-ExpectedWindowsSid',$script:Owner.Sid)
        # The elevated window reports back through this file; otherwise its error closes with it.
        $result = Join-Path ([IO.Path]::GetTempPath()) ('ghr-wsl-setup-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $arguments += @('-ResultFile',$result)
        try {
            try { $process = Start-Process -FilePath $script:HostPowerShell -Verb RunAs -ArgumentList (($arguments | ForEach-Object { Quote-WslArgument $_ }) -join ' ') -Wait -PassThru }
            catch { throw "Windows elevation was declined or failed: $($_.Exception.Message) Run ghr wsl setup to retry." }
            $detail = if (Test-Path -LiteralPath $result) { (Get-Content -Raw -Encoding UTF8 -LiteralPath $result).Trim() } else { '' }
            if ($process.ExitCode -ne 0) {
                if (-not $detail) { $detail = 'the elevated window closed before reporting a result' }
                throw "Windows host setup failed: $detail Run ghr wsl setup to retry."
            }
            if ($detail) { Write-Host $detail }
        } finally { Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue }
        Write-Host 'Windows host setup finished. Run ghr status in WSL to check the task.'
        return
    }
    $description = Invoke-WslHelper @('describe') | ConvertFrom-Json
    if ($description.root -cne $script:InstallRoot -or $description.user -cne $LinuxUser -or $description.uid -eq 0 -or $description.arch -notin @('x64','arm64')) {
        throw 'InstallRoot must belong to the specified non-root Linux user and contain an installed Linux ghr.'
    }
    $existing = Get-OwnedWslTask
    $credential = Get-Credential -UserName $script:Owner.Name -Message 'Windows account password (not PIN). Task Scheduler uses it to start WSL before login. ghr does not store this password.'
    if ($null -eq $credential) { throw 'Setup cancelled; no Windows task was changed.' }
    $credentialSid = Resolve-WindowsSid $credential.UserName
    if ($credentialSid -ne $script:Owner.Sid) { throw 'Use the same Windows account that owns this WSL distribution.' }
    $registered = $false
    try {
        Register-WslTask $credential ([bool]$description.stopped)
        $registered = $true
        $null = Invoke-WslHelper @('link',$Distribution,$LinuxUser,$script:HostPowerShell,$script:TaskName)
        if ($description.stopped) { Disable-ScheduledTask -TaskName $script:TaskName | Out-Null }
        else { Start-ScheduledTask -TaskName $script:TaskName }
        if ($description.prevent_sleep -eq $false) { Unregister-WslAwake } else { Register-WslAwake (Connect-WslScheduler) }
    } catch {
        if ($registered -and -not $existing) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false }
        throw
    } finally { $credential = $null }
    Write-Host "WSL boot task installed: $script:TaskName"
    if ($description.prevent_sleep -ne $false) { Write-Host 'Sleep prevention: on; Windows stays awake, also with the lid closed, while the runner runs.' }
    Write-Host 'Runs as the distribution owner before Windows login. Use ghr status/start/stop/restart/uninstall inside WSL.'
    Write-Host 'If the Windows password changes, run this setup again. Passwordless/PIN-only accounts need a usable account password.'
}
function Invoke-WslHostAction([string]$RequestedAction) {
    $task = Get-OwnedWslTask
    if (-not $task) {
        if ($RequestedAction -in @('Stop','Remove')) { return }
        throw 'WSL host task is missing. Run ghr wsl setup inside the owning distribution.'
    }
    switch ($RequestedAction) {
        'Status' {
            Write-Host "WSL host task: $($task.State) ($script:TaskName)"
            $awake = Get-ScheduledTask -TaskName "$script:TaskName-Awake" -ErrorAction SilentlyContinue
            $held = Test-Path -LiteralPath (Join-Path (Join-Path (Get-AwakeStore) 'owners') "$script:TaskName-Awake")
            if (-not $awake) { Write-Host 'Windows sleep prevention: off (run ghr wsl setup to turn it on)' }
            elseif ($held) { Write-Host 'Windows sleep prevention: on; stays awake with the lid closed' }
            else { Write-Host "Windows sleep prevention: $($awake.State); released while the runner is stopped" }
        }
        'Start' { Enable-ScheduledTask -TaskName $script:TaskName | Out-Null; Start-ScheduledTask -TaskName $script:TaskName }
        # Linux writes conf/stopped before this call. The hold process exits on its own,
        # without terminating the distribution or other WSL sessions.
        'Stop' { Disable-ScheduledTask -TaskName $script:TaskName | Out-Null }
        'Remove' { Disable-ScheduledTask -TaskName $script:TaskName | Out-Null; Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false }
        default { throw 'Unsupported host task action.' }
    }
}
if ($Action -ne 'Library') {
    if ($env:OS -ne 'Windows_NT') { throw 'Run this helper in Windows PowerShell.' }
    Initialize-WslHost
    if ($Action -ne 'Install') { Invoke-WslHostAction $Action }
    elseif (-not $ResultFile) { Install-WslHost }
    else {
        # This is the elevated window: report the outcome to the WSL terminal, and keep the
        # window open on failure so the message can be read here as well.
        try {
            Install-WslHost
            [IO.File]::WriteAllText($ResultFile, '', (New-Object Text.UTF8Encoding($false)))
        } catch {
            $message = $_.Exception.Message
            try { [IO.File]::WriteAllText($ResultFile, $message, (New-Object Text.UTF8Encoding($false))) } catch { }
            Write-Host "Windows host setup failed: $message" -ForegroundColor Red
            Read-Host 'Press Enter to close this window' | Out-Null
            exit 1
        }
    }
}
