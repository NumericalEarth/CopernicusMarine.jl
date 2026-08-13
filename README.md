# CopernicusMarine.jl

Julia interface to the [Copernicus Marine Toolbox](https://github.com/mercator-ocean/copernicus-marine-toolbox) for downloading Copernicus Marine datasets.

<a href="https://github.com/NumericalEarth/CopernicusMarine.jl/actions">
  <img alt="CI" src="https://github.com/NumericalEarth/CopernicusMarine.jl/actions/workflows/CI.yml/badge.svg">
</a>

## Overview

CopernicusMarine.jl provides two download backends, selected automatically at runtime:

| Platform | Backend |
|---|---|
| x86-64 Linux, macOS, Windows | Standalone [`copernicusmarine`](https://github.com/mercator-ocean/copernicus-marine-toolbox) executable, downloaded automatically on first use — no Python or conda required |
| ARM64 Linux (e.g. NVIDIA GH200) | Pure Julia Zarr client — no binary dependency |

On x86-64 the executable backend supports any dataset and variable in the Copernicus Marine catalogue. The pure Julia backend currently supports a curated set of global multiyear datasets listed below.

## Installation

```julia
using Pkg
Pkg.add("CopernicusMarine")
```

## Authentication

You need free [Copernicus Marine](https://marine.copernicus.eu/) credentials to download data. Either store them once with `login`:

```julia
using CopernicusMarine
login(username="your_username", password="your_password")
```

or set them in the environment before downloading:

```julia
ENV["COPERNICUSMARINE_SERVICE_USERNAME"] = "your_username"
ENV["COPERNICUSMARINE_SERVICE_PASSWORD"] = "your_password"
```

## Usage

Keyword arguments map directly to the toolbox's command-line options (underscores become dashes, e.g. `output_directory` → `--output-directory`). Options that accept multiple values, such as `--variable`, take a vector.

### Subset a dataset

```julia
using CopernicusMarine

subset(dataset_id = "cmems_mod_ibi_bgc_anfc_0.027deg-3D_P1D-m",
       variable = ["chl", "o2"],
       minimum_longitude = -5, maximum_longitude = -3,
       minimum_latitude = 43, maximum_latitude = 44,
       start_datetime = "2023-09-01", end_datetime = "2023-09-30",
       output_directory = "data")
```

### Download original files

```julia
CopernicusMarine.get(dataset_id = "cmems_mod_ibi_bgc_anfc_0.027deg-3D_P1D-m",
                     filter = "*20241221*",
                     output_directory = "data")
```

(`get` is not exported because it would clash with `Base.get`; call it as `CopernicusMarine.get`.)

### Inspect the catalogue

`describe` returns the catalogue as a parsed JSON object:

```julia
catalogue = describe(contains="Global Ocean")
```

### Access the executable directly

```julia
exe = CopernicusMarine.executable()   # path to the downloaded binary
run(`$exe subset --help`)
```

Downloaded data files (NetCDF or Zarr) can be read with packages such as
[NCDatasets.jl](https://github.com/JuliaGeo/NCDatasets.jl).

## Supported datasets (pure Julia backend)

The following global multiyear datasets are available on all platforms via the pure Julia
Zarr backend. Output is written as NetCDF with positive-down depth coordinates.

### Global Physics — GLOBAL_MULTIYEAR_PHY_001_030 (0.083°)

| Dataset ID | Temporal resolution |
|---|---|
| `cmems_mod_glo_phy_my_0.083deg_P1D-m` | Daily |
| `cmems_mod_glo_phy_my_0.083deg_P1M-m` | Monthly |

Variables: `thetao`, `so`, `uo`, `vo`, `zos`

### Global Biogeochemistry — GLOBAL_MULTIYEAR_BGC_001_029 (0.25°)

| Dataset ID | Temporal resolution |
|---|---|
| `cmems_mod_glo_bgc_my_0.25deg_P1D-m` | Daily |
| `cmems_mod_glo_bgc_my_0.25deg_P1M-m` | Monthly |

Variables: `chl`, `no3`, `nppv`, `o2`, `po4`, `si`

Other dataset IDs can still be used on ARM64 — the backend falls back to STAC discovery and
will attempt to fetch the dataset's geoChunked Zarr store. If the store layout matches the
supported format the download will succeed; add the URL to `KNOWN_ZARR_URLS` in
`src/zarr_backend.jl` to avoid the discovery overhead on future calls.

Browse the full CMEMS catalogue at https://stac.marine.copernicus.eu to find other dataset IDs.
