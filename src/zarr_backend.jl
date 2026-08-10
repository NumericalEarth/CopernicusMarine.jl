import Blosc
import HTTP
using Dates: Date, DateTime, Hour, Second, now
using NCDatasets: NCDataset, defDim, defVar

# ─── OAuth2 token ─────────────────────────────────────────────────────────────

const _AUTH_URL = "https://auth.marine.copernicus.eu/realms/MIS/protocol/openid-connect/token"

mutable struct _TokenCache
    token::String
    expires_at::DateTime
end

const _CACHE = Ref{Union{Nothing,_TokenCache}}(nothing)

function _get_token(username::String, password::String)
    cache = _CACHE[]
    !isnothing(cache) && now() < cache.expires_at - Second(60) && return cache.token

    body = "client_id=toolbox&grant_type=password" *
           "&username=$(HTTP.URIs.escapeuri(username))" *
           "&password=$(HTTP.URIs.escapeuri(password))" *
           "&scope=openid+profile+email"
    resp = HTTP.post(_AUTH_URL,
                     ["Content-Type" => "application/x-www-form-urlencoded"],
                     body; status_exception=true, readtimeout=30)
    data = JSON3.read(resp.body)
    token = String(data["access_token"])
    expires_in = get(data, "expires_in", 600)
    _CACHE[] = _TokenCache(token, now() + Second(Int(expires_in)))
    return token
end

# ─── Known Zarr URLs (avoids STAC traversal on every call) ────────────────────
# Add BGC dataset IDs here as they are validated. Physics datasets use geoChunked
# (mdl-arco-geo-025) which includes depth_chunk=0 (~0.5 m); timeChunked does not.

const _KNOWN_ZARR = Dict{String,String}(
    "cmems_mod_glo_phy_my_0.083deg_P1D-m" =>
        "https://s3.waw3-1.cloudferro.com/mdl-arco-geo-025/arco/" *
        "GLOBAL_MULTIYEAR_PHY_001_030/" *
        "cmems_mod_glo_phy_my_0.083deg_P1D-m_202311/geoChunked.zarr",
    "cmems_mod_glo_phy_my_0.083deg_P1M-m" =>
        "https://s3.waw3-1.cloudferro.com/mdl-arco-geo-025/arco/" *
        "GLOBAL_MULTIYEAR_PHY_001_030/" *
        "cmems_mod_glo_phy_my_0.083deg_P1M-m_202311/geoChunked.zarr",
)

# ─── STAC discovery (used when dataset not in _KNOWN_ZARR) ────────────────────

const _CONFIG_URL = "https://stac.marine.copernicus.eu/clients-config-v1"

function _discover_zarr_url(dataset_id::String)
    config      = JSON3.read(HTTP.get(_CONFIG_URL; status_exception=true, readtimeout=30).body)
    stac_root   = String(config["catalogues"][1]["stacRoot"])
    mapping_url = String(config["catalogues"][1]["idMapping"])

    mapping = JSON3.read(HTTP.get(mapping_url; status_exception=true, readtimeout=60).body)
    haskey(mapping, dataset_id) || error("Dataset '$dataset_id' not found in CMEMS catalogue")
    product_ids = String.(split(String(mapping[dataset_id]), ","))

    for product_id in product_ids
        product_resp = HTTP.get(joinpath(stac_root, product_id, "product.stac.json");
                                status_exception=false, readtimeout=30)
        product_resp.status >= 300 && continue
        product = JSON3.read(product_resp.body)

        for link in product["links"]
            get(link, "rel", "") == "item" || continue
            href = String(link["href"])
            contains(href, dataset_id) || continue

            dataset_resp = HTTP.get(joinpath(stac_root, product_id, href);
                                    status_exception=false, readtimeout=30)
            dataset_resp.status >= 300 && continue
            dataset = JSON3.read(dataset_resp.body)

            geo_url, time_url = nothing, nothing
            for (_, asset) in pairs(dataset["assets"])
                asset_href = get(asset, "href", "")
                contains(asset_href, "geoChunked")  && (geo_url  = String(asset_href))
                contains(asset_href, "timeChunked") && (time_url = String(asset_href))
            end
            # geoChunked has all depth levels (incl. ~0.5 m); prefer it
            !isnothing(geo_url)  && return geo_url
            !isnothing(time_url) && return time_url
        end
    end
    error("No geoChunked or timeChunked Zarr found for '$dataset_id'")
