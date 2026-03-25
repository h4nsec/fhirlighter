# init-ig.ps1 — Scaffold a new FHIR Implementation Guide
# Run this script once inside a new empty directory.
# It will set up the full project structure and install all tooling.
param(
    [switch]$Force  # Overwrite existing files without prompting
)
$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

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

function Patch-SessionPath {
    param([string]$javaExe, [string]$rubyBin, [string]$gemBin, [string]$projectRoot)
    $env:JAVA_HOME = Split-Path (Split-Path $javaExe)
    $additions = @( (Split-Path $javaExe), $rubyBin, $gemBin, "$projectRoot\node_modules\.bin" )
    foreach ($p in $additions) {
        if ($p -and $env:PATH -notlike "*$p*") { $env:PATH = "$p;$env:PATH" }
    }
}

# ─────────────────────────────────────────────────────────────
# HEADER
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  FHIR IG Initialiser" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ─────────────────────────────────────────────────────────────
# GUARD — don't clobber an existing project
# ─────────────────────────────────────────────────────────────
$targetDir = Get-Location
if ((Test-Path "$targetDir\sushi-config.yaml") -and -not $Force) {
    Write-Host "  sushi-config.yaml already exists in this directory." -ForegroundColor Yellow
    Write-Host "  This looks like an existing IG project. Use dev.ps1 instead." -ForegroundColor Yellow
    Write-Host "  Run with -Force to overwrite." -ForegroundColor DarkGray
    exit 1
}

# ─────────────────────────────────────────────────────────────
# PREREQUISITE CHECKS
# ─────────────────────────────────────────────────────────────
Write-Host "  Checking prerequisites..." -ForegroundColor Cyan
$prereqsFailed = $false

# Java
$javaExe = Find-Java
if ($javaExe) {
    $javaVer = & $javaExe -version 2>&1 | Select-String "version" | Select-Object -First 1
    Write-Host "  [OK] Java     : $javaExe" -ForegroundColor Green
    Write-Host "                  $javaVer" -ForegroundColor DarkGray
} else {
    Write-Host "  [MISSING] Java — download from https://adoptium.net" -ForegroundColor Red
    $prereqsFailed = $true
}

# Node / npm
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    $npmVer = & npm --version 2>&1
    Write-Host "  [OK] npm      : $($npmCmd.Source) (v$npmVer)" -ForegroundColor Green
} else {
    Write-Host "  [MISSING] npm — download from https://nodejs.org" -ForegroundColor Red
    $prereqsFailed = $true
}

# Ruby
$rubyBin = Find-RubyBin
if ($rubyBin) {
    $rubyVer = & ruby --version 2>&1
    Write-Host "  [OK] Ruby     : $rubyBin" -ForegroundColor Green
    Write-Host "                  $rubyVer" -ForegroundColor DarkGray
} else {
    Write-Host "  [MISSING] Ruby — download from https://rubyinstaller.org" -ForegroundColor Red
    $prereqsFailed = $true
}

if ($prereqsFailed) {
    Write-Host ""
    Write-Host "  One or more prerequisites are missing. Install them and re-run." -ForegroundColor Red
    exit 1
}

$gemBin = Find-GemBin
Patch-SessionPath -javaExe $javaExe -rubyBin $rubyBin -gemBin $gemBin -projectRoot $targetDir

# ─────────────────────────────────────────────────────────────
# COLLECT IG DETAILS
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Configure your IG" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Press Enter to accept the default shown in [brackets]." -ForegroundColor DarkGray
Write-Host ""

