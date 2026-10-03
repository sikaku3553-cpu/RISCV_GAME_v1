param(
    [string]$Iverilog = "iverilog",
    [string]$Vvp = "vvp",
    [string]$IverilogBase = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root "sources_1/new"
$simDir = Join-Path $root "sim_1/new"
$buildDir = Join-Path $root ".sim_build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$sources = Get-ChildItem -LiteralPath $srcDir -Filter "*.v" |
    Sort-Object Name |
    ForEach-Object { $_.FullName }

$tests = @(
    "tb_v2_decoder",
    "tb_v2_immediates",
    "tb_v2_integer",
    "tb_v2_boundaries",
    "tb_v2_control_flow",
    "tb_v2_memory",
    "tb_v2_memory_boundaries",
    "tb_v2_mmio",
    "tb_v2_faults",
    "tb_v2_lutram_reset",
    "tb_v2_pipeline",
    "tb_v2_board"
)

foreach ($test in $tests) {
    $testFile = Join-Path $simDir ($test + ".v")
    $outputFile = Join-Path $buildDir ($test + ".vvp")
    $compileArgs = @("-g2012", "-Wall", "-I", $simDir, "-s", $test, "-o", $outputFile)
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
    & $Vvp $outputFile
    if ($LASTEXITCODE -ne 0) {
        throw "Simulation failed: $test"
    }
}

Write-Host "PASS: all TD8_To_RISCV_v2 tests"