end

function _zarr_url(dataset_id::String)
    haskey(_KNOWN_ZARR, dataset_id) && return _KNOWN_ZARR[dataset_id]
    return _discover_zarr_url(dataset_id)
end

# ─── Zarr metadata ─────────────────────────────────────────────────────────────

struct _ArrayMeta
    shape::NTuple{4,Int}
    ndim::Int
    chunks::NTuple{4,Int}
    dtype::String
    compressor_id::Union{Nothing,String}
    fill_value::Union{Nothing,Float64}
    scale_factor::Union{Nothing,Float64}
    add_offset::Union{Nothing,Float64}
end

function _load_zmeta(zarr_url::String)
    resp = HTTP.get(zarr_url * "/.zmetadata"; status_exception=true, readtimeout=30)
    JSON3.read(resp.body)
end

function _parse_array_meta(zmeta, varpath::String)::_ArrayMeta
    zarray    = zmeta["metadata"][varpath * "/.zarray"]
    n_dims    = length(zarray["shape"])
    shape_vec = Int[zarray["shape"]...]
    chunk_vec = Int[zarray["chunks"]...]

    while length(shape_vec) < 4; pushfirst!(shape_vec, 1); end
    while length(chunk_vec) < 4; pushfirst!(chunk_vec, 1); end

    compressor_id = let c = zarray["compressor"]
        isnothing(c) ? nothing : get(c, "id", nothing)
    end
    fill_value = let f = zarray["fill_value"]
        if isnothing(f)
            nothing
        elseif f isa AbstractString
            parse(Float64, String(f))
        else
            Float64(f)
        end
    end

    scale_factor, add_offset = nothing, nothing
    attrs_key = varpath * "/.zattrs"
    if haskey(zmeta["metadata"], attrs_key)
        attrs = zmeta["metadata"][attrs_key]
        haskey(attrs, "scale_factor") && (scale_factor = Float64(attrs["scale_factor"]))
        haskey(attrs, "add_offset")   && (add_offset   = Float64(attrs["add_offset"]))
    end

    return _ArrayMeta(
        ntuple(i -> shape_vec[i], 4),
        n_dims,
        ntuple(i -> chunk_vec[i], 4),
        String(zarray["dtype"]),
        compressor_id, fill_value, scale_factor, add_offset,
    )
end

# ─── Chunk fetch & decode ──────────────────────────────────────────────────────

function _fetch_raw(zarr_url::String, key::String, token::Union{String,Nothing})
    headers = isnothing(token) ? Pair{String,String}[] : ["Authorization" => "Bearer $token"]
    for attempt in 1:5
        resp = HTTP.get(zarr_url * "/" * key, headers;
                        status_exception=false, readtimeout=120, retry=false)
        # S3 endpoints reject Bearer tokens with 400; retry without auth
        if resp.status == 400 && !isempty(headers)
            headers = Pair{String,String}[]
            resp = HTTP.get(zarr_url * "/" * key, headers;
                            status_exception=false, readtimeout=120, retry=false)
        end
        (resp.status == 404 || resp.status == 403) && return nothing
        resp.status < 300 && return resp.body
        resp.status < 500 && error("HTTP $(resp.status) for $key")
        attempt < 5 && sleep(10 * attempt)
        attempt == 5 && error("HTTP $(resp.status) for $key after 5 attempts")
    end
end

function _decode(raw::Vector{UInt8}, meta::_ArrayMeta)::Vector{Float32}
    buffer = if meta.compressor_id == "blosc"
        Blosc.decompress(UInt8, raw)
    else
        raw
    end

    vals = if meta.dtype in ("<i2", ">i2")
        Float32.(reinterpret(Int16, buffer))
    elseif meta.dtype in ("<i4", ">i4")
        Float32.(reinterpret(Int32, buffer))
    elseif meta.dtype in ("<f4", ">f4")
        reinterpret(Float32, buffer)
    elseif meta.dtype in ("<f8", ">f8")
        Float32.(reinterpret(Float64, buffer))
    else
        error("Unsupported dtype $(meta.dtype)")
    end

    scale    = isnothing(meta.scale_factor) ? 1.0f0 : Float32(meta.scale_factor)
    offset   = isnothing(meta.add_offset)   ? 0.0f0 : Float32(meta.add_offset)
    fill_val = isnothing(meta.fill_value)   ? nothing : Float32(meta.fill_value)

    out = similar(vals)
    fill_is_nan = !isnothing(fill_val) && isnan(Float32(fill_val))
    @inbounds for i in eachindex(vals)
        v = vals[i]
        is_fill = if isnothing(fill_val)
            false
        elseif fill_is_nan
            isnan(v)
        else
            v == Float32(fill_val)
        end
        out[i] = is_fill ? NaN32 : v * scale + offset
    end
    return out
