# Run manually with credentials in environment:
#   COPERNICUS_USERNAME=... COPERNICUS_PASSWORD=... julia --project test/test_executable_downloading.jl
#
# Not included in standard CI (Pkg.test()) because it requires network + credentials,
# the ~50 MB standalone toolbox binary, and a real CMEMS download. Follow the
# NumericalEarth convention of keeping download tests in a separate file excluded
# from the main test suite (see test/test_zarr_downloading.jl).
#
# This exercises `subset_via_executable` end to end, which is what PR #8's
# `cli_arguments(pairs(cli_kwargs))` fix actually changes: before the fix, the
# real `cli_kwargs` NamedTuple built inside `subset_via_executable` reached
# `cli_arguments` unwrapped and threw a `BoundsError` on the first scalar field,
# so this test could not have passed pre-fix.

using CopernicusMarine
using Test
using NCDatasets: NCDataset

const CM = CopernicusMarine

username = get(ENV, "COPERNICUS_USERNAME",
           get(ENV, "COPERNICUSMARINE_SERVICE_USERNAME", ""))
password = get(ENV, "COPERNICUS_PASSWORD",
           get(ENV, "COPERNICUSMARINE_SERVICE_PASSWORD", ""))

if isempty(username) || isempty(password)
    error("Set COPERNICUS_USERNAME and COPERNICUS_PASSWORD before running this test")
end

if !CM.has_executable()
    error("No usable standalone toolbox binary on this platform (ARM64 Linux?); " *
          "cannot run the executable-backed download test here")
end

@testset "Executable-backed download" begin

    @testset "daily thetao, small box near Bouvet" begin
        out = joinpath(tempdir(), "cmtest_$(getpid())_executable.nc")
        try
            path = CM.subset_via_executable(
                dataset_id        = "cmems_mod_glo_phy_my_0.083deg_P1D-m",
                variable          = ["thetao"],
                username          = username,
                password          = password,
                output_directory  = tempdir(),
                output_filename   = basename(out),
                minimum_longitude = 3.0,
                maximum_longitude = 4.0,
                minimum_latitude  = -55.0,
                maximum_latitude  = -54.0,
                minimum_depth     = 0.0,
                maximum_depth     = 10.0,
                start_datetime    = "2000-01-01T00:00:00",
                end_datetime      = "2000-01-01T00:00:00",
                skip_existing     = false,
            )
            @test isfile(path)
            @test filesize(path) > 0

            NCDataset(path) do ds
                @test haskey(ds, "thetao")
                thetao = ds["thetao"][:, :, :, :]
                @test !all(ismissing, thetao)
            end
        finally
            rm(out; force=true)
        end
    end

end
