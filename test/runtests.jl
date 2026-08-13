using CopernicusMarine
using Test
using Dates

const CM = CopernicusMarine

@testset "CopernicusMarine.jl" begin

    @testset "cli_arguments translation" begin
        @test CM.cli_arguments(pairs((;))) == String[]

        @test CM.cli_arguments(pairs((output_directory = "data",))) ==
              ["--output-directory", "data"]

        @test CM.cli_arguments(pairs((minimum_longitude = -5,))) ==
              ["--minimum-longitude", "-5"]

        @test CM.cli_arguments(pairs((overwrite = true,))) == ["--overwrite"]

        @test CM.cli_arguments(pairs((overwrite = false, filter = nothing))) == String[]

        @test CM.cli_arguments(pairs((variable = ["chl", "o2"],))) ==
              ["--variable", "chl", "--variable", "o2"]

        args = CM.cli_arguments(pairs((
            dataset_id = "cmems_mod_ibi_bgc_anfc",
            variable = ["chl", "o2"],
            minimum_longitude = -5,
            overwrite = true,
            disable_progress_bar = false,
            output_directory = "data",
        )))
        @test args == [
            "--dataset-id", "cmems_mod_ibi_bgc_anfc",
            "--variable", "chl", "--variable", "o2",
            "--minimum-longitude", "-5",
            "--overwrite",
            "--output-directory", "data",
        ]
    end

    @testset "asset selection" begin
        name = CM.asset_name()
        @test name isa String
        @test !isempty(name)

        if Sys.iswindows()
            @test name == "copernicusmarine.exe"
        elseif Sys.isapple()
            @test name == (Sys.ARCH === :aarch64 ? "copernicusmarine_macos-arm64.cli" :
                                                    "copernicusmarine_macos-x86_64.cli")
        elseif Sys.islinux()
            glibc = CM.glibc_version()
            expected = (glibc !== nothing && glibc >= v"2.39") ?
                       "copernicusmarine_linux-glibc-2.39.cli" :
                       "copernicusmarine_linux-glibc-2.35.cli"
            @test name == expected
            @test glibc === nothing || glibc isa VersionNumber
        end

        url = CM.asset_url()
        @test startswith(url, "https://github.com/mercator-ocean/copernicus-marine-toolbox/releases/download/")
        @test occursin("v$(CM.TOOLBOX_VERSION)", url)
        @test endswith(url, name)
    end

    @testset "public API surface" begin
        for f in (subset, describe, login)
            @test f isa Function
        end
        @test :subset in names(CopernicusMarine)
        @test :describe in names(CopernicusMarine)
        @test :login in names(CopernicusMarine)

        # `get` exists but is intentionally not exported (clashes with Base.get)
        @test CM.get isa Function
        @test !(:get in names(CopernicusMarine))
    end

    @testset "scratch directory" begin
        @test isassigned(CM.SCRATCH)
        @test isdir(CM.SCRATCH[])
    end

    @testset "executable detection" begin
        result = CM.has_executable()
        @test result isa Bool
        # ARM64 Linux: the binary is x86_64-only and must not be attempted
        if Sys.islinux() && Sys.ARCH === :aarch64
            @test result == false
        end
    end

    # Downloads (~50 MB) and runs the standalone binary. Needs network, no credentials.
    @testset "executable download and invocation" begin
        if !CM.has_executable()
            @info "Skipping executable tests: no usable binary on this platform (ARM64?)"
            @test_skip "no executable"
        else
            exe = CM.executable()
            @test isfile(exe)
            @test exe == CM.executable()  # cached: second call returns same path

            version_output = read(`$exe --version`, String)
            @test occursin(CM.TOOLBOX_VERSION, version_output)

            help_output = read(`$exe --help`, String)
            @test occursin("subset", help_output)
            @test occursin("describe", help_output)
        end
    end

    # ── Zarr backend unit tests (no network, no credentials) ──────────────────

    @testset "Zarr: _overlap_ranges" begin
        # Chunk 0 of size 4 against global [1,4]: full overlap
        act, src, dst = CM.overlap_ranges(0, 4, 1, 4, 8)
        @test act == 4
        @test src == 1:4
        @test dst == 1:4

        # Chunk 1 of size 4 against global [1,4]: no overlap (chunk covers [5,8])
        act2, src2, dst2 = CM.overlap_ranges(1, 4, 1, 4, 8)
        @test isnothing(act2)

        # Partial overlap: chunk 0 covers [1,4], global [3,6]
        act3, src3, dst3 = CM.overlap_ranges(0, 4, 3, 6, 8)
        @test act3 == 4
        @test src3 == 3:4   # positions 3-4 within the chunk
        @test dst3 == 1:2   # positions 1-2 in the output

        # Last chunk may be smaller than chunk_size
        act4, src4, dst4 = CM.overlap_ranges(1, 4, 5, 6, 6)
        @test act4 == 2     # only 2 elements in the last chunk (6 total, chunk_size=4)
        @test src4 == 1:2
        @test dst4 == 1:2
    end

    @testset "Zarr: _depth_range" begin
        # Positive-down convention (timeChunked style): [0.494, 1.541, 2.646, 5.079, 10.0]
        depths_pos = Float64[0.494, 1.541, 2.646, 5.079, 10.0]
        # searchsortedlast(v, 5.0) stops before 5.079, so max depth 5.0 → indices 1:3
        @test CM.depth_range(depths_pos, 0.0, 5.0) == 1:3
        @test CM.depth_range(depths_pos, nothing, nothing) == 1:5

        # Negative elevation convention (geoChunked): [-10.0, -5.079, -2.646, -1.541, -0.494]
        # depth range [0, 5] maps to elevation range [-5, 0]
        # searchsortedfirst(v, -5.0) skips -5.079 (< -5.0), returns index 3 (-2.646)
        depths_neg = Float64[-10.0, -5.079, -2.646, -1.541, -0.494]
        @test CM.depth_range(depths_neg, 0.0, 5.0) == 3:5
        @test CM.depth_range(depths_neg, nothing, nothing) == 1:5
    end

    @testset "Zarr: _time_range" begin
        epoch = DateTime(1950, 1, 1)
        # hours since 1950-01-01 for each day in Jan 2000
        t_values = Float64[(DateTime(2000, 1, d) - epoch).value ÷ 3_600_000 for d in 1:5]

        # 3 days within range (0-based indices)
        idxs = CM.time_range(t_values, DateTime("2000-01-02"), DateTime("2000-01-04"))
        @test idxs == [1, 2, 3]   # day 2 → index 1, day 3 → index 2, day 4 → index 3

        # Single day
        @test CM.time_range(t_values, DateTime("2000-01-01"), DateTime("2000-01-01")) == [0]

        # Empty range (before any data)
        @test isempty(CM.time_range(t_values, DateTime("1999-01-01"), DateTime("1999-12-31")))
    end

    @testset "Zarr: known URL lookup" begin
        for id in ("cmems_mod_glo_phy_my_0.083deg_P1D-m",
                   "cmems_mod_glo_phy_my_0.083deg_P1M-m",
                   "cmems_mod_glo_bgc_my_0.25deg_P1D-m",
                   "cmems_mod_glo_bgc_my_0.25deg_P1M-m")
            url = CM.zarr_url(id)
            @test occursin("geoChunked", url)
            @test occursin("s3.waw3-1.cloudferro.com", url)
            @test endswith(url, ".zarr")
        end

        # BGC uses a different bucket (geo-018) from physics (geo-025)
        @test occursin("mdl-arco-geo-018", CM.zarr_url("cmems_mod_glo_bgc_my_0.25deg_P1D-m"))
        @test occursin("mdl-arco-geo-025", CM.zarr_url("cmems_mod_glo_phy_my_0.083deg_P1D-m"))
    end

end
