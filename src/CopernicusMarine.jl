module CopernicusMarine

export subset, describe, login

using DocStringExtensions: TYPEDSIGNATURES

include("executable.jl")   # binary management + _has_executable() + _subset_via_executable
include("zarr_backend.jl") # pure Julia Zarr path + _subset_via_zarr

"""
$TYPEDSIGNATURES

Download a subset of a CMEMS dataset as a NetCDF file.

When a `copernicusmarine` executable is available (either on `PATH` or
auto-downloaded), it is used directly. On platforms where the binary is not
supported (e.g. ARM64 Linux), the request is served by a pure Julia Zarr
client instead.

# Keyword arguments

- `dataset_id` — CMEMS dataset identifier.
- `variable` / `variables` — single variable name or a vector of names.
- `username`, `password` — CMEMS credentials.
  Defaults to `COPERNICUS_USERNAME`/`COPERNICUSMARINE_SERVICE_USERNAME` and
  `COPERNICUS_PASSWORD`/`COPERNICUSMARINE_SERVICE_PASSWORD` environment variables.
- `output_directory`, `output_filename` — where to write the output NetCDF.
- `minimum_longitude`, `maximum_longitude` — longitude range (°E).
- `minimum_latitude`, `maximum_latitude` — latitude range (°N).
- `minimum_depth`, `maximum_depth` — depth range (m, positive down). `nothing` = full column.
- `start_datetime`, `end_datetime` — ISO-8601 strings, e.g. `"2020-01-01T00:00:00"`.
- `skip_existing` — skip download if the output file already exists (default `true`).
- `coordinates_selection_method` — `"outside"` (default) or `"inside"`.
"""
function subset(;
    dataset_id::String,
    variable  = nothing,
    variables = nothing,
    username::String = get(ENV, "COPERNICUS_USERNAME",
                       get(ENV, "COPERNICUSMARINE_SERVICE_USERNAME", "")),
    password::String = get(ENV, "COPERNICUS_PASSWORD",
                       get(ENV, "COPERNICUSMARINE_SERVICE_PASSWORD", "")),
    output_directory::String,
    output_filename::String,
    minimum_longitude::Real,
    maximum_longitude::Real,
    minimum_latitude::Real,
    maximum_latitude::Real,
    minimum_depth::Union{Real,Nothing} = nothing,
    maximum_depth::Union{Real,Nothing} = nothing,
    start_datetime::Union{String,Nothing} = nothing,
    end_datetime::Union{String,Nothing}   = nothing,
    skip_existing::Bool = true,
    coordinates_selection_method::String  = "outside",
    kwargs...
)
    kw = (; dataset_id, variable, variables, username, password,
            output_directory, output_filename,
            minimum_longitude, maximum_longitude,
            minimum_latitude, maximum_latitude,
            minimum_depth, maximum_depth,
            start_datetime, end_datetime,
            skip_existing, coordinates_selection_method, kwargs...)
    if has_executable()
        return subset_via_executable(; kw...)
    else
        return subset_via_zarr(; kw...)
    end
end

function __init__()
    SCRATCH[] = @get_scratch!("copernicusmarine-v$(TOOLBOX_VERSION)")
    return nothing
end

end # module CopernicusMarine
