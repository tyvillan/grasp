# Builds and runs GRASP's core on Windows:
#
#   scripts\windows\grasp.cmd check    swift run grasp-check
#   scripts\windows\grasp.cmd test     swift test
#   scripts\windows\grasp.cmd build    swift build
#   scripts\windows\grasp.cmd app      builds and opens the GRASP app (Windows\)
#   scripts\windows\grasp.cmd app-build  builds the app without opening it
#   scripts\windows\grasp.cmd uia-probe  finds which control crashes UI Automation
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
    [ValidateSet('check', 'test', 'build', 'app', 'app-build', 'uia-probe')]
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

# --- UI Automation probe ---------------------------------------------------

# Opens one window per control kind, walks each with UI Automation the way
# Narrator would, and records which ones take the app down. Standard
# output and error go to files: a GUI app writing to a console it failed
# to attach to is a suspected cause of a separate startup crash.
function Invoke-UiaProbe([string]$Bin) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $logs = Join-Path $Repo '.build-windows\uia-probe'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null

    # The GRASP app itself, as a renamed copy so SwiftCrossUI's
    # single-instance redirect doesn't hand it to a GRASP window already open.
    $appCopy = Join-Path $Bin 'GRASPWindowsUiaProbe.exe'
    Copy-Item (Join-Path $Bin 'GRASPWindows.exe') $appCopy -Force

    $cases = @('text', 'vstack', 'button', 'disabled-button', 'list', 'split', 'scroll', 'shape',
               'rectangle', 'background', 'divider', 'textfield', 'toggle', 'spinner') |
        ForEach-Object { @{ Name = $_; Exe = (Join-Path $Bin 'UIAProbe.exe') } }
    $cases += @{ Name = 'grasp-app'; Exe = $appCopy }

    $results = foreach ($case in $cases) {
        $env:PROBE = $case.Name
        $env:GRASP_SUPPORT_DIR = Join-Path $logs 'library'
        $proc = Start-Process -FilePath $case.Exe -PassThru `
            -RedirectStandardOutput (Join-Path $logs "$($case.Name).out.txt") `
            -RedirectStandardError (Join-Path $logs "$($case.Name).err.txt")
        # Read the handle now: without it PowerShell can't report the exit
        # code once the process has ended.
        $null = $proc.Handle
        $handle = [IntPtr]::Zero
        for ($i = 0; $i -lt 80 -and $handle -eq [IntPtr]::Zero -and -not $proc.HasExited; $i++) {
            Start-Sleep -Milliseconds 250
            $proc.Refresh()
            $handle = $proc.MainWindowHandle
        }
        $walk = 'no window'
        if ($handle -ne [IntPtr]::Zero) {
            Start-Sleep -Seconds 1
            try {
                $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
                $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                                       [System.Windows.Automation.Condition]::TrueCondition)
                $walk = "walked $($found.Count) elements"
            } catch {
                $ex = $_.Exception
                while ($ex.InnerException) { $ex = $ex.InnerException }
                $walk = 'error ' + ('0x{0:X8}' -f $ex.HResult) + ': ' + $ex.Message
            }
        }
        Start-Sleep -Seconds 2
        $proc.Refresh()
        $outcome = if ($proc.HasExited) { 'CRASHED (exit 0x{0:X8})' -f $proc.ExitCode } else { 'survived' }
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
        Start-Sleep -Milliseconds 500
        [pscustomobject]@{ Control = $case.Name; 'UI Automation' = $walk; App = $outcome }
    }
    Remove-Item Env:PROBE, Env:GRASP_SUPPORT_DIR -ErrorAction SilentlyContinue
    Remove-Item $appCopy -ErrorAction SilentlyContinue

    $table = $results | Format-Table -AutoSize -Wrap | Out-String -Width 200
    Write-Host $table
    $table | Set-Content (Join-Path $logs 'results.txt')
    Write-Host "Logs and results: $logs"
}

# --- App linking -----------------------------------------------------------

# Linker flags for GRASPWindows.exe: embed the app icon
# (Windows\Resources\GRASP.rc) and link as a GUI program, so starting it
# from a shortcut shows GRASP's icon and no console window. The Windows
# package builds no DLLs of its own, so these only reach the exe. Every
# command that builds the app uses them, so none quietly relinks it as a
# console program without its icon.
function Get-AppLinkFlags {
    $res = Join-Path $Repo '.build-windows\GRASP.res'
    & rc.exe /nologo /fo $res (Join-Path $Repo 'Windows\Resources\GRASP.rc')
    if ($LASTEXITCODE -ne 0) { throw 'Compiling the app icon failed.' }
    return @('-Xlinker', $res, '-Xlinker', '/SUBSYSTEM:WINDOWS', '-Xlinker', '/ENTRY:mainCRTStartup')
}

# --- Swift -----------------------------------------------------------------

Push-Location $Repo
try {
    switch ($Command) {
        'check' { Step 'swift run grasp-check'; & swift run @flags @SwiftArgs grasp-check }
        'test'  { Step 'swift test';            & swift test @flags @SwiftArgs }
        'build' { Step 'swift build';           & swift build @flags @SwiftArgs }
        'app'   {
            # The app is its own package, so its SwiftCrossUI dependency
            # stays out of the Mac and iPhone builds.
            Set-Location (Join-Path $Repo 'Windows')
            # Name SwiftCrossUI's backend outright. Left to DefaultBackend's
            # platform conditions, Swift 6.4's build system still compiles
            # the Linux-only Gtk targets and fails on a missing gtk/gtk.h.
            $env:SCUI_DEFAULT_BACKEND = 'WinUIBackend'
            $appFlags = Get-AppLinkFlags
            Step 'swift run GRASPWindows'
            & swift run @flags @appFlags @SwiftArgs GRASPWindows
        }
        'app-build' {
            # The same build as 'app', without opening the window: for
            # checking warnings, or rebuilding while GRASP is closed.
            Set-Location (Join-Path $Repo 'Windows')
            $env:SCUI_DEFAULT_BACKEND = 'WinUIBackend'
            $appFlags = Get-AppLinkFlags
            Step 'swift build --product GRASPWindows'
            & swift build @flags @appFlags @SwiftArgs --product GRASPWindows
        }
        'uia-probe' {
            Set-Location (Join-Path $Repo 'Windows')
            $env:SCUI_DEFAULT_BACKEND = 'WinUIBackend'
            Step 'Building the probe and the app'
            & swift build @flags --product UIAProbe
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            $appFlags = Get-AppLinkFlags
            & swift build @flags @appFlags --product GRASPWindows
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            $bin = Get-ChildItem -Path .build -Recurse -Filter UIAProbe.exe |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
                ForEach-Object { $_.DirectoryName }
            if (-not $bin) { throw 'Built UIAProbe.exe not found under Windows\.build.' }
            Invoke-UiaProbe -Bin $bin
            exit 0
        }
    }
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
