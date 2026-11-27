param(
  [ValidateSet('windows', 'android-arm64', 'all')]
  [string]$Target = 'windows'
)

$ErrorActionPreference = 'Stop'
$crateDir = Join-Path $PSScriptRoot '..\native\ttplay_stream'

Push-Location $crateDir
try {
  if ($Target -eq 'windows' -or $Target -eq 'all') {
    Write-Host 'Building ttplay_stream.dll for Windows...'
    cargo build --release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  if ($Target -eq 'android-arm64' -or $Target -eq 'all') {
    Write-Host 'Building libttplay_stream.so for Android arm64-v8a...'
    cargo ndk -t arm64-v8a -o ..\..\android\app\src\main\jniLibs build --release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
} finally {
  Pop-Location
}
