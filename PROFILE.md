# PowerShell Profile Setup

One-time setup to make the FHIR tools available from anywhere on your machine.

## 1. Clone this repo to a fixed location

```powershell
git clone https://github.com/your-org/fhirlighter C:\Users\your-user\dev-tools\fhirlighter
```

## 2. Add functions to your PowerShell profile

Open your profile (creates it if it doesn't exist):

```powershell
notepad $PROFILE
```

Add the following — update `$FhirToolsDir` to wherever you cloned the repo:

```powershell
# FHIR IG tools
$FhirToolsDir = "C:\Users\your-user\dev-tools\fhirlighter"

function New-FhirIG {
    powershell -ExecutionPolicy Bypass -File "$FhirToolsDir\init-ig.ps1" @args
}

function Start-FhirIG {
    powershell -ExecutionPolicy Bypass -File (Join-Path (Get-Location) "dev.ps1") @args
}
```

Save and reload:

```powershell
. $PROFILE
```

## 3. Usage

```powershell
# In any empty directory — scaffold a new IG
New-FhirIG

# Inside an existing IG project — start a dev session
Start-FhirIG
```

## Managed laptop / execution policy

If `$PROFILE` is blocked by execution policy, add this to your VSCode `settings.json`
to scope the bypass to the VSCode terminal only:

```json
"terminal.integrated.env.windows": {
    "PSExecutionPolicyPreference": "Bypass"
}
```
