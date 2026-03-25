# fhirlighter

PowerShell tooling to scaffold and develop [FHIR Implementation Guides](https://hl7.org/fhir/implementationguide.html) on Windows without relying on global PATH or system-wide installs.

Designed for managed laptops where you can't set permanent environment variables or install software globally.

## What's in here

| File | Purpose |
|------|---------|
| `init-ig.ps1` | Scaffold a brand new FHIR IG from scratch |
| `dev.ps1` | Start a dev session inside an existing IG project |
| `PROFILE.md` | One-time PowerShell profile setup to call scripts from anywhere |

## Prerequisites

These need to be installed before using the scripts. No PATH setup required — the scripts will find them automatically.

| Tool | Why | Download |
|------|-----|----------|
| Java 17+ | Runs the HL7 IG Publisher | [adoptium.net](https://adoptium.net) |
| Node.js / npm | Runs SUSHI (FSH compiler) | [nodejs.org](https://nodejs.org) |
| Ruby 3.x | Runs Jekyll (page assembly) | [rubyinstaller.org](https://rubyinstaller.org) |

## Quick start

### New project

```powershell
mkdir my-fhir-ig
cd my-fhir-ig
powershell -ExecutionPolicy Bypass -File path\to\fhirlighter\init-ig.ps1
```

Prompts you for IG details, then sets up the full project structure, installs SUSHI, Jekyll, and downloads the IG Publisher automatically.

### Existing project

```powershell
cd my-fhir-ig
powershell -ExecutionPolicy Bypass -File dev.ps1
```

Checks your environment, patches the session PATH, then presents a menu:

```
  [1] Full build       (IG Publisher — generates website)
  [2] SUSHI only       (compile FSH → JSON, no website)
  [3] Watch mode       (rebuild automatically on file changes)
  [4] Update publisher (download latest publisher.jar)
  [5] Open QA report   (open output\qa.html in browser)
  [6] Exit
```

## Global setup (recommended)

See [PROFILE.md](PROFILE.md) to register `New-FhirIG` and `Start-FhirIG` as PowerShell functions so you can call them from any directory without specifying the script path each time.

## How it works

- **SUSHI** is installed locally per-project via `npm install` — no global install, no PATH dependency
- **Java and Ruby** are discovered at runtime by scanning common Windows install locations
- **Session PATH** is patched in memory for the duration of the script — no permanent changes to your system
- **Jekyll** is installed automatically via `gem install` if not found
- **publisher.jar** is downloaded from the [HL7 GitHub releases](https://github.com/HL7/fhir-ig-publisher/releases) into `input-cache/` if not present

## What gets generated

Running `init-ig.ps1` produces a standard FHIR IG project layout:

```
my-fhir-ig/
├── sushi-config.yaml        — IG metadata, dependencies, pages, menu
├── ig.ini                   — template selection
├── dev.ps1                  — dev session script (copied from fhirlighter)
├── package.json             — local SUSHI install
├── .gitignore
├── input/
│   ├── fsh/
│   │   ├── aliases.fsh      — terminology URL aliases
│   │   ├── profiles/        — profile definitions (.fsh)
│   │   ├── extensions/
│   │   ├── valuesets/
│   │   ├── codesystems/
│   │   └── instances/       — example resources
│   ├── pagecontent/
│   │   └── index.md         — IG home page
│   ├── images/
│   └── includes/
│       └── menu.xml         — navigation menu
└── input-cache/
    └── publisher.jar        — HL7 IG Publisher (gitignored)
```

## Further reading

- [FSH School](https://fshschool.org) — FHIR Shorthand language reference and tutorials
- [HL7 IG Publisher](https://github.com/HL7/fhir-ig-publisher) — publisher documentation
- [FHIR Shorthand spec](https://build.fhir.org/ig/HL7/fhir-shorthand/) — full FSH language reference
