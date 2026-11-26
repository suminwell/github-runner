$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-status-' + [Guid]::NewGuid().ToString('N'))
if ($env:OS -ne 'Windows_NT') { $env:SystemRoot = '/tmp' }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
try {
    . (Join-Path $repo 'windows/ghr.ps1') -Command library
    $script:Root = $fixture
    New-Item -ItemType Directory -Path (Join-Path $fixture 'conf') -Force | Out-Null
    $oldWork = Join-Path $fixture 'old work'; $newWork = Join-Path $fixture 'new work'
    Write-Json (Join-Path $fixture 'conf/settings.json') @{arch='arm64';work_dir=$newWork}
    Initialize-Manager -Control
    $current = [Diagnostics.Process]::GetCurrentProcess()
    Record-Process (Join-Path $fixture 'conf/manager.json') $current
    Record-Process (Join-Path $fixture 'conf/children/1.json') $current
    Record-Process (Join-Path $fixture 'conf/workers/2.json') $current
    Write-AtomicText (Join-Path $fixture 'conf/active-work-dir') $oldWork
    Save-State @{
        '1'=@{login='alpha';runner_id=101;runner_name="$script:Prefix-1"}
        '2'=@{login='beta';runner_id=102;runner_name="$script:Prefix-1"}
        '3'=@{login='gamma';runner_id=103;runner_name="$script:Prefix-1";active=$false}
        '4'=@{login='denied';runner_id=104;runner_name="$script:Prefix-1"}
    }
    $script:Deny = $true
    function Get-RemoteRunners([string]$Login) {
        switch ($Login) {
            alpha { return [pscustomobject]@{id=101;name="$script:Prefix-1";status='online';busy=$true} }
            beta { return [pscustomobject]@{id=102;name="$script:Prefix-1";status='offline';busy=$false} }
            gamma { return [pscustomobject]@{id=999;name="$script:Prefix-1";status='online';busy=$false} }
            denied { if ($script:Deny) { throw 'Simulated HTTP 403' }; return @() }
            default { throw 'Unexpected organization' }
        }
    }
    function Capture-Status {
        $script:StatusFailed = $false
        return (& { try { Show-Status } catch { $script:StatusFailed = $true; Write-Host $_.Exception.Message } } 6>&1 | Out-String -Width 240)
    }
    $before = Get-Content -Raw -LiteralPath (Join-Path $fixture 'conf/organizations.json')
    $report = Capture-Status
    Assert $script:StatusFailed 'API failure preserved'
    Assert ($report.Contains("Manager: running (PID $PID)")) 'manager and PID'
    Assert ($report.Contains("Install directory: $fixture")) 'installation directory'
    Assert ($report.Contains("Data directory: $(Join-Path $oldWork 'data')") -and $report.Contains("Logs directory: $(Join-Path $oldWork 'logs')")) 'current data and log paths'
    Assert ($report.Contains("Configuration: pending; next start uses $(Join-Path $newWork 'data')")) 'pending data directory explicit'
    Assert ($report -match '(?m)^alpha +\S+ +online +true +running +\d+\s*$') 'online busy listener'
    Assert ($report -match '(?m)^beta +\S+ +offline +false +restarting +\d+\s*$') 'worker without listener is restarting'
    Assert ($report -match '(?m)^gamma +\S+ +missing +- +paused +-\s*$') 'missing ID is not confused with matching name'
    Assert ($report -match '(?m)^denied +\S+ +unknown +\? +stopped +-\s*$') 'API error is unknown'
    Assert ($report.Contains('GitHub: 1 online, 1 offline, 1 missing, 1 unknown; 1 busy') -and $report.Contains('Local: 1 running, 1 restarting, 2 stopped/paused')) 'remote and local counts'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'conf/organizations.json')) -ceq $before) 'status leaves registrations unchanged'
    $script:Deny = $false
    Remove-Item -LiteralPath (Join-Path $fixture 'conf/manager.json')
    Write-AtomicText (Join-Path $fixture 'conf/stopped') 'stopped'
    $report = Capture-Status
    Assert (-not $script:StatusFailed -and $report.Contains('Manager: stopped (run ghr start to resume)') -and $report.Contains("$oldWork (last run; manager stopped)")) 'stopped manager retains last-run directory'
    Record-Process (Join-Path $fixture 'conf/manager.json') $current
    Remove-Item -LiteralPath (Join-Path $fixture 'conf/stopped')
    Write-AtomicText (Join-Path $fixture 'conf/active-work-dir') $newWork
    $report = Capture-Status
    Assert ($report.Contains("Data directory: $(Join-Path $newWork 'data')") -and $report.Contains('Configuration: no pending directory change')) 'applied directory reflected'
    Save-State @{}
    Remove-Item -LiteralPath (Join-Path $fixture 'conf/manager.json'),(Join-Path $fixture 'conf/active-work-dir')
    $report = Capture-Status
    Assert ($report.Contains('configured; not started yet') -and $report.Contains('No runners registered yet.') -and $report.Contains('Organizations: 0')) 'empty installation still shows overview'
    Write-Host 'PASS Windows status: directories, pending config, process states and GitHub results'
} finally { if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
