module CopernicusMarine

using Scratch: @get_scratch!
using Downloads: Downloads
using JSON3: JSON3

export subset, describe, login

"""
The version of the Copernicus Marine Toolbox standalone executable that this
package downloads and drives. See https://github.com/mercator-ocean/copernicus-marine-toolbox/releases.
"""
const TOOLBOX_VERSION = "2.4.1"

# Populated by `__init__` with the directory holding the downloaded executable.
const SCRATCH = Ref{String}()

"""
    asset_name()

Return the file name of the standalone `copernicusmarine` executable published on
the GitHub releases page for the current platform. Throws if the platform is not
supported.

The Linux build is the `glibc-2.35` variant, which is forward compatible with
newer glibc versions.
"""
function asset_name()
    if Sys.iswindows()
        return "copernicusmarine.exe"
    elseif Sys.isapple()
        return Sys.ARCH === :aarch64 ? "copernicusmarine_macos-arm64.cli" :
                                       "copernicusmarine_macos-x86_64.cli"
    elseif Sys.islinux()
        return "copernicusmarine_linux-glibc-2.35.cli"
    else
        error("CopernicusMarine.jl does not support $(Sys.MACHINE): no standalone " *
              "`copernicusmarine` executable is published for this platform.")
    end
end

"""
    asset_url(version=TOOLBOX_VERSION)

Return the GitHub releases download URL for the standalone executable matching the
current platform and `version`.
"""
asset_url(version=TOOLBOX_VERSION) =
    "https://github.com/mercator-ocean/copernicus-marine-toolbox/releases/download/v$(version)/$(asset_name())"

# Local file name for the downloaded executable.
_executable_path() = joinpath(SCRATCH[], Sys.iswindows() ? "copernicusmarine.exe" : "copernicusmarine")

"""
    executable(; force=false)

Return the path to the standalone `copernicusmarine` executable, downloading it
into a scratch directory on first use. Pass `force=true` to re-download.
"""
function executable(; force::Bool=false)
    exe = _executable_path()

    if force || !isfile(exe)
        url = asset_url()
        @info "Downloading the copernicusmarine v$(TOOLBOX_VERSION) executable from $(url) ..."
        Downloads.download(url, exe)

        if !Sys.iswindows()
            chmod(exe, 0o755)
        end

        # Downloaded executables can be quarantined by macOS Gatekeeper, which
        # prevents them from running. Strip the attribute if present.
        if Sys.isapple()
            try
                run(pipeline(`xattr -d com.apple.quarantine $exe`; stderr=devnull))
            catch
                # No quarantine attribute set, or `xattr` unavailable; ignore.
            end
        end

        @info "... copernicusmarine has been installed at $(exe)."
    end

    return exe
end

"""
    cli_arguments(kwargs)

Translate a collection of keyword pairs into a vector of command-line arguments.

- Underscores in keys become dashes: `output_directory` -> `--output-directory`.
- `true` becomes a bare flag; `false` and `nothing` are omitted.
- A vector value repeats the flag once per element, matching repeatable options
  such as `--variable`.
- Any other value is appended as a stringified argument.
"""
function cli_arguments(kwargs)
    args = String[]
    for (key, value) in kwargs
        flag = "--" * replace(string(key), "_" => "-")
        if value === true
            push!(args, flag)
        elseif value === false || value === nothing
            continue
        elseif value isa AbstractVector
            for element in value
                push!(args, flag, string(element))
            end
        else
            push!(args, flag, string(value))
        end
    end
    return args
end

"""
    command(subcommand, kwargs)

Build the `Cmd` that invokes `copernicusmarine <subcommand>` with `kwargs`
translated to command-line options by [`cli_arguments`](@ref).
"""
command(subcommand::AbstractString, kwargs) =
    `$(executable()) $subcommand $(cli_arguments(kwargs))`

"""
    login(; kwargs...)

Run `copernicusmarine login` to store Copernicus Marine credentials. Pass
`username` and `password` to log in non-interactively, e.g.

```julia
login(username="me", password="secret")
```

Credentials may instead be supplied through the `COPERNICUSMARINE_SERVICE_USERNAME`
and `COPERNICUSMARINE_SERVICE_PASSWORD` environment variables, in which case the
other commands pick them up automatically and `login` is not required.
"""
login(; kwargs...) = run(command("login", kwargs))

"""
    subset(; kwargs...)

Run `copernicusmarine subset` to download a subset of a dataset as a NetCDF file
or Zarr store. Keyword arguments map to CLI options, e.g.

```julia
subset(dataset_id = "cmems_mod_ibi_bgc_anfc_0.027deg-3D_P1D-m",
       variable = ["chl", "o2"],
       minimum_longitude = -5, maximum_longitude = -3,
       minimum_latitude = 43, maximum_latitude = 44,
       start_datetime = "2023-09-01", end_datetime = "2023-09-30",
       output_directory = "data")
```
"""
subset(; kwargs...) = run(command("subset", kwargs))

"""
    get(; kwargs...)

Run `copernicusmarine get` to download the original data files of a dataset, e.g.

```julia
CopernicusMarine.get(dataset_id = "cmems_mod_ibi_bgc_anfc_0.027deg-3D_P1D-m",
                     filter = "*20241221*",
                     output_directory = "data")
```

`get` is not exported because it would clash with `Base.get`; call it as
`CopernicusMarine.get`.
"""
get(; kwargs...) = run(command("get", kwargs))

"""
    describe(; kwargs...)

Run `copernicusmarine describe` and return the catalogue as a parsed JSON object.
Keyword arguments filter the catalogue, e.g. `describe(contains="Global Ocean")`.
"""
function describe(; kwargs...)
    json = read(command("describe", kwargs), String)
    return JSON3.read(json)
end

function __init__()
    SCRATCH[] = @get_scratch!("copernicusmarine-v$(TOOLBOX_VERSION)")
    return nothing
end

end # module CopernicusMarine
