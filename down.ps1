<#
.SYNOPSIS
Stop the shared infrastructure. Databases and model weights are plain folders and are never touched.

.PARAMETER Llm  Stop only the vLLM server (frees the GPU) and leave the databases running.
#>
param([switch]$Llm)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Invoke-Docker {
    param([string[]]$DockerArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @DockerArgs | Out-Host
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
}

if ($Llm) {
    $code = Invoke-Docker @('compose', '--profile', 'llm', 'stop', 'vllm')
} else {
    $code = Invoke-Docker @('compose', '--profile', 'llm', '--profile', 'models', 'down', '--remove-orphans')
}
if ($code -ne 0) { Write-Host "Error: docker compose stop failed (exit $code)." -ForegroundColor Red; exit 1 }
Write-Host "Stopped. data\ and models\ are untouched." -ForegroundColor Green
