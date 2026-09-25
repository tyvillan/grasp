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

## What doesn't work on Windows yet

| Feature | Status |
| --- | --- |
| Reading PDFs | Planned, using Windows' own PDF reader (Windows.Data.Pdf) |
| Text in photos (OCR) | Planned, using Windows' own OCR (Windows.Media.Ocr) |
| Apple's on-device AI | Mac and iPhone only. On Windows, AI runs through Ollama |
| The app itself | Next step, once the core checks pass |

For AI features, install [Ollama for Windows](https://ollama.com/download)
and pull a model, for example `ollama pull qwen3.5:9b`. The check reports
whether it can see Ollama. It passes either way.
