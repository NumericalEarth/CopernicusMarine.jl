# CopernicusMarine.jl

Julia wrapper for the python package [copernicusmarine](https://github.com/mercator-ocean/copernicus-marine-toolbox).

<a href="https://github.com/NumericalEarth/CopernicusMarine.jl/actions">
  <img alt="CI" src="https://github.com/NumericalEarth/CopernicusMarine.jl/actions/workflows/CI.yml/badge.svg">
</a>

## Overview

CopernicusMarine.jl provides a Julia interface to the [copernicusmarine](https://github.com/mercator-ocean/copernicus-marine-toolbox) Python library, which provides tools downloading Copernicus datasets.

## Installation

```julia
using Pkg
Pkg.add("CopernicusMarine")
```

## Usage

By importing the package you have access to the python package via:

```julia
julia> using CopernicusMarine

julia> CopernicusMarine.copernicusmarine
Python: <module 'copernicusmarine' from '/Users/arandomuser/CopernicusMarine.jl/.CondaPkg/.pixi/envs/default/lib/python3.13/site-packages/copernicusmarine/__init__.py'>
```
