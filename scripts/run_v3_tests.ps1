param(
    [string]$Iverilog = "iverilog",
    [string]$Vvp = "vvp",
    [string]$IverilogBase = "",
    [string]$VvpModulePath = "",
    [switch]$SkipFirmware
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root "sources_1/new"
$simDir = Join-Path $root "sim_1/new"
$buildDir = Join-Path $root ".sim_build/v3"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $root
try {
    if (-not $SkipFirmware) {
        Write-Host "[firmware] assemble, ISA-check, and behavior-test"
        & (Join-Path $root "firmware/build.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Firmware build or behavior test failed."
        }
    }

    $sources = Get-ChildItem -LiteralPath $srcDir -Filter "*.v" |
        Sort-Object Name |
        ForEach-Object { $_.FullName }

    $tests = @(
        "tb_v3_platform_io",
        "tb_v3_sync_memory",
        "tb_v3_memory_subsystem",
        "tb_v3_vga_timing",
        "tb_v3_tile_renderer",
        "tb_v3_game_soc"
    )

    foreach ($test in $tests) {
        $testFile = Join-Path $simDir ($test + ".v")
        $outputFile = Join-Path $buildDir ($test + ".vvp")
        $compileArgs = @(
            "-g2012", "-Wall", "-I", $simDir,
            "-s", $test, "-o", $outputFile
        )
        if ($IverilogBase -ne "") {
            $compileArgs += @("-B", $IverilogBase)
        }
        $compileArgs += $sources
        $compileArgs += $testFile

        Write-Host "[compile] $test"
        & $Iverilog @compileArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Compilation failed: $test"
        }

        Write-Host "[run]     $test"
        $vvpArgs = @()
        if ($VvpModulePath -ne "") {
            $vvpArgs += @("-M", $VvpModulePath)
        }
        $vvpArgs += $outputFile
        & $Vvp @vvpArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Simulation failed: $test"
        }
    }

    Write-Host "PASS: firmware plus all TD8_To_RISCV_v3 game-platform tests"
}
finally {
    Pop-Location
}
