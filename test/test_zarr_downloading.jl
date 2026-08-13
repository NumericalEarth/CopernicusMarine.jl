# Run manually with credentials in environment:
#   COPERNICUS_USERNAME=... COPERNICUS_PASSWORD=... julia --project test/test_zarr_downloading.jl
#
# Not included in standard CI (Pkg.test()) because it requires network + credentials
# and ~100 MB of downloads. Follow the NumericalEarth convention of keeping download
# tests in a separate file excluded from the main test suite.

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

@testset "Zarr pure-Julia download" begin

    @testset "daily thetao, 0–10 m, small box near Bouvet" begin
        out = joinpath(tempdir(), "cmtest_$(getpid())_daily.nc")
        try
            path = CM.subset_via_zarr(
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
                depths = ds["depth"][:]
                thetao = ds["thetao"][:, :, :, :]  # lon × lat × depth × time

                # First depth level should be ~0.49 m (verifies geoChunked store)
                @test depths[1] > 0.0
                @test depths[1] < 1.0
                @info "depth[1] = $(round(depths[1], digits=3)) m  (expected ~0.494)"

                # Depths should be positive and ascending
                @test all(diff(depths) .> 0)

                # Most values should be non-missing in this ocean region
                # (NCDatasets returns fill values as missing, not NaN)
                miss_frac = count(ismissing, thetao) / length(thetao)
                @test miss_frac < 0.1
                @info "Missing fraction: $(round(miss_frac * 100, digits=1))% (expected <10%)"

                @info "Output shape: $(size(thetao))  (lon × lat × depth × time)"
            end
        finally
            rm(out; force=true)
        end
    end

    @testset "skip_existing returns immediately on second call" begin
        out = joinpath(tempdir(), "cmtest_$(getpid())_skip.nc")
        kw = (
            dataset_id        = "cmems_mod_glo_phy_my_0.083deg_P1D-m",
            variable          = ["thetao"],
            username          = username,
            password          = password,
            output_directory  = tempdir(),
            output_filename   = basename(out),
            minimum_longitude = 3.0,
            maximum_longitude = 3.1,
            minimum_latitude  = -55.0,
            maximum_latitude  = -54.9,
            minimum_depth     = 0.0,
            maximum_depth     = 1.0,
            start_datetime    = "2000-01-01T00:00:00",
            end_datetime      = "2000-01-01T00:00:00",
        )
        try
            path1 = CM.subset_via_zarr(; kw..., skip_existing=false)
            mtime1 = mtime(path1)
            sleep(0.1)
            path2 = CM.subset_via_zarr(; kw..., skip_existing=true)
            @test path1 == path2
            @test mtime(path2) == mtime1   # file was not re-downloaded
        finally
            rm(out; force=true)
        end
    end

    @testset "BGC daily: chl and o2, surface box near Bouvet" begin
        out = joinpath(tempdir(), "cmtest_$(getpid())_bgc.nc")
        try
            path = CM.subset_via_zarr(
                dataset_id        = "cmems_mod_glo_bgc_my_0.25deg_P1D-m",
                variable          = ["chl", "o2"],
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
            NCDataset(path) do ds
                @test haskey(ds, "chl")
                @test haskey(ds, "o2")

                chl = ds["chl"][:, :, :, :]
                @test !all(ismissing, chl)

                depths = ds["depth"][:]
                @test depths[1] < 1.0     # geoChunked includes ~0.5 m surface level
                @test all(diff(depths) .> 0)

                @test ds["chl"].attrib["units"] == "mg m-3"
                @test ds["o2"].attrib["units"]  == "mmol m-3"
            end
        finally
            rm(out; force=true)
        end
    end

    @testset "monthly dataset URL resolves to geoChunked" begin
        url = CM.zarr_url("cmems_mod_glo_phy_my_0.083deg_P1M-m")
        @test occursin("geoChunked", url)
        out = joinpath(tempdir(), "cmtest_$(getpid())_monthly.nc")
        try
            path = CM.subset_via_zarr(
                dataset_id        = "cmems_mod_glo_phy_my_0.083deg_P1M-m",
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
                maximum_depth     = 5.0,
                start_datetime    = "2000-01-01T00:00:00",
                end_datetime      = "2000-01-01T00:00:00",
                skip_existing     = false,
            )
            @test isfile(path)
            NCDataset(path) do ds
                @test ds["depth"][1] < 1.0
            end
        finally
            rm(out; force=true)
        end
    end

end