end

# ─── 1-D coordinate loading ────────────────────────────────────────────────────

function _load_coord_1d(zarr_url::String, zmeta, varpath::String,
                        token::Union{String,Nothing})::Vector{Float64}
    meta       = _parse_array_meta(zmeta, varpath)
    n_elements = meta.shape[4]
    chunk_size = meta.chunks[4]
    n_chunks   = cld(n_elements, chunk_size)

    result = Vector{Float64}(undef, n_elements)
    for chunk_index in 0:(n_chunks - 1)
        key   = "$varpath/$chunk_index"
        start = chunk_index * chunk_size
        len   = min(chunk_size, n_elements - start)
        raw   = _fetch_raw(zarr_url, key, token)
        isnothing(raw) && continue
        vals  = _decode(raw, meta)
        result[(start + 1):(start + len)] .= Float64.(vals[1:len])
    end
    return result
end

# ─── Index helpers ─────────────────────────────────────────────────────────────

_range_in(coords, lo, hi) =
    searchsortedfirst(coords, Float64(lo)) : searchsortedlast(coords, Float64(hi))

function _depth_range(depths, minimum_depth, maximum_depth)
    isnothing(minimum_depth) && isnothing(maximum_depth) && return 1:length(depths)
    lo = isnothing(minimum_depth) ? -Inf : Float64(minimum_depth)
    hi = isnothing(maximum_depth) ?  Inf : Float64(maximum_depth)
    # Elevation convention (negative, e.g. -5727 … -0.49): invert lo/hi
    if !isempty(depths) && depths[end] < 0
        searchsortedfirst(depths, -hi) : searchsortedlast(depths, -lo)
    else
        searchsortedfirst(depths, lo) : searchsortedlast(depths, hi)
    end
end

const _EPOCH = DateTime(1950, 1, 1)

function _time_range(time_values::Vector{Float64}, t0::DateTime, t1::DateTime)
    date_start, date_stop = Date(t0), Date(t1)
    indices = Int[]
    for (i, hours) in enumerate(time_values)
        dt = _EPOCH + Hour(round(Int, hours))
        Date(dt) >= date_start && Date(dt) <= date_stop && push!(indices, i - 1)
    end
    return indices
end

# ─── 4-D chunk download (time, depth, latitude, longitude) ────────────────────

struct _ChunkJob4D
    key        :: String
    actual_lon :: Int
    actual_lat :: Int
    src_lon    :: UnitRange{Int}
    src_lat    :: UnitRange{Int}
    dst_lon    :: UnitRange{Int}
    dst_lat    :: UnitRange{Int}
    id         :: Int
    it         :: Int
end

struct _ChunkJob3D
    key        :: String
    actual_lon :: Int
    actual_lat :: Int
    src_lon    :: UnitRange{Int}
    src_lat    :: UnitRange{Int}
    dst_lon    :: UnitRange{Int}
    dst_lat    :: UnitRange{Int}
    it         :: Int
end

function _overlap_ranges(chunk_start, chunk_size, global_start, global_stop, total)
    actual  = min(chunk_size, total - chunk_start * chunk_size)
    c_start = chunk_start * chunk_size + 1
    c_stop  = c_start + actual - 1
    o_start = max(global_start, c_start)
    o_stop  = min(global_stop,  c_stop)
    o_start > o_stop && return nothing, nothing, nothing
    src = (o_start - c_start + 1):(o_stop - c_start + 1)
    dst = (o_start - global_start + 1):(o_stop - global_start + 1)
    return actual, src, dst
end

