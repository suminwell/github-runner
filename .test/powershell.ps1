$ErrorActionPreference = 'Stop'
$onWindows = $env:OS -eq 'Windows_NT'
if (-not $onWindows) { $env:SystemRoot = '/tmp' }
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-ps-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$success = $false
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
try {
    # Load only installer helper definitions, without administrator/host operations.
    $tokens = $null; $errors = $null
    $installer = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'windows\install.ps1'), [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'installer syntax'
    foreach ($name in @('Get-NativeArchitecture','Move-PreviousLayout')) {
        $definition = $installer.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Get-ItemProperty { return [pscustomobject]@{PROCESSOR_ARCHITECTURE=$script:NativeArch} }
    $script:NativeArch = 'AMD64'; Assert ((Get-NativeArchitecture) -eq 'x64') 'native x64 detected'
    $script:NativeArch = 'ARM64'; Assert ((Get-NativeArchitecture) -eq 'arm64') 'native ARM64 detected'
    $script:NativeArch = 'x86'; $failed = $false; try { Get-NativeArchitecture } catch { $failed = $true }
    Assert $failed 'unsupported architecture rejected'
    Remove-Item Function:Get-ItemProperty
    foreach ($arch in @('x64','arm64')) {
        $upgradeRoot = Join-Path $fixture "upgrade-$arch"; $legacy = Join-Path $upgradeRoot $arch
        foreach ($part in @('.state','bin\alpha\runner','data\alpha\repo','logs')) { New-Item -ItemType Directory -Force -Path (Join-Path $legacy $part) | Out-Null }
        Set-Content (Join-Path $legacy '.state\settings.json') '{}'
        Set-Content (Join-Path $legacy '.state\organizations.json') '{"1":{"login":"alpha","runner_id":100,"runner_name":"local-windows-x64-3"}}'
        Set-Content (Join-Path $legacy 'data\alpha\repo\.hidden') 'keep'
        Set-Content (Join-Path $legacy 'bin\alpha\runner\.credentials') 'credential'
        Set-Content (Join-Path $legacy 'bin\service.ps1') 'old script'
        Set-Content (Join-Path $legacy 'bin\install.ps1') 'old script'
        Move-PreviousLayout $upgradeRoot $arch
        Assert (-not (Test-Path $legacy)) 'architecture directory removed'
        Assert (-not (Test-Path (Join-Path $upgradeRoot 'bin\service.ps1'))) 'old script removed'
        Assert ((Get-Content (Join-Path $upgradeRoot 'data\alpha\repo\.hidden')) -eq 'keep') 'work data preserved'
        Assert ((Get-Content (Join-Path $upgradeRoot 'bin\alpha\runner\.credentials')) -eq 'credential') 'credentials preserved'
        $migrated = Get-Content -Raw (Join-Path $upgradeRoot '.state\organizations.json') | ConvertFrom-Json
        Assert ($migrated.'1'.relocated -and $migrated.'1'.runner_id -eq 100 -and $migrated.'1'.runner_name -eq 'local-windows-x64-3') 'identity preserved for reconfiguration'
        Move-PreviousLayout $upgradeRoot $arch
    }
    $conflictRoot = Join-Path $fixture 'conflicting-layout'
    New-Item -ItemType Directory -Force -Path (Join-Path $conflictRoot 'x64\.state'),(Join-Path $conflictRoot 'data') | Out-Null
    Set-Content (Join-Path $conflictRoot 'x64\.state\settings.json') '{}'
    $failed = $false; try { Move-PreviousLayout $conflictRoot 'x64' } catch { $failed = $true }
    Assert $failed 'conflicting layouts not merged'
    Assert (Test-Path (Join-Path $conflictRoot 'x64\.state\settings.json')) 'conflicting layout retained'
    foreach ($arch in @('x64','arm64')) {
        $testRoot = Join-Path $fixture $arch
        New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'bin'), (Join-Path $testRoot '.state') | Out-Null
        Copy-Item (Join-Path $repo 'windows\service.ps1') (Join-Path $testRoot 'service.ps1')
        $env:LOCAL_RUNNER_ROOT = $testRoot
        . (Join-Path $testRoot 'service.ps1') -Mode Library -Root $testRoot
        if (-not $onWindows) { $script:PowerShell = (Get-Process -Id $PID).Path }
        Write-Json (Join-Path $testRoot '.state\settings.json') @{ arch=$arch; poll_seconds=10; restart_seconds=1; organizations=@() }
        Write-AtomicText (Join-Path $testRoot '.state\gh-path') $script:PowerShell
        Write-AtomicText (Join-Path $testRoot '.state\github-token') 'secret-test-token'
        Initialize-Manager
        $unicodePath = 'C:\' + [char]0x5DE5 + [char]0x4F5C
        Write-Json (Join-Path $testRoot '.state\unicode.json') @{ path=$unicodePath }
        Assert ((Read-Json (Join-Path $testRoot '.state\unicode.json')).path -ceq $unicodePath) 'UTF-8 paths round-trip'
        $script:Remote = @{}; $script:NextId = 100; $script:FailDiscovery = $false; $script:Raced = $false
        $script:Members = @(@{ state='active'; organization=@{id=1;login='alpha'} })
        function Invoke-GitHubApi([string]$Endpoint, [string]$Method='GET', [switch]$Paginate) {
            if ($Endpoint -like 'user/memberships/*') {
                if ($script:FailDiscovery) { throw 'Simulated network failure' }
                return ,@($script:Members)
            }
            if ($Endpoint -match '^orgs/([^/]+)/actions/runners\?') {
                $runners = @($script:Remote[$Matches[1]]) | Where-Object { $null -ne $_ }
                return ,@([pscustomobject]@{runners=@($runners | Select-Object -First 1)},[pscustomobject]@{runners=@($runners | Select-Object -Skip 1)})
            }
            if ($Endpoint -match '^orgs/([^/]+)/actions/runners/(\d+)$' -and $Method -eq 'DELETE') {
                $script:Remote[$Matches[1]] = @($script:Remote[$Matches[1]] | Where-Object id -ne ([long]$Matches[2]))
                return $null
            }
            throw "Unexpected fake API endpoint: $Endpoint"
        }
        function Register-Runner([string]$Login, [string]$Name) {
            if ($Login -eq 'race' -and -not $script:Raced) {
                $script:Raced = $true
                $script:Remote.race = @([pscustomobject]@{id=997;name=$Name;busy=$false})
                throw 'Another installation took this number.'
            }
            if (@($script:Remote[$Login] | Where-Object name -eq $Name).Count) { throw 'Name already exists.' }
            $runnerId = $script:NextId; $script:NextId++
            $directory = Join-Path $script:Root "bin\$Login\runner"
            New-Item -ItemType Directory -Force -Path $directory, (Join-Path $script:Root "data\$Login") | Out-Null
            Write-Json (Join-Path $directory '.runner') @{agentId=$runnerId;agentName=$Name}
            $script:Remote[$Login] = @($script:Remote[$Login] | Where-Object { $null -ne $_ }) + @([pscustomobject]@{id=$runnerId; name=$Name; busy=$false; status='online'})
            if ($Login -eq 'partial') { throw 'Reported failure after registration.' }
            return $runnerId
        }
        Invoke-Reconcile
        Assert ((Get-State)['1'].runner_id -eq 100) 'registration persisted'
        Assert ($script:Remote.alpha[0].name -eq "$script:Prefix-1") 'architecture name and first index'
        Assert ((Get-State)['1'].runner_name -eq "$script:Prefix-1") 'name persisted'
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
        $script:Remote.beta = @([pscustomobject]@{id=999;name="local-windows-$otherArch-50";busy=$false})
        Reconcile-Organization '2' 'beta'
        Assert ($script:Remote.beta.Count -eq 2) 'other architecture does not conflict'
        Assert ($script:Remote.beta[-1].name -eq "$script:Prefix-1") 'per-organization sequence'
        $script:Remote.collision = @(
            [pscustomobject]@{id=998;name="$script:Prefix-1";busy=$false},
            [pscustomobject]@{id=990;name="$script:Prefix-3";busy=$false},
            [pscustomobject]@{id=991;name="$script:Prefix-10";busy=$false;status='offline'},
            [pscustomobject]@{id=992;name="$script:Prefix-99-extra";busy=$false},
            [pscustomobject]@{id=993;name='unrelated-100';busy=$false}
        )
        Reconcile-Organization '3' 'collision'
        Assert ($script:Remote.collision[-1].name -eq "$script:Prefix-11") 'maximum numeric index across pages including offline runners'
        Assert ($script:Remote.collision[0].id -eq 998) 'other machine retained'
        $previous = $script:NextId; Reconcile-Organization '3' 'collision'
        Assert ($script:NextId -eq $previous) 'number stable after restart'
        Reconcile-Organization '5' 'race'
        Assert ($script:Remote.race[-1].name -eq "$script:Prefix-2" -and $script:Remote.race[0].id -eq 997) 'concurrent allocation retries without replacing'
        Reconcile-Organization '6' 'partial'
        Assert ((Get-State)['6'].runner_name -eq "$script:Prefix-1") 'partial registration recovered'
        $state = Get-State; $state['3'] | Add-Member -NotePropertyName relocated -NotePropertyValue $true; Save-State $state
        Reconcile-Organization '3' 'collision'
        Assert ((Get-State)['3'].runner_name -eq "$script:Prefix-11" -and -not (Get-State)['3'].relocated) 'relocation keeps the number'
        ($script:Remote.collision | Where-Object name -eq "$script:Prefix-11").id = 995
        Reconcile-Organization '3' 'collision'
        Assert ($script:Remote.collision[-1].name -eq "$script:Prefix-12" -and @($script:Remote.collision | Where-Object id -eq 995).Count -eq 1) 'taken repair number increments without replacing'
        $script:Remote.legacy = @([pscustomobject]@{id=996;name=$script:Prefix;busy=$true})
        $directory = Join-Path $testRoot 'bin\legacy\runner'; New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Write-Json (Join-Path $directory '.runner') @{agentId=996}
        $state = Get-State; $state['7'] = @{login='legacy';runner_id=996;runner_name=$script:Prefix}; Save-State $state
        Reconcile-Organization '7' 'legacy'
        Assert ($script:Remote.legacy[0].name -eq $script:Prefix) 'busy legacy upgrade deferred'
        $script:Remote.legacy[0].busy = $false; Reconcile-Organization '7' 'legacy'
        Assert ($script:Remote.legacy.Count -eq 1 -and $script:Remote.legacy[0].name -eq "$script:Prefix-1") 'idle legacy name upgraded'
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
        Remove-Item Env:LOCAL_RUNNER_ROOT
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
