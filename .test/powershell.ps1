$ErrorActionPreference = 'Stop'
$onWindows = $env:OS -eq 'Windows_NT'
if (-not $onWindows) { $env:SystemRoot = '/tmp' }
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-ps-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$success = $false
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
try {
    foreach ($arch in @('x64','arm64')) {
        $testRoot = Join-Path $fixture $arch
        New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'bin'), (Join-Path $testRoot '.state') | Out-Null
        Copy-Item (Join-Path $repo "windows\$arch\bin\service.ps1") (Join-Path $testRoot 'bin\service.ps1')
        $env:LOCAL_RUNNER_ROOT = $testRoot
        . (Join-Path $testRoot 'bin\service.ps1') -Mode Library -Root $testRoot
        if (-not $onWindows) { $script:PowerShell = (Get-Process -Id $PID).Path }
        Write-Json (Join-Path $testRoot '.state\settings.json') @{ arch=$arch; poll_seconds=10; restart_seconds=1; organizations=@() }
        Write-AtomicText (Join-Path $testRoot '.state\gh-path') $script:PowerShell
        Write-AtomicText (Join-Path $testRoot '.state\github-token') 'secret-test-token'
        Initialize-Manager
        $script:Remote = @{}; $script:NextId = 100; $script:FailDiscovery = $false
        $script:Members = @(@{ state='active'; organization=@{id=1;login='alpha'} })
        function Invoke-GitHubApi([string]$Endpoint, [string]$Method='GET', [switch]$Paginate) {
            if ($Endpoint -like 'user/memberships/*') {
                if ($script:FailDiscovery) { throw 'Simulated network failure' }
                return ,@($script:Members)
            }
            if ($Endpoint -match '^orgs/([^/]+)/actions/runners\?') {
                return ,@([pscustomobject]@{runners=@($script:Remote[$Matches[1]]) | Where-Object { $null -ne $_ }})
            }
            if ($Endpoint -match '^orgs/([^/]+)/actions/runners/(\d+)$' -and $Method -eq 'DELETE') {
                $script:Remote[$Matches[1]] = @($script:Remote[$Matches[1]] | Where-Object id -ne ([long]$Matches[2]))
                return $null
            }
            throw "Unexpected fake API endpoint: $Endpoint"
        }
        function Register-Runner([string]$Login) {
            $runnerId = $script:NextId; $script:NextId++
            $directory = Join-Path $script:Root "bin\$Login\runner"
            New-Item -ItemType Directory -Force -Path $directory, (Join-Path $script:Root "data\$Login") | Out-Null
            Write-Json (Join-Path $directory '.runner') @{agentId=$runnerId}
            $script:Remote[$Login] = @($script:Remote[$Login] | Where-Object { $null -ne $_ }) + @([pscustomobject]@{id=$runnerId; name=$script:Name; busy=$false; status='online'})
            return $runnerId
        }
        Invoke-Reconcile
        Assert ((Get-State)['1'].runner_id -eq 100) 'registration persisted'
        Assert ($script:Remote.alpha[0].name -eq "local-windows-$arch") 'architecture name'
        Invoke-Reconcile
        Assert ($script:NextId -eq 101) 'idempotency'
        $script:FailDiscovery = $true
        $failed = $false; try { Invoke-Reconcile } catch { $failed = $true }
        Assert $failed 'network failure propagated'
        Assert ((Get-State).ContainsKey('1')) 'network failure retains state'
        $script:FailDiscovery = $false
        $script:Remote.alpha = @(); Invoke-Reconcile
        Assert ($script:NextId -eq 102) 'remote deletion recovery'
        Remove-Item (Join-Path $testRoot 'bin\alpha\runner\.runner') -Force; Invoke-Reconcile
        Assert ($script:NextId -eq 103) 'missing local configuration recovery'
        Write-AtomicText (Join-Path $testRoot 'data\alpha\keep') 'keep'
        $script:Members = @(@{state='active';organization=@{id=1;login='renamed'}})
        $script:Remote.renamed = $script:Remote.alpha; $script:Remote.Remove('alpha')
        $script:Remote.renamed[0].busy = $true; Invoke-Reconcile
        Assert ((Get-State)['1'].login -eq 'alpha') 'busy rename deferred'
        $script:Remote.renamed[0].busy = $false; Invoke-Reconcile
        Assert ((Get-State)['1'].login -eq 'renamed') 'organization renamed'
        Assert (Test-Path (Join-Path $testRoot 'data\alpha\keep')) 'old data retained'
        Save-State @{}; $previous = $script:NextId; Invoke-Reconcile
        Assert ($script:NextId -eq $previous) 'registration recovered after state loss'
        $otherArch = if ($arch -eq 'x64') { 'arm64' } else { 'x64' }
        $script:Remote.beta = @([pscustomobject]@{id=999;name="local-windows-$otherArch";busy=$false})
        Reconcile-Organization '2' 'beta'
        Assert ($script:Remote.beta.Count -eq 2) 'other architecture does not conflict'
        $script:Remote.collision = @([pscustomobject]@{id=998;name=$script:Name;busy=$false})
        $failed = $false; try { Reconcile-Organization '3' 'collision' } catch { $failed = $true }
        Assert $failed 'same architecture collision rejected'
        $failed = $false; try { Reconcile-Organization '4' '../escape' } catch { $failed = $true }
        Assert $failed 'invalid organization rejected'
        # Exercise real native argument quoting and removal of management credentials.
        $probe = Join-Path $testRoot 'argument probe.ps1'
        Write-AtomicText $probe '[pscustomobject]@{values=@($args);token=$env:GH_TOKEN}|ConvertTo-Json -Compress'
        $env:GH_TOKEN = 'should-not-reach-runner'
        $arguments = @('a b','x"y','C:\trailing\')
        $output = Invoke-Native $script:PowerShell (@('-NoProfile','-File',$probe) + $arguments)
        $parsed = $output | ConvertFrom-Json
        Assert (($parsed.values | ConvertTo-Json -Compress) -eq ($arguments | ConvertTo-Json -Compress)) 'native argument quoting'
        Assert (-not $parsed.token) 'credential environment excluded'
        # Exercise actual wrapper restart, without real GitHub runners or host services.
        if ($onWindows) {
        $runner = Join-Path $testRoot 'bin\renamed\runner'
        $env:FAKE_RUN_MARKER = Join-Path $testRoot 'runs'
        Write-AtomicText (Join-Path $runner 'probe.ps1') 'if($env:GH_TOKEN){exit 92}; Add-Content -LiteralPath $env:FAKE_RUN_MARKER -Value run; Start-Sleep -Milliseconds 200'
        Write-AtomicText (Join-Path $runner 'run.cmd') "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File probe.ps1`r`nexit /b %ERRORLEVEL%`r`n"
        Start-Worker '1' 'renamed'
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 200
            $runs = if (Test-Path $env:FAKE_RUN_MARKER) { @(Get-Content $env:FAKE_RUN_MARKER).Count } else { 0 }
        } while ($runs -lt 2 -and [DateTime]::UtcNow -lt $deadline)
        Assert ($runs -ge 2) 'worker restarts exited listener'
        Stop-Worker '1'
        }
        $script:Members = @(); Invoke-Reconcile
        Assert ((Get-State).Count -eq 0) 'removed membership stopped'
        Assert (Test-Path (Join-Path $testRoot 'data\alpha\keep')) 'data retained after removal'
        $text = Get-Content -Raw (Join-Path $testRoot 'logs\service.log')
        Assert ($text -notmatch 'secret-test-token|should-not-reach-runner') 'no credential log leak'
        if ($onWindows) { Write-Host "PASS windows/${arch}: core logic, quoting, native worker restart and cleanup" }
        else { Write-Host "PASS windows/${arch}: core logic and quoting; native Windows worker test is deferred to CI" }
    }
    $success = $true
} finally {
    if (Get-Command Stop-Worker -ErrorAction SilentlyContinue) { foreach ($id in @('1','2','3')) { try { Stop-Worker $id } catch {} } }
    Remove-Item Env:LOCAL_RUNNER_ROOT,Env:FAKE_RUN_MARKER,Env:GH_TOKEN -ErrorAction SilentlyContinue
    if ($success) { Remove-Item $fixture -Recurse -Force } else { Write-Host "Retained fixture: $fixture" }
}
