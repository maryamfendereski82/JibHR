# Independent Postgres backup. DATABASE_URL must already be in the environment.
# The dump is not committed.

$ErrorActionPreference = "Stop"
if (-not $env:DATABASE_URL) { throw "DATABASE_URL is missing" }
$stamp = Get-Date -Format "yyyyMMdd-HHmm"
$dir = Join-Path $PSScriptRoot "..\backups"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir "jibhr-$stamp.dump"
pg_dump --format=custom --no-owner --dbname $env:DATABASE_URL --file $file
Write-Host "wrote $file"
