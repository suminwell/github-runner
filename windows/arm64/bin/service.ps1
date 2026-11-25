param([ValidateSet('serve', 'status')][string]$Command = 'serve')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$python = Join-Path $root '.state\python\python.exe'
& $python (Join-Path $PSScriptRoot 'manager.py') $Command --root $root
exit $LASTEXITCODE
