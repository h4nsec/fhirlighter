# dev.ps1 — FHIR IG development session
# Run this at the start of every dev session inside an IG project directory.
$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot

# ─────────────────────────────────────────────────────────────
# SHARED TOOL DISCOVERY
# ─────────────────────────────────────────────────────────────
function Find-Java {
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) { return $java.Source }
    $candidates = @(
        "$env:ProgramFiles\Java",
        "$env:ProgramFiles\Eclipse Adoptium",
        "$env:ProgramFiles\Microsoft",
        "$env:ProgramFiles\OpenJDK",
        "$env:LOCALAPPDATA\Programs\Eclipse Adoptium",
        "$env:LOCALAPPDATA\Programs\OpenJDK"
    )
    foreach ($base in $candidates) {
        if (Test-Path $base) {
            $found = Get-ChildItem $base -Recurse -Filter "java.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}

function Find-RubyBin {
    $ruby = Get-Command ruby -ErrorAction SilentlyContinue
    if ($ruby) { return Split-Path $ruby.Source }
    $found = Get-ChildItem "C:\Ruby*\bin\ruby.exe" -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return Split-Path $found.FullName }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Programs\Ruby*\bin\ruby.exe" -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return Split-Path $found.FullName }
    return $null
}

function Find-GemBin {
    $ruby = Get-Command ruby -ErrorAction SilentlyContinue
    if ($ruby) {
        $gemBin = & ruby -e "puts Gem.bindir" 2>$null
        if ($gemBin -and (Test-Path $gemBin.Trim())) { return $gemBin.Trim() }
    }
    return $null
}

# ─────────────────────────────────────────────────────────────
# HEADER
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  FHIR IG Dev Session" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray

# Read IG title from sushi-config.yaml if present
$igLabel = Split-Path $projectRoot -Leaf
if (Test-Path "$projectRoot\sushi-config.yaml") {
    $titleLine = Get-Content "$projectRoot\sushi-config.yaml" |
                 Where-Object { $_ -match '^\s*title\s*:' } |
                 Select-Object -First 1
    if ($titleLine -match ':\s*[''"]?(.+?)[''"]?\s*$') {
        $igLabel = $matches[1]
    }
}
Write-Host "  Project : $igLabel" -ForegroundColor White
Write-Host "  Dir     : $projectRoot" -ForegroundColor DarkGray
Write-Host ""

# ─────────────────────────────────────────────────────────────
# GUARD — must be an IG project
# ─────────────────────────────────────────────────────────────
if (-not (Test-Path "$projectRoot\sushi-config.yaml")) {
    Write-Host "  ERROR: sushi-config.yaml not found." -ForegroundColor Red
    Write-Host "  Run this script from inside an IG project directory." -ForegroundColor Red
    Write-Host "  To scaffold a new IG, run init-ig.ps1 instead." -ForegroundColor DarkGray
    exit 1
}

# ─────────────────────────────────────────────────────────────
# PREREQUISITE CHECKS + PATH PATCHING
# ─────────────────────────────────────────────────────────────
Write-Host "  Checking environment..." -ForegroundColor Cyan
$prereqsFailed = $false

$javaExe = Find-Java
if ($javaExe) {
    Write-Host "  [OK] Java     : $javaExe" -ForegroundColor Green
} else {
    Write-Host "  [MISSING] Java — https://adoptium.net" -ForegroundColor Red
    $prereqsFailed = $true
}

$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    Write-Host "  [OK] npm      : $($npmCmd.Source)" -ForegroundColor Green
} else {
    Write-Host "  [MISSING] npm — https://nodejs.org" -ForegroundColor Red
    $prereqsFailed = $true
}

$rubyBin = Find-RubyBin
if ($rubyBin) {
    Write-Host "  [OK] Ruby     : $rubyBin" -ForegroundColor Green
} else {
    Write-Host "  [MISSING] Ruby — https://rubyinstaller.org" -ForegroundColor Red
    $prereqsFailed = $true
}

if ($prereqsFailed) {
    Write-Host ""
    Write-Host "  Fix the above before continuing." -ForegroundColor Red
    exit 1
}

