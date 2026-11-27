$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-awake-' + [Guid]::NewGuid().ToString('N'))
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'owners') -Force | Out-Null
    . (Join-Path $repo 'windows/awake.ps1') -Action Library -StateDir $fixture
    # powercfg and SetThreadExecutionState are replaced by an in-memory power scheme.
    $script:Lid = @{ac=1; dc=2}; $script:Sets = 0; $script:Awake = $null; $script:HasLid = $true
    $script:Labels = @('Current AC Power Setting Index','Current DC Power Setting Index')
    function Invoke-PowerCfg([string[]]$Arguments) {
        switch ($Arguments[0]) {
            '/getactivescheme' { return 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)' }
            '/query' {
                if (-not $script:HasLid) { throw 'no lid' }
                return @('    Possible Setting Index: 000', '    Possible Setting Friendly Name: Do nothing',
                    ('    {0}: 0x{1:x8}' -f $script:Labels[0], $script:Lid.ac), ('    {0}: 0x{1:x8}' -f $script:Labels[1], $script:Lid.dc))
            }
            '/setacvalueindex' { Assert ($Arguments[1] -eq '381b4222-f694-41f0-9685-ff5bb260df2e') 'scheme kept'; $script:Lid.ac = [int]$Arguments[4]; $script:Sets++ }
            '/setdcvalueindex' { $script:Lid.dc = [int]$Arguments[4]; $script:Sets++ }
            '/setactive' { }
            default { throw "unexpected powercfg $Arguments" }
        }
    }
    function Set-ExecutionState([bool]$Awake) { $script:Awake = $Awake }
    # 1. While held, the lid does nothing and idle sleep is blocked; release restores both.
    Enter-Awake 'task-a'
    Assert ($script:Lid.ac -eq 0 -and $script:Lid.dc -eq 0 -and $script:Awake) 'held: lid does nothing, system required'
    $recorded = Get-Content -Raw (Join-Path $fixture 'lid.json') | ConvertFrom-Json
    Assert ($recorded.ac -eq 1 -and $recorded.dc -eq 2) 'owner lid setting recorded'
    Enter-Awake 'task-a'
    Assert ((Get-Content -Raw (Join-Path $fixture 'lid.json') | ConvertFrom-Json).ac -eq 1) 'repeat hold keeps the original'
    # 2. Two installations: the original comes back only after the last one lets go.
    Enter-Awake 'task-b'
    Exit-Awake 'task-a'
    Assert ($script:Lid.ac -eq 0 -and -not $script:Awake) 'other installation still holds the lid'
    Exit-Awake 'task-b'
    Assert ($script:Lid.ac -eq 1 -and $script:Lid.dc -eq 2) 'lid restored after the last release'
    Assert (-not (Test-Path (Join-Path $fixture 'lid.json'))) 'saved setting removed'
    $script:Sets = 0; Exit-Awake 'task-b'
    Assert ($script:Sets -eq 0) 'release without a hold changes nothing'
    # 3. Localized powercfg output is parsed by value, not by label.
    $script:Labels = @('当前交流电源设置索引','当前直流电源设置索引'); $script:Lid = @{ac=3; dc=1}
    $lid = Get-LidAction
    Assert ($lid.ac -eq 3 -and $lid.dc -eq 1 -and $lid.scheme -eq '381b4222-f694-41f0-9685-ff5bb260df2e') 'localized lid action'
    # 4. A machine without a lid still stays awake.
    $script:HasLid = $false
    Enter-Awake 'desktop'; Assert ($script:Awake) 'desktop stays awake'
    Exit-Awake 'desktop'; Assert (-not $script:Awake -and -not (Test-Path (Join-Path $fixture 'owners/desktop'))) 'desktop released'
    # 5. The manager record must match a live process's start time.
    $current = [Diagnostics.Process]::GetCurrentProcess()
    $script:Record = Join-Path $fixture 'manager.json'
    $Record = $script:Record; $HoldTask = $null
    [IO.File]::WriteAllText($Record, (ConvertTo-Json @{process_id=$current.Id; started=$current.StartTime.ToUniversalTime().Ticks}))
    Assert (Test-ManagerAlive) 'live manager'
    [IO.File]::WriteAllText($Record, (ConvertTo-Json @{process_id=$current.Id; started=1}))
    Assert (-not (Test-ManagerAlive)) 'reused PID is not the manager'
    Remove-Item $Record; Assert (-not (Test-ManagerAlive)) 'missing record'
    # 6. A WSL guard follows the hold task and removes itself once that task is gone.
    $script:HasLid = $true; $script:Lid = @{ac=1; dc=1}
    $script:Hold = 'Running'; $script:Unregistered = $null
    function Get-ScheduledTask { param($TaskName, $ErrorAction); if ($script:Hold) { return [pscustomobject]@{State=$script:Hold} } }
    function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm, $ErrorAction); $script:Unregistered = $TaskName }
    $HoldTask = 'LocalGitHubRunner-WSL-x'; $Name = 'LocalGitHubRunner-WSL-x-Awake'
    Assert (Test-ManagerAlive) 'running hold task'
    Enter-Awake $Name
    $script:Hold = 'Ready'; Assert (-not (Test-ManagerAlive)) 'stopped hold task'
    $script:Hold = $null
    New-Item -ItemType Directory -Force (Join-Path $fixture 'bin') | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture "bin/$Name.ps1"), '')
    $Interval = 0.01; Invoke-AwakeGuard
    Assert ($script:Unregistered -eq $Name -and $script:Lid.ac -eq 1 -and -not (Test-Path (Join-Path $fixture "bin/$Name.ps1"))) 'orphan guard released and removed itself'
    $failed = $false; try { Assert-AwakeName '..\escape' } catch { $failed = $true }
    Assert $failed 'task names cannot be paths'
    Write-Host 'PASS Windows awake guard: lid and idle sleep held while running, owner setting restored, WSL orphan cleanup'
} finally { if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
