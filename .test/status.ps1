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
        '1.2'=@{login='alpha';runner_id=204;runner_name="$script:Prefix-2"}
        '1'=@{login='alpha';runner_id=101;runner_name="$script:Prefix-1"}
        '2'=@{login='beta';runner_id=102;runner_name="$script:Prefix-1"}
        '3'=@{login='gamma';runner_id=103;runner_name="$script:Prefix-1";active=$false}
        '4'=@{login='denied';runner_id=104;runner_name="$script:Prefix-1"}
    }
    $script:Deny = $true
    function Get-RemoteRunners([string]$Login) {
        switch ($Login) {
            alpha { return @(
                [pscustomobject]@{id=204;name="$script:Prefix-2";status='online';busy=$false},
                [pscustomobject]@{id=203;name='zeta-manual';status='online';busy=$false},
                [pscustomobject]@{id=101;name="$script:Prefix-1";status='online';busy=$true},
                [pscustomobject]@{id=201;name='Build-box';status='online';busy=$true},
                [pscustomobject]@{id=202;name='local-linux-x64-1';status='offline';busy=$null}) }
            beta { return [pscustomobject]@{id=102;name="$script:Prefix-1";status='offline';busy=$false} }
            gamma { return [pscustomobject]@{id=999;name="$script:Prefix-1";status='online';busy=$false} }
            denied { if ($script:Deny) { throw 'Simulated HTTP 403' }; return @() }
            default { throw 'Unexpected organization' }
        }
    }
    # The runner lines printed under an organization, without the branch characters.
    function Get-Block([string]$Report, [string]$Organization) {
        $lines = @($Report -split "`r?`n"); $result = @(); $on = $false
        foreach ($text in $lines) {
            if ($text -ceq $Organization) { $on = $true; continue }
            if ($on -and $text -match ('^[' + [char]0x251C + [char]0x2514 + ']' + [char]0x2500 + '{2} ')) { $result += $text; continue }
            $on = $false
        }
        return ,$result
    }
    $mid = [string][char]0x251C + [char]0x2500 + [char]0x2500; $end = [string][char]0x2514 + [char]0x2500 + [char]0x2500
    function Field([string]$Item, [string]$Value) { return ('{0,-26} {1}' -f $Item,$Value) }
    function Has-Line([string]$Report, [string]$Line) { return @($Report -split "`r?`n") -ccontains $Line }
    function Capture-Status {
        $script:StatusFailed = $false
        return (& { try { Show-Status } catch { $script:StatusFailed = $true; Write-Host $_.Exception.Message } } 6>&1 | Out-String -Width 240)
    }
    $before = Get-Content -Raw -LiteralPath (Join-Path $fixture 'conf/organizations.json')
    $report = Capture-Status
    Assert $script:StatusFailed 'API failure preserved'
    Assert ((Has-Line $report (Field 'Manager' "running (PID $PID)"))) 'manager and PID'
    Assert ((Has-Line $report (Field 'Install directory' $fixture))) 'installation directory'
    Assert ((Has-Line $report (Field 'Jobs directory' (Join-Path $oldWork 'jobs'))) -and (Has-Line $report (Field 'Logs directory' (Join-Path $oldWork 'logs')))) 'current data and log paths'
    Assert ($report.Contains((Field 'Configuration' "pending; next start uses $(Join-Path $newWork 'jobs')"))) 'pending jobs directory explicit'
    Assert ($report -match '(?m)^ITEM +VALUE\s*$') 'overview table header'
    $tables = @('ITEM ', "`nConfiguration ", 'ORGANIZATION / RUNNER', "`nSUMMARY ", "`nOrganizations ", "`nLocal ") | ForEach-Object { $report.IndexOf($_) }
    Assert (-not ($tables -contains -1) -and (($tables | Sort-Object) -join ',') -eq ($tables -join ',')) 'overview, runner and summary tables in order'
    $alpha = Get-Block $report 'alpha'; $beta = Get-Block $report 'beta'; $gamma = Get-Block $report 'gamma'; $denied = Get-Block $report 'denied'
    Assert ($report -match '(?m)^ORGANIZATION / RUNNER +GITHUB +BUSY +LOCAL +PID\s*$') 'tree header'
    Assert ($alpha[0].StartsWith("$mid $script:Prefix-1 ") -and $alpha[0] -match ' online +true +running +\d+\s*$') 'online busy listener'
    Assert ($beta.Count -eq 1 -and $beta[0].StartsWith("$end ") -and $beta[0] -match ' offline +false +restarting +\d+\s*$') 'worker without listener is restarting'
    Assert ($gamma[0] -match ' missing +- +paused +-\s*$' -and $gamma[1].StartsWith("$end ") -and $gamma[1] -match ' online +false +other +-\s*$') 'missing ID is not confused with matching name'
    Assert ($denied.Count -eq 1 -and $denied[0] -match ' unknown +\? +stopped +-\s*$') 'API error is unknown'
    $header = @($report -split "`r?`n" | Where-Object { $_ -clike 'ORGANIZATION /*' })[0]
    Assert ($header.IndexOf('GITHUB') -eq $alpha[0].IndexOf('online')) 'columns align with the header'
    Assert ((Has-Line $report (Field 'GitHub' '2 online, 1 offline, 1 missing, 1 unknown; 1 busy')) -and (Has-Line $report (Field 'Local' '1 running, 1 restarting, 3 stopped/paused'))) 'remote and local counts'
    Assert ((Has-Line $report (Field 'Organizations' '4')) -and (Has-Line $report (Field 'Runners' '5')) -and (Has-Line $report (Field 'Runners per organization' '1'))) 'organization and runner counts'
    $alphaRows = @($alpha | ForEach-Object { ($_ -split ' +')[1] })
    Assert (($alphaRows -join ',') -ceq "$script:Prefix-1,$script:Prefix-2,Build-box,local-linux-x64-1,zeta-manual") 'this installation first, in order, then other runners sorted by name'
    Assert ($alpha[1] -match " $script:Prefix-2 +online +false +stopped +-\s*$") 'second runner of the organization'
    Assert ($alpha[2] -match ' Build-box +online +true +other +-\s*$') 'busy runner of another machine'
    Assert ($alpha[3] -match ' local-linux-x64-1 +offline +\? +other +-\s*$') 'other platform runner'
    Assert ($alpha[4].StartsWith("$end zeta-manual ")) 'last runner closes the branch'
    Assert ((Has-Line $report (Field 'Other runners' '4 (3 online, 1 offline); 1 busy'))) 'other runner counts'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'conf/organizations.json')) -ceq $before) 'status leaves registrations unchanged'
    $script:Deny = $false
    Remove-Item -LiteralPath (Join-Path $fixture 'conf/manager.json')
    Write-AtomicText (Join-Path $fixture 'conf/stopped') 'stopped'
    $report = Capture-Status
    Assert (-not $script:StatusFailed -and (Has-Line $report (Field 'Manager' 'stopped (run ghr start to resume)')) -and $report.Contains("$oldWork (last run; manager stopped)")) 'stopped manager retains last-run directory'
    Record-Process (Join-Path $fixture 'conf/manager.json') $current
    Remove-Item -LiteralPath (Join-Path $fixture 'conf/stopped')
    Write-AtomicText (Join-Path $fixture 'conf/active-work-dir') $newWork
    $report = Capture-Status
    Assert ((Has-Line $report (Field 'Jobs directory' (Join-Path $newWork 'jobs'))) -and (Has-Line $report (Field 'Configuration' 'no pending directory change'))) 'applied directory reflected'
    Save-State @{}
    Remove-Item -LiteralPath (Join-Path $fixture 'conf/manager.json'),(Join-Path $fixture 'conf/active-work-dir')
    $report = Capture-Status
    Assert ($report.Contains('configured; not started yet') -and $report.Contains('No runners registered yet.') -and (Has-Line $report (Field 'Organizations' '0'))) 'empty installation still shows overview'
    Write-Host 'PASS Windows status: directories, pending config, process states and GitHub results'
} finally { if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
