<#
.SYNOPSIS
Start the shared market-research infrastructure (Postgres, MongoDB, Neo4j, optionally vLLM).

.DESCRIPTION
Creates .env with generated admin passwords the first time, creates the data folders, starts
the databases, waits until they are healthy, then provisions one isolated database and user per
project and writes the connection settings to secrets\<project>.env (git-ignored). A project's
compose file points its env_file at that file and joins the `market-infra` network.

Safe to run repeatedly: existing containers, data, passwords and project accounts are reused.

.PARAMETER Project  Project name(s) to provision, e.g. ath_scanner. Lower-case letters, digits, underscore.
.PARAMETER Llm      Also start the vLLM server (holds the GPU; weights must be in models\huggingface, see models.ps1).
.PARAMETER Rebuild  Rebuild the vLLM image.
.PARAMETER NoWait   With -Llm: start vLLM but do not wait for it (a caller that has other work to do
                    first can poll the container's health itself: docker inspect mri-vllm).
#>
param(
    [string[]]$Project = @(),
    [switch]$Llm,
    [switch]$Rebuild,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# docker writes ordinary progress to stderr; keep it from becoming a PowerShell error.
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

function New-Secret {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]', '').Substring(0, 24)
}

function Read-EnvFile([string]$Path) {
    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $map
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

Write-Host "=== Shared market-research infrastructure ===" -ForegroundColor Cyan

$null = & docker info 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: Docker is not running. Start Docker Desktop and retry." -ForegroundColor Red; exit 1 }

# .env: keep whatever is there, add only what is missing (never rotate an existing password,
# the databases were initialised with it).
$envPath = Join-Path $PSScriptRoot '.env'
$cfg = Read-EnvFile $envPath
$added = @()
foreach ($name in 'POSTGRES_ADMIN_PASSWORD', 'MONGO_ADMIN_PASSWORD', 'NEO4J_PASSWORD') {
    if (-not $cfg.ContainsKey($name)) { $cfg[$name] = New-Secret; $added += $name }
}
if ($added.Count -gt 0) {
    $existing = if (Test-Path -LiteralPath $envPath) { [IO.File]::ReadAllText($envPath) } else { "" }
    if ($existing -and -not $existing.EndsWith("`n")) { $existing += "`n" }
    $new = ($added | ForEach-Object { "$_=$($cfg[$_])" }) -join "`n"
    Write-Utf8NoBom $envPath ($existing + $new + "`n")
    Write-Host ".env: generated $($added -join ', ') (git-ignored)."
}
$adminPg    = if ($cfg['POSTGRES_ADMIN_USER']) { $cfg['POSTGRES_ADMIN_USER'] } else { 'mri_admin' }
$adminMongo = if ($cfg['MONGO_ADMIN_USER'])    { $cfg['MONGO_ADMIN_USER'] }    else { 'mri_admin' }

# Data folders: created here so Docker does not create them root-owned or in the wrong place.
$dataDir   = if ($cfg['DATA_DIR'])   { $cfg['DATA_DIR'] }   else { './data' }
$modelsDir = if ($cfg['MODELS_DIR']) { $cfg['MODELS_DIR'] } else { './models' }
foreach ($rel in "$dataDir/postgres", "$dataDir/mongo", "$dataDir/neo4j/data", "$dataDir/neo4j/logs", "$modelsDir/huggingface", 'secrets') {
    $full = if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $PSScriptRoot $rel }
    New-Item -ItemType Directory -Force -Path $full | Out-Null
}

Write-Host "Starting postgres, mongo and neo4j..." -ForegroundColor Cyan
$code = Invoke-Docker @('compose', 'up', '-d', '--wait', '--wait-timeout', '300', 'postgres', 'mongo', 'neo4j')
if ($code -ne 0) {
    Write-Host "Error: the databases did not become healthy. See: docker compose logs" -ForegroundColor Red
    exit 1
}

# One database + one user per project. Idempotent: re-applying the stored password is a no-op.
function Initialize-Project([string]$Name) {
    if ($Name -notmatch '^[a-z][a-z0-9_]{1,30}$') {
        throw "Project name '$Name' must be lower-case letters, digits and underscores, starting with a letter."
    }
    $secretPath = Join-Path $PSScriptRoot "secrets\$Name.env"
    $s = Read-EnvFile $secretPath
    if (-not $s['POSTGRES_PASSWORD']) { $s['POSTGRES_PASSWORD'] = New-Secret }
    if (-not $s['MONGO_PASSWORD'])    { $s['MONGO_PASSWORD']    = New-Secret }
    $pgPw = $s['POSTGRES_PASSWORD']; $mgPw = $s['MONGO_PASSWORD']

    $sql = @"
DO `$`$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$Name') THEN
    CREATE ROLE $Name LOGIN PASSWORD '$pgPw';
  ELSE
    ALTER ROLE $Name PASSWORD '$pgPw';
  END IF;
END `$`$;
SELECT 'CREATE DATABASE $Name OWNER $Name' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$Name')\gexec
"@
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = $sql | & docker exec -i -e "PGPASSWORD=$($cfg['POSTGRES_ADMIN_PASSWORD'])" mri-postgres psql -U $adminPg -d postgres -v ON_ERROR_STOP=1 -q
        if ($LASTEXITCODE -ne 0) { throw "Postgres provisioning for '$Name' failed: $out" }

        $js = "const d = db.getSiblingDB('$Name'); if (d.getUser('$Name')) { d.updateUser('$Name', {pwd: '$mgPw'}) } else { d.createUser({user: '$Name', pwd: '$mgPw', roles: [{role: 'readWrite', db: '$Name'}]}) }; print('ok')"
        $out = $js | & docker exec -i mri-mongo mongosh "mongodb://${adminMongo}:$($cfg['MONGO_ADMIN_PASSWORD'])@localhost:27017/admin" --quiet
        if ($LASTEXITCODE -ne 0) { throw "Mongo provisioning for '$Name' failed: $out" }
    } finally {
        $ErrorActionPreference = $prev
    }

    $lines = @(
        "# Connection settings for project '$Name' on the shared infrastructure. Generated by up.ps1; git-ignored.",
        "POSTGRES_HOST=postgres",
        "POSTGRES_PORT=5432",
        "POSTGRES_DB=$Name",
        "POSTGRES_USER=$Name",
        "POSTGRES_PASSWORD=$pgPw",
        "POSTGRES_DSN=postgresql://${Name}:${pgPw}@postgres:5432/$Name",
        "MONGO_URI=mongodb://${Name}:${mgPw}@mongo:27017/${Name}?authSource=$Name",
        "MONGO_DB=$Name",
        "MONGO_PASSWORD=$mgPw",
        "NEO4J_URI=bolt://neo4j:7687",
        "NEO4J_USER=neo4j",
        "NEO4J_PASSWORD=$($cfg['NEO4J_PASSWORD'])",
        "NEO4J_AUTH=neo4j/$($cfg['NEO4J_PASSWORD'])",
        "VLLM_URL=http://vllm:8000"
    )
    Write-Utf8NoBom $secretPath (($lines -join "`n") + "`n")
    Write-Host "Project '$Name': postgres db+user, mongo db+user ready -> secrets\$Name.env" -ForegroundColor Green
}
foreach ($p in $Project) { Initialize-Project $p }

