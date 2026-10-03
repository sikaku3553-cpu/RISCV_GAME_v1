param(
    [string]$OutputDirectory = "build"
)

$ErrorActionPreference = "Stop"
$FirmwareDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source = Join-Path $FirmwareDirectory "game.S"
$Assembler = Join-Path $FirmwareDirectory "rv32i_asm.py"
$Output = Join-Path $FirmwareDirectory $OutputDirectory

$BundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if (Test-Path -LiteralPath $BundledPython) {
    $Python = $BundledPython
    $PythonArguments = @()
} elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
    $Python = (Get-Command python3).Source
    $PythonArguments = @()
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $Python = (Get-Command py).Source
    $PythonArguments = @("-3")
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $Python = (Get-Command python).Source
    $PythonArguments = @()
} else {
    throw "Python 3 is required to run the self-contained RV32I assembler."
}

& $Python @PythonArguments $Assembler $Source --output-dir $Output
if ($LASTEXITCODE -ne 0) {
    throw "RV32I firmware build or post-assembly validation failed."
}

$BehaviorTest = Join-Path $FirmwareDirectory "test_firmware.py"
& $Python @PythonArguments $BehaviorTest --build-dir $Output
if ($LASTEXITCODE -ne 0) {
    throw "RV32I firmware behavioral smoke test failed."
}

Write-Host "Firmware build complete: $Output"
Get-Content -LiteralPath (Join-Path $Output "rv32i_validation.txt")
