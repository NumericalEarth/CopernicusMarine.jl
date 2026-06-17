using CopernicusMarine
using Test

const CM = CopernicusMarine

@testset "CopernicusMarine.jl" begin

    @testset "cli_arguments translation" begin
        # Empty input
        @test CM.cli_arguments(pairs((;))) == String[]

        # Underscores become dashes; values are stringified
        @test CM.cli_arguments(pairs((output_directory = "data",))) ==
              ["--output-directory", "data"]

        # Numbers are stringified
        @test CM.cli_arguments(pairs((minimum_longitude = -5,))) ==
              ["--minimum-longitude", "-5"]

        # `true` becomes a bare flag
        @test CM.cli_arguments(pairs((overwrite = true,))) == ["--overwrite"]

        # `false` and `nothing` are omitted entirely
        @test CM.cli_arguments(pairs((overwrite = false, filter = nothing))) == String[]

        # Vectors repeat the flag once per element (e.g. repeatable --variable)
        @test CM.cli_arguments(pairs((variable = ["chl", "o2"],))) ==
              ["--variable", "chl", "--variable", "o2"]

        # A realistic combined call preserves order and handles every case
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
            # glibc_version parses to a VersionNumber on Linux
            @test glibc === nothing || glibc isa VersionNumber
        end

        url = CM.asset_url()
        @test startswith(url, "https://github.com/mercator-ocean/copernicus-marine-toolbox/releases/download/")
        @test occursin("v$(CM.TOOLBOX_VERSION)", url)
        @test endswith(url, name)
    end

    @testset "public API surface" begin
        # Exported verbs
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

    # These tests download (~50 MB) and execute the standalone binary. They need
    # network access but no Copernicus Marine credentials.
    @testset "executable download and invocation" begin
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
