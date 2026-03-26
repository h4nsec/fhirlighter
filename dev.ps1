# dev.ps1 - FHIR IG development session
$ErrorActionPreference = "Continue"
$projectRoot = $PSScriptRoot

# ------------------------------------------------------------------
# UNICODE CHARS
# ------------------------------------------------------------------
$C_CHECK  = [char]0x2713
$C_CROSS  = [char]0x2717
$C_WARN   = [char]0x25B6
$C_DOT    = [char]0x25CF
$C_SPIN   = @(
    [char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838,
    [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827,
    [char]0x2807, [char]0x280F
)

# ------------------------------------------------------------------
# SPINNER
# ------------------------------------------------------------------
$script:SpinPS = $null
$script:SpinRS = $null

function Start-Spinner {
    param([string]$Message)
    $script:SpinRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:SpinRS.Open()
    $script:SpinPS = [System.Management.Automation.PowerShell]::Create()
    $script:SpinPS.Runspace = $script:SpinRS
    [void]$script:SpinPS.AddScript({
        param($msg, $frames)
        $i = 0
        while ($true) {
            [Console]::Write("`r  $($frames[$i % $frames.Length])  $msg   ")
            [System.Threading.Thread]::Sleep(80)
            $i++
        }
    }).AddArgument($Message).AddArgument($C_SPIN)
    $script:SpinHandle = $script:SpinPS.BeginInvoke()
}

function Stop-Spinner {
    param([string]$Message, [bool]$OK = $true)
    try { $script:SpinPS.Stop()    } catch {}
    try { $script:SpinPS.Dispose() } catch {}
    try { $script:SpinRS.Close()   } catch {}
    try { $script:SpinRS.Dispose() } catch {}
    $pad = " " * 50
    if ($OK) {
        Write-Host "`r  $C_CHECK  $Message$pad" -ForegroundColor Green
    } else {
        Write-Host "`r  $C_CROSS  $Message$pad" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------
# OUTPUT HELPERS
# ------------------------------------------------------------------
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "  $("-" * 44)" -ForegroundColor DarkGray
}

function Write-OK   { param([string]$Msg) Write-Host "  $C_CHECK  $Msg" -ForegroundColor Green  }
function Write-Fail { param([string]$Msg) Write-Host "  $C_CROSS  $Msg" -ForegroundColor Red    }
function Write-Warn { param([string]$Msg) Write-Host "  $C_WARN   $Msg" -ForegroundColor Yellow }
function Write-Info { param([string]$Msg) Write-Host "  $C_DOT    $Msg" -ForegroundColor DarkGray }

# ------------------------------------------------------------------
# TOOL DISCOVERY
# ------------------------------------------------------------------
function Find-Java {
    $j = Get-Command java -ErrorAction SilentlyContinue
    if ($j) { return $j.Source }
    foreach ($base in @(
        "$env:ProgramFiles\Java",
        "$env:ProgramFiles\Eclipse Adoptium",
        "$env:ProgramFiles\Microsoft",
        "$env:ProgramFiles\OpenJDK",
        "$env:LOCALAPPDATA\Programs\Eclipse Adoptium",
        "$env:LOCALAPPDATA\Programs\OpenJDK"
    )) {
        if (Test-Path $base) {
            $f = Get-ChildItem $base -Recurse -Filter "java.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
}

function Find-RubyBin {
    $r = Get-Command ruby -ErrorAction SilentlyContinue
    if ($r) { return Split-Path $r.Source }
    $f = Get-ChildItem "C:\Ruby*\bin\ruby.exe" -ErrorAction SilentlyContinue |
         Sort-Object FullName -Descending | Select-Object -First 1
    if ($f) { return Split-Path $f.FullName }
    $f = Get-ChildItem "$env:LOCALAPPDATA\Programs\Ruby*\bin\ruby.exe" -ErrorAction SilentlyContinue |
         Sort-Object FullName -Descending | Select-Object -First 1
    if ($f) { return Split-Path $f.FullName }
    return $null
}

function Find-GemBin {
    $r = Get-Command ruby -ErrorAction SilentlyContinue
    if ($r) {
        $g = & ruby -e "puts Gem.bindir" 2>$null
        if ($g -and (Test-Path $g.Trim())) { return $g.Trim() }
    }
    return $null
}

function Find-Git {
    $g = Get-Command git -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    foreach ($candidate in @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles\Git\bin\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# ==================================================================
# MAIN
# ==================================================================

# ------------------------------------------------------------------
# HEADER
# ------------------------------------------------------------------
$igLabel = Split-Path $projectRoot -Leaf
if (Test-Path "$projectRoot\sushi-config.yaml") {
    $tl = Get-Content "$projectRoot\sushi-config.yaml" |
          Where-Object { $_ -match '^\s*title\s*:' } |
          Select-Object -First 1
    if ($tl -match ':\s*[''"]?(.+?)[''"]?\s*$') { $igLabel = $matches[1] }
}

$igVer = ""
if (Test-Path "$projectRoot\sushi-config.yaml") {
    $vl = Get-Content "$projectRoot\sushi-config.yaml" |
          Where-Object { $_ -match '^\s*version\s*:' } |
          Select-Object -First 1
    if ($vl -match ':\s*(.+?)\s*$') { $igVer = "  v$($matches[1])" }
}

Write-Host ""
Write-Host "  +--------------------------------------------+" -ForegroundColor DarkCyan
Write-Host "  |  FHIR IG Dev Session                       |" -ForegroundColor DarkCyan
Write-Host "  |  $($igLabel.PadRight(42))  |" -ForegroundColor White
Write-Host "  |  $($projectRoot.PadRight(42))  |" -ForegroundColor DarkGray
Write-Host "  +--------------------------------------------+" -ForegroundColor DarkCyan

# ------------------------------------------------------------------
# GUARD
# ------------------------------------------------------------------
if (-not (Test-Path "$projectRoot\sushi-config.yaml")) {
    Write-Host ""
    Write-Fail "sushi-config.yaml not found."
    Write-Info "Run this from inside an IG project, or run init-ig.ps1 to scaffold a new one."
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------------
# ENVIRONMENT CHECKS
# ------------------------------------------------------------------
Write-Section "Checking Environment"
$prereqsFailed = $false

$javaExe = Find-Java
if ($javaExe) {
    Write-OK "Java    $javaExe"
} else {
    Write-Fail "Java not found  ->  https://adoptium.net"
    $prereqsFailed = $true
}

$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    Write-OK "npm     $($npmCmd.Source)"
} else {
    Write-Fail "npm not found  ->  https://nodejs.org"
    $prereqsFailed = $true
}

$rubyBin = Find-RubyBin
if ($rubyBin) {
    Write-OK "Ruby    $rubyBin"
} else {
    Write-Fail "Ruby not found  ->  https://rubyinstaller.org"
    $prereqsFailed = $true
}

$gitExe = Find-Git
if ($gitExe) {
    $gv = (& $gitExe --version 2>&1).ToString().Trim()
    Write-OK "Git     $gv"
} else {
    Write-Fail "Git not found  ->  https://git-scm.com"
    $prereqsFailed = $true
}

if ($prereqsFailed) {
    Write-Host ""
    Write-Host "  Fix missing prerequisites then re-run." -ForegroundColor Red
    Write-Host ""
    exit 1
}

$gemBin = Find-GemBin
$gitBin = if ($gitExe) { Split-Path $gitExe } else { $null }
$env:JAVA_HOME = Split-Path (Split-Path $javaExe)
foreach ($p in @((Split-Path $javaExe), $rubyBin, $gemBin, $gitBin, "$projectRoot\node_modules\.bin")) {
    if ($p -and ($env:PATH -notlike "*$p*")) { $env:PATH = "$p;$env:PATH" }
}
Write-OK "Session PATH patched"

# SUSHI
Start-Spinner "Checking SUSHI..."
$npmOut = & npm install --prefix "$projectRoot" 2>&1
if ($LASTEXITCODE -eq 0) {
    $sv = (& npx --prefix "$projectRoot" sushi --version 2>&1).ToString().Trim()
    Stop-Spinner "SUSHI v$sv ready"
} else {
    Stop-Spinner "SUSHI install failed" -OK $false
    exit 1
}

# Jekyll
$jekyll = Get-Command jekyll -ErrorAction SilentlyContinue
if ($jekyll) {
    $jv = (& jekyll --version 2>&1).ToString().Trim()
    Write-OK "Jekyll  $jv"
} else {
    Start-Spinner "Installing Jekyll..."
    & gem install jekyll bundler 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Stop-Spinner "Jekyll installed"
    } else {
        Stop-Spinner "Jekyll install failed (builds may fail)" -OK $false
    }
}

# publisher.jar
$publisherJar = "$projectRoot\input-cache\publisher.jar"
if (-not (Test-Path $publisherJar)) {
    Start-Spinner "Downloading IG Publisher..."
    New-Item -ItemType Directory -Force -Path "$projectRoot\input-cache" | Out-Null
    try {
        Invoke-WebRequest -Uri "https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar" -OutFile $publisherJar -UseBasicParsing
        $mb = [math]::Round((Get-Item $publisherJar).Length / 1MB, 0)
        Stop-Spinner "IG Publisher downloaded  (${mb} MB)"
    } catch {
        Stop-Spinner "Download failed - check connection" -OK $false
    }
} else {
    $mb = [math]::Round((Get-Item $publisherJar).Length / 1MB, 0)
    Write-OK "IG Publisher  (${mb} MB)"
}

# ------------------------------------------------------------------
# MENU
# ------------------------------------------------------------------
Write-Host ""
Write-Host "  +--------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  What would you like to do?                |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |                                            |" -ForegroundColor DarkGray
Write-Host "  |   [1]  Full build       (website + QA)    |" -ForegroundColor White
Write-Host "  |   [2]  SUSHI only       (FSH -> JSON)     |" -ForegroundColor White
Write-Host "  |   [3]  Watch mode       (auto rebuild)    |" -ForegroundColor White
Write-Host "  |   [4]  Update publisher (latest .jar)     |" -ForegroundColor White
Write-Host "  |   [5]  Open QA report   (browser)         |" -ForegroundColor White
Write-Host "  |   [6]  Exit                                |" -ForegroundColor DarkGray
Write-Host "  |                                            |" -ForegroundColor DarkGray
Write-Host "  +--------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

$choice = Read-Host "  Enter choice [1-6]"
Write-Host ""

switch ($choice) {
    "1" {
        Write-Host "  Starting full build..." -ForegroundColor Cyan
        Write-Host "  First run may take 10-15 min (package downloads + terminology)." -ForegroundColor DarkGray
        Write-Host ""
        $start = Get-Date
        & $javaExe -Xmx4g -jar $publisherJar -ig "$projectRoot"
        $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds)
        Write-Host ""
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Build complete  (${elapsed}s)"
            Write-Info "output\index.html  - review the IG"
            Write-Info "output\qa.html     - errors and warnings"
        } else {
            Write-Fail "Build finished with errors  (${elapsed}s)"
            Write-Info "Check output\qa.html for details"
        }
    }
    "2" {
        Write-Host "  Running SUSHI..." -ForegroundColor Cyan
        Write-Host ""
        & npx --prefix "$projectRoot" sushi build "$projectRoot"
        Write-Host ""
        if ($LASTEXITCODE -eq 0) {
            Write-OK "SUSHI complete  ->  fsh-generated\resources\"
        } else {
            Write-Fail "SUSHI finished with errors"
        }
    }
    "3" {
        Write-Host "  Starting watch mode..." -ForegroundColor Cyan
        Write-Info "IG rebuilds automatically on file changes."
        Write-Info "Press Ctrl+C to stop."
        Write-Host ""
        & $javaExe -Xmx4g -jar $publisherJar -ig "$projectRoot" -watch
    }
    "4" {
        Start-Spinner "Downloading latest IG Publisher..."
        try {
            Invoke-WebRequest -Uri "https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar" -OutFile $publisherJar -UseBasicParsing
            $mb = [math]::Round((Get-Item $publisherJar).Length / 1MB, 0)
            Stop-Spinner "IG Publisher updated  (${mb} MB)"
        } catch {
            Stop-Spinner "Download failed" -OK $false
        }
    }
    "5" {
        $qa = "$projectRoot\output\qa.html"
        if (Test-Path $qa) {
            Start-Process $qa
            Write-OK "Opening output\qa.html"
        } else {
            Write-Warn "output\qa.html not found - run a full build first."
        }
    }
    "6" {
        Write-Info "Goodbye."
        Write-Host ""
        exit 0
    }
    default {
        Write-Warn "Invalid choice."
    }
}

Write-Host ""
