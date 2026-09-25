# Builds and runs GRASP's core on Windows:
#
#   scripts\windows\grasp.cmd check    swift run grasp-check
#   scripts\windows\grasp.cmd test     swift test
#   scripts\windows\grasp.cmd build    swift build
#
# Anything after the command is passed on to swift.
#
# Why a script rather than plain `swift run`: GRDB, GRASP's database
# library, links the system's SQLite, and Windows doesn't ship one. The
# first run downloads SQLite's official source and compiles it with the two
# optional features GRASP needs -- full-text search (FTS5, for searching
# notes) and WAL snapshots (which GRDB builds in) -- then points the Swift
# build at it. It also enters Visual Studio's build environment, so this
# works from a plain PowerShell window.

param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'test', 'build')]
    [string]$Command = 'check',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$SwiftArgs = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with its progress bar
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

# SQLite 3.53.4. The SHA-256 was taken from the zip whose SHA3-256 matches
# the one sqlite.org publishes on its download page.
$SqliteVersion = '3530400'
$SqliteUrl = "https://www.sqlite.org/2026/sqlite-amalgamation-$SqliteVersion.zip"
$SqliteSha256 = '1E71DDF93849C6A6ECF58B827C0692073D2DD7EE40196158068F7B29F422E87D'

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }

# --- Environment -----------------------------------------------------------

# A shell opened before Swift was installed has a stale PATH and no SDKROOT.
foreach ($name in 'Path', 'SDKROOT') {
    $machine = [Environment]::GetEnvironmentVariable($name, 'Machine')
    $user = [Environment]::GetEnvironmentVariable($name, 'User')
    if ($name -eq 'Path') {
        $env:Path = (@($env:Path, $machine, $user) | Where-Object { $_ }) -join ';'
    } elseif (-not $env:SDKROOT) {
        $env:SDKROOT = if ($machine) { $machine } else { $user }
    }
}
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    throw 'Swift is not installed, or not on PATH. See WINDOWS.md, step 1.'
}

# Visual Studio's compiler and linker (cl.exe, link.exe, lib.exe).
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    Step 'Entering the Visual Studio build environment'
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'Visual Studio is not installed. See WINDOWS.md, step 1.' }
    $vs = & $vswhere -latest -products * -property installationPath
    if (-not $vs) { throw 'No Visual Studio installation found. See WINDOWS.md, step 1.' }
    Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -Arch $Arch -HostArch $Arch | Out-Null
}

# --- SQLite ----------------------------------------------------------------

$Sqlite = Join-Path $Repo ".build-windows\sqlite-$SqliteVersion-$Arch"
if (-not (Test-Path (Join-Path $Sqlite 'sqlite3.lib'))) {
    Step "Building SQLite $SqliteVersion (once)"
    New-Item -ItemType Directory -Force -Path $Sqlite | Out-Null
    $zip = Join-Path $Sqlite 'source.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $SqliteUrl -OutFile $zip
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash
    if ($hash -ne $SqliteSha256) {
        Remove-Item $zip
        throw "SQLite download doesn't match its expected hash (got $hash)."
    }
    Expand-Archive -Force -Path $zip -DestinationPath $Sqlite
    $source = Join-Path $Sqlite "sqlite-amalgamation-$SqliteVersion"

    Push-Location $Sqlite
    try {
        # /MD: the DLL C runtime, which Swift on Windows links against.
        & cl.exe /nologo /c /O2 /MD /W0 `
            /DSQLITE_ENABLE_FTS5 /DSQLITE_ENABLE_SNAPSHOT /DSQLITE_THREADSAFE=1 `
            "$source\sqlite3.c" /Fo:sqlite3.obj
        if ($LASTEXITCODE -ne 0) { throw 'Compiling SQLite failed.' }
        # A static library, so there's no sqlite3.dll to ship or find at run time.
        & lib.exe /nologo /OUT:sqlite3.lib sqlite3.obj
        if ($LASTEXITCODE -ne 0) { throw 'Packaging SQLite failed.' }
        Copy-Item "$source\sqlite3.h", "$source\sqlite3ext.h" $Sqlite
        Remove-Item sqlite3.obj, $zip
        Remove-Item -Recurse $source
    } finally {
        Pop-Location
    }
}

# GRDB's module map does `#include <sqlite3.h>` and `link "sqlite3"`: put
# both on the search paths -- as flags for Swift and clang, and in INCLUDE
# and LIB for link.exe.
$env:INCLUDE = "$Sqlite;$env:INCLUDE"
$env:LIB = "$Sqlite;$env:LIB"
$flags = @('-Xcc', "-I$Sqlite", '-Xswiftc', '-L', '-Xswiftc', $Sqlite)

# --- Swift -----------------------------------------------------------------

Push-Location $Repo
try {
    switch ($Command) {
        'check' { Step 'swift run grasp-check'; & swift run @flags @SwiftArgs grasp-check }
        'test'  { Step 'swift test';            & swift test @flags @SwiftArgs }
        'build' { Step 'swift build';           & swift build @flags @SwiftArgs }
    }
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
