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
    foreach ($name in @('Get-NativeArchitecture')) {
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
        # A runner/PID record may disappear after the existence check. Force that
        # ordering at the filesystem boundary while exercising the real reader.
        & {
            $vanishing = Join-Path $testRoot 'conf\vanishing.json'
            Write-Json $vanishing @{ value=1 }
            function Get-Content {
                param([switch]$Raw, [string]$Encoding, [string]$LiteralPath)
                Remove-Item -LiteralPath $LiteralPath -Force
                Microsoft.PowerShell.Management\Get-Content -Raw -Encoding $Encoding -LiteralPath $LiteralPath
            }
            Assert ($null -eq (Read-Json $vanishing)) 'record removed during read is absent, not a fatal error'
            # Opened while File.Replace swaps it in: the provider reports a file, not an item.
            function Get-Content { param([switch]$Raw, [string]$Encoding, [string]$LiteralPath); throw (New-Object IO.FileNotFoundException('Could not find file', $LiteralPath)) }
            Write-Json $vanishing @{ value=1 }
            Assert ($null -eq (Read-Json $vanishing)) 'record replaced during read is absent, not a fatal error'
        }
        $invalidJson = Join-Path $testRoot 'conf\invalid.json'
        Write-AtomicText $invalidJson '{invalid'
        $failed = $false; try { $null = Read-Json $invalidJson } catch { $failed = $true }
        Assert $failed 'malformed JSON is still reported'
        $script:Remote = @{}; $script:NextId = 100; $script:FailDiscovery = $false; $script:Raced = $false
        $script:Members = @(@{ state='active'; organization=@{id=1;login='alpha'} })
        function Invoke-GitHubApi([string]$Endpoint, [string]$Method='GET', [switch]$Paginate) {
            if ($Endpoint -match '^organizations/(\d+)$') {
                $state = Get-State; $id = $Matches[1]
                $key = @($state.Keys | Where-Object { $_.Split('.')[0] -eq $id }) | Select-Object -First 1
                return [pscustomobject]@{id=[long]$id;login=$state[$key].login}
            }
            if ($Endpoint -match '^orgs/([^/]+)$') {
                $state = Get-State; $login = $Matches[1]
                $key = @($state.Keys | Where-Object { $state[$_].login -ceq $login }) | Select-Object -First 1
                if ($null -eq $key) { throw "Unknown organization $login" }
                return [pscustomobject]@{id=[long]$key.Split('.')[0];login=$login}
            }
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
            $directory = Join-Path (Get-RunnerHome $Login $Name) 'app'
            New-Item -ItemType Directory -Force -Path $directory, (Get-RunnerJobs $Login $Name) | Out-Null
            Write-Json (Join-Path $directory '.runner') @{agentId=$runnerId;agentName=$Name;gitHubUrl="https://github.com/$Login"}
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
        # Directories follow organization and runner name: runner\<login>\<name>, jobs\<login>\<name>.
        function Get-FixtureName([string]$Key) { return (Get-State)[$Key].runner_name }
        Remove-Item (Join-Path (Get-RunnerHome 'alpha' (Get-FixtureName '1')) 'app\.runner') -Force; Invoke-Reconcile
        Assert ($script:NextId -eq 103) 'missing local configuration recovery'
        $alphaJobs = Get-RunnerJobs 'alpha' (Get-FixtureName '1')
        Write-AtomicText (Join-Path $alphaJobs 'keep') 'keep'
        $script:Members = @(@{state='active';organization=@{id=1;login='renamed'}})
        $script:Remote.renamed = $script:Remote.alpha; $script:Remote.Remove('alpha')
        $script:Remote.renamed[0].busy = $true; Invoke-Reconcile
        Assert ((Get-State)['1'].login -eq 'alpha') 'busy rename deferred'
        $script:Remote.renamed[0].busy = $false; Invoke-Reconcile
        Assert ((Get-State)['1'].login -eq 'renamed') 'organization renamed'
        Assert (Test-Path (Join-Path $alphaJobs 'keep')) 'old jobs retained'
        Assert (-not (Test-Path (Join-Path $testRoot 'runner\alpha')) -and (Test-Path (Join-Path (Get-RunnerHome 'renamed' (Get-FixtureName '1')) 'app'))) 'rename moves the program directory'
        Save-State @{}; $previous = $script:NextId; Invoke-Reconcile
        Assert ($script:NextId -eq $previous) 'registration recovered after state loss'
        # runner_count: each organization gets that many runners, each with its own number,
        # program directory and jobs directory under the organization.
        function Set-FixtureCount([int]$Count) {
            $settings = Read-Json (Join-Path $testRoot 'conf\settings.json')
            $settings | Add-Member -NotePropertyName runner_count -NotePropertyValue $Count -Force
            Write-Json (Join-Path $testRoot 'conf\settings.json') $settings
        }
        # Half of 6 CPUs allows 3 runners per organization, whatever machine runs the tests.
        $env:LOCAL_RUNNER_CPU_COUNT = '6'
        Set-FixtureCount 3; Invoke-Reconcile
        $state = Get-State
        Assert ($state.ContainsKey('1.2') -and $state.ContainsKey('1.3') -and $state['1.3'].login -eq 'renamed') 'extra runners registered'
        Assert (@($state['1'].runner_name, $state['1.2'].runner_name, $state['1.3'].runner_name | Select-Object -Unique).Count -eq 3) 'each runner has its own number'
        Assert ((Test-Path (Join-Path (Get-RunnerHome 'renamed' $state['1.2'].runner_name) 'app\.runner')) -and (Test-Path (Get-RunnerJobs 'renamed' $state['1.3'].runner_name))) 'each runner has its own directories'
        Assert ($script:Remote.renamed.Count -eq 3) 'three registrations'
        $previous = $script:NextId; Invoke-Reconcile
        Assert ($script:NextId -eq $previous) 'runner count is idempotent'
        # Lowering the count removes the extra runners and their directories once idle; a busy
        # one finishes its job first.
        $second = $state['1.2'].runner_name; $third = $state['1.3'].runner_name
        Write-AtomicText (Join-Path (Get-RunnerJobs 'renamed' $second) 'keep') 'keep'
        ($script:Remote.renamed | Where-Object id -eq $state['1.3'].runner_id).busy = $true
        Set-FixtureCount 1; Invoke-Reconcile
        $state = Get-State
        Assert ($state.ContainsKey('1.3') -and -not $state.ContainsKey('1.2')) 'idle extra runner removed, busy one kept'
        Assert (-not (Test-Path (Get-RunnerHome 'renamed' $second)) -and -not (Test-Path (Get-RunnerJobs 'renamed' $second)) -and (Test-Path (Get-RunnerHome 'renamed' $third))) 'idle runner directories removed, busy one kept'
        $script:Remote.renamed | ForEach-Object { $_.busy = $false }; Invoke-Reconcile
        Assert (-not (Get-State).ContainsKey('1.3') -and $script:Remote.renamed.Count -eq 1 -and $script:Remote.renamed[0].id -eq (Get-State)['1'].runner_id) 'busy extra runner removed once idle'
        Assert (-not (Test-Path (Get-RunnerHome 'renamed' $third)) -and -not (Test-Path (Get-RunnerJobs 'renamed' $third))) 'its directories removed too'
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
        ($script:Remote.collision | Where-Object name -eq "$script:Prefix-11").id = 995
        Reconcile-Organization '3' 'collision'
        Assert ($script:Remote.collision[-1].name -eq "$script:Prefix-12" -and @($script:Remote.collision | Where-Object id -eq 995).Count -eq 1) 'taken repair number increments without replacing'
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
        Assert (-not @((Get-State).Keys | Where-Object { $_.Contains('.') }).Count) 'a failing organization does not change the runner count of others'
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
        # The parent exits promptly, but its child retains the redirected pipe handles.
        # The same deadline must cover output draining, not just the parent's lifetime.
        $pipeChild = Join-Path $testRoot 'pipe child.ps1'
        $pipeParent = Join-Path $testRoot 'pipe parent.ps1'
        $pipeRecord = Join-Path $testRoot 'pipe-child.json'
        Write-AtomicText $pipeChild 'Start-Sleep -Seconds 10; [Console]::Out.WriteLine("late output")'
        Write-AtomicText $pipeParent @'
param($Executable,$Child,$Record)
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $Executable; $info.UseShellExecute = $false
$info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Child + '"'
$childProcess = [Diagnostics.Process]::Start($info)
@{id=$childProcess.Id;started=$childProcess.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json | Set-Content -LiteralPath $Record
exit 0
'@
        $timer = [Diagnostics.Stopwatch]::StartNew(); $message = ''
        try {
            try { $null = Invoke-Native $script:PowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$pipeParent,$script:PowerShell,$pipeChild,$pipeRecord) -Timeout 2 }
            catch { $message = $_.Exception.Message }
            Assert ($message -match 'after the process exited' -and (Test-Path $pipeRecord) -and $timer.Elapsed.TotalSeconds -lt 6) 'native deadline includes inherited output pipes after parent exit'
        } finally {
            $record = Read-Json $pipeRecord
            if ($record) {
                $childProcess = Get-Process -Id $record.id -ErrorAction SilentlyContinue
                if ($childProcess -and $childProcess.StartTime.ToUniversalTime().Ticks -eq [long]$record.started) { $childProcess.Kill(); $childProcess.WaitForExit(); $childProcess.Dispose() }
            }
        }
        # WSL's Windows bridge uses the same bounded output handling. Exercise its
        # real process invocation with a fixture executable, without launching WSL.
        & {
            . (Join-Path $repo 'linux/wsl.ps1') -Action Library
            $script:WslExe = $script:PowerShell
            $script:WslArguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$pipeParent,$script:PowerShell,$pipeChild,$pipeRecord)
            $timer = [Diagnostics.Stopwatch]::StartNew(); $message = ''
            try {
                try { $null = Invoke-WslHelper @() -TimeoutSeconds 2 } catch { $message = $_.Exception.Message }
                Assert ($message -match 'after the process exited' -and (Test-Path $pipeRecord) -and $timer.Elapsed.TotalSeconds -lt 6) 'WSL bridge deadline includes inherited output pipes after parent exit'
            } finally {
                $record = Read-Json $pipeRecord
                if ($record) {
                    $childProcess = Get-Process -Id $record.id -ErrorAction SilentlyContinue
                    if ($childProcess -and $childProcess.StartTime.ToUniversalTime().Ticks -eq [long]$record.started) { $childProcess.Kill(); $childProcess.WaitForExit(); $childProcess.Dispose() }
                }
            }
        }
        # Exercise actual wrapper restart, without real GitHub runners or host services.
        if ($onWindows) {
        # Fixtures run as the CI user; production records may only stop LocalService.
        # Keep this override limited to processes whose command line names this fixture.
        function Test-StoppableProcess([int]$ProcessId) {
            $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
            return ($candidate -and $candidate.CommandLine -and $candidate.CommandLine.Contains($fixture))
        }
        Remove-Item Env:LOCAL_RUNNER_ROOT
        $runner = Join-Path (Get-RunnerHome 'renamed' (Get-FixtureName '1')) 'app'
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
        # The installer stops processes with the new script, not the installed copy, and a
        # forged record cannot make it stop an administrator-owned process.
        $sleeper = [Diagnostics.Process]::Start((New-ProcessInfo $script:PowerShell @('-NoProfile','-Command','Start-Sleep -Seconds 60')))
        $forged = Join-Path $testRoot 'conf\workers\9.json'
        Record-Process $forged $sleeper
        try {
            $null = Invoke-Native $script:PowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repo 'windows\service.ps1'),'-Mode','Stop','-Root',$testRoot)
            Assert (-not $sleeper.HasExited -and -not (Test-Path $forged)) 'forged state cannot stop an administrator-owned process'
        } finally { if (-not $sleeper.HasExited) { $sleeper.Kill(); $sleeper.WaitForExit() }; $sleeper.Dispose() }
        }
        $script:Members = @(); Invoke-Reconcile
        Assert (@((Get-State).Values | Where-Object active -ne $false).Count -eq 0) 'removed membership stopped and retained for uninstall'
        Assert (Test-Path (Join-Path $alphaJobs 'keep')) 'jobs retained after removal'
        Invoke-Reconcile
        Assert (@(Select-String -LiteralPath (Join-Path $testRoot 'logs\service.log') -SimpleMatch 'Stopped organization 3;').Count -eq 1) 'deactivation logged once'
        $text = Get-Content -Raw (Join-Path $testRoot 'logs\service.log')
        Assert ($text -notmatch 'secret-test-token|should-not-reach-runner') 'no credential log leak'
        # Exercise management with real child processes and a fake scheduled task.
        function Assert-Administrator {}
        function Grant-WorkDirectory([string]$Directory) { New-Item -ItemType Directory -Force -Path $Directory | Out-Null }
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
            # ghr config: full option names only; a new data directory must exist and be empty.
            $shown = & $launcher config --data-dir
            Assert ($LASTEXITCODE -eq 0 -and "$shown".Trim() -eq $testRoot) 'show data directory'
            function Test-ConfigRejected([string[]]$Arguments) {
                try { $null = Invoke-Native $script:PowerShell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $testRoot 'bin\ghr.ps1'),'config') + $Arguments); return $false }
                catch { return $true }
            }
            foreach ($arguments in @(@('-d',$newWork), @('--dir',$newWork), @('--runner-count','2'), @('--data-dir',$newWork,'extra'))) {
                Assert (Test-ConfigRejected $arguments) "rejected ghr config $($arguments -join ' ')"
            }
            Assert ((Test-ConfigRejected @('--data-dir',$newWork)) -and -not (Test-Path $newWork)) 'missing data directory rejected'
            New-Item -ItemType Directory -Path $newWork | Out-Null; Write-AtomicText (Join-Path $newWork 'other') 'other'
            Assert (Test-ConfigRejected @('--data-dir',$newWork)) 'non-empty data directory rejected'
            Remove-Item -LiteralPath (Join-Path $newWork 'other')
            & $launcher config --data-dir $newWork
            Assert ($LASTEXITCODE -eq 0 -and (Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq $newWork) 'public --data-dir syntax with spaces in path'
            # ghr runner: one more or one fewer per organization, from 1 to half the CPUs.
            function Test-RunnerRejected([string[]]$Arguments) {
                try { $null = Invoke-Native $script:PowerShell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $testRoot 'bin\ghr.ps1'),'runner') + $Arguments); return $false }
                catch { $script:RunnerError = $_.Exception.Message; return $true }
            }
            $shown = & $launcher runner
            Assert ($LASTEXITCODE -eq 0 -and "$shown".Trim() -ceq 'Runners per organization: 1 (maximum 3: 6 CPUs / 2)') 'show runner count and maximum'
            Assert ((Test-RunnerRejected @('-s')) -and $script:RunnerError -match 'keeps at least 1') 'last runner kept'
            $shown = & $launcher runner --add
            Assert ($LASTEXITCODE -eq 0 -and "$shown" -match 'registers the new runners') 'add one runner'
            $shown = & $launcher runner -a
            Assert ($LASTEXITCODE -eq 0 -and "$shown" -match 'Runners per organization: 2 -> 3' -and (Read-Json (Join-Path $testRoot 'conf\settings.json')).runner_count -eq 3) 'add up to the maximum'
            Assert ((Test-RunnerRejected @('--add')) -and $script:RunnerError -match 'maximum on this machine \(6 CPUs / 2\)') 'more than half the CPUs refused'
            foreach ($arguments in @(@('--count'), @('-x'), @('-a','-s'), @('add'))) { Assert (Test-RunnerRejected $arguments) "rejected ghr runner $($arguments -join ' ')" }
            $shown = & $launcher runner --sub
            Assert ($LASTEXITCODE -eq 0 -and "$shown" -match 'once they are idle') 'remove one runner'
            & $launcher runner -s | Out-Null
            Assert ((Read-Json (Join-Path $testRoot 'conf\settings.json')).runner_count -eq 1) 'back to one runner'
            $failed = $false
            try { $null = Invoke-Native $script:PowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $testRoot 'bin\ghr.ps1'),'config',"--data-dir=$newWork-equals") } catch { $failed = $true }
            Assert ($failed -and -not (Test-Path "$newWork-equals")) 'removed --data-dir= syntax rejected without creating directory'
            Assert ((Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq $newWork) 'invalid syntax leaves configuration unchanged'
            Assert ((Get-Content -Raw -Encoding UTF8 (Join-Path $testRoot 'conf\active-work-dir')) -eq $testRoot) 'configuration remains pending'
            Stop-Installation; Start-Installation
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 100
                $current = Read-Json (Join-Path (Get-RunnerHome 'renamed' (Get-FixtureName '1')) 'app\.runner')
            } while ($current.workFolder -ne (Join-Path $newWork "jobs\renamed\$(Get-FixtureName '1')") -and [DateTime]::UtcNow -lt $deadline)
            Assert ($current.workFolder -eq (Join-Path $newWork "jobs\renamed\$(Get-FixtureName '1')")) 'restart applies work folder'
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
            New-Item -ItemType Directory -Path $newWork | Out-Null
            Set-WorkDirectory $newWork
            Assert ($script:WorkDir -eq $testRoot) 'configuration does not change running settings'
            Assert ((Read-Json (Join-Path $testRoot 'conf\settings.json')).work_dir -eq $newWork) 'new directory saved'
        }
        $script:FailDelete = $true; $failed = $false
        try { Uninstall-Runner } catch { $failed = $true }
        Assert ($failed -and (Test-Path (Join-Path $testRoot 'conf\github-token'))) 'failed unregister retains credentials'
        $script:FailDelete = $false; Uninstall-Runner
        Assert (-not (Test-Path (Join-Path $testRoot 'conf')) -and -not (Test-Path (Join-Path $testRoot 'runner')) -and -not (Test-Path $launcher)) 'uninstall removes runtime and command'
        Assert (Test-Path (Join-Path $alphaJobs 'keep')) 'uninstall preserves jobs'
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