# Returns (n_lon, n_lat, n_depth, n_time) for NCDatasets column-major layout.
function _fetch_4d(zarr_url::String, meta::_ArrayMeta, varname::String,
                   time_indices::Vector{Int},
                   depth_indices::AbstractRange{Int},
                   latitude_indices::AbstractRange{Int},
                   longitude_indices::AbstractRange{Int},
                   token::Union{String,Nothing})
    chunk_time, chunk_depth, chunk_lat, chunk_lon = meta.chunks
    _, n_depth_total, n_lat_total, n_lon_total    = meta.shape

    n_time  = length(time_indices)
    n_depth = length(depth_indices)
    n_lat   = length(latitude_indices)
    n_lon   = length(longitude_indices)
    out     = fill(NaN32, n_lon, n_lat, n_depth, n_time)

    lat_start = first(latitude_indices);  lat_stop = last(latitude_indices)
    lon_start = first(longitude_indices); lon_stop = last(longitude_indices)
    lat_chunk_start = div(lat_start - 1, chunk_lat)
    lat_chunk_stop  = div(lat_stop  - 1, chunk_lat)
    lon_chunk_start = div(lon_start - 1, chunk_lon)
    lon_chunk_stop  = div(lon_stop  - 1, chunk_lon)

    jobs = _ChunkJob4D[]
    for (it, ti) in enumerate(time_indices), (id, di) in enumerate(depth_indices),
        lat_chunk in lat_chunk_start:lat_chunk_stop,
        lon_chunk in lon_chunk_start:lon_chunk_stop

        act_lat, src_lat, dst_lat = _overlap_ranges(lat_chunk, chunk_lat,
                                                     lat_start, lat_stop, n_lat_total)
        isnothing(act_lat) && continue
        act_lon, src_lon, dst_lon = _overlap_ranges(lon_chunk, chunk_lon,
                                                     lon_start, lon_stop, n_lon_total)
        isnothing(act_lon) && continue

        t_chunk = div(ti, chunk_time)
        d_chunk = div(di - 1, chunk_depth)
        key = "$varname/$t_chunk.$d_chunk.$lat_chunk.$lon_chunk"
        push!(jobs, _ChunkJob4D(key, act_lon, act_lat, src_lon, src_lat,
                                dst_lon, dst_lat, id, it))
    end

    @info "  $varname: fetching $(length(jobs)) chunks ($(min(32, length(jobs))) concurrent)..."
    results = asyncmap(jobs; ntasks=min(32, length(jobs))) do job
        raw = _fetch_raw(zarr_url, job.key, token)
        isnothing(raw) && return nothing
        # Zarr C-order (lat × lon) → Julia column-major (lon × lat)
        tile = reshape(_decode(raw, meta)[1:(job.actual_lon * job.actual_lat)],
                       job.actual_lon, job.actual_lat)
        (slice   = tile[job.src_lon, job.src_lat],
         dst_lon = job.dst_lon, dst_lat = job.dst_lat,
         id      = job.id,      it      = job.it)
    end

    for r in results
        isnothing(r) && continue
        out[r.dst_lon, r.dst_lat, r.id, r.it] .= r.slice
    end
    return out
end

