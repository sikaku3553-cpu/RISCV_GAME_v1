param(
    [string]$Yosys = "yosys"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$script = "scripts/yosys_synth_check.ys"

Push-Location $root
try {
    & $Yosys -s $script
    if ($LASTEXITCODE -ne 0) {
        throw "Yosys synthesis regression failed"
    }
    Write-Host "PASS: Yosys Xilinx-7 synthesis and LUTRAM assertions"
} finally {
    Pop-Location
}

