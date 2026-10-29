$ErrorActionPreference = "Stop"

$gameRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$fontPath = Join-Path $gameRoot "KiraMono.ttf"
$gameExe = Join-Path $gameRoot "BGI.exe"

if (-not (Test-Path -LiteralPath $fontPath)) {
    throw "KiraMono.ttf was not found beside the launcher."
}
if (-not (Test-Path -LiteralPath $gameExe)) {
    throw "BGI.exe was not found beside the launcher."
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class KiraKiraFontResource {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int AddFontResource(string fileName);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool RemoveFontResource(string fileName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr window,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out UIntPtr result
    );
}
"@

$added = [KiraKiraFontResource]::AddFontResource($fontPath)
if ($added -lt 1) {
    throw "Windows could not load KiraMono.ttf."
}

$broadcast = [IntPtr]0xffff
$wmFontChange = 0x001d
$sendAbortIfHung = 0x0002
$result = [UIntPtr]::Zero
[void][KiraKiraFontResource]::SendMessageTimeout(
    $broadcast,
    $wmFontChange,
    [UIntPtr]::Zero,
    [IntPtr]::Zero,
    $sendAbortIfHung,
    1000,
    [ref]$result
)

try {
    $process = Start-Process -FilePath $gameExe -WorkingDirectory $gameRoot -PassThru
    $process.WaitForExit()
    $exitCode = $process.ExitCode
}
finally {
    [void][KiraKiraFontResource]::RemoveFontResource($fontPath)
    $result = [UIntPtr]::Zero
    [void][KiraKiraFontResource]::SendMessageTimeout(
        $broadcast,
        $wmFontChange,
        [UIntPtr]::Zero,
        [IntPtr]::Zero,
        $sendAbortIfHung,
        1000,
        [ref]$result
    )
}

exit $exitCode
