# ==============================================================================
# Gather-TimberbornBugReport.ps1
# Collects system specs, logs, and error reports for a Timberborn bug report.
# Output: A zip file on your Desktop ready to attach to a bug report.
# ==============================================================================
$OutputDir  = "$env:TEMP\TimberbornBugReport"
$ZipDest    = "$env:USERPROFILE\Desktop\TimberbornBugReport.zip"
$ErrorReportSrc = "C:\Users\curti\OneDrive\Documents\Timberborn\Error reports"
$PlayerLogSrc   = "$env:APPDATA\..\LocalLow\Mechanistry\Timberborn\Player.log"
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Timberborn Bug Report Gatherer ===" -ForegroundColor Cyan
Write-Host ""
# Clean up any previous run
if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
# ==============================================================================
# 1. SYSTEM SPECS
# ==============================================================================
Write-Host "[1/5] Gathering system specs..." -ForegroundColor Yellow
$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=" * 70)
$report.Add("TIMBERBORN BUG REPORT - SYSTEM SPECIFICATIONS")
$report.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add("=" * 70)
$report.Add("")
# --- Windows ---
$os = Get-CimInstance Win32_OperatingSystem
$report.Add("--- OPERATING SYSTEM ---")
$report.Add("Name        : $($os.Caption)")
$report.Add("Version     : $($os.Version)")
$report.Add("Build       : $($os.BuildNumber)")
$report.Add("Architecture: $($os.OSArchitecture)")
$report.Add("")
# --- CPU ---
$cpu = Get-CimInstance Win32_Processor
$report.Add("--- CPU ---")
$report.Add("Name        : $($cpu.Name)")
$report.Add("Cores       : $($cpu.NumberOfCores) physical / $($cpu.NumberOfLogicalProcessors) logical")
$report.Add("Max Speed   : $($cpu.MaxClockSpeed) MHz")
$report.Add("")
# --- Hybrid Core Layout (Intel P-core / E-core detection) ---
$report.Add("--- HYBRID CORE LAYOUT (P-cores vs E-cores) ---")
try {
    $coreInfo = @()
    $logicalProcessors = Get-CimInstance -ClassName Win32_Processor
    # Use CPUID-style detection via performance counter or registry hint
    # Best available without native API: report logical layout from WMI
    $report.Add("Logical Processors : $($cpu.NumberOfLogicalProcessors)")
    $report.Add("Physical Cores     : $($cpu.NumberOfCores)")
    $eCoreCount = $cpu.NumberOfLogicalProcessors - ($cpu.NumberOfCores * 2)
    if ($eCoreCount -gt 0) {
        $report.Add("Estimated P-cores  : $($cpu.NumberOfCores - ($eCoreCount)) (hyperthreaded, logical CPUs 0-$( ($cpu.NumberOfCores - ($eCoreCount))*2 - 1 ))")
        $report.Add("Estimated E-cores  : $($eCoreCount) (no HT, logical CPUs follow P-cores)")
        $report.Add("Note               : This is a hybrid CPU. E-core scheduling may cause Unity/Burst crashes.")
    } else {
        $report.Add("Core layout appears homogeneous (no E-cores detected).")
    }
    # Also dump raw processor info from registry for developer reference
    $cpuRegPath = "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor"
    $coreDetails = Get-ChildItem $cpuRegPath | ForEach-Object {
        $name = (Get-ItemProperty $_.PSPath).'ProcessorNameString'
        "  CPU $($_.PSChildName): $name"
    }
    $report.Add("")
    $report.Add("Raw registry processor entries:")
    $coreDetails | ForEach-Object { $report.Add($_) }
} catch {
    $report.Add("(Could not enumerate core layout detail: $_)")
}
$report.Add("")
# --- RAM ---
$ram = Get-CimInstance Win32_PhysicalMemory
$totalRamGB = [math]::Round(($ram | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
$report.Add("--- MEMORY ---")
$report.Add("Total RAM   : $totalRamGB GB")
$ram | ForEach-Object {
    $report.Add("  Slot $($_.DeviceLocator): $([math]::Round($_.Capacity/1GB,0)) GB @ $($_.Speed) MHz - $($_.Manufacturer) ($($_.PartNumber.Trim()))")
}
$report.Add("")
# --- GPU ---
$gpus = Get-CimInstance Win32_VideoController
$report.Add("--- GPU(s) ---")
foreach ($gpu in $gpus) {
    $report.Add("Name        : $($gpu.Name)")
    $report.Add("Driver Ver  : $($gpu.DriverVersion)")
    $report.Add("Driver Date : $($gpu.DriverDate)")
    $vramMB = [math]::Round($gpu.AdapterRAM / 1MB, 0)
    $report.Add("VRAM        : $vramMB MB")
    $report.Add("")
}
# --- Storage ---
$report.Add("--- STORAGE (drives with game/OS) ---")
Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
    $totalGB = [math]::Round(($_.Used + $_.Free) / 1GB, 1)
    $freeGB  = [math]::Round($_.Free / 1GB, 1)
    $report.Add("  Drive $($_.Name): $totalGB GB total, $freeGB GB free")
}
$report.Add("")
# --- Current Process Affinity (informational) ---
$report.Add("--- PROCESS AFFINITY NOTE ---")
$report.Add("Workaround confirmed: Setting Timberborn affinity to CPUs 0-3 (P-cores only) stops crashes.")
$report.Add("This excludes all E-cores (Gracemont architecture) from scheduling Unity job threads.")
$report.Add("Hypothesis: Burst-compiled job code is being scheduled onto E-cores which lack")
$report.Add("identical ISA support, causing an illegal instruction fault or memory inconsistency.")
$report.Add("")
# --- DirectX / Feature Level ---
$report.Add("--- DIRECTX ---")
try {
    $dxDiagOutput = & dxdiag /t "$OutputDir\dxdiag.txt" 2>$null
    Start-Sleep -Seconds 4   # dxdiag is async, give it a moment
    if (Test-Path "$OutputDir\dxdiag.txt") {
        $dx = Get-Content "$OutputDir\dxdiag.txt" | Select-String "DirectX Version"
        $report.Add("$($dx -join ', ')")
        $report.Add("(Full dxdiag.txt included in zip)")
    }
} catch {
    $report.Add("(dxdiag output unavailable: $_)")
}
$report.Add("")
$report | Set-Content "$OutputDir\SystemSpecs.txt" -Encoding UTF8
Write-Host "    System specs written." -ForegroundColor Green
# ==============================================================================
# 2. INSTALLED / RUNNING .NET AND UNITY INFO
# ==============================================================================
Write-Host "[2/5] Gathering runtime info..." -ForegroundColor Yellow
$runtimeReport = [System.Collections.Generic.List[string]]::new()
$runtimeReport.Add("--- .NET RUNTIMES INSTALLED ---")
try {
    $dotnetVersions = & dotnet --list-runtimes 2>$null
    if ($dotnetVersions) {
        $dotnetVersions | ForEach-Object { $runtimeReport.Add("  $_") }
    } else {
        $runtimeReport.Add("  (dotnet CLI not found or no runtimes listed)")
    }
} catch {
    $runtimeReport.Add("  (dotnet CLI not available)")
}
$runtimeReport.Add("")
$runtimeReport.Add("--- TIMBERBORN EXECUTABLE INFO ---")
$steamPaths = @(
    "C:\Program Files (x86)\Steam\steamapps\common\Timberborn",
    "C:\Program Files\Steam\steamapps\common\Timberborn"
)
$found = $false
foreach ($path in $steamPaths) {
    $exe = Get-ChildItem "$path\*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
        $ver = $exe.VersionInfo
        $runtimeReport.Add("Path        : $($exe.FullName)")
        $runtimeReport.Add("File Version: $($ver.FileVersion)")
        $runtimeReport.Add("Product Ver : $($ver.ProductVersion)")
        $found = $true
        break
    }
}
if (-not $found) {
    $runtimeReport.Add("  Could not locate Timberborn executable in default Steam paths.")
    $runtimeReport.Add("  Please add game version manually to your bug report.")
}
$runtimeReport | Set-Content "$OutputDir\RuntimeInfo.txt" -Encoding UTF8
Write-Host "    Runtime info written." -ForegroundColor Green
# ==============================================================================
# 3. ERROR REPORTS
# ==============================================================================
Write-Host "[3/5] Copying error reports from OneDrive..." -ForegroundColor Yellow
$errDest = "$OutputDir\ErrorReports"
New-Item -ItemType Directory -Path $errDest | Out-Null
if (Test-Path $ErrorReportSrc) {
    $files = Get-ChildItem $ErrorReportSrc -Recurse -File
    $files | ForEach-Object {
        $dest = $_.FullName.Replace($ErrorReportSrc, $errDest)
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item $_.FullName $dest
    }
    Write-Host "    Copied $($files.Count) error report file(s)." -ForegroundColor Green
} else {
    Write-Host "    WARNING: Error report folder not found at: $ErrorReportSrc" -ForegroundColor Red
    "Error report folder not found at: $ErrorReportSrc" | Set-Content "$errDest\MISSING.txt"
}
# ==============================================================================
# 4. PLAYER.LOG
# ==============================================================================
Write-Host "[4/5] Copying Player.log..." -ForegroundColor Yellow
$resolvedLog = [System.Environment]::ExpandEnvironmentVariables($PlayerLogSrc)
# AppData is a known-folder so resolve properly
$localLowLog = "$env:USERPROFILE\AppData\LocalLow\Mechanistry\Timberborn\Player.log"
if (Test-Path $localLowLog) {
    Copy-Item $localLowLog "$OutputDir\Player.log"
    Write-Host "    Player.log copied." -ForegroundColor Green
    # Extract last 150 lines as a quick-view summary
    $tail = Get-Content $localLowLog -Tail 150
    $tail | Set-Content "$OutputDir\Player_last150lines.txt" -Encoding UTF8
    Write-Host "    Last 150 lines extracted for quick reference." -ForegroundColor Green
} else {
    Write-Host "    WARNING: Player.log not found at expected path:" -ForegroundColor Red
    Write-Host "    $localLowLog" -ForegroundColor Red
    "Player.log not found. Expected path: $localLowLog" | Set-Content "$OutputDir\Player_MISSING.txt"
}
# ==============================================================================
# 5. PACKAGE INTO ZIP
# ==============================================================================
Write-Host "[5/5] Packaging into zip..." -ForegroundColor Yellow
if (Test-Path $ZipDest) { Remove-Item $ZipDest -Force }
Compress-Archive -Path "$OutputDir\*" -DestinationPath $ZipDest -CompressionLevel Optimal
Write-Host ""
Write-Host "=== Done! ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Bug report package saved to:" -ForegroundColor White
Write-Host "  $ZipDest" -ForegroundColor Green
Write-Host ""
Write-Host "Zip contains:" -ForegroundColor White
Write-Host "  SystemSpecs.txt         - Full hardware specs + hybrid core analysis"
Write-Host "  RuntimeInfo.txt         - .NET runtimes + Timberborn exe version"
Write-Host "  ErrorReports\           - All files from your Timberborn error report folder"
Write-Host "  Player.log              - Full Unity player log"
Write-Host "  Player_last150lines.txt - Quick-view tail of the log"
Write-Host "  dxdiag.txt              - DirectX diagnostic output"
Write-Host ""
Write-Host "Attach TimberbornBugReport.zip to your report at:" -ForegroundColor White
Write-Host "  https://www.timberborn.com/ or the Steam Discussions page" -ForegroundColor Cyan
Write-Host ""
