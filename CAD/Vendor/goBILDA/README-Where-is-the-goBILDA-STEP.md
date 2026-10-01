# goBILDA Vendor CAD Cache

This directory contains the scripts used by S0MA OpenLab to reconstruct the local goBILDA CAD library from goBILDA's public product catalogue.

The two main scripts are:

```text
gobilda-sync.sh
gobilda-convert-FCStd.sh
```

`gobilda-sync.sh` downloads and organises the vendor CAD source files. `gobilda-convert-FCStd.sh` converts the downloaded STEP/STP files into the FreeCAD library at `CAD/goBILDA`.

## Paths are project-relative

The scripts derive their paths from their own location. The repository can therefore be cloned anywhere; there is no hard-coded `D:\\Sauce\\S0MA` requirement.

They assume this layout is preserved:

```text
CAD/
├── goBILDA/                 # generated FreeCAD .FCStd library
└── Vendor/
    └── goBILDA/             # this directory + source CAD cache + scripts
```

## 1. Download / refresh the vendor CAD

From WSL:

```bash
cd CAD/Vendor/goBILDA
chmod +x gobilda-sync.sh gobilda-convert-FCStd.sh
./gobilda-sync.sh
```

On first run, the sync script creates its own Python virtual environment under:

```text
~/.cache/soma-gobilda-sync/venv
```

It installs the small Python dependency set it needs there, leaving the system Python environment alone.

Useful options include:

```bash
./gobilda-sync.sh --dry-run
./gobilda-sync.sh --root structure
./gobilda-sync.sh --root motion
./gobilda-sync.sh --delay 3 --jitter 1
```

Run `./gobilda-sync.sh --help` for the full option set.

## 2. Convert STEP/STP files to FreeCAD

After the sync has started, or after it has completed:

```bash
./gobilda-convert-FCStd.sh
```

The converter can run at the same time as the downloader. It checks that each STEP file has stopped changing before touching it, defers any file that still appears busy, and skips `.FCStd` files that already exist and are non-zero.

By default it expects:

```text
C:\Program Files\FreeCAD 1.1\bin\freecadcmd.exe
```

If FreeCAD lives elsewhere:

```bash
FREECAD_CMD="/mnt/c/Path/To/FreeCAD/bin/freecadcmd.exe" ./gobilda-convert-FCStd.sh
```

## Deliberately slow and polite

The downloader is intentionally conservative. It is designed to reconstruct a development reference library without hammering goBILDA's website.

The default request policy is:

```text
minimum delay: 2.0 seconds
random jitter: 0.0-0.75 seconds
```

It also honours retry delays, applies exponential backoff around Cloudflare/rate-limit responses, and reuses the local vendor tree as its resume mechanism. Existing SKU files are skipped rather than downloaded again.

This means a complete first pass can take a long time. That is deliberate. Please do not remove the delays or turn the script into an aggressive parallel scraper.

## Resume and exclusions

The vendor tree is the download resume state. Re-running the sync rescans the catalogue but skips SKUs already present locally.

Confirmed products without usable STEP data are recorded in:

```text
gobilda-no-step-exclusions.txt
```

The audit/error log is written to:

```text
gobilda-sync-errors.log
```

Conversion failures are written to:

```text
gobilda-convert-FCStd-errors.log
```

## Public-repository intent

S0MA OpenLab publishes the acquisition/conversion tooling so contributors can reconstruct the reference library themselves. This avoids making the public repository a large mirror of third-party vendor CAD while keeping the process reproducible.