# Returns (n_lon, n_lat, n_time) for 3-D variables like zos.
function _fetch_3d(zarr_url::String, meta::_ArrayMeta, varname::String,
                   time_indices::Vector{Int},
                   latitude_indices::AbstractRange{Int},
                   longitude_indices::AbstractRange{Int},
                   token::Union{String,Nothing})
    @assert meta.ndim == 3 "Expected 3-D variable, got ndim=$(meta.ndim)"

    # _parse_array_meta left-pads to 4 dims; real dims at indices 2:4
    n_time_total, n_lat_total, n_lon_total = meta.shape[2], meta.shape[3], meta.shape[4]
    chunk_time, chunk_lat, chunk_lon       = meta.chunks[2], meta.chunks[3], meta.chunks[4]

    n_time = length(time_indices)
    n_lat  = length(latitude_indices)
    n_lon  = length(longitude_indices)
    out    = fill(NaN32, n_lon, n_lat, n_time)

    lat_start = first(latitude_indices);  lat_stop = last(latitude_indices)
    lon_start = first(longitude_indices); lon_stop = last(longitude_indices)
    lat_chunk_start = div(lat_start - 1, chunk_lat)
    lat_chunk_stop  = div(lat_stop  - 1, chunk_lat)
    lon_chunk_start = div(lon_start - 1, chunk_lon)
    lon_chunk_stop  = div(lon_stop  - 1, chunk_lon)

    jobs = _ChunkJob3D[]
    for (it, ti) in enumerate(time_indices),
        lat_chunk in lat_chunk_start:lat_chunk_stop,
        lon_chunk in lon_chunk_start:lon_chunk_stop

        act_lat, src_lat, dst_lat = _overlap_ranges(lat_chunk, chunk_lat,
                                                     lat_start, lat_stop, n_lat_total)
        isnothing(act_lat) && continue
        act_lon, src_lon, dst_lon = _overlap_ranges(lon_chunk, chunk_lon,
                                                     lon_start, lon_stop, n_lon_total)
        isnothing(act_lon) && continue

        t_chunk = div(ti, chunk_time)
        key = "$varname/$t_chunk.$lat_chunk.$lon_chunk"
        push!(jobs, _ChunkJob3D(key, act_lon, act_lat, src_lon, src_lat,
                                dst_lon, dst_lat, it))
    end

    @info "  $varname: fetching $(length(jobs)) chunks ($(min(32, length(jobs))) concurrent)..."
    results = asyncmap(jobs; ntasks=min(32, length(jobs))) do job
        raw = _fetch_raw(zarr_url, job.key, token)
        isnothing(raw) && return nothing
        tile = reshape(_decode(raw, meta)[1:(job.actual_lon * job.actual_lat)],
                       job.actual_lon, job.actual_lat)
        (slice   = tile[job.src_lon, job.src_lat],
         dst_lon = job.dst_lon, dst_lat = job.dst_lat,
         it      = job.it)
    end

    for r in results
        isnothing(r) && continue
        out[r.dst_lon, r.dst_lat, r.it] .= r.slice
    end
    return out
end

# ─── NetCDF output ─────────────────────────────────────────────────────────────

const _LONG_NAMES = Dict(
    "thetao" => "Sea water potential temperature",
    "so"     => "Sea water salinity",
    "uo"     => "Eastward sea water velocity",
    "vo"     => "Northward sea water velocity",
    "zos"    => "Sea surface height above geoid",
    "deptho" => "Sea floor depth below geoid",
)

const _UNITS = Dict(
    "thetao" => "degrees_C",
    "so"     => "0.001",
    "uo"     => "m s-1",
    "vo"     => "m s-1",
    "zos"    => "m",
    "deptho" => "m",
)

function _write_nc(path, data, variable_list,
                   longitudes, latitudes, depths, time_values::Vector{Float64})
    NCDataset(path, "c") do ds
        defDim(ds, "longitude", length(longitudes))
        defDim(ds, "latitude",  length(latitudes))
        defDim(ds, "depth",     length(depths))
        defDim(ds, "time",      length(time_values))

        lon_var = defVar(ds, "longitude", Float32, ("longitude",))
        lon_var[:] = Float32.(longitudes)
        lon_var.attrib["units"]     = "degrees_east"
        lon_var.attrib["long_name"] = "Longitude"

        lat_var = defVar(ds, "latitude", Float32, ("latitude",))
        lat_var[:] = Float32.(latitudes)
        lat_var.attrib["units"]     = "degrees_north"
        lat_var.attrib["long_name"] = "Latitude"

        depth_var = defVar(ds, "depth", Float32, ("depth",))
        depth_var[:] = Float32.(depths)
        depth_var.attrib["units"]     = "m"
        depth_var.attrib["positive"]  = "down"
        depth_var.attrib["long_name"] = "Depth"

        time_var = defVar(ds, "time", Float64, ("time",))
        time_var[:] = time_values
        time_var.attrib["units"]     = "hours since 1950-01-01"
        time_var.attrib["calendar"]  = "gregorian"
        time_var.attrib["long_name"] = "Time"

        for varname in variable_list
            haskey(data, varname) || continue
            arr = data[varname]
            var = if ndims(arr) == 4
                v = defVar(ds, varname, Float32, ("longitude", "latitude", "depth", "time"),
                           fillvalue = NaN32)
                v[:, :, :, :] = arr
                v
            elseif ndims(arr) == 3
                v = defVar(ds, varname, Float32, ("longitude", "latitude", "time"),
                           fillvalue = NaN32)
                v[:, :, :] = arr
                v
            else
                nothing
            end
            if !isnothing(var)
                var.attrib["long_name"] = get(_LONG_NAMES, varname, varname)
                var.attrib["units"]     = get(_UNITS, varname, "")
            end
        end

        ds.attrib["source"]      = "Copernicus Marine Service (CMEMS)"
        ds.attrib["Conventions"] = "CF-1.8"
        ds.attrib["history"]     = "Downloaded by CopernicusMarine.jl (pure Julia)"
    end
