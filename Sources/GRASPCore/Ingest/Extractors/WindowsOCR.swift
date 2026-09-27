#if os(Windows)
import Foundation

/// Text from PDFs and images on Windows, through Windows' own PDF renderer
/// (Windows.Data.Pdf) and OCR engine (Windows.Media.Ocr).
///
/// Swift can't reach those WinRT APIs directly here -- the bindings this
/// project uses don't include them -- but Windows PowerShell can, so this
/// runs a small script and reads its output. Each PDF page is rendered and
/// read by OCR, which works for typed and scanned PDFs alike (the Mac reads
/// a PDF's text layer, and OCRs only the pages that have none).
///
/// nil when the file couldn't be read at all; "" when it had no legible
/// text -- the same convention as `PDFExtractor` and `ImageExtractor`.
enum WindowsOCR {
    /// The longest one file may take: a 60-page PDF is about 30 seconds.
    static let timeout: TimeInterval = 180

    static func extractText(from url: URL) -> String? {
        guard let script = scriptURL() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: powershellPath)
        process.arguments = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                             "-File", nativePath(script), "-Path", nativePath(url)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `C:\Users\...`: WinRT's StorageFile refuses forward slashes, which is
    /// what `URL.path` gives.
    private static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    private static var powershellPath: String {
        let windows = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        return windows + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    }

    /// The script, written once per version to the temp folder.
    private static func scriptURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-ocr-v1.ps1")
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try Data(script.utf8).write(to: url)
            } catch {
                return nil
            }
        }
        return url
    }

    private static let script = #"""
    param([string]$Path)
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
    function Await($op, [Type]$type) { $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(); $t.Result }
    function AwaitAction($op) { $t = $asTaskAction.Invoke($null, @($op)); $t.Wait() }
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $engine) { exit 2 }
    function Read-Stream($stream) {
        $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        ($result.Lines | ForEach-Object { $_.Text }) -join "`n"
    }
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    if ($Path -match '\.pdf$') {
        $doc = Await ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
        for ($i = 0; $i -lt $doc.PageCount; $i++) {
            $page = $doc.GetPage($i)
            $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
            $options = New-Object Windows.Data.Pdf.PdfPageRenderOptions
            # About 2.5x a letter page's points: sharp enough for small print.
            $options.DestinationWidth = [uint32]([math]::Min(2400, $page.Size.Width * 2.5))
            AwaitAction ($page.RenderToStreamAsync($stream, $options))
            Read-Stream $stream
            ''
        }
    } else {
        $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        Read-Stream $stream
    }
    """#
}
#endif
