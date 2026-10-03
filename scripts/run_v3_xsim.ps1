param(
    [string]$VivadoBin = "C:\AMDDesignTools\2025.2\Vivado\bin",
    [string[]]$Tests = @("tb_v3_game_soc"),
    [switch]$AllTests,
    [switch]$SkipFirmware
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root "sources_1/new"
$simDir = Join-Path $root "sim_1/new"
$buildDir = Join-Path $root ".sim_build/v3_xsim"

$xvlog = Join-Path $VivadoBin "xvlog.bat"
$xelab = Join-Path $VivadoBin "xelab.bat"
$xsim = Join-Path $VivadoBin "xsim.bat"
foreach ($tool in @($xvlog, $xelab, $xsim)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Vivado Simulator tool not found: $tool"
    }
}

$knownTests = @(
    "tb_v3_platform_io",
    "tb_v3_sync_memory",
    "tb_v3_memory_subsystem",
    "tb_v3_vga_timing",
    "tb_v3_tile_renderer",
    "tb_v3_game_soc"
)
if ($AllTests) {
    $Tests = $knownTests
}
if ($Tests.Count -eq 0) {
    throw "No testbench was selected."
}

$selectedTests = @()
foreach ($test in $Tests) {
    if ($test -notmatch '^tb_v3_[A-Za-z0-9_]+$') {
        throw "Invalid testbench name: $test"
    }
    $testFile = Join-Path $simDir ($test + ".v")
    if (-not (Test-Path -LiteralPath $testFile -PathType Leaf)) {
        throw "Testbench not found: $testFile"
    }
    if ($selectedTests -notcontains $test) {
        $selectedTests += $test
    }
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

if (-not $SkipFirmware) {
    Write-Host "[firmware] assemble, ISA-check, and behavior-test"
    & (Join-Path $root "firmware/build.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Firmware build or behavior test failed."
    }
}

$firmwareHex = Join-Path $root "firmware/build/imem_game.hex"
if (-not (Test-Path -LiteralPath $firmwareHex -PathType Leaf)) {
    throw "Firmware image not found: $firmwareHex"
}

# The SoC testbench deliberately uses the same relative ROM path as synthesis.
# Mirror that path below the isolated XSim working directory.
$stagedFirmwareDir = Join-Path $buildDir "firmware/build"
New-Item -ItemType Directory -Force -Path $stagedFirmwareDir | Out-Null
Copy-Item -LiteralPath $firmwareHex -Destination (Join-Path $stagedFirmwareDir "imem_game.hex") -Force

$sources = Get-ChildItem -LiteralPath $srcDir -Filter "*.v" |
    Sort-Object Name |
    ForEach-Object { $_.FullName }
$testFiles = $selectedTests | ForEach-Object { Join-Path $simDir ($_ + ".v") }

Push-Location $buildDir
try {
    $compileArgs = @(
        "--incr",
        "--relax",
        "--work", "work",
        "--include", $simDir,
        "--log", (Join-Path $buildDir "xvlog.log")
    )
    $compileArgs += $sources
    $compileArgs += $testFiles

    Write-Host "[xvlog] compile v3 RTL and $($selectedTests.Count) testbench(es)"
    & $xvlog @compileArgs
    if ($LASTEXITCODE -ne 0) {
        throw "xvlog failed. See $(Join-Path $buildDir 'xvlog.log')"
    }

    foreach ($test in $selectedTests) {
        $snapshot = $test + "_snapshot"
        $elabLog = Join-Path $buildDir ($test + "_xelab.log")
        $simLog = Join-Path $buildDir ($test + "_xsim.log")
        $waveFile = Join-Path $buildDir ($test + ".wdb")

        Write-Host "[xelab] $test"
        $elabArgs = @(
            "--incr",
            "--relax",
            "--debug", "typical",
            "--mt", "auto",
            "--snapshot", $snapshot,
            "--log", $elabLog,
            ("work." + $test)
        )
        & $xelab @elabArgs
        if ($LASTEXITCODE -ne 0) {
            throw "xelab failed for $test. See $elabLog"
        }

        Write-Host "[xsim]  $test"
        $simArgs = @(
            $snapshot,
            "--runall",
            "--onerror", "quit",
            "--onfinish", "quit",
            "--wdb", $waveFile,
            "--log", $simLog
        )
        & $xsim @simArgs
        if ($LASTEXITCODE -ne 0) {
            throw "xsim failed for $test. See $simLog"
        }

        $simulationText = Get-Content -LiteralPath $simLog -Raw
        if (($simulationText -match '(?m)^FAIL:') -or
            ($simulationText -notmatch '(?m)^PASS:')) {
            throw "Testbench did not report PASS: $test. See $simLog"
        }
        Write-Host "[pass]  $test"
    }

    Write-Host "PASS: Vivado Simulator completed all selected v3 tests"
}
finally {
    Pop-Location
}
