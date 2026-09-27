# Installs GRASP for the current user, like an ordinary Windows app:
#
#   scripts\windows\install.ps1              builds the optimised app, then installs it
#   scripts\windows\install.ps1 -SkipBuild   installs the last optimised build
#   scripts\windows\install.ps1 -Uninstall   removes it again
#
# Goes to %LOCALAPPDATA%\Programs\GRASP (no administrator needed), with the
# Swift runtime copied beside the app so it doesn't depend on the developer
# toolchain, a Start menu entry, a desktop shortcut, and an entry in
# Settings > Apps > Installed apps that uninstalls it. Your library in
# %LOCALAPPDATA%\GRASP is never touched, by installing or uninstalling.

param(
    [switch]$SkipBuild,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\GRASP'
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'GRASP.lnk'
$Desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'GRASP.lnk'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GRASP'
# The exe keeps its build name: the single-instance key and the grasp://
# sign-in link are both tied to it (see SignInLink.swift).
$ExeName = 'GRASPWindows.exe'

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }

function Stop-Grasp {
    $running = Get-Process -Name GRASPWindows -ErrorAction SilentlyContinue
    if (-not $running) { return }
    Step 'Closing GRASP'
    $running | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 3
    Get-Process -Name GRASPWindows -ErrorAction SilentlyContinue | Stop-Process -Force
}

if ($Uninstall) {
    Stop-Grasp
    Step "Removing $InstallDir"
    if (Test-Path $InstallDir) { [IO.Directory]::Delete($InstallDir, $true) }
    foreach ($link in $StartMenu, $Desktop) {
        if (Test-Path $link) {
            $target = (New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath
            # Only our shortcuts: a desktop GRASP.lnk pointing at a dev build stays.
            if ($target -like "$InstallDir*") { [IO.File]::Delete($link) }
        }
    }
    if (Test-Path $UninstallKey) { Remove-Item $UninstallKey -Recurse }
    Write-Host 'GRASP is uninstalled. Your library in %LOCALAPPDATA%\GRASP is still there.' -ForegroundColor Green
    exit 0
}

$Products = Join-Path $Repo 'Windows\.build\out\Products\Release-windows-x86_64'
if (-not $SkipBuild) {
    Stop-Grasp
    Step 'Building the optimised app (this can take ten minutes or more)'
    & (Join-Path $PSScriptRoot 'grasp.cmd') app-release
    if ($LASTEXITCODE -ne 0) { throw 'The build failed; nothing was installed.' }
}
$Exe = Join-Path $Products $ExeName
if (-not (Test-Path $Exe)) { throw "No optimised build at $Exe. Run without -SkipBuild." }

# The Swift runtime: the directory holding swiftCore.dll on this PC.
$swiftCore = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Swift\Runtimes') -Recurse -Filter swiftCore.dll -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $swiftCore) { throw 'The Swift runtime (swiftCore.dll) was not found under %LOCALAPPDATA%\Programs\Swift\Runtimes.' }
$Runtime = $swiftCore.DirectoryName

Stop-Grasp
Step "Installing to $InstallDir"
if (Test-Path $InstallDir) { [IO.Directory]::Delete($InstallDir, $true) }
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item $Exe $InstallDir
# Resource bundles the app loads at run time (the Windows App SDK bootstrap
# among them).
Get-ChildItem $Products -Directory -Filter '*.bundle' | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $InstallDir $_.Name) -Recurse
}
Step "Copying the Swift runtime from $Runtime"
Get-ChildItem $Runtime -Filter '*.dll' | Copy-Item -Destination $InstallDir
# The uninstaller Settings > Apps runs is this same script.
Copy-Item $PSCommandPath (Join-Path $InstallDir 'install.ps1')

$InstalledExe = Join-Path $InstallDir $ExeName
Step 'Adding Start menu and desktop shortcuts'
$shell = New-Object -ComObject WScript.Shell
foreach ($path in $StartMenu, $Desktop) {
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = $InstalledExe
    $link.WorkingDirectory = $InstallDir
    $link.IconLocation = "$InstalledExe,0"
    $link.Description = 'GRASP: flashcards and lessons from your notes'
    $link.Save()
}

Step 'Registering the uninstaller'
$size = [int]((Get-ChildItem $InstallDir -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
New-Item -Path $UninstallKey -Force | Out-Null
$uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\install.ps1`" -Uninstall"
$values = @{
    DisplayName = 'GRASP'; Publisher = 'GRASP'; DisplayIcon = "$InstalledExe,0"
    InstallLocation = $InstallDir; UninstallString = $uninstallCommand; QuietUninstallString = $uninstallCommand
    DisplayVersion = (Get-Date -Format 'yyyy.M.d')
}
foreach ($name in $values.Keys) { New-ItemProperty -Path $UninstallKey -Name $name -Value $values[$name] -Force | Out-Null }
New-ItemProperty -Path $UninstallKey -Name EstimatedSize -Value $size -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $UninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $UninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host "GRASP is installed. Open it from the Start menu or the desktop shortcut." -ForegroundColor Green
