$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this command in an Administrator PowerShell window.'
}
$base = if ($env:LOCAL_RUNNER_BASE_URL) { $env:LOCAL_RUNNER_BASE_URL } else { 'https://raw.githubusercontent.com/suminwell/github-runner/main' }
$homeDirectory = if ($env:LOCAL_RUNNER_HOME) { $env:LOCAL_RUNNER_HOME } else { Join-Path $env:ProgramData 'local-github-runner' }
$root = Join-Path $homeDirectory 'windows'
$bin = Join-Path $root 'bin'
$state = Join-Path $root '.state'
New-Item -ItemType Directory -Force -Path $root, $bin, $state, (Join-Path $root 'logs') | Out-Null
# LocalService runs jobs with limited OS privileges and can access only this install's credentials.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $identity.User.Value)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
$rule = New-Object Security.AccessControl.FileSystemAccessRule(
    (New-Object Security.Principal.SecurityIdentifier('S-1-5-19')), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $root -AclObject $acl

$serviceExe = Join-Path $bin 'LocalGitHubRunner.exe'
$existing = Get-CimInstance Win32_Service -Filter "Name='LocalGitHubRunner'"
if ($existing) {
    if ($existing.PathName.Trim('"') -ne $serviceExe) { throw 'Another installation owns the LocalGitHubRunner service.' }
    Stop-Service LocalGitHubRunner
}

function Get-SourceFile([string]$Source, [string]$Destination) {
    if ($env:LOCAL_RUNNER_SOURCE_DIR) {
        Copy-Item -LiteralPath (Join-Path $env:LOCAL_RUNNER_SOURCE_DIR $Source) -Destination "$Destination.new" -Force
    } else {
        Invoke-WebRequest -UseBasicParsing "$base/$Source" -OutFile "$Destination.new"
    }
    Move-Item -LiteralPath "$Destination.new" -Destination $Destination -Force
}

# An isolated official Python runtime avoids PATH, Store aliases and user-profile permissions.
$pythonDirectory = Join-Path $state 'python'
$python = Join-Path $pythonDirectory 'python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    $nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($nativeArch) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { throw 'Windows x64 or ARM64 is required.' } }
    $version = '3.14.10'
    $hashes = @{ amd64 = '90905e64a840557d8c1bc4f5b74db3d7ee85e3ffb217611cac1c7813acea4159'; arm64 = 'bbe116bb1248820359cbf25127ac5c7794ea161869d83686cfbc9a45203ff836' }
    $archive = Join-Path $state 'python.zip'
    Invoke-WebRequest -UseBasicParsing "https://www.python.org/ftp/python/$version/python-$version-embed-$arch.zip" -OutFile $archive
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant() -ne $hashes[$arch]) {
        Remove-Item -LiteralPath $archive
        throw 'Python runtime SHA-256 mismatch.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $pythonDirectory -Force
    Remove-Item -LiteralPath $archive
}
Get-SourceFile 'common/manager.py' (Join-Path $bin 'manager.py')
Get-SourceFile 'common/windows-service.cs' (Join-Path $bin 'windows-service.cs')
Get-SourceFile 'windows/bin/service.ps1' (Join-Path $bin 'service.ps1')
& $python (Join-Path $bin 'manager.py') prepare --root $root
if ($LASTEXITCODE -ne 0) { throw 'Dependency or GitHub login setup failed.' }

if (Test-Path -LiteralPath $serviceExe) { Remove-Item -LiteralPath $serviceExe }
# Compile using built-in Windows PowerShell/.NET Framework, even when invoked from pwsh.
$compileScript = Join-Path $state 'compile.ps1'
@'
param($Source, $Output)
$ErrorActionPreference = 'Stop'
Add-Type -Path $Source -ReferencedAssemblies System.ServiceProcess -OutputAssembly $Output -OutputType ConsoleApplication
'@ | Set-Content -LiteralPath $compileScript -Encoding UTF8
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $compileScript (Join-Path $bin 'windows-service.cs') $serviceExe
if ($LASTEXITCODE -ne 0) { throw 'Windows service host compilation failed.' }
if (-not $existing) {
    $localServiceName = (New-Object Security.Principal.SecurityIdentifier('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
    & sc.exe create LocalGitHubRunner binPath= "`"$serviceExe`"" start= auto obj= $localServiceName
    if ($LASTEXITCODE -ne 0) { throw 'Service creation failed.' }
}
& sc.exe config LocalGitHubRunner start= delayed-auto
if ($LASTEXITCODE -ne 0) { throw 'Service startup configuration failed.' }
& sc.exe failure LocalGitHubRunner reset= 86400 actions= restart/10000/restart/30000/restart/60000
if ($LASTEXITCODE -ne 0) { throw 'Service recovery configuration failed.' }
& sc.exe failureflag LocalGitHubRunner 1
if ($LASTEXITCODE -ne 0) { throw 'Service recovery flag configuration failed.' }
Start-Service LocalGitHubRunner
Write-Host "Installed in $root"
Write-Host "Status: & '$bin\service.ps1' status"
Write-Host "Logs: $root\logs\service.log"
