module CopernicusMarine

using CondaPkg
using PythonCall

"""
    install_copernicusmarine()

Install the Copernicus Marine CLI using CondaPkg.
Returns a NamedTuple containing package information if successful.
"""
function install_copernicusmarine()
    @info "Installing the copernicusmarine CLI..."
    CondaPkg.add("copernicusmarine"; channel = "conda-forge")
    cli = CondaPkg.which("copernicusmarine")
    @info "... the copernicusmarine CLI has been installed at $(cli)."
    return cli
end

# Placeholder (will be overwritten in __init__)
copernicusmarine = Py(nothing)

function __init__()
    global copernicusmarine
    try
        copernicusmarine = pyimport("copernicusmarine")
    catch er1
        @warn "Python package 'copernicusmarine' not found. Attempting to install..."
        try
            install_copernicusmarine()
            copernicusmarine = pyimport("copernicusmarine")
        catch er2
            error("Failed to install or import 'copernicusmarine':\n$(er2)")
        end
    end
end

end # module CopernicusMarine
