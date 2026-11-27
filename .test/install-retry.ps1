$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-install-retry-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$success = $false
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
try {
    if ($env:OS -eq 'Windows_NT') {
        # Check the actual CIM settings property without registering or starting a task.
        $nativeSettings = New-ScheduledTaskSettingsSet
        $nativeSettings.Enabled = $false
        Assert (-not $nativeSettings.Enabled) 'native task settings accept disabled registration'
    }
    $tokens = $null; $errors = $null
    $installer = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'windows/install.ps1'), [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'installer syntax'
    foreach ($name in @('Move-PreviousLayout','Initialize-InstallSettings')) {
        $definition = $installer.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    # Execute the actual ordered installation stages in temporary directories. Exclude
    # host identity, task registration, downloads and login; those are not test targets.
    function Get-InstallerStage([string]$First, [string]$Until) {
        $selected = @(); $started = $false
        foreach ($statement in $installer.EndBlock.Statements) {
            $text = $statement.Extent.Text
            if ($text.StartsWith($First, [StringComparison]::Ordinal)) { $started = $true }
            if ($started -and $text.StartsWith($Until, [StringComparison]::Ordinal)) { break }
            if ($started) { $selected += $text }
        }
        Assert ($selected.Count -gt 0) "stage found: $First"
        return [scriptblock]::Create(($selected -join "`n"))
    }
    $preflight = Get-InstallerStage '$knownInstallation = ' '$bin = Join-Path $installRoot'
    $prepare = Get-InstallerStage 'Move-PreviousLayout $installRoot' '$existing = Get-Command gh'
    $otherArchCheck = Get-InstallerStage 'if ((Test-Path (Join-Path $installRoot "$otherArch' '$migrate = '
    $startup = Get-InstallerStage '$taskSettings.Enabled = ' 'foreach ($old in '
    function Protect-AdminFile([string]$Path) {}
    function Grant-ServiceWrite([string]$Directory) {}
    foreach ($arch in @('x64','arm64')) {
        $installRoot = Join-Path $fixture $arch
        $first = Join-Path $fixture "first-$arch"; $second = Join-Path $fixture "second-$arch"
        New-Item -ItemType Directory -Path $installRoot,$first,$second | Out-Null
        $bin = Join-Path $installRoot 'bin'; $state = Join-Path $installRoot 'conf'
        Push-Location $first
        try { . $preflight; . $prepare } finally { Pop-Location }
        # A download/login exception here leaves exactly the real prepared state.
        $settingsPath = Join-Path $state 'settings.json'
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        Assert ($settings.platform -eq 'windows' -and $settings.arch -eq $arch -and $settings.work_dir -eq $first) 'fresh settings precede external failure boundaries'
        Push-Location $second
        try { . $preflight; Assert $knownInstallation 'retry recognizes its own partial install'; . $prepare } finally { Pop-Location }
        Assert ((Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).work_dir -eq $first) 'retry preserves original working directory'
        $before = Get-Content -Raw -LiteralPath $settingsPath
        Initialize-InstallSettings $installRoot $arch
        Assert ((Get-Content -Raw -LiteralPath $settingsPath) -ceq $before) 'existing settings preserved byte for byte'
        # Run the real final enabled-state/startup decision with inert scheduler mocks.
        function New-ScheduledTaskPrincipal { return [pscustomobject]@{} }
        function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Settings,$Principal,[switch]$Force); $script:RegisteredEnabled = $Settings.Enabled }
        function Enable-ScheduledTask { $script:Enabled = $true }
        function Disable-ScheduledTask { $script:Enabled = $false }
        function Start-ScheduledTask { $script:Started = $true }
        # SID translation is Windows-only; use the actual decision statements alone on
        # other hosts, and keep the full native registration block for Windows CI.
        $startupText = $startup.ToString()
        if ($env:OS -ne 'Windows_NT') { $startupText = ($startupText -split '\r?\n' | Where-Object { $_ -notmatch '^\$localService = ' }) -join "`n" }
        foreach ($stopped in @($false,$true)) {
            if ($stopped) { Set-Content -LiteralPath (Join-Path $state 'stopped') -Value stopped }
            $taskSettings = [pscustomobject]@{Enabled=$true}; $script:Enabled = $null; $script:Started = $false
            $taskName = 'fixture'; $action = $null; $boot = $null; $watchdog = $null; $localService = 'fixture'
            . ([scriptblock]::Create($startupText))
            Assert ($script:RegisteredEnabled -eq (-not $stopped) -and $script:Enabled -eq (-not $stopped) -and $script:Started -eq (-not $stopped)) 'upgrade preserves stopped state at registration and startup'
        }
    }
    # The SYSTEM sleep guard runs from an Administrator-only copy when prevent_sleep is on,
    # and is removed, giving the lid setting back, when it is turned off.
    $awake = Get-InstallerStage '$awakeTask = ' "Remove-Item (Join-Path `$state 'python')"
    $env:LOCAL_RUNNER_AWAKE_STORE = Join-Path $fixture 'awake'
    New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCAL_RUNNER_AWAKE_STORE 'bin') | Out-Null
    $bin = Join-Path $fixture 'awake-bin'; $state = Join-Path $fixture 'awake-state'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null; Copy-Item (Join-Path $repo 'windows/awake.ps1') (Join-Path $bin 'awake.ps1')
    $script:Calls = @(); $script:Task = $null
    function Invoke-FakePowerShell { $script:Calls += ,($args -join ' '); $global:LASTEXITCODE = 0 }
    $windowsPowerShell = 'Invoke-FakePowerShell'
    function Get-ScheduledTask { param($TaskName,$ErrorAction); return $script:Task }
    function Stop-ScheduledTask { param($TaskName,$ErrorAction) }
    function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm,$ErrorAction); $script:Task = $null; $script:Unregistered = $TaskName }
    function New-ScheduledTaskAction { param($Execute,$Argument); return [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
    function New-ScheduledTaskSettingsSet { return [pscustomobject]@{} }
    function New-TimeSpan { return [TimeSpan]::Zero }
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); return [pscustomobject]@{UserId=$UserId;RunLevel=$RunLevel} }
    function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Settings,$Principal,[switch]$Force); $script:Task = [pscustomobject]@{TaskName=$TaskName;Action=$Action;Principal=$Principal} }
    function Start-ScheduledTask { param($TaskName) }
    $taskName = 'LocalGitHubRunner-x64'; $boot = $null; $watchdog = $null
    $settings = @{prevent_sleep=$true}
    . $awake
    $copy = Join-Path (Join-Path $env:LOCAL_RUNNER_AWAKE_STORE 'bin') 'LocalGitHubRunner-x64-Awake.ps1'
    Assert ($script:Task.TaskName -eq 'LocalGitHubRunner-x64-Awake' -and $script:Task.Principal.UserId -eq 'S-1-5-18') 'guard registered as SYSTEM'
    Assert ($script:Task.Action.Arguments.Contains("-File `"$copy`"") -and $script:Task.Action.Arguments.Contains((Join-Path $state 'manager.json'))) 'guard runs the protected copy against the manager record'
    Assert ((Test-Path $copy) -and ($script:Calls[0] -match '-Action Prepare')) 'store prepared before the copy'
    $settings = @{prevent_sleep=$false}; $script:Calls = @()
    . $awake
    Assert ($script:Unregistered -eq 'LocalGitHubRunner-x64-Awake' -and -not (Test-Path $copy) -and ($script:Calls[0] -match '-Action Release -Name LocalGitHubRunner-x64-Awake')) 'turning it off releases and removes the guard'
    Remove-Item Env:LOCAL_RUNNER_AWAKE_STORE
    $arch = 'x64'
    foreach ($oldState in @('.state','conf')) {
        $installRoot = Join-Path $fixture "legacy-$oldState"
        $legacyState = Join-Path $installRoot "x64/$oldState"
        New-Item -ItemType Directory -Path $legacyState -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $legacyState 'settings.json') -Value '{"platform":"windows","work_dir":"preserved"}'
        Set-Content -LiteralPath (Join-Path $legacyState 'stopped') -Value stopped
        $bin = Join-Path $installRoot 'bin'; $state = Join-Path $installRoot 'conf'
        . $preflight; . $prepare
        Assert ((Test-Path (Join-Path $state 'stopped')) -and (Get-Content -Raw -LiteralPath (Join-Path $state 'settings.json') | ConvertFrom-Json).work_dir -eq 'preserved') 'legacy migration retains stopped marker and configuration'
    }
    $installRoot = Join-Path $fixture 'unrelated'
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'bin') -Force | Out-Null
    $failed = $false; try { . $preflight } catch { $failed = $true }
    Assert ($failed -and -not (Test-Path (Join-Path $installRoot 'conf'))) 'unrelated program directory refused'
    $installRoot = Join-Path $fixture 'foreign-platform'
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'x64/conf') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installRoot 'x64/conf/settings.json') -Value '{"platform":"linux"}'
    $failed = $false; try { . $preflight } catch { $failed = $true }
    Assert $failed 'legacy architecture/conf platform validated'
    $installRoot = Join-Path $fixture 'foreign-architecture'; $otherArch = 'arm64'
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'arm64/conf') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installRoot 'arm64/conf/settings.json') -Value '{"platform":"windows"}'
    $failed = $false; try { . $otherArchCheck } catch { $failed = $true }
    Assert $failed 'legacy architecture/conf mismatch refused'
    $success = $true
    Write-Host 'PASS Windows installer retry, original data directory, stopped upgrade and layout ownership'
} finally {
    if ($success) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    else { Write-Host "Retained fixture: $fixture" }
}
