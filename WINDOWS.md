# GRASP on Windows

GRASP for Windows reuses the same Swift core as the Mac and iPhone apps:
importing notes, the study scheduler, overviews and sync. Only the screens
are built separately. This guide gets that core building on a Windows PC and
checks that it works, which has to happen before any Windows screens are built.

## 1. Install the tools (once)

Open **PowerShell** and run these three commands. Each one takes a few minutes.

```powershell
# Visual Studio's C++ build tools and the Windows SDK, which Swift needs
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget

# Swift itself (6.2 or newer)
winget install --id Swift.Toolchain -e --source winget

# Git, to download GRASP
winget install --id Git.Git -e --source winget
```

Then:

- **Turn on Developer Mode**: Settings → System → For developers →
  Developer Mode. Swift's package manager needs it to create links between
  files.
- **Close PowerShell and open a new window.**

Check it worked:

```powershell
swift --version
```

This should print `Swift version 6.x`.

## 2. Download GRASP

```powershell
cd $HOME
git clone https://github.com/tyvillan/grasp.git
cd grasp
git checkout windows-core
```

If the repository is private, Git will ask you to sign in to GitHub the first
time, and a browser window opens for that.

## 3. Run the check

```powershell
scripts\windows\grasp.cmd check
```

Use this script instead of running `swift` directly. GRASP's database
library needs SQLite, and Windows doesn't include one. On its first run the
script downloads SQLite's official source, checks it against a pinned hash,
and compiles it with the features GRASP uses. It also sets up Visual Studio's
compiler and linker, so a plain PowerShell window works. The SQLite it builds
stays in `.build-windows\`.

The first run downloads GRASP's libraries and compiles everything, which takes
several minutes. Then it runs nine checks against GRASP's core: it creates a
library, imports a sample Matrix Theory note, schedules a review, row-reduces
a matrix, and so on.

- **"Everything passed"**: the core works on your PC.
- **Anything else**, including a build error before the checks start: copy
  all of the output and send it over.

## 4. Run the full test suite (optional, but useful)

```powershell
scripts\windows\grasp.cmd test
```

This runs the same 470+ tests the Mac passes. Some that read the Mac owner's
real notes vault skip themselves on other machines. Send over any failures.

## 5. Open the app (development build)

The Windows app lives in `Windows\`. It's built with
[SwiftCrossUI](https://github.com/moreSwift/swift-cross-ui), which draws
native WinUI controls. For now it's a prototype: import notes (or try the
built-in sample lecture), approve drafts, study due cards, and step through
a row reduction from the notes.

It needs two more things from Microsoft, once:

```powershell
# The Windows SDK version SwiftCrossUI's WinUI bindings are built against
winget install --id Microsoft.WindowsSDK.10.0.17763 -e --source winget
```

Then download and run the **Windows App SDK 1.5 runtime** installer for your
PC. For most PCs that's
[x64](https://aka.ms/windowsappsdk/1.5/1.5.250108004/windowsappruntimeinstall-x64.exe);
for Arm PCs use
[arm64](https://aka.ms/windowsappsdk/1.5/1.5.250108004/windowsappruntimeinstall-arm64.exe).
This is the stable 1.5 release SwiftCrossUI's WinUI bindings are built
against. It doesn't need admin rights. If you installed the older
`1.5-preview1` runtime, this one installs alongside it.

Then:

```powershell
scripts\windows\grasp.cmd app
```

The app keeps its library in `%LOCALAPPDATA%\GRASP`, the same folder
grasp-check reports.

## 6. Install GRASP like an ordinary app

```powershell
scripts\windows\install.ps1
```

This builds the optimised app (ten minutes or more the first time) and
installs it for you alone, in `%LOCALAPPDATA%\Programs\GRASP`, with a
Start menu entry, a desktop shortcut and an entry in Settings > Apps >
Installed apps that uninstalls it. No administrator rights are needed, and
the Swift runtime is copied beside the app, so it keeps working if the
developer tools change. Run it again after pulling changes to update.
`-SkipBuild` reinstalls the last build; `-Uninstall` removes it. Your
library in `%LOCALAPPDATA%\GRASP` is never touched either way.

## 7. Local AI (optional)

Overviews, AI test questions and the card tools (Refine, Fill Gaps) run on
a local model through Ollama:

```powershell
winget install Ollama.Ollama
ollama pull qwen3.5:9b
```

The model is about 6 GB and wants a graphics card with 8 GB of memory; on
the processor alone it works, slowly. Ollama starts with Windows, and
GRASP's Settings > Local AI shows whether it can see it.

## What doesn't work on Windows yet

| Feature | Status |
| --- | --- |
| Reading PDFs and text in photos | Not yet: notes imported on a Mac arrive with their PDF text through sync; imported here, PDFs and images are skipped |
| Apple's on-device AI, widgets, Mac Calendar sync | Mac and iPhone only. On Windows, AI runs through Ollama |

Everything else the Mac app does -- the dashboard, calendar, study,
Learn and Test, overviews, card editing and AI tools, search, profiles and
sync -- works on Windows too.