function Prompt-Value {
    param([string]$Label, [string]$Default, [string]$Hint = "")
    $display = if ($Default) { " [$Default]" } else { "" }
    if ($Hint) { Write-Host "  $Hint" -ForegroundColor DarkGray }
    $val = Read-Host "  $Label$display"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

$igTitle     = Prompt-Value "IG Title"       "My FHIR Implementation Guide"  "Human-readable name"
$igId        = Prompt-Value "Package ID"     "my.fhir.ig"                    "NPM-style, e.g. hl7.fhir.us.myig"
$igName      = Prompt-Value "IG Name"        ($igId -replace '[^a-zA-Z0-9]','') "PascalCase, no spaces"
$canonical   = Prompt-Value "Canonical URL"  "http://example.org/fhir/$igId" "Base URL for all artifacts"
$version     = Prompt-Value "Version"        "0.1.0"
$fhirVersion = Prompt-Value "FHIR Version"   "4.0.1"                         "4.0.1 (R4) | 4.3.0 (R4B) | 5.0.0 (R5)"
$status      = Prompt-Value "Status"         "draft"                         "draft | active | retired"
$publisher   = Prompt-Value "Publisher Name" "My Organization"
$pubUrl      = Prompt-Value "Publisher URL"  "http://example.org"
$pubEmail    = Prompt-Value "Publisher Email" ""

Write-Host ""
Write-Host "  IG Details" -ForegroundColor Cyan
Write-Host "    Title     : $igTitle"
Write-Host "    ID        : $igId"
Write-Host "    Canonical : $canonical"
Write-Host "    Version   : $version ($fhirVersion)"
Write-Host ""
$confirm = Read-Host "  Create this IG? [Y/n]"
if ($confirm -match '^[Nn]') { Write-Host "  Aborted." -ForegroundColor Yellow; exit 0 }

# ─────────────────────────────────────────────────────────────
# FOLDER STRUCTURE
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Creating folder structure..." -ForegroundColor Cyan

$dirs = @(
    "input\fsh\profiles",
    "input\fsh\extensions",
    "input\fsh\valuesets",
    "input\fsh\codesystems",
    "input\fsh\instances",
    "input\pagecontent",
    "input\images",
    "input\includes",
    "input\intro-notes",
    "input-cache"
)
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Force -Path "$targetDir\$d" | Out-Null
}
Write-Host "  [OK] Folders created." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# WRITE CONFIG FILES
# ─────────────────────────────────────────────────────────────
Write-Host "  Writing configuration files..." -ForegroundColor Cyan

# sushi-config.yaml
$emailLine = if ($pubEmail) { "`n      - system: email`n        value: $pubEmail" } else { "" }
@"
id: $igId
canonical: $canonical
name: $igName
title: "$igTitle"
status: $status
version: $version
fhirVersion: $fhirVersion
releaseLabel: CI Build
license: CC0-1.0
copyrightYear: $(Get-Date -Format yyyy)+

publisher:
  name: $publisher
  url: $pubUrl$emailLine

dependencies:
  hl7.terminology.r4: 6.0.0
  # Add more dependencies here, e.g:
  # hl7.fhir.us.core: 6.1.0

pages:
  index.md:
    title: Home
  artifacts.html:
    title: Artifacts

menu:
  Home: index.html
  Artifacts: artifacts.html

parameters:
  show-inherited-invariants: false
  excludettl: true
"@ | Set-Content "$targetDir\sushi-config.yaml" -Encoding UTF8

# ig.ini
@"
[IG]
ig = fsh-generated/resources/ImplementationGuide-$igId.json
template = hl7.fhir.template#current
usage-stats-opt-out = true
"@ | Set-Content "$targetDir\ig.ini" -Encoding UTF8

# .gitignore
@"
input-cache/
output/
temp/
template/
txcache/
*.log
.DS_Store
"@ | Set-Content "$targetDir\.gitignore" -Encoding UTF8

Write-Host "  [OK] sushi-config.yaml, ig.ini, .gitignore written." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# WRITE STARTER FSH
# ─────────────────────────────────────────────────────────────

