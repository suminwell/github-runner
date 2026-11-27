$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-uninstall-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
if ($env:OS -ne 'Windows_NT') { $env:SystemRoot = '/tmp' }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
try {
    . (Join-Path $repo 'windows/ghr.ps1') -Command library
    function New-Case([string]$Name) {
        $script:Root = Join-Path $fixture $Name
        foreach ($directory in @('conf','runner/directory-is-not-identity/runner/app')) { New-Item -ItemType Directory -Path (Join-Path $script:Root $directory) -Force | Out-Null }
        $script:Prefix = 'local-windows-x64'
        Save-State @{}
        Write-AtomicText (Join-Path $script:Root 'conf/github-token') 'fixture-credential'
        $script:Metadata = Join-Path $script:Root 'runner/directory-is-not-identity/runner/app/.runner'
        Write-Json $script:Metadata @{agentId=42;agentName="$script:Prefix-1";gitHubUrl='https://github.com/alpha'}
        $script:Remote = @(@{id=42;name="$script:Prefix-1"},@{id=43;name='unrelated-runner'})
        $script:Deleted = @(); $script:FailDelete = $false
    }
    function Invoke-GitHubApi([string]$Endpoint, [string]$Method = 'GET', [switch]$Paginate) {
        if ($Endpoint -in @('orgs/alpha','organizations/100')) { return [pscustomobject]@{id=100;login='alpha'} }
        if ($Endpoint -in @('orgs/beta','organizations/200')) { return [pscustomobject]@{id=200;login='beta'} }
        if ($Endpoint -eq 'orgs/alpha/actions/runners?per_page=100') { return ,@([pscustomobject]@{runners=$script:Remote}) }
        if ($Endpoint -eq 'orgs/beta/actions/runners?per_page=100') { return ,@([pscustomobject]@{runners=@(@{id=42;name='tracked-beta'})}) }
        if ($Endpoint -eq 'orgs/beta/actions/runners/42' -and $Method -eq 'DELETE') { $script:Deleted += 'beta/42'; return }
        if ($Endpoint -match '^orgs/alpha/actions/runners/(\d+)$' -and $Method -eq 'DELETE') {
            if ($script:FailDelete) { throw 'Simulated DELETE failure' }
            $runnerId = [long]$Matches[1]
            $script:Deleted += $runnerId
            $script:Remote = @($script:Remote | Where-Object id -ne $runnerId)
            return
        }
        throw "Unexpected API endpoint: $Endpoint"
    }
    New-Case fresh
    $duplicate = Join-Path $script:Root 'runner/duplicate-local-copy/runner/app'
    New-Item -ItemType Directory -Path $duplicate -Force | Out-Null
    Copy-Item -LiteralPath $script:Metadata -Destination (Join-Path $duplicate '.runner')
    Unregister-Runners
    Assert ($script:Deleted.Count -eq 1 -and $script:Deleted[0] -eq 42 -and $script:Remote.Count -eq 1 -and $script:Remote[0].id -eq 43) 'only owned unrecorded registration removed'
    Unregister-Runners
    Assert ($script:Deleted.Count -eq 1) 'retry is idempotent after remote removal'
    New-Case same-id-other-organization
    Save-State @{'200'=@{login='beta';runner_id=42;runner_name='tracked-beta'}}
    Move-Item -LiteralPath (Join-Path $script:Root 'runner/directory-is-not-identity') -Destination (Join-Path $script:Root 'runner/beta')
    Unregister-Runners
    Assert ($script:Deleted.Count -eq 2 -and $script:Deleted -contains 42 -and $script:Deleted -contains 'beta/42' -and $script:Remote.Count -eq 1 -and $script:Remote[0].id -eq 43) 'tracked ID in beta does not suppress orphan recovery in alpha'
    New-Case repaired
    Save-State @{'100'=@{login='alpha';runner_id=41;runner_name="$script:Prefix-1"}}
    $script:Remote += @{id=41;name='previous-owned-runner'}
    Unregister-Runners
    Assert ($script:Deleted.Count -eq 2 -and $script:Remote.Count -eq 1 -and $script:Remote[0].id -eq 43) 'repair crash cleans old and new owned registrations'
    foreach ($invalid in @('name','url','state','metadata')) {
        New-Case $invalid
        switch ($invalid) {
            name { $script:Remote[0].name = 'other-installation' }
            url { $local = Read-Json $script:Metadata; $local.gitHubUrl = 'https://github.com/alpha/repository'; Write-Json $script:Metadata $local }
            state { Write-AtomicText (Join-Path $script:Root 'conf/organizations.json') '[]' }
            metadata { Write-AtomicText $script:Metadata '{broken' }
        }
        $failed = $false; try { Unregister-Runners } catch { $failed = $true }
        Assert ($failed -and $script:Deleted.Count -eq 0 -and (Test-Path (Join-Path $script:Root 'conf/github-token'))) "ambiguous $invalid ownership retains credentials"
    }
    New-Case retry
    $script:FailDelete = $true
    $failed = $false; try { Unregister-Runners } catch { $failed = $true }
    Assert ($failed -and (Test-Path $script:Metadata) -and (Test-Path (Join-Path $script:Root 'conf/github-token'))) 'failed DELETE retains ownership evidence and credentials'
    $script:FailDelete = $false
    Unregister-Runners
    Assert ($script:Deleted.Count -eq 1 -and $script:Remote[0].id -eq 43) 'retry removes only owned registration'
    Write-Host 'PASS Windows uninstall recovery, identity validation and retry'
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
