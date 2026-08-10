using Scratch: @get_scratch!
using Downloads: Downloads
using JSON3: JSON3

const TOOLBOX_VERSION = "2.4.1"
const SCRATCH = Ref{String}()

"""
    glibc_version()

Return the host's glibc version as a `VersionNumber` on Linux, or `nothing` if it
cannot be determined (or off Linux).
"""
function glibc_version()
    Sys.islinux() || return nothing
    try
        return VersionNumber(unsafe_string(ccall(:gnu_get_libc_version, Cstring, ())))
    catch
        return nothing
    end
end

"""
    asset_name()

Return the file name of the standalone `copernicusmarine` executable published on
the GitHub releases page for the current platform. Throws if the platform is not
supported.
"""
function asset_name()
    if Sys.iswindows()
        return "copernicusmarine.exe"
    elseif Sys.isapple()
        return Sys.ARCH === :aarch64 ? "copernicusmarine_macos-arm64.cli" :
                                       "copernicusmarine_macos-x86_64.cli"
    elseif Sys.islinux()
        glibc = glibc_version()
        if glibc !== nothing && glibc >= v"2.39"
            return "copernicusmarine_linux-glibc-2.39.cli"
        else
            return "copernicusmarine_linux-glibc-2.35.cli"
        end
    else
        error("CopernicusMarine.jl: no standalone executable for $(Sys.MACHINE)")
    end
end

"""
    asset_url(version=TOOLBOX_VERSION)

Return the GitHub releases download URL for the standalone executable matching the
current platform and `version`.
"""
asset_url(version=TOOLBOX_VERSION) =
    "https://github.com/mercator-ocean/copernicus-marine-toolbox/releases/download/v$(version)/$(asset_name())"

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
        @info "Downloading copernicusmarine v$(TOOLBOX_VERSION) from $(url) ..."
        Downloads.download(url, exe)
        if !Sys.iswindows()
            chmod(exe, 0o755)
        end
        if Sys.isapple()
            try
                run(pipeline(`xattr -d com.apple.quarantine $exe`; stderr=devnull))
            catch
            end
        end
        @info "copernicusmarine installed at $(exe)."
    end
    return exe
end

"""
    cli_arguments(kwargs)

Translate keyword pairs into CLI arguments. Underscores become dashes, `true`
becomes a bare flag, `false`/`nothing` are omitted, vectors repeat the flag.
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

Build the `Cmd` that invokes the auto-downloaded executable with `subcommand`
and keyword arguments translated to CLI options.
"""
command(subcommand::AbstractString, kwargs) =
    `$(executable()) $subcommand $(cli_arguments(kwargs))`

"""
    login(; kwargs...)

Run `copernicusmarine login` to store Copernicus Marine credentials.
"""
login(; kwargs...) = run(command("login", kwargs))

"""
    describe(; kwargs...)

Run `copernicusmarine describe` and return the catalogue as a parsed JSON object.
"""
function describe(; kwargs...)
    json = read(command("describe", kwargs), String)
    return JSON3.read(json)
end

# ── Executable-based subset ────────────────────────────────────────────────────

function _subset_via_executable(;
    dataset_id::String,
    variable  = nothing,
    variables = nothing,
    username::String,
    password::String,
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
    output_path = joinpath(output_directory, output_filename)
    skip_existing && isfile(output_path) && return output_path
    mkpath(output_directory)

    variable_list = let v = something(variable, variables, nothing)
        isnothing(v) ? nothing :
        v isa AbstractArray ? collect(string.(v)) : [string(v)]
    end

    @info "CopernicusMarine.jl (executable)  dataset=$dataset_id"

    cli_kwargs = (
        dataset_id                   = dataset_id,
        variable                     = variable_list,
        output_directory             = output_directory,
        output_filename              = output_filename,
        minimum_longitude            = minimum_longitude,
        maximum_longitude            = maximum_longitude,
        minimum_latitude             = minimum_latitude,
        maximum_latitude             = maximum_latitude,
        minimum_depth                = minimum_depth,
        maximum_depth                = maximum_depth,
        start_datetime               = start_datetime,
        end_datetime                 = end_datetime,
        coordinates_selection_method = coordinates_selection_method,
        force_download               = true,
    )

    # Prefer PATH-installed binary; fall back to auto-downloaded one
    exe = something(Sys.which("copernicusmarine"), executable())
    cmd = Cmd(vcat([exe, "subset"], cli_arguments(cli_kwargs)))

    # Pass credentials via env vars to avoid shell-history exposure
    withenv("COPERNICUSMARINE_SERVICE_USERNAME" => username,
            "COPERNICUSMARINE_SERVICE_PASSWORD" => password) do
        run(cmd)
    end
    return output_path
end

# ── Executable detection ───────────────────────────────────────────────────────

"""
Return `true` if a usable `copernicusmarine` executable is available.

Checks `PATH` first, then attempts to auto-download the standalone binary.
Returns `false` on ARM64 Linux (binary is x86_64 only) or if download fails.
"""
function _has_executable()
    !isnothing(Sys.which("copernicusmarine")) && return true
    # ARM64 Linux: binary is x86_64-only and will not run
    Sys.islinux() && Sys.ARCH === :aarch64 && return false
    try
        executable()
        return true
    catch
        return false
    end
end
