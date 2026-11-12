$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$name = "jibhr-pg-test"
$port = 54329

docker rm -f $name 2>&1 | Out-Null
Start-Sleep -Seconds 1
docker run -d --name $name -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=jibhr -p "${port}:5432" postgres:17
if ($LASTEXITCODE -ne 0) { throw "could not start postgres" }

$ready = $false
foreach ($i in 1..40) {
  docker exec $name psql -U postgres -d jibhr -c "select 1" *> $null
  if ($LASTEXITCODE -eq 0) { $ready = $true; break }
  Start-Sleep -Seconds 1
}
if (-not $ready) { throw "Postgres did not become ready" }

docker exec $name mkdir -p /work/migrations /work/tests | Out-Null
docker cp "$root\supabase\migrations\." "${name}:/work/migrations"
docker cp "$root\supabase\tests\." "${name}:/work/tests"

docker exec $name psql -U postgres -d jibhr -v ON_ERROR_STOP=1 -f /work/tests/00_local_auth_stub.sql
if ($LASTEXITCODE -ne 0) { throw "auth stub failed" }

Get-ChildItem "$root\supabase\migrations\*.sql" | Sort-Object Name | ForEach-Object {
  Write-Host "apply $($_.Name)"
  docker exec $name psql -U postgres -d jibhr -v ON_ERROR_STOP=1 -f "/work/migrations/$($_.Name)"
  if ($LASTEXITCODE -ne 0) { throw "migration failed: $($_.Name)" }
}

Write-Host "critical tests"
docker exec $name psql -U postgres -d jibhr -v ON_ERROR_STOP=1 -f /work/tests/critical.sql
if ($LASTEXITCODE -ne 0) { throw "critical tests failed" }

Write-Host "group page tests"
docker exec $name psql -U postgres -d jibhr -v ON_ERROR_STOP=1 -f /work/tests/attendance_group_page.sql
if ($LASTEXITCODE -ne 0) { throw "group page tests failed" }

Write-Host "dashboard split tests"
docker exec $name psql -U postgres -d jibhr -v ON_ERROR_STOP=1 -f /work/tests/dashboard_split.sql
if ($LASTEXITCODE -ne 0) { throw "dashboard split tests failed" }

Write-Host "DB TESTS PASSED"
