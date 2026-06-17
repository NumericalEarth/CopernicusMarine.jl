# CopernicusMarine.jl

Julia interface to the [Copernicus Marine Toolbox](https://github.com/mercator-ocean/copernicus-marine-toolbox) for downloading Copernicus Marine datasets.

<a href="https://github.com/NumericalEarth/CopernicusMarine.jl/actions">
  <img alt="CI" src="https://github.com/NumericalEarth/CopernicusMarine.jl/actions/workflows/CI.yml/badge.svg">
</a>

## Overview

CopernicusMarine.jl drives the standalone [`copernicusmarine`](https://github.com/mercator-ocean/copernicus-marine-toolbox) command-line executable. The required executable is a single, self-contained binary that is downloaded automatically on first use — there is **no Python, conda, or pip dependency**.

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
