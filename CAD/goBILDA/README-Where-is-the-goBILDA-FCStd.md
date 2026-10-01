# goBILDA FreeCAD Library

This directory is the generated FreeCAD working library for the goBILDA CAD catalogue used by S0MA OpenLab.

The source STEP/STP files live in:

```text
CAD/Vendor/goBILDA/
```

The converter mirrors that vendor directory structure here and creates `.FCStd` files alongside the same logical categories.

## Build or update this library

Run the converter from WSL:

```bash
cd CAD/Vendor/goBILDA
chmod +x gobilda-convert-FCStd.sh
./gobilda-convert-FCStd.sh
```

Or, from this directory:

```bash
../Vendor/goBILDA/gobilda-convert-FCStd.sh
```

The converter:

- discovers the project paths relative to its own location, so the repository does **not** need to live at `D:\\Sauce\\...`;
- reads STEP/STP files from `CAD/Vendor/goBILDA`;
- writes converted files into `CAD/goBILDA` while preserving the source folder layout;
- skips an existing non-zero `.FCStd` file;
- briefly checks that a STEP file is stable before converting it, so it can safely run while the downloader is still working;
- records conversion failures in `CAD/Vendor/goBILDA/gobilda-convert-FCStd-errors.log`.

## FreeCAD command

By default the script expects the Windows FreeCAD command-line executable at:

```text
C:\Program Files\FreeCAD 1.1\bin\freecadcmd.exe
```

If FreeCAD is installed elsewhere, override the command for that run:

```bash
FREECAD_CMD="/mnt/c/Path/To/FreeCAD/bin/freecadcmd.exe" ./gobilda-convert-FCStd.sh
```

## Generated content

This tree is reproducible from the vendor CAD cache and conversion script. In the public S0MA OpenLab repository, the scripts are the important source artefacts; the full generated CAD library does not need to be treated as hand-authored project content.
