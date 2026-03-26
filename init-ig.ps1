# init-ig.ps1 - Scaffold a new FHIR Implementation Guide
param([switch]$Force)
$ErrorActionPreference = "Continue"
$scriptDir = $PSScriptRoot

# ------------------------------------------------------------------
# UNICODE CHARS - assigned via char codes so the parser never sees
# raw multi-byte literals, which can confuse older PS versions
# ------------------------------------------------------------------
$C_CHECK  = [char]0x2713  # checkmark
$C_CROSS  = [char]0x2717  # cross
$C_WARN   = [char]0x25B6  # triangle (warning)
$C_DOT    = [char]0x25CF  # filled circle
$C_SPIN   = @(
    [char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838,
    [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827,
    [char]0x2807, [char]0x280F
)  # braille spinner frames

# ------------------------------------------------------------------
# SPINNER  (runs in a background runspace)
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
function Write-Banner {
    $w = 56
    $line = "-" * $w
    Write-Host ""
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "    ______  __  __  ___  ____  " -ForegroundColor Cyan
    Write-Host "   / ____/ / / / / /  / / __ \ " -ForegroundColor Cyan
    Write-Host "  / ___/  / /_/ / /  / / /_/ / " -ForegroundColor Cyan
    Write-Host " / /     / __  / /  / / _, _/  " -ForegroundColor Cyan
    Write-Host "/_/  lighter /_/ /_/ /_/ |_|   " -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    FHIR Implementation Guide Tooling" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "  $("-" * 44)" -ForegroundColor DarkGray
}

function Write-OK   { param([string]$Msg) Write-Host "  $C_CHECK  $Msg" -ForegroundColor Green   }
function Write-Fail { param([string]$Msg) Write-Host "  $C_CROSS  $Msg" -ForegroundColor Red     }
function Write-Warn { param([string]$Msg) Write-Host "  $C_WARN   $Msg" -ForegroundColor Yellow  }
function Write-Info { param([string]$Msg) Write-Host "  $C_DOT    $Msg" -ForegroundColor DarkGray }

# Write UTF-8 without BOM - Set-Content -Encoding UTF8 adds BOM on PS 5.1
# which breaks FSH and YAML parsers
function Write-NoBOM {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

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

function Patch-SessionPath {
    param([string]$javaExe, [string]$rubyBin, [string]$gemBin, [string]$projectRoot, [string]$gitExe)
    $env:JAVA_HOME = Split-Path (Split-Path $javaExe)
    $gitBin = if ($gitExe) { Split-Path $gitExe } else { $null }
    foreach ($p in @((Split-Path $javaExe), $rubyBin, $gemBin, $gitBin, "$projectRoot\node_modules\.bin")) {
        if ($p -and ($env:PATH -notlike "*$p*")) { $env:PATH = "$p;$env:PATH" }
    }
}

# ------------------------------------------------------------------
# PROMPT HELPER
# ------------------------------------------------------------------
function Prompt-Value {
    param([string]$Label, [string]$Default, [string]$Hint = "")
    if ($Hint) { Write-Host "    $Hint" -ForegroundColor DarkGray }
    $display = if ($Default) { " [$Default]" } else { "" }
    $val = Read-Host "    $Label$display"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

# ==================================================================
# MAIN
# ==================================================================
Write-Banner

# ------------------------------------------------------------------
# GUARD
# ------------------------------------------------------------------
$targetDir = (Get-Location).Path
if ((Test-Path "$targetDir\sushi-config.yaml") -and (-not $Force)) {
    Write-Warn "sushi-config.yaml already exists here."
    Write-Info "Use dev.ps1 for an existing project, or run with -Force to overwrite."
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------------
# PREREQUISITES
# ------------------------------------------------------------------
Write-Section "Checking Prerequisites"
$prereqsFailed = $false

$javaExe = Find-Java
if ($javaExe) {
    $jv = (& $javaExe -version 2>&1 | Where-Object { $_ -match "version" } | Select-Object -First 1).ToString().Trim()
    Write-OK "Java    $jv"
    Write-Info "$javaExe"
} else {
    Write-Fail "Java not found  ->  https://adoptium.net"
    $prereqsFailed = $true
}

$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    $nv = (& npm --version 2>&1).ToString().Trim()
    Write-OK "npm     v$nv"
    Write-Info "$($npmCmd.Source)"
} else {
    Write-Fail "npm not found  ->  https://nodejs.org"
    $prereqsFailed = $true
}

$rubyBin = Find-RubyBin
if ($rubyBin) {
    $rv = (& ruby --version 2>&1).ToString().Trim()
    Write-OK "Ruby    $rv"
    Write-Info "$rubyBin"
} else {
    Write-Fail "Ruby not found  ->  https://rubyinstaller.org"
    $prereqsFailed = $true
}

$gitExe = Find-Git
if ($gitExe) {
    $gv = (& $gitExe --version 2>&1).ToString().Trim()
    Write-OK "Git     $gv"
    Write-Info "$gitExe"
} else {
    Write-Fail "Git not found  ->  https://git-scm.com"
    $prereqsFailed = $true
}

if ($prereqsFailed) {
    Write-Host ""
    Write-Host "  Install missing prerequisites then re-run." -ForegroundColor Red
    Write-Host ""
    exit 1
}

$gemBin = Find-GemBin
Patch-SessionPath -javaExe $javaExe -rubyBin $rubyBin -gemBin $gemBin -projectRoot $targetDir -gitExe $gitExe

# ------------------------------------------------------------------
# IG DETAILS
# ------------------------------------------------------------------
Write-Section "Configure Your IG"
Write-Host "  Press Enter to accept defaults shown in [brackets]." -ForegroundColor DarkGray
Write-Host ""

$igTitle     = Prompt-Value "IG Title"       "My FHIR Implementation Guide" "Human-readable name shown in the IG website"
$igId        = Prompt-Value "Package ID"     "my.fhir.ig"                   "NPM-style, e.g. hl7.fhir.us.myig"
$igName      = Prompt-Value "IG Name"        ($igId -replace '[^a-zA-Z0-9]','') "PascalCase, no spaces"
$canonical   = Prompt-Value "Canonical URL"  "http://example.org/fhir/$igId" "Persistent base URL for all artifacts"
$version     = Prompt-Value "Version"        "0.1.0"
$fhirVersion = Prompt-Value "FHIR Version"   "4.0.1"                        "4.0.1 (R4) | 4.3.0 (R4B) | 5.0.0 (R5)"
$status      = Prompt-Value "Status"         "draft"                        "draft | active | retired"
$publisher   = Prompt-Value "Publisher Name" "My Organization"
$pubUrl      = Prompt-Value "Publisher URL"  "http://example.org"
$pubEmail    = Prompt-Value "Publisher Email" ""

# ------------------------------------------------------------------
# TEMPLATE SELECTION
# ------------------------------------------------------------------
Write-Host ""
Write-Section "Template Selection"
Write-Host "  The IG template controls the website layout, branding, and style." -ForegroundColor DarkGray
Write-Host "  Ask your team for the package ID if using a custom organisational template." -ForegroundColor DarkGray
Write-Host ""
Write-Host "    [1]  fhir.base.template    Standard community IG  (recommended for non-HL7)" -ForegroundColor White
Write-Host "    [2]  hl7.fhir.template     Official HL7 IG        (ID must start with hl7.)" -ForegroundColor White
Write-Host "    [3]  Custom                Enter a package ID     (e.g. myorg.fhir.template)" -ForegroundColor White
Write-Host ""

# Auto-suggest based on package ID prefix
$templateDefault = if ($igId.StartsWith("hl7.")) { "2" } else { "1" }
$templateChoice  = Read-Host "  Choose template [1/2/3, default $templateDefault]"
if ([string]::IsNullOrWhiteSpace($templateChoice)) { $templateChoice = $templateDefault }

switch ($templateChoice) {
    "1" {
        $igTemplate = "fhir.base.template#current"
        Write-OK "Template: fhir.base.template#current"
    }
    "2" {
        if (-not $igId.StartsWith("hl7.")) {
            Write-Warn "hl7.fhir.template requires an ID starting with 'hl7.' - your ID is '$igId'."
            Write-Warn "The build will fail at the template stage unless you change your package ID."
        }
        $igTemplate = "hl7.fhir.template#current"
        Write-OK "Template: hl7.fhir.template#current"
    }
    "3" {
        Write-Host ""
        Write-Host "    Enter the full template package ID including version." -ForegroundColor DarkGray
        Write-Host "    Examples:" -ForegroundColor DarkGray
        Write-Host "      myorg.fhir.template#1.0.0   (published to packages.fhir.org)" -ForegroundColor DarkGray
        Write-Host "      myorg.fhir.template#current  (latest CI build)" -ForegroundColor DarkGray
        Write-Host "      #local-template              (use template/ folder in this project)" -ForegroundColor DarkGray
        Write-Host ""
        $customTemplate = Read-Host "    Template package ID"
        if ([string]::IsNullOrWhiteSpace($customTemplate)) {
            Write-Warn "No template entered, falling back to fhir.base.template#current."
            $igTemplate = "fhir.base.template#current"
        } else {
            $igTemplate = $customTemplate.Trim()
        }
        Write-OK "Template: $igTemplate"
    }
    default {
        Write-Warn "Invalid choice, using fhir.base.template#current."
        $igTemplate = "fhir.base.template#current"
    }
}

Write-Host ""
Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
Write-Host "  |  $($igTitle.PadRight(47))|" -ForegroundColor White
Write-Host "  |  ID        : $($igId.PadRight(35))|" -ForegroundColor DarkGray
Write-Host "  |  Canonical : $($canonical.PadRight(35))|" -ForegroundColor DarkGray
Write-Host "  |  Version   : $("$version ($fhirVersion)".PadRight(35))|" -ForegroundColor DarkGray
Write-Host "  |  Template  : $($igTemplate.PadRight(35))|" -ForegroundColor DarkGray
Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkGray
Write-Host ""

$confirm = Read-Host "  Create this IG? [Y/n]"
if ($confirm -match '^[Nn]') {
    Write-Warn "Aborted."
    Write-Host ""
    exit 0
}

# ------------------------------------------------------------------
# BUILD PROJECT
# ------------------------------------------------------------------
Write-Section "Building Project"

# Folders
Start-Spinner "Creating folder structure..."
foreach ($d in @(
    "input\fsh\profiles", "input\fsh\extensions", "input\fsh\valuesets",
    "input\fsh\codesystems", "input\fsh\instances", "input\pagecontent",
    "input\images", "input\includes", "input\intro-notes", "input-cache"
)) {
    New-Item -ItemType Directory -Force -Path "$targetDir\$d" | Out-Null
}
Stop-Spinner "Folder structure created"

# Config files
Start-Spinner "Writing config files..."
$year = (Get-Date).Year
$emailLine = if ($pubEmail) { "`n  email: $pubEmail" } else { "" }

$sushiConfig = "id: $igId`ncanonical: $canonical`nname: $igName`ntitle: `"$igTitle`"`nstatus: $status`nversion: $version`nfhirVersion: $fhirVersion`nreleaseLabel: CI Build`nlicense: CC0-1.0`ncopyrightYear: ${year}+`n`npublisher:`n  name: $publisher`n  url: $pubUrl$emailLine`n`ndependencies:`n  hl7.terminology.r4: 5.5.0`n  # hl7.fhir.us.core: 6.1.0`n`npages:`n  index.md:`n    title: Home`n  artifacts.html:`n    title: Artifacts`n`nparameters:`n  show-inherited-invariants: false`n  excludettl: true`n"
Write-NoBOM "$targetDir\sushi-config.yaml" $sushiConfig

Write-NoBOM "$targetDir\ig.ini" "[IG]`nig = fsh-generated/resources/ImplementationGuide-$igId.json`ntemplate = $igTemplate`n"
Write-NoBOM "$targetDir\.gitignore" "input-cache/`noutput/`ntemp/`ntemplate/`ntxcache/`n*.log`n.DS_Store`n"
Stop-Spinner "Config files written"

# Starter FSH
Start-Spinner "Writing starter FSH and pages..."
Write-NoBOM "$targetDir\input\fsh\aliases.fsh" "// Common terminology aliases`nAlias: ``$SCT   = http://snomed.info/sct`nAlias: ``$LOINC = http://loinc.org`nAlias: ``$UCUM  = http://unitsofmeasure.org`nAlias: ``$ICD10 = http://hl7.org/fhir/sid/icd-10-cm`n"
Write-NoBOM "$targetDir\input\fsh\profiles\.gitkeep"  "// Add profile .fsh files here`n"
Write-NoBOM "$targetDir\input\pagecontent\index.md"   "### Introduction`n`n**$igTitle** - version $version`n`nThis implementation guide defines...`n`n### Scope`n`n### Authors and Contributors`n`n| Name | Role |`n|------|------|`n| $publisher | Publisher |`n"
Write-NoBOM "$targetDir\input\includes\menu.xml"      "<ul xmlns=`"http://www.w3.org/1999/xhtml`" class=`"nav navbar-nav`">`n  <li><a href=`"index.html`">Home</a></li>`n  <li><a href=`"artifacts.html`">Artifacts</a></li>`n</ul>`n"
Stop-Spinner "Starter FSH and pages written"

# package.json + SUSHI
Write-NoBOM "$targetDir\package.json" "{`n  `"name`": `"$igId`",`n  `"private`": true,`n  `"devDependencies`": {`n    `"fsh-sushi`": `"3.x`"`n  },`n  `"scripts`": {`n    `"sushi`": `"sushi build .`",`n    `"dev`": `"powershell -ExecutionPolicy Bypass -File dev.ps1`"`n  }`n}`n"

Start-Spinner "Installing SUSHI..."
$npmOut = & npm install --prefix "$targetDir" 2>&1
$npmOK = ($LASTEXITCODE -eq 0)
if ($npmOK) {
    $sv = & npx --prefix "$targetDir" sushi --version 2>&1
    Stop-Spinner "SUSHI v$sv installed"
} else {
    Stop-Spinner "SUSHI install failed" -OK $false
    Write-Host $npmOut -ForegroundColor Red
    exit 1
}

# Jekyll
$jekyll = Get-Command jekyll -ErrorAction SilentlyContinue
if (-not $jekyll) {
    Start-Spinner "Installing Jekyll..."
    $gemOut = & gem install jekyll bundler 2>&1
    $gemOK = ($LASTEXITCODE -eq 0)
    if ($gemOK) {
        Stop-Spinner "Jekyll installed"
    } else {
        Stop-Spinner "Jekyll install failed (build may not work)" -OK $false
    }
} else {
    $jv = (& jekyll --version 2>&1).ToString().Trim()
    Write-OK "Jekyll already installed  ($jv)"
}

# publisher.jar
$publisherJar = "$targetDir\input-cache\publisher.jar"
if (-not (Test-Path $publisherJar)) {
    Start-Spinner "Downloading IG Publisher..."
    $publisherUrl = "https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar"
    try {
        Invoke-WebRequest -Uri $publisherUrl -OutFile $publisherJar -UseBasicParsing
        $sizeMB = [math]::Round((Get-Item $publisherJar).Length / 1MB, 0)
        Stop-Spinner "IG Publisher downloaded  (${sizeMB} MB)"
    } catch {
        Stop-Spinner "IG Publisher download failed" -OK $false
        Write-Warn "Try running dev.ps1 to retry the download."
    }
} else {
    $sizeMB = [math]::Round((Get-Item $publisherJar).Length / 1MB, 0)
    Write-OK "IG Publisher already present  (${sizeMB} MB)"
}

# Copy dev.ps1
$devSrc  = "$scriptDir\dev.ps1"
$devDest = "$targetDir\dev.ps1"
if ((Test-Path $devSrc) -and ($targetDir -ne $scriptDir)) {
    Start-Spinner "Copying dev.ps1..."
    Copy-Item $devSrc $devDest -Force
    Stop-Spinner "dev.ps1 copied"
} elseif (-not (Test-Path $devSrc)) {
    Write-Warn "dev.ps1 not found at $devSrc - copy it manually"
}

# ------------------------------------------------------------------
# SUMMARY
# ------------------------------------------------------------------
Write-Host ""
Write-Host "  +=====================================================+" -ForegroundColor Cyan
Write-Host "  |                                                     |" -ForegroundColor Cyan
Write-Host "  |   $C_CHECK  Project created successfully!                  |" -ForegroundColor Cyan
Write-Host "  |                                                     |" -ForegroundColor Cyan
Write-Host "  |   $igTitle" -ForegroundColor White -NoNewline
Write-Host (" " * (52 - $igTitle.Length)) -NoNewline
Write-Host "|" -ForegroundColor Cyan
Write-Host "  |   v$version  ($fhirVersion)$((" " * (46 - $version.Length - $fhirVersion.Length)))|" -ForegroundColor DarkGray
Write-Host "  |                                                     |" -ForegroundColor Cyan
Write-Host "  +=====================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Project structure:" -ForegroundColor DarkGray
Write-Host "    $(Split-Path $targetDir -Leaf)/"
Write-Host "    +-- sushi-config.yaml"
Write-Host "    +-- ig.ini"
Write-Host "    +-- dev.ps1"
Write-Host "    +-- input/"
Write-Host "    |   +-- fsh/          <-- write your FSH here"
Write-Host "    |   +-- pagecontent/  <-- write your docs here"
Write-Host "    +-- input-cache/"
Write-Host "        +-- publisher.jar"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Edit input\fsh\profiles\  to define your profiles"
Write-Host "    2. Edit input\pagecontent\index.md  with your narrative"
Write-Host "    3. Run .\dev.ps1  to start a build session"
Write-Host ""
