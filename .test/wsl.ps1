$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $env:SystemRoot) { $env:SystemRoot = '/tmp' }
. (Join-Path $repo 'linux/wsl.ps1') -Action Library -Distribution 'Ubuntu Work' -LinuxUser 'runner' -InstallRoot '/home/runner/Runner Work'
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
if ($env:OS -eq 'Windows_NT') {
    # Validate native task shape, quoting and ACL APIs with an inert temporary task.
    # No WSL is launched and no real account password is required.
    Initialize-WslHost
    $scheduler = Connect-WslScheduler
    $definition = New-WslTaskDefinition $scheduler
    Assert ($definition.Principal.LogonType -eq 1 -and $definition.Principal.RunLevel -eq 0) 'native definition uses password and limited privileges'
    Assert ($definition.Triggers.Item(1).Type -eq 8 -and $definition.Triggers.Item(2).Repetition.Interval -eq 'PT1M') 'native boot trigger and minute watchdog'
    Assert (-not $definition.Triggers.Item(2).Repetition.Duration) 'native watchdog repeats indefinitely'
    Assert ($definition.Settings.MultipleInstances -eq 2 -and $definition.Settings.ExecutionTimeLimit -eq 'PT0S') 'native instance and duration settings'
    Assert ($definition.Settings.Priority -eq 4 -and -not $definition.Settings.StopIfGoingOnBatteries) 'normal priority, kept on battery'
    $name = 'LocalGitHubRunner-WSL-Test-' + [Guid]::NewGuid().ToString('N')
    $definition.Settings.Enabled = $false
    foreach ($trigger in $definition.Triggers) { $trigger.Enabled = $false }
    $definition.Principal.LogonType = 3 # Only the inactive test task uses InteractiveToken.
    $folder = $scheduler.GetFolder('\')
    $nativeRegistered = $false
    try {
        $task = $folder.RegisterTaskDefinition($name, $definition, 6, $script:Owner.Name, $null, 3, (Get-WslTaskSddl))
        $nativeRegistered = $true
        $task.SetSecurityDescriptor((Get-WslTaskSddl), 0)
        $readback = Get-ScheduledTask -TaskName $name
        Assert ($readback.Actions[0].Arguments -ceq $script:HoldArguments) 'native task action quoting round trip'
        Assert ((Resolve-WindowsSid $readback.Principal.UserId) -eq $script:Owner.Sid -and "$($readback.Principal.RunLevel)" -eq 'Limited') 'native principal readback'
        $sddl = $task.GetSecurityDescriptor(4)
        $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($sddl)
        $ownerAccess = @($descriptor.DiscretionaryAcl | Where-Object {
            $_.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
            $_.SecurityIdentifier.Value -eq $script:Owner.Sid -and
            (($_.AccessMask -band 0x1f01ff) -eq 0x1f01ff -or ($_.AccessMask -band 0x10000000) -ne 0)
        })
        Assert ($ownerAccess.Count -gt 0) "native task grants owning user full access: $sddl"
    } finally { if ($nativeRegistered) { $folder.DeleteTask($name, 0) } }
    Write-Host 'PASS native Windows task definition, action round trip, principal SID and task ACL'
}
function Get-WindowsOwner { return @{Name='fixture\owner';Sid='S-1-5-21-1-2-3-1001'} }
function Resolve-WindowsSid([string]$Account) { if ($Account -in @('fixture\owner','S-1-5-21-1-2-3-1001')) { return 'S-1-5-21-1-2-3-1001' }; return 'S-1-5-21-1-2-3-1002' }
$script:IsAdmin = $true
function Test-HostAdministrator { return $script:IsAdmin }
Initialize-WslHost
$firstName = $script:TaskName
Initialize-WslHost
Assert ($script:TaskName -eq $firstName) 'stable task identity'
Assert ($script:HoldArguments.Contains('"Ubuntu Work"') -and $script:HoldArguments.Contains('"/home/runner/Runner Work/bin/wsl.sh"')) 'native paths with spaces quoted'
# wsl.exe only recognizes its options unquoted; a quoted "--distribution" ran as a shell command.
Assert ($script:HoldArguments.StartsWith('--distribution "Ubuntu Work" --user ') -and $script:HoldArguments.Contains(' --exec /bin/bash ') -and $script:HoldArguments.EndsWith(' hold')) 'wsl.exe options unquoted'
Assert ((Quote-WslArgument 'a"b') -ceq '"a\"b"' -and (Quote-WslArgument '') -ceq '""') 'quotes and empty values still quoted'
$script:SavedTask = $null; $script:Enabled = $false; $script:Started = $false; $script:Linked = $false; $script:LinuxStopped = $false
function Get-ScheduledTask { param($TaskName,$ErrorAction); return $script:SavedTask }
# A task registered by an earlier version, with every argument quoted, is still this installation's.
$script:SavedTask = [pscustomobject]@{Actions=@([pscustomobject]@{Execute=$script:WslExe;Arguments=$script:LegacyHoldArguments});Principal=[pscustomobject]@{UserId='fixture\owner';LogonType='Password';RunLevel='Limited'};Description=$script:TaskDescription;State='Running'}
Assert ($script:LegacyHoldArguments.StartsWith('"--distribution" ') -and $null -ne (Get-OwnedWslTask)) 'legacy fully quoted task still owned'
$script:SavedTask.Actions[0].Arguments = '--distribution Other hold'
$failed = $false; try { $null = Get-OwnedWslTask } catch { $failed = $true }
Assert $failed 'a changed action is still refused'
$script:SavedTask = $null
function Get-Credential { param($UserName,$Message); return [pscredential]::new($UserName,(ConvertTo-SecureString 'fake-password-only' -AsPlainText -Force)) }
function Register-WslTask([pscredential]$Credential, [bool]$Stopped) {
    Assert ($Credential.GetNetworkCredential().Password -eq 'fake-password-only' -and $Credential.UserName -eq 'fixture\owner') 'credential passed only to registration boundary'
    $script:SavedTask = [pscustomobject]@{Actions=@([pscustomobject]@{Execute=$script:WslExe;Arguments=$script:HoldArguments});Principal=[pscustomobject]@{UserId='fixture\owner';LogonType='Password';RunLevel='Limited'};Description=$script:TaskDescription;State='Running'}
    $script:Enabled = -not $Stopped
}
function Invoke-WslHelper([string[]]$Arguments) {
    if ($Arguments[0] -eq 'describe') { return (@{root='/home/runner/Runner Work';user='runner';uid=1000;arch='arm64';stopped=$script:LinuxStopped;prevent_sleep=$script:PreventSleep} | ConvertTo-Json) }
    Assert ($Arguments[0] -eq 'link' -and $Arguments[1] -eq 'Ubuntu Work' -and $Arguments[4] -eq $script:TaskName) 'task metadata linked without password'
    Assert (-not (($Arguments -join ' ') -match 'fake-password')) 'no password sent into Linux'
    $script:Linked = $true
}
function Start-ScheduledTask { param($TaskName); $script:Started = $true }
# The SYSTEM sleep guard follows the Linux prevent_sleep setting.
$script:PreventSleep = $true; $script:Awake = $null
function Connect-WslScheduler { return $null }
function Register-WslAwake($Scheduler) { $script:Awake = 'registered' }
function Unregister-WslAwake { $script:Awake = 'removed' }
function Enable-ScheduledTask { param($TaskName); $script:Enabled = $true }
function Disable-ScheduledTask { param($TaskName); $script:Enabled = $false }
function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm); $script:SavedTask = $null }
Install-WslHost
Assert ($script:Linked -and $script:Started) 'setup links and starts task'
Assert ($script:Awake -eq 'registered') 'sleep guard registered by default'
Assert ($script:SavedTask.Principal.LogonType -eq 'Password' -and $script:SavedTask.Principal.RunLevel -eq 'Limited') 'before-login startup with limited privileges'
Invoke-WslHostAction Stop
$script:LinuxStopped = $true; $script:Started = $false
Install-WslHost
Assert (-not $script:Enabled -and -not $script:Started) 'credential refresh preserves stopped state'
$script:PreventSleep = $false; Install-WslHost
Assert ($script:Awake -eq 'removed') 'sleep guard removed when prevent_sleep is off'
$script:PreventSleep = $true
$script:LinuxStopped = $false
Invoke-WslHostAction Stop; Assert (-not $script:Enabled) 'stop disables startup'
Invoke-WslHostAction Start; Assert $script:Enabled 'start restores startup'
$original = $script:SavedTask.Actions[0].Arguments
$script:SavedTask.Actions[0].Arguments = 'another action'
$failed = $false; try { Invoke-WslHostAction Remove } catch { $failed = $true }
Assert ($failed -and $null -ne $script:SavedTask) 'foreign task preserved'
$script:SavedTask.Actions[0].Arguments = $original
Invoke-WslHostAction Remove; Assert ($null -eq $script:SavedTask) 'uninstall removes owned task'
$failed = $false; try { Invoke-WslHostAction Start } catch { $failed = $true }
Assert $failed 'missing host task reported'
$script:IsAdmin = $false
function Start-Process {
    param($FilePath,$Verb,$ArgumentList,[switch]$Wait,[switch]$PassThru)
    Assert ($Verb -eq 'RunAs' -and $Wait -and $PassThru) 'setup elevates and waits for local prompts'
    Assert ($ArgumentList.Contains('linux') -and $ArgumentList.Contains('wsl.ps1') -and $ArgumentList.Contains('-ExpectedWindowsSid')) 'elevated script retains distribution owner and Linux helper path'
    return [pscustomobject]@{ExitCode=0}
}
Install-WslHost
# A failure inside the elevated window reaches the WSL terminal with its message.
function Start-Process {
    param($FilePath,$Verb,$ArgumentList,[switch]$Wait,[switch]$PassThru)
    # Options are unquoted; the path is quoted only when it contains spaces.
    $match = [regex]::Match($ArgumentList, '(?:^| )-ResultFile (?:"([^"]+)"|(\S+))')
    $file = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
    Assert $file 'elevated window receives a result file'
    [IO.File]::WriteAllText($file, 'The user name or password is incorrect.')
    return [pscustomobject]@{ExitCode=1}
}
$message = ''; try { Install-WslHost } catch { $message = $_.Exception.Message }
Assert ($message -match 'The user name or password is incorrect\.' -and $message -match 'ghr wsl setup') "elevated error reported: $message"
function Start-Process { param($FilePath,$Verb,$ArgumentList,[switch]$Wait,[switch]$PassThru); throw 'The operation was canceled by the user.' }
$message = ''; try { Install-WslHost } catch { $message = $_.Exception.Message }
Assert ($message -match 'declined' -and $message -match 'canceled by the user') "declined elevation reported: $message"
$ExpectedWindowsSid = 'S-1-5-21-1-2-3-1002'
$failed = $false; try { Initialize-WslHost } catch { $failed = $true }
Assert $failed 'elevation must not switch the Windows distribution owner'
Write-Host 'PASS WSL task ownership, credentials boundary, boot startup and lifecycle (OS interfaces mocked)'
