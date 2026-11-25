param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$OrgId)
$WorkerOrganizationId = $OrgId
. (Join-Path $Root 'bin\service.ps1') -Mode Library -Root $Root
function Invoke-Worker([string]$Id) {
    if ($Id -notmatch '^\d+$') { throw 'Invalid organization ID.' }
    $login = (Get-State)[$Id].login
    if (-not (Test-Organization $login)) { throw 'Invalid organization.' }
    $record = Join-Path $script:Root "conf\children\$Id.json"
    $lock = [IO.File]::Open((Join-Path $script:Root "conf\worker-$Id.lock"), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Stop-Record $record
        while (-not (Test-Path (Join-Path $script:Root 'conf\stopped'))) {
            $info = New-ProcessInfo $script:PowerShell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Root "runner\$login\listener.ps1"))
            $process = [Diagnostics.Process]::Start($info)
            Record-Process $record $process
            $process.WaitForExit(); $process.Dispose()
            Remove-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds $script:RestartSeconds
        }
    } finally { Stop-Record $record; $lock.Dispose() }
}
try {
    Initialize-Manager -Control
    $activeDirectory = Join-Path $script:Root 'conf\active-work-dir'
    if (Test-Path $activeDirectory) { $script:LogDir = Join-Path ((Get-Content -Raw -Encoding UTF8 $activeDirectory).Trim()) 'logs' }
    Invoke-Worker $WorkerOrganizationId
} catch {
    Write-Log "Worker $WorkerOrganizationId stopped: $($_.Exception.Message)"
    exit 1
}
