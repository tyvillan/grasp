# Regenerates Windows\Resources\GRASP.ico from the iPhone app icon, the
# same artwork as the Mac's AppIcon.icns. Run it again if the icon changes:
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows\make-icon.ps1
#
# The iPhone source is a full square (iOS rounds it itself), so this rounds
# the corners to match the Mac icon, then writes every size Windows asks
# for as a PNG-compressed icon entry.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Source = Join-Path $Repo 'GRASPiOS\App\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$Output = Join-Path $Repo 'Windows\Resources\GRASP.ico'
$Sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256

# The standard layout: 256 as PNG, smaller sizes as 32-bit bitmaps
# (BITMAPINFOHEADER, bottom-up BGRA rows, then an empty AND mask), which
# every Windows component can read.
function IconEntryData([Drawing.Bitmap]$bmp, [int]$size) {
    $ms = New-Object IO.MemoryStream
    if ($size -ge 256) {
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        return ,$ms.ToArray()
    }
    $w = New-Object IO.BinaryWriter $ms
    $maskRow = [int]([Math]::Ceiling($size / 32.0) * 4)
    $w.Write([UInt32]40); $w.Write([Int32]$size); $w.Write([Int32]($size * 2))
    $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]0)
    $w.Write([UInt32]($size * $size * 4 + $maskRow * $size))
    $w.Write([Int32]0); $w.Write([Int32]0); $w.Write([UInt32]0); $w.Write([UInt32]0)
    for ($y = $size - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $size; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
        }
    }
    $w.Write((New-Object byte[] ($maskRow * $size)))
    $w.Flush()
    return ,$ms.ToArray()
}

$src = [Drawing.Image]::FromFile($Source)
$pngs = foreach ($size in $Sizes) {
    $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([Drawing.Color]::Transparent)

    # A rounded square, radius about 22% of the side, as on macOS.
    $r = [single]($size * 0.225)
    $d = $r * 2
    $s = [single]$size
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($s - $d, 0, $d, $d, 270, 90)
    $path.AddArc($s - $d, $s - $d, $d, $d, 0, 90)
    $path.AddArc(0, $s - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = New-Object Drawing.TextureBrush $src
    $brush.ScaleTransform($s / $src.Width, $s / $src.Height)
    $g.FillPath($brush, $path)

    $g.Dispose()
    $data = [byte[]](IconEntryData $bmp $size)
    , $data
    $brush.Dispose(); $path.Dispose(); $bmp.Dispose()
}
$src.Dispose()

# ICONDIR, then one ICONDIRENTRY per size, then the PNG data.
$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$Sizes.Count)
$offset = 6 + 16 * $Sizes.Count
for ($i = 0; $i -lt $Sizes.Count; $i++) {
    $dim = if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] }   # 0 means 256
    $w.Write([byte]$dim); $w.Write([byte]$dim)
    $w.Write([byte]0); $w.Write([byte]0)                       # palette, reserved
    $w.Write([UInt16]1); $w.Write([UInt16]32)                  # planes, bits per pixel
    $w.Write([UInt32]$pngs[$i].Length); $w.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $w.Write([byte[]]$png) }
$w.Flush()
New-Item -ItemType Directory -Force -Path (Split-Path $Output) | Out-Null
[IO.File]::WriteAllBytes($Output, $out.ToArray())
Write-Host "Wrote $Output ($($out.Length) bytes, sizes $($Sizes -join ', '))"