# aliases.fsh
@"
// Common terminology aliases — add more as needed
Alias: `$SCT    = http://snomed.info/sct
Alias: `$LOINC  = http://loinc.org
Alias: `$UCUM   = http://unitsofmeasure.org
Alias: `$ICD10  = http://hl7.org/fhir/sid/icd-10-cm
Alias: `$RXN    = http://www.nlm.nih.gov/research/umls/rxnorm
"@ | Set-Content "$targetDir\input\fsh\aliases.fsh" -Encoding UTF8

# Starter profile placeholder
@"
// TODO: Define your profiles here
// Example:
//
// Profile:     MyPatient
// Parent:      Patient
// Id:          my-patient
// Title:       "My Patient Profile"
// Description: "Patient profile for this IG."
// * name 1..* MS
// * birthDate 1..1 MS
"@ | Set-Content "$targetDir\input\fsh\profiles\.gitkeep" -Encoding UTF8

# ─────────────────────────────────────────────────────────────
# WRITE PAGES
# ─────────────────────────────────────────────────────────────

@"
### Introduction

**$igTitle** — version $version

This implementation guide defines...

### Scope

### Authors and Contributors

| Name | Role |
|------|------|
| $publisher | Publisher |

### Dependencies

This IG depends on the following published IGs:

| IG | Version |
|----|---------|
| HL7 Terminology | 6.0.0 |
"@ | Set-Content "$targetDir\input\pagecontent\index.md" -Encoding UTF8

# menu.xml
@"
<ul xmlns="http://www.w3.org/1999/xhtml" class="nav navbar-nav">
  <li><a href="index.html">Home</a></li>
  <li><a href="artifacts.html">Artifacts</a></li>
</ul>
"@ | Set-Content "$targetDir\input\includes\menu.xml" -Encoding UTF8

Write-Host "  [OK] Starter FSH, pages, and menu written." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# PACKAGE.JSON + SUSHI
# ─────────────────────────────────────────────────────────────
Write-Host "  Installing SUSHI locally..." -ForegroundColor Cyan

@"
{
  "name": "$igId",
  "private": true,
  "devDependencies": {
    "fsh-sushi": "3.x"
  },
  "scripts": {
    "sushi": "sushi build .",
    "dev": "powershell -ExecutionPolicy Bypass -File dev.ps1"
  }
}
"@ | Set-Content "$targetDir\package.json" -Encoding UTF8

& npm install --prefix "$targetDir"
if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
Write-Host "  [OK] SUSHI installed." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# JEKYLL
# ─────────────────────────────────────────────────────────────
$jekyll = Get-Command jekyll -ErrorAction SilentlyContinue
if (-not $jekyll) {
    Write-Host "  Installing Jekyll..." -ForegroundColor Cyan
    & gem install jekyll bundler
    if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: Jekyll install failed — build may not work." -ForegroundColor Yellow }
    else { Write-Host "  [OK] Jekyll installed." -ForegroundColor Green }
} else {
    Write-Host "  [OK] Jekyll already installed." -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────
# DOWNLOAD publisher.jar
# ─────────────────────────────────────────────────────────────
$publisherJar = "$targetDir\input-cache\publisher.jar"
if (-not (Test-Path $publisherJar)) {
    Write-Host "  Downloading IG Publisher (this may take a minute)..." -ForegroundColor Cyan
    $publisherUrl = "https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar"
    Invoke-WebRequest -Uri $publisherUrl -OutFile $publisherJar
    Write-Host "  [OK] publisher.jar downloaded." -ForegroundColor Green
} else {
    Write-Host "  [OK] publisher.jar already present." -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────
# COPY dev.ps1 INTO THE NEW PROJECT
# ─────────────────────────────────────────────────────────────
$devScriptSource = "$scriptDir\dev.ps1"
$devScriptDest   = "$targetDir\dev.ps1"
if (Test-Path $devScriptSource) {
    if ($targetDir -ne $scriptDir) {
        Copy-Item $devScriptSource $devScriptDest -Force
        Write-Host "  [OK] dev.ps1 copied into project." -ForegroundColor Green
    }
} else {
    Write-Host "  WARNING: dev.ps1 not found at $devScriptSource — skipping copy." -ForegroundColor Yellow
    Write-Host "           Run dev.ps1 from the fhirlighter directory manually." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  IG scaffolded successfully." -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Edit input\fsh\profiles\ to define your profiles"
Write-Host "    2. Edit input\pagecontent\index.md with your IG narrative"
Write-Host "    3. Run dev.ps1 to start a build session"
Write-Host ""
