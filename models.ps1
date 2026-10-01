<#
.SYNOPSIS
Download every model weight listed in models.json into models\huggingface (skips what is present).

.PARAMETER List  Only show what is in models\huggingface and its size.
#>
param([switch]$List)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if ($List) {
    $hub = Join-Path $PSScriptRoot 'models\huggingface\hub'
    if (-not (Test-Path -LiteralPath $hub)) { Write-Host "No models yet."; exit 0 }
    Get-ChildItem -LiteralPath $hub -Directory -Filter 'models--*' | ForEach-Object {
        $bytes = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum
        '{0,-52} {1,8:N2} GB' -f ($_.Name -replace '^models--', '' -replace '--', '/'), ($bytes / 1GB)
    }
    exit 0
}

$null = & docker info 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: Docker is not running." -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'models\huggingface') | Out-Null

$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker compose --profile models run --rm model-fetch | Out-Host
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previous
}
if ($code -ne 0) { Write-Host "Error: at least one model failed to download." -ForegroundColor Red; exit 1 }
Write-Host "All models present in models\huggingface." -ForegroundColor Green