end

# ─── Pure-Julia download ───────────────────────────────────────────────────────

function _subset_via_zarr(;
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
        isnothing(v) ? String[] :
        v isa AbstractArray ? String[string(x) for x in v] : [string(v)]
    end
    isempty(variable_list) && error("No variables specified")

    isempty(username) && error("No CMEMS username (set COPERNICUS_USERNAME or pass username=...)")
    isempty(password) && error("No CMEMS password (set COPERNICUS_PASSWORD or pass password=...)")

    @info "CopernicusMarine.jl (zarr)  dataset=$dataset_id  vars=$(variable_list)"
    @info "  lon=[$minimum_longitude, $maximum_longitude]  lat=[$minimum_latitude, $maximum_latitude]"
    isnothing(start_datetime) || @info "  $start_datetime → $end_datetime"

    token    = _get_token(username, password)
    zarr_url = _zarr_url(dataset_id)
    @info "  zarr=$zarr_url"

    zmeta = _load_zmeta(zarr_url)

    @info "  Loading coordinates..."
    longitudes = _load_coord_1d(zarr_url, zmeta, "longitude", token)
    latitudes  = _load_coord_1d(zarr_url, zmeta, "latitude",  token)
    elev_key   = haskey(zmeta["metadata"], "elevation/.zarray") ? "elevation" : "depth"
    depths     = _load_coord_1d(zarr_url, zmeta, elev_key, token)

    longitude_indices = _range_in(longitudes, minimum_longitude, maximum_longitude)
    latitude_indices  = _range_in(latitudes,  minimum_latitude,  maximum_latitude)
    depth_indices     = _depth_range(depths,   minimum_depth,     maximum_depth)

    isempty(longitude_indices) && error("No longitudes in [$minimum_longitude, $maximum_longitude]")
    isempty(latitude_indices)  && error("No latitudes in [$minimum_latitude, $maximum_latitude]")
    isempty(depth_indices)     && error("No depths in [$minimum_depth, $maximum_depth]")

    @info "  $(length(longitude_indices)) lon × $(length(latitude_indices)) lat × $(length(depth_indices)) depth"

    time_indices, output_time_values = if isnothing(start_datetime)
        ([0], [0.0])
    else
        @info "  Loading time axis..."
        time_values = _load_coord_1d(zarr_url, zmeta, "time", nothing)
        t0 = DateTime(start_datetime)
        t1 = DateTime(end_datetime)
        indices = _time_range(time_values, t0, t1)
        isempty(indices) && error("No time steps in [$start_datetime, $end_datetime]")
        @info "  $(length(indices)) time step(s)"
        (indices, time_values[indices .+ 1])
    end

    data = Dict{String,Array{Float32}}()
    for varname in variable_list
        @info "  Fetching $varname..."
        meta = _parse_array_meta(zmeta, varname)
        if meta.ndim == 4
            data[varname] = _fetch_4d(zarr_url, meta, varname,
                                      time_indices, depth_indices,
                                      latitude_indices, longitude_indices, token)
        elseif meta.ndim == 3
            data[varname] = _fetch_3d(zarr_url, meta, varname,
                                      time_indices, latitude_indices, longitude_indices, token)
        else
            @warn "  Skipping $varname: unsupported ndim=$(meta.ndim)"
        end
    end

    # geoChunked elevation is negative (elevation below sea level); normalise to
    # positive-ascending depth for NumericalEarth compatibility.
    selected_depths = depths[depth_indices]
    if !isempty(selected_depths) && selected_depths[1] < 0
        depths_out = abs.(selected_depths[end:-1:1])
        for varname in variable_list
            haskey(data, varname) || continue
            ndims(data[varname]) == 4 && (data[varname] = data[varname][:, :, end:-1:1, :])
        end
    else
        depths_out = selected_depths
    end

    @info "  Writing $output_path..."
    _write_nc(output_path, data, variable_list,
              longitudes[longitude_indices], latitudes[latitude_indices],
              depths_out, output_time_values)

    @info "  Done: $(round(filesize(output_path) / 1024 / 1024, digits=1)) MB"
    return output_path
end