if ($Llm) {
    $hub = Join-Path $PSScriptRoot ("$modelsDir/huggingface/hub" -replace '^\./', '')
    if (-not (Test-Path -LiteralPath (Join-Path $hub 'models--Qwen--Qwen3-4B-Instruct-2507'))) {
        Write-Host "Model weights are not in models\huggingface yet. Run .\models.ps1 first (about 9 GB)." -ForegroundColor Red
        exit 1
    }
    Write-Host "Starting vLLM (GPU)..." -ForegroundColor Cyan
    $upArgs = @('compose', '--profile', 'llm', 'up', '-d')
    if (-not $NoWait) { $upArgs += @('--wait', '--wait-timeout', '1800') }
    if ($Rebuild) { $upArgs += '--build' }
    $upArgs += 'vllm'
    $code = Invoke-Docker $upArgs
    if ($code -ne 0) { Write-Host "Error: vLLM did not become healthy. See: docker logs mri-vllm" -ForegroundColor Red; exit 1 }
}

Write-Host ""
Write-Host "Ready (localhost only):" -ForegroundColor Green
Write-Host "  Postgres   127.0.0.1:$(if ($cfg['POSTGRES_PORT']) { $cfg['POSTGRES_PORT'] } else { 5432 })      in-network: postgres:5432"
Write-Host "  MongoDB    127.0.0.1:$(if ($cfg['MONGO_PORT']) { $cfg['MONGO_PORT'] } else { 27017 })     in-network: mongo:27017"
Write-Host "  Neo4j      http://127.0.0.1:$(if ($cfg['NEO4J_HTTP_PORT']) { $cfg['NEO4J_HTTP_PORT'] } else { 7474 })   in-network: bolt://neo4j:7687"
if ($Llm) { Write-Host "  vLLM       http://127.0.0.1:$(if ($cfg['VLLM_PORT']) { $cfg['VLLM_PORT'] } else { 8001 })   in-network: http://vllm:8000" }
