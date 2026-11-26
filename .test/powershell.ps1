$ErrorActionPreference = 'Stop'
$onWindows = $env:OS -eq 'Windows_NT'
if (-not $onWindows) { $env:SystemRoot = '/tmp' }
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-ps-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$success = $false
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
try {
    # Test the root entry point with a fake platform installer and download response.
    if ($onWindows) {
        & {
            $saved = @{}
            foreach ($name in @('LOCAL_RUNNER_SOURCE_DIR','LOCAL_RUNNER_BASE_URL','LOCAL_RUNNER_HOME','BOOTSTRAP_RESULT')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
            try {
                $source = Join-Path $fixture 'source tree'
                New-Item -ItemType Directory -Path (Join-Path $source 'windows') -Force | Out-Null
                $env:BOOTSTRAP_RESULT = Join-Path $fixture 'bootstrap-result.json'
                $env:LOCAL_RUNNER_HOME = Join-Path $fixture 'custom home'
                $env:LOCAL_RUNNER_SOURCE_DIR = $source; $env:LOCAL_RUNNER_BASE_URL = $null
                $fakeInstaller = 'param($Architecture); @{arch=$Architecture;source=$env:LOCAL_RUNNER_SOURCE_DIR;root=$env:LOCAL_RUNNER_HOME} | ConvertTo-Json | Set-Content $env:BOOTSTRAP_RESULT'
                Set-Content (Join-Path $source 'windows\install.ps1') $fakeInstaller
                Copy-Item (Join-Path $repo 'install.ps1') (Join-Path $source 'install.ps1')
                & (Join-Path $repo 'install.ps1') -Architecture arm64
                $result = Get-Content -Raw $env:BOOTSTRAP_RESULT | ConvertFrom-Json
                Assert ($result.arch -eq 'arm64' -and $result.source -eq $source -and $result.root -eq $env:LOCAL_RUNNER_HOME) 'source, architecture and install home forwarded'
                $env:LOCAL_RUNNER_SOURCE_DIR = $null
                & (Join-Path $source 'install.ps1') -Architecture x64
                $result = Get-Content -Raw $env:BOOTSTRAP_RESULT | ConvertFrom-Json
                Assert ($result.arch -eq 'x64' -and $result.source -eq $source) 'local checkout discovered'
                Assert (-not $env:LOCAL_RUNNER_SOURCE_DIR) 'source environment restored'
                $env:LOCAL_RUNNER_BASE_URL = 'https://example.invalid/pinned'
                function Invoke-WebRequest {
                    param([switch]$UseBasicParsing, [int]$TimeoutSec, [Parameter(Position=0)][string]$Uri)
                    Assert ($Uri -eq 'https://example.invalid/pinned/windows/install.ps1') 'Windows download URL'
                    return [pscustomobject]@{Content=$fakeInstaller}
                }
                Get-Content -Raw (Join-Path $repo 'install.ps1') | Invoke-Expression
                $result = Get-Content -Raw $env:BOOTSTRAP_RESULT | ConvertFrom-Json
                Assert ($result.arch -eq 'auto' -and -not $result.source) 'piped entry point uses requested remote source'
                Remove-Item $env:BOOTSTRAP_RESULT
                function Invoke-WebRequest { throw 'Simulated download failure' }
                $failed = $false; try { & (Join-Path $repo 'install.ps1') } catch { $failed = $true }
                Assert ($failed -and -not (Test-Path $env:BOOTSTRAP_RESULT)) 'failed download never executed'
                $env:LOCAL_RUNNER_SOURCE_DIR = $source
                Set-Content (Join-Path $source 'windows\install.ps1') 'throw "Simulated installer failure"'
                $failed = $false; try { & (Join-Path $repo 'install.ps1') } catch { $failed = $true }
                Assert $failed 'platform failure propagated'
            } finally {
                foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
            }
        }
    } else {
        $failed = $false; try { & (Join-Path $repo 'install.ps1') } catch { $failed = $true }
        Assert $failed 'PowerShell entry point rejects non-Windows'
    }
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
        foreach ($part in @('conf','bin\alpha\runner','data\alpha\repo','logs')) { New-Item -ItemType Directory -Force -Path (Join-Path $legacy $part) | Out-Null }
        Set-Content (Join-Path $legacy 'conf\settings.json') '{}'
        Set-Content (Join-Path $legacy 'conf\organizations.json') '{"1":{"login":"alpha","runner_id":100,"runner_name":"local-windows-x64-3"}}'
        Set-Content (Join-Path $legacy 'data\alpha\repo\.hidden') 'keep'
        Set-Content (Join-Path $legacy 'bin\alpha\runner\.credentials') 'credential'
        Set-Content (Join-Path $legacy 'bin\alpha\runner\.runner') '{"agentId":100}'
        Set-Content (Join-Path $legacy 'bin\service.ps1') 'old script'
        Set-Content (Join-Path $legacy 'bin\install.ps1') 'old script'
        Move-PreviousLayout $upgradeRoot $arch
        Assert (-not (Test-Path $legacy)) 'architecture directory removed'
        Assert (Test-Path (Join-Path $upgradeRoot 'bin\service.ps1')) 'old script retained until update'
        Assert ((Get-Content (Join-Path $upgradeRoot 'data\alpha\repo\.hidden')) -eq 'keep') 'work data preserved'
        Assert ((Get-Content (Join-Path $upgradeRoot 'runner\alpha\app\.credentials')) -eq 'credential') 'credentials preserved'
        Assert ((Get-Content -Raw (Join-Path $upgradeRoot 'runner\alpha\app\.runner') | ConvertFrom-Json).agentId -eq 100) 'runner moved to dedicated directory'
        $migrated = Get-Content -Raw (Join-Path $upgradeRoot 'conf\organizations.json') | ConvertFrom-Json
        Assert ($migrated.'1'.runner_id -eq 100 -and $migrated.'1'.runner_name -eq 'local-windows-x64-3') 'identity preserved for reconfiguration'
        Move-PreviousLayout $upgradeRoot $arch
    }
    $conflictRoot = Join-Path $fixture 'conflicting-layout'
    New-Item -ItemType Directory -Force -Path (Join-Path $conflictRoot 'x64\conf'),(Join-Path $conflictRoot 'data') | Out-Null
    Set-Content (Join-Path $conflictRoot 'x64\conf\settings.json') '{}'
    $failed = $false; try { Move-PreviousLayout $conflictRoot 'x64' } catch { $failed = $true }
    Assert $failed 'conflicting layouts not merged'
    Assert (Test-Path (Join-Path $conflictRoot 'x64\conf\settings.json')) 'conflicting layout retained'
    foreach ($arch in @('x64','arm64')) {
        $testRoot = Join-Path $fixture $arch
        New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'bin'), (Join-Path $testRoot 'conf') | Out-Null
        Copy-Item (Join-Path $repo 'windows\service.ps1') (Join-Path $testRoot 'bin\service.ps1')
        Copy-Item (Join-Path $repo 'windows\runner.ps1') (Join-Path $testRoot 'bin\runner.ps1')
        Copy-Item (Join-Path $repo 'windows\ghr.ps1') (Join-Path $testRoot 'bin\ghr.ps1')
        $env:LOCAL_RUNNER_ROOT = $testRoot
        . (Join-Path $testRoot 'bin\ghr.ps1') -Command library
        if (-not $onWindows) { $script:PowerShell = (Get-Process -Id $PID).Path }
        Write-Json (Join-Path $testRoot 'conf\settings.json') @{ arch=$arch; poll_seconds=10; restart_seconds=1; organizations=@() }
        Write-AtomicText (Join-Path $testRoot 'conf\gh-path') $script:PowerShell
        Write-AtomicText (Join-Path $testRoot 'conf\github-token') 'secret-test-token'
        Initialize-Manager
        $unicodePath = 'C:\' + [char]0x5DE5 + [char]0x4F5C
        Write-Json (Join-Path $testRoot 'conf\unicode.json') @{ path=$unicodePath }
        Assert ((Read-Json (Join-Path $testRoot 'conf\unicode.json')).path -ceq $unicodePath) 'UTF-8 paths round-trip'
        $script:Remote = @{}; $script:NextId = 100; $script:FailDiscovery = $false; $script:Raced = $false
        $script:Members = @(@{ state='active'; organization=@{id=1;login='alpha'} })
        function Invoke-GitHubApi([string]$Endpoint, [string]$Method='GET', [switch]$Paginate) {
            if ($Endpoint -match '^organizations/(\d+)$') { return [pscustomobject]@{id=[long]$Matches[1];login=(Get-State)[$Matches[1]].login} }
            if ($Endpoint -like 'user/memberships/*') {
                if ($script:FailDiscovery) { throw 'Simulated network failure' }
                return ,@($script:Members)
            }
            if ($Endpoint -like 'orgs/denied/*') { throw 'HTTP 403: Resource not accessible by integration' }
            if ($Endpoint -match '^orgs/([^/]+)/actions/runners\?') {
                $runners = @($script:Remote[$Matches[1]]) | Where-Object { $null -ne $_ }
                return ,@([pscustomobject]@{runners=@($runners | Select-Object -First 1)},[pscustomobject]@{runners=@($runners | Select-Object -Skip 1)})
            }
            if ($Endpoint -match '^orgs/([^/]+)/actions/runners/(\d+)$' -and $Method -eq 'DELETE') {
                if ($script:FailDelete) { throw 'Simulated deletion failure.' }
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
            $directory = Join-Path $script:Root "runner\$Login\app"
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
        Remove-Item (Join-Path $testRoot 'runner\alpha\app\.runner') -Force; Invoke-Reconcile
        Assert ($script:NextId -eq 103) 'missing local configuration recovery'
        Write-AtomicText (Join-Path $testRoot 'data\alpha\keep') 'keep'
        $script:Members = @(@{state='active';organization=@{id=1;login='renamed'}})
        $script:Remote.renamed = $script:Remote.alpha; $script:Remote.Remove('alpha')
        $script:Remote.renamed[0].busy = $true; Invoke-Reconcile
        Assert ((Get-State)['1'].login -eq 'alpha') 'busy rename deferred'
        $script:Remote.renamed[0].busy = $false; Invoke-Reconcile
        Assert ((Get-State)['1'].login -eq 'renamed') 'organization renamed'
        Assert (Test-Path (Join-Path $testRoot 'data\alpha\keep')) 'old data retained'
        Assert (-not (Test-Path (Join-Path $testRoot 'runner\alpha')) -and (Test-Path (Join-Path $testRoot 'runner\renamed\app'))) 'rename moves the program directory'
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
        $directory = Join-Path $testRoot 'runner\legacy\app'; New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Write-Json (Join-Path $directory '.runner') @{agentId=996}
        $state = Get-State; $state['7'] = @{login='legacy';runner_id=996;runner_name=$script:Prefix}; Save-State $state
        Reconcile-Organization '7' 'legacy'
        Assert ($script:Remote.legacy[0].name -eq $script:Prefix) 'busy legacy upgrade deferred'
        $script:Remote.legacy[0].busy = $false; Reconcile-Organization '7' 'legacy'
        Assert ($script:Remote.legacy.Count -eq 1 -and $script:Remote.legacy[0].name -eq "$script:Prefix-1") 'idle legacy name upgraded'
        $failed = $false; try { Reconcile-Organization '4' '../escape' } catch { $failed = $true }
        Assert $failed 'invalid organization rejected'
        # An organization without runner permission backs off instead of failing every poll.
        $script:Members = @(@{state='active';organization=@{id=1;login='renamed'}}, @{state='active';organization=@{id=8;login='denied'}})
        $backoff = Join-Path $testRoot 'conf\backoff\8.json'
        Invoke-Reconcile
        Assert ((Read-Json $backoff).count -eq 1) 'failing organization backs off'
        Invoke-Reconcile
        Assert ((Read-Json $backoff).count -eq 1) 'backoff skips retries until due'
        Write-Json $backoff @{ after=0; count=1 }; Invoke-Reconcile
        Assert ((Read-Json $backoff).count -eq 2 -and [long](Read-Json $backoff).after -gt [DateTime]::UtcNow.AddSeconds(15).Ticks) 'backoff grows after repeated failure'
        # Exercise real native argument quoting and removal of management credentials.
        $probe = Join-Path $testRoot 'argument probe.ps1'
        Write-AtomicText $probe '[pscustomobject]@{values=@($args);token=$env:GH_TOKEN}|ConvertTo-Json -Compress'
        $env:GH_TOKEN = 'should-not-reach-runner'
        $arguments = @('a b','x"y','C:\trailing\')
        $output = Invoke-Native $script:PowerShell (@('-NoProfile','-File',$probe) + $arguments)
        $parsed = $output | ConvertFrom-Json
        Assert (($parsed.values | ConvertTo-Json -Compress) -eq ($arguments | ConvertTo-Json -Compress)) 'native argument quoting'
        Assert (-not $parsed.token) 'credential environment excluded'
        $failing = Join-Path $testRoot 'failing probe.ps1'
        Write-AtomicText $failing '[Console]::Error.WriteLine("bad token super-secret-value"); exit 3'
        $message = ''; try { $null = Invoke-Native $script:PowerShell @('-NoProfile','-File',$failing) -Redact @('super-secret-value') } catch { $message = $_.Exception.Message }
        Assert ($message -match 'exit 3' -and $message -match 'bad token \*\*\*' -and $message -notmatch 'super-secret') 'native failure explains itself without secrets'
        # Exercise actual wrapper restart, without real GitHub runners or host services.
        if ($onWindows) {
        Remove-Item Env:LOCAL_RUNNER_ROOT
        $runner = Join-Path $testRoot 'runner\renamed\app'
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
        # The installer stops any state layout with the new script, not the installed copy.
        $legacyState = Join-Path $fixture "legacy state $arch"
        New-Item -ItemType Directory -Force -Path (Join-Path $legacyState 'workers') | Out-Null
        $sleeper = [Diagnostics.Process]::Start((New-ProcessInfo $script:PowerShell @('-NoProfile','-Command','Start-Sleep -Seconds 60')))
        Record-Process (Join-Path $legacyState 'workers\9.json') $sleeper
        $null = Invoke-Native $script:PowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repo 'windows\service.ps1'),'-Mode','Stop','-Root',$testRoot,'-StateDir',$legacyState)
        Assert ($sleeper.WaitForExit(10000) -and -not (Test-Path (Join-Path $legacyState 'workers\9.json'))) 'stop mode works from an explicit state directory'
        }
        $script:Members = @(); Invoke-Reconcile
        Assert (@((Get-State).Values | Where-Object active -ne $false).Count -eq 0) 'removed membership stopped and retained for uninstall'
        Assert (Test-Path (Join-Path $testRoot 'data\alpha\keep')) 'data retained after removal'
        Invoke-Reconcile
        Assert (@(Select-String -LiteralPath (Join-Path $testRoot 'logs\service.log') -SimpleMatch 'Stopped organization 3;').Count -eq 1) 'deactivation logged once'
        $text = Get-Content -Raw (Join-Path $testRoot 'logs\service.log')
        Assert ($text -notmatch 'secret-test-token|should-not-reach-runner') 'no credential log leak'
        # Exercise management with real child processes and a fake scheduled task.
        function Assert-Administrator {}
        function Grant-DataDirectory([string]$Directory) { New-Item -ItemType Directory -Force -Path $Directory | Out-Null }
        if (-not $onWindows) { function Protect-AdminFile([string]$Path) {} }
        $script:TaskExists = $true; $script:TaskEnabled = $false; $script:FailDelete = $false
        function Get-ScheduledTask { if ($script:TaskExists) { return [pscustomobject]@{TaskName='fixture';Actions=[pscustomobject]@{Arguments=('-File "' + (Join-Path $script:Root 'bin\service.ps1') + '"')}} } }
        function Disable-ScheduledTask { $script:TaskEnabled = $false }
        function Enable-ScheduledTask { $script:TaskEnabled = $true }
        function Stop-ScheduledTask { Stop-Record (Join-Path $script:Root 'conf\manager.json') }
        function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm); $script:TaskExists = $false }
        function Start-ScheduledTask {
            $info = New-ProcessInfo $script:PowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Root 'bin\service.ps1'))
            $script:SupervisorProcess = [Diagnostics.Process]::Start($info)
        }
        Show-Status
        $launcher = Join-Path $testRoot 'bin\ghr.cmd'; Write-AtomicText $launcher (Get-CommandText)
        $newWork = Join-Path $fixture "new work $arch"
        if ($onWindows) {
            $state = Get-State; $state['1'].active = $true; Save-State $state
            Start-Installation
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while ($null -eq (Get-RecordedProcess (Join-Path $testRoot 'conf\manager.json')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Assert ($script:TaskEnabled) 'start enables startup'
            $defaultWork = Join-Path $fixture "default work $arch"
            New-Item -ItemType Directory -Path $defaultWork | Out-Null
            Push-Location $defaultWork
            try {
                foreach ($flag in @('--dir','-d')) {
                    & $launcher config $flag
                    Assert ($LASTEXITCODE -eq 0 -and (Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq $defaultWork) 'omitted path uses current directory'
                }
            } finally { Pop-Location }
            & $launcher config -d "$newWork-short"
            Assert ($LASTEXITCODE -eq 0 -and (Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq "$newWork-short") 'public -d syntax with spaces in path'
            & $launcher config --dir $newWork
            Assert ($LASTEXITCODE -eq 0 -and (Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq $newWork) 'public --dir space syntax with spaces in path'
            $failed = $false
            try { $null = Invoke-Native $script:PowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $testRoot 'bin\ghr.ps1'),'config',"--dir=$newWork-equals") } catch { $failed = $true }
            Assert ($failed -and -not (Test-Path "$newWork-equals")) 'removed --dir= syntax rejected without creating directory'
            Assert ((Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq $newWork) 'invalid syntax leaves configuration unchanged'
            Assert ((Get-Content -Raw -Encoding UTF8 (Join-Path $testRoot 'conf\active-work-dir')) -eq $testRoot) 'configuration remains pending'
            Stop-Installation; Start-Installation
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 100
                $current = Read-Json (Join-Path $testRoot 'runner\renamed\app\.runner')
            } while ($current.workFolder -ne (Join-Path $newWork 'data\renamed') -and [DateTime]::UtcNow -lt $deadline)
            Assert ($current.workFolder -eq (Join-Path $newWork 'data\renamed')) 'restart applies work folder'
            Stop-Installation
            Assert (-not $script:TaskEnabled -and $null -eq (Get-RecordedProcess (Join-Path $testRoot 'conf\manager.json'))) 'stop disables watchdog and kills manager'
            $info = New-ProcessInfo $script:PowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $testRoot 'bin\ghr.ps1'),'logs','-f')
            $info.RedirectStandardOutput = $true
            $follower = [Diagnostics.Process]::Start($info); $followed = $follower.StandardOutput.ReadToEndAsync()
            $followerRecord = Join-Path $fixture 'follower.json'; Record-Process $followerRecord $follower
            Start-Sleep -Milliseconds 800
            $previousLogDir = $script:LogDir; $script:LogDir = Join-Path $newWork 'logs'
            Write-Log 'follow-marker'
            Start-Sleep -Milliseconds 800
            Move-Item (Join-Path $newWork 'logs\service.log') (Join-Path $newWork 'logs\service.log.rotated')
            Write-Log 'rotation-marker'
            Start-Sleep -Milliseconds 800
            Stop-Record $followerRecord; $follower.WaitForExit()
            $captured = $followed.GetAwaiter().GetResult(); $follower.Dispose()
            $script:LogDir = $previousLogDir
            Assert ($captured -match 'follow-marker' -and $captured -match 'rotation-marker') 'logs follow new lines across rotation'
        } else {
            Set-WorkDirectory $newWork
            Assert ($script:WorkDir -eq $testRoot) 'configuration does not change running settings'
            Assert ((Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq $newWork) 'new directory saved'
        }
        $script:FailDelete = $true; $failed = $false
        try { Uninstall-Runner } catch { $failed = $true }
        Assert ($failed -and (Test-Path (Join-Path $testRoot 'conf\github-token'))) 'failed unregister retains credentials'
        $script:FailDelete = $false; Uninstall-Runner
        Assert (-not (Test-Path (Join-Path $testRoot 'conf')) -and -not (Test-Path (Join-Path $testRoot 'runner')) -and -not (Test-Path $launcher)) 'uninstall removes runtime and command'
        Assert (Test-Path (Join-Path $testRoot 'data\alpha\keep')) 'uninstall preserves work data'
        Assert (@($script:Remote.beta | Where-Object id -eq 999).Count -eq 1) 'uninstall preserves other machines'
        if ($onWindows) { Write-Host "PASS windows/${arch}: core logic, quoting, native worker restart and cleanup" }
        else { Write-Host "PASS windows/${arch}: core logic and quoting; native Windows worker test is deferred to CI" }
    }
    $success = $true
} finally {
    if (Get-Command Stop-Record -ErrorAction SilentlyContinue) {
        try { Stop-Record (Join-Path $script:Root 'conf\manager.json'); Stop-Record (Join-Path $fixture 'follower.json') } catch {}
    }
    if (Get-Command Stop-Worker -ErrorAction SilentlyContinue) { foreach ($id in @('1','2','3')) { try { Stop-Worker $id } catch {} } }
    Remove-Item Env:LOCAL_RUNNER_ROOT,Env:FAKE_RUN_MARKER,Env:GH_TOKEN -ErrorAction SilentlyContinue
    if ($success) { Remove-Item $fixture -Recurse -Force } else { Write-Host "Retained fixture: $fixture" }
}