# Patch session PATH
$gemBin = Find-GemBin
$env:JAVA_HOME = Split-Path (Split-Path $javaExe)
$additions = @( (Split-Path $javaExe), $rubyBin, $gemBin, "$projectRoot\node_modules\.bin" )
foreach ($p in $additions) {
    if ($p -and $env:PATH -notlike "*$p*") { $env:PATH = "$p;$env:PATH" }
}
Write-Host "  [OK] Session PATH patched." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# SUSHI — ensure local install
# ─────────────────────────────────────────────────────────────
Write-Host "  Checking SUSHI..." -ForegroundColor Cyan
& npm install --prefix "$projectRoot" --silent
if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
$sushiVer = & npx --prefix "$projectRoot" sushi --version 2>&1
Write-Host "  [OK] SUSHI $sushiVer" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# JEKYLL — install if missing
# ─────────────────────────────────────────────────────────────
$jekyll = Get-Command jekyll -ErrorAction SilentlyContinue
if (-not $jekyll) {
    Write-Host "  Jekyll not found — installing..." -ForegroundColor Yellow
    & gem install jekyll bundler
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Jekyll install failed. Full builds may not work." -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] Jekyll installed." -ForegroundColor Green
    }
} else {
    Write-Host "  [OK] Jekyll   : $($jekyll.Source)" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────
# PUBLISHER.JAR — download if missing
# ─────────────────────────────────────────────────────────────
$publisherJar = "$projectRoot\input-cache\publisher.jar"
if (-not (Test-Path $publisherJar)) {
    Write-Host "  publisher.jar not found — downloading..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path "$projectRoot\input-cache" | Out-Null
    $url = "https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar"
    Invoke-WebRequest -Uri $url -OutFile $publisherJar
    Write-Host "  [OK] publisher.jar downloaded." -ForegroundColor Green
} else {
    $jarSize = [math]::Round((Get-Item $publisherJar).Length / 1MB, 1)
    Write-Host "  [OK] publisher.jar ($jarSize MB)" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────
# MENU
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  What would you like to do?" -ForegroundColor Cyan
Write-Host ""
Write-Host "    [1] Full build       (IG Publisher — generates website)" -ForegroundColor White
Write-Host "    [2] SUSHI only       (compile FSH → JSON, no website)" -ForegroundColor White
Write-Host "    [3] Watch mode       (rebuild automatically on file changes)" -ForegroundColor White
Write-Host "    [4] Update publisher (download latest publisher.jar)" -ForegroundColor White
Write-Host "    [5] Open QA report   (open output\qa.html in browser)" -ForegroundColor White
Write-Host "    [6] Exit" -ForegroundColor DarkGray
Write-Host ""

$choice = Read-Host "  Enter choice [1-6]"

switch ($choice) {

    "1" {
        Write-Host ""
        Write-Host "  Running full build..." -ForegroundColor Cyan
        Write-Host "  This may take several minutes on the first run." -ForegroundColor DarkGray
        Write-Host ""
        & $javaExe -Xmx4g -jar $publisherJar -ig "$projectRoot"
        Write-Host ""
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Build complete." -ForegroundColor Green
            Write-Host "  Open output\index.html to review the IG." -ForegroundColor DarkGray
            Write-Host "  Open output\qa.html to review errors and warnings." -ForegroundColor DarkGray
        } else {
            Write-Host "  Build finished with errors. Check output\qa.html." -ForegroundColor Red
        }
    }

    "2" {
        Write-Host ""
        Write-Host "  Running SUSHI..." -ForegroundColor Cyan
        & npx --prefix "$projectRoot" sushi build "$projectRoot"
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "  SUSHI complete. JSON artifacts written to fsh-generated\resources\" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "  SUSHI finished with errors." -ForegroundColor Red
        }
    }

    "3" {
        Write-Host ""
        Write-Host "  Starting watch mode..." -ForegroundColor Cyan
        Write-Host "  The IG will rebuild automatically when files change." -ForegroundColor DarkGray
        Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
        Write-Host ""
        & $javaExe -Xmx4g -jar $publisherJar -ig "$projectRoot" -watch
    }

    "4" {
        Write-Host ""
        Write-Host "  Downloading latest publisher.jar..." -ForegroundColor Cyan
        $url = "https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar"
        Invoke-WebRequest -Uri $url -OutFile $publisherJar
        $jarSize = [math]::Round((Get-Item $publisherJar).Length / 1MB, 1)
        Write-Host "  [OK] publisher.jar updated ($jarSize MB)." -ForegroundColor Green
    }

    "5" {
        $qaPath = "$projectRoot\output\qa.html"
        if (Test-Path $qaPath) {
            Start-Process $qaPath
        } else {
            Write-Host "  output\qa.html not found. Run a full build first." -ForegroundColor Yellow
        }
    }

    "6" {
        Write-Host "  Exiting." -ForegroundColor DarkGray
        exit 0
    }

    default {
        Write-Host "  Invalid choice." -ForegroundColor Yellow
    }
}

Write-Host ""
