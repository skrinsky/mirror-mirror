# Mirror Mirror - Windows Quick Installer
# Usage: irm https://raw.githubusercontent.com/skrinsky/mirror-mirror/main/install.ps1 | iex
#
# Requires: git, Python 3.10
# Downloads the pre-built VST3 from GitHub Releases and sets up the Python environment.
# Does NOT require Visual Studio or cmake.

param(
    [string]$InstallDir = "$env:USERPROFILE\mirror-mirror"
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/skrinsky/mirror-mirror.git"
$Vst3Dest = "$env:LOCALAPPDATA\Programs\Common\VST3"

function Write-Info  { Write-Host ">>> $args" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "OK  $args" -ForegroundColor Green }
function Write-Fail  { Write-Host "ERROR: $args" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "  Mirror Mirror - Windows Installer" -ForegroundColor Magenta
Write-Host "  ===================================" -ForegroundColor Magenta
Write-Host "  Install dir : $InstallDir"
Write-Host ""

# ── git ───────────────────────────────────────────────────────────────────────
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fail "git not found. Install from https://git-scm.com and re-run."
}
Write-Ok "git $(git --version)"

# ── uv (Python environment manager) ──────────────────────────────────────────
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Info "Installing uv (Python environment manager)..."
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
    $env:PATH = "$env:USERPROFILE\.local\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Fail "uv install failed. Please install manually: https://docs.astral.sh/uv/getting-started/installation/"
}
Write-Ok "uv $(uv --version)"

# ── Clone repo ────────────────────────────────────────────────────────────────
if (Test-Path "$InstallDir\.git") {
    Write-Info "Repo already exists at $InstallDir - pulling latest..."
    git -C $InstallDir pull --ff-only
    git -C $InstallDir submodule update --init --recursive
} else {
    Write-Info "Cloning Mirror Mirror into $InstallDir..."
    git clone --recurse-submodules $RepoUrl $InstallDir
}
Write-Ok "Repo at $InstallDir"

# ── Python environment (always Python 3.10 via uv) ───────────────────────────
# Python 3.12+ broke pkg_resources (used by vendor deps). Pin to 3.10 regardless
# of what Python is installed on the system.
Write-Info "Setting up Python environment (this may take a few minutes)..."
$VenvDir = "$InstallDir\.venv"

if (-not (Test-Path $VenvDir)) {
    uv venv --python 3.10 $VenvDir
}

$PythonVenv = "$VenvDir\Scripts\python.exe"
$UvPip = "uv pip install --python $PythonVenv"

Invoke-Expression "$UvPip -U setuptools<81 pip wheel" | Out-Null

# Detect CUDA for PyTorch — check PATH and common install locations
Write-Info "Detecting platform for PyTorch..."
$TorchCmd = $null
$nvidiaSmiPath = $null
foreach ($p in @("nvidia-smi", "C:\Windows\System32\nvidia-smi.exe",
                 "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) {
    try {
        $out = (& $p 2>$null) -join "`n"
        if ($out -match "CUDA Version") { $nvidiaSmiPath = $p; $nvidiaSmiOut = $out; break }
    } catch {}
}
if ($nvidiaSmiPath) {
    if ($nvidiaSmiOut -match "CUDA Version: (\d+)\.(\d+)") {
        $cudaMajor = [int]$Matches[1]; $cudaMinor = [int]$Matches[2]
        if ($cudaMajor -ge 12 -and $cudaMinor -ge 4) { $idx = "cu124" }
        elseif ($cudaMajor -ge 12)                   { $idx = "cu121" }
        else                                          { $idx = "cu118" }
        Write-Host "  NVIDIA CUDA $cudaMajor.$cudaMinor detected -> PyTorch $idx"
        $TorchCmd = "$UvPip torch torchaudio --index-url https://download.pytorch.org/whl/$idx"
    }
}

if (-not $TorchCmd) {
    Write-Host "  No NVIDIA GPU detected -> PyTorch CPU build"
    $TorchCmd = "$UvPip torch torchaudio --index-url https://download.pytorch.org/whl/cpu"
}
Invoke-Expression $TorchCmd | Out-Null

# Install requirements
$ReqFile = "$InstallDir\requirements.txt"
if (Test-Path $ReqFile) { Invoke-Expression "$UvPip -r $ReqFile" | Out-Null }

$VendorReq = "$InstallDir\vendor\all-in-one-ai-midi-pipeline\requirements.txt"
if (Test-Path $VendorReq) {
    $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
    Get-Content $VendorReq | Where-Object { $_ -notmatch "^(torch|torchaudio|torchvision)([=<>!~ ]|$)" } | Set-Content $tmp
    Invoke-Expression "$UvPip -r $tmp" | Out-Null
    Remove-Item $tmp
}
Write-Ok "Python environment ready"

# ── Download pre-built VST3 ───────────────────────────────────────────────────
Write-Info "Fetching latest release from GitHub..."
try {
    $release = Invoke-RestMethod "https://api.github.com/repos/skrinsky/mirror-mirror/releases/latest"
    $vst3Asset = $release.assets | Where-Object { $_.name -match "VST3.*Windows" } | Select-Object -First 1

    if (-not $vst3Asset) {
        # Fall back to any VST3 asset
        $vst3Asset = $release.assets | Where-Object { $_.name -match "VST3" } | Select-Object -First 1
    }

    if ($vst3Asset) {
        $tmp = "$env:TEMP\mirror-mirror-vst3.zip"
        Write-Info "Downloading VST3..."
        Invoke-WebRequest $vst3Asset.browser_download_url -OutFile $tmp
        $tmpExtract = "$env:TEMP\mirror-mirror-vst3"
        Expand-Archive $tmp -DestinationPath $tmpExtract -Force
        New-Item -ItemType Directory -Force -Path $Vst3Dest | Out-Null
        $vst3Bundle = Get-ChildItem $tmpExtract -Filter "*.vst3" -Recurse | Select-Object -First 1
        $destPath = "$Vst3Dest\Mirror Mirror.vst3"
        if (Test-Path $destPath) { Remove-Item $destPath -Recurse -Force }
        Copy-Item $vst3Bundle.FullName $destPath -Recurse
        Remove-Item $tmp, $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "VST3 installed to $Vst3Dest"
    } else {
        Write-Host "  No VST3 release asset found." -ForegroundColor Yellow
        Write-Host "  Build from source with install-dev.sh (requires Visual Studio)."
    }
} catch {
    Write-Host "  No release found on GitHub yet." -ForegroundColor Yellow
    Write-Host "  Build from source with install-dev.sh (requires Visual Studio)."
}

# ── Done ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ========================================" -ForegroundColor Green
Write-Host "  Mirror Mirror installed successfully!" -ForegroundColor Green
Write-Host "  ========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  VST3 installed to: $Vst3Dest\Mirror Mirror.vst3"
Write-Host "  Repo location:     $InstallDir"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Open your DAW and scan for new plugins"
Write-Host "    2. Add Mirror Mirror to a MIDI track"
Write-Host "    3. Drop audio files into $InstallDir\data\raw\"
Write-Host "    4. Hit Process in the plugin to begin"
Write-Host ""
