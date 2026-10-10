$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (!(Get-Command java -ErrorAction SilentlyContinue)) { throw 'Install Java 21 or newer.' }
if (!$env:KARO_DATA_DIR) { $env:KARO_DATA_DIR = Join-Path $PSScriptRoot 'data' }
if (!$env:BEYONDNET_DB_CONFIG) { $env:BEYONDNET_DB_CONFIG = Join-Path $PSScriptRoot 'data/postgres.properties' }
if (!(Test-Path $env:BEYONDNET_DB_CONFIG) -and !$env:BEYONDNET_DB_URL) { throw 'Set up PostgreSQL and data/postgres.properties first. See docs/SPRING_BOOT_SETUP.md.' }
& mvn -q -f backend/pom.xml -DskipTests package
if ($LASTEXITCODE -ne 0) { throw 'Java bank build failed.' }
& java -jar backend/target/bank-1.2.0.jar @args
