[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Host-only regression for smoke verdicts. These disposable console programs
# deliberately simulate a GPU inventory and CLI; they are not inference evidence.
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('ninfer-sm75-smoke-test-' + [guid]::NewGuid().ToString('N'))
$OriginalPath = $env:PATH
$OriginalOutput = $env:NINFER_SMOKE_FIXTURE_OUTPUT
$OriginalExit = $env:NINFER_SMOKE_FIXTURE_EXIT
try {
    foreach ($Rel in @('scripts', 'bin', 'tools')) {
        New-Item -ItemType Directory -Path (Join-Path $TestRoot $Rel) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'smoke-test-windows-sm75.ps1') -Destination (Join-Path $TestRoot 'scripts')
    $FixtureExe = Join-Path $TestRoot 'bin\ninfer.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class SmokeFixture {
    public static int Main() {
        if (Path.GetFileName(Environment.GetCommandLineArgs()[0]).Equals("nvidia-smi.exe", StringComparison.OrdinalIgnoreCase)) {
            Console.WriteLine("0, NVIDIA GeForce RTX 2080 Ti, 22528, 7.5, 616.56");
            return 0;
        }
        Console.Error.WriteLine("Diagnostic output: SM75 OK");
        Console.WriteLine(Environment.GetEnvironmentVariable("NINFER_SMOKE_FIXTURE_OUTPUT"));
        return int.Parse(Environment.GetEnvironmentVariable("NINFER_SMOKE_FIXTURE_EXIT"));
    }
}
'@ -Language CSharp -OutputAssembly $FixtureExe -OutputType ConsoleApplication
    Copy-Item -LiteralPath $FixtureExe -Destination (Join-Path $TestRoot 'tools\nvidia-smi.exe')
    $env:PATH = (Join-Path $TestRoot 'tools') + ';' + $OriginalPath
    $Model = Join-Path $TestRoot 'fixture.ninfer'
    [IO.File]::WriteAllText($Model, 'host-only test fixture')
    $Smoke = Join-Path $TestRoot 'scripts\smoke-test-windows-sm75.ps1'
    foreach ($Case in @(
        @{ Name = 'correct content with native stderr'; Output = 'SM75 OK'; Exit = 0; Error = $null },
        @{ Name = 'wrong content despite matching diagnostic'; Output = 'wrong answer'; Exit = 0; Error = '*unexpected content*' },
        @{ Name = 'empty content'; Output = ''; Exit = 0; Error = '*unexpected content*' },
        @{ Name = 'nonzero CLI exit with correct content'; Output = 'SM75 OK'; Exit = 1; Error = '*exit code 1*' }
    )) {
        $env:NINFER_SMOKE_FIXTURE_OUTPUT = $Case.Output
        $env:NINFER_SMOKE_FIXTURE_EXIT = [string]$Case.Exit
        $ActualError = $null
        try { & $Smoke -Model $Model } catch { $ActualError = $_.Exception.Message }
        if ($null -eq $Case.Error) {
            if ($null -ne $ActualError) { throw "Expected success for '$($Case.Name)': $ActualError" }
        } elseif ($null -eq $ActualError -or $ActualError -notlike $Case.Error) {
            throw "Expected '$($Case.Error)' for '$($Case.Name)', got '$ActualError'."
        }
        Write-Host "[PASS] $($Case.Name)"
    }
} finally {
    $env:PATH = $OriginalPath
    $env:NINFER_SMOKE_FIXTURE_OUTPUT = $OriginalOutput
    $env:NINFER_SMOKE_FIXTURE_EXIT = $OriginalExit
    $FullRoot = [IO.Path]::GetFullPath($TestRoot)
    $TempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($FullRoot.StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $FullRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
