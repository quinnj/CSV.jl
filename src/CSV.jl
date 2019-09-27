module CSV

# stdlib
using Mmap, Dates, Unicode
using Parsers, Tables
using PooledArrays, CategoricalArrays, WeakRefStrings, DataFrames

function validate(fullpath::Union{AbstractString,IO}; kwargs...)
    Base.depwarn("`CSV.validate` is deprecated. `CSV.read` now prints warnings on misshapen files.", :validate)
    Tables.columns(File(fullpath; kwargs...))
    return
end

include("utils.jl")
include("detection.jl")

struct Error <: Exception
    msg::String
end

Base.showerror(io::IO, e::Error) = println(io, e.msg)

struct File
    name::String
    names::Vector{Symbol}
    types::Vector{Type}
    rows::Int64
    cols::Int64
    e::UInt8
    categorical::Bool
    refs::Vector{Vector{String}}
    buf::Vector{UInt8}
    tapes::Vector{Vector{UInt64}}
end

getname(f::File) = getfield(f, :name)
getnames(f::File) = getfield(f, :names)
gettypes(f::File) = getfield(f, :types)
getrows(f::File) = getfield(f, :rows)
getcols(f::File) = getfield(f, :cols)
gete(f::File) = getfield(f, :e)
getcategorical(f::File) = getfield(f, :categorical)
function getrefs(f::File, col)
    @inbounds r = getfield(f, :refs)[col]
    return r
end
getbuf(f::File) = getfield(f, :buf)
function gettape(f::File, col)
    @inbounds t = getfield(f, :tapes)[col]
    return t
end

function Base.show(io::IO, f::File)
    println(io, "CSV.File(\"$(getname(f))\"):")
    println(io, "Size: $(getrows(f)) x $(getcols(f))")
    show(io, Tables.schema(f))
end

const EMPTY_POSITIONS = Int64[]
const EMPTY_TYPEMAP = Dict{TypeCode, TypeCode}()
const EMPTY_REFS = Vector{String}[]
const EMPTY_REFVALUES = String[]

const INVALID_DELIMITERS = ['\r', '\n', '\0']

"""
    isvaliddelim(delim)

Whether a character or string is valid for use as a delimiter.
"""
isvaliddelim(delim) = false
isvaliddelim(delim::Char) = delim ∉ INVALID_DELIMITERS
isvaliddelim(delim::AbstractString) = all(isvaliddelim, delim)

"""
    checkvaliddelim(delim)

Checks whether a character or string is valid for use as a delimiter.  If
`delim` is `nothing`, it is assumed that the delimiter will be auto-selected.
Throws an error if `delim` is invalid.
"""
function checkvaliddelim(delim)
    delim ≢ nothing && !isvaliddelim(delim) &&
        throw(ArgumentError("invalid delim argument = '$(escape_string(string(delim)))', "*
                            "the following delimiters are invalid: $INVALID_DELIMITERS"))
end

"""
    checkvalidsource(source)

Checks whether the argument is valid for use as a data source, otherwise throws
an error.
"""
function checkvalidsource(source)
    !isa(source, IO) && !isa(source, Vector{UInt8}) && !isa(source, Cmd) && !isfile(source) &&
        throw(ArgumentError("\"$source\" is not a valid file"))
end

"""
    CSV.File(source; kwargs...) => CSV.File

Read a csv input (a filename given as a String or FilePaths.jl type, or any other IO source), returning a `CSV.File` object.

Opens the file and uses passed arguments to detect the number of columns and column types.
The returned `CSV.File` object supports the [Tables.jl](https://github.com/JuliaData/Tables.jl) interface
and can iterate `CSV.Row`s. `CSV.Row` supports `propertynames` and `getproperty` to access individual row values.
Note that duplicate column names will be detected and adjusted to ensure uniqueness (duplicate column name `a` will become `a_1`).
For example, one could iterate over a csv file with column names `a`, `b`, and `c` by doing:

```julia
for row in CSV.File(file)
    println("a=\$(row.a), b=\$(row.b), c=\$(row.c)")
end
```

By supporting the Tables.jl interface, a `CSV.File` can also be a table input to any other table sink function. Like:

```julia
# materialize a csv file as a DataFrame
df = CSV.File(file) |> DataFrame!

# load a csv file directly into an sqlite database table
db = SQLite.DB()
tbl = CSV.File(file) |> SQLite.load!(db, "sqlite_table")
```

Supported keyword arguments include:
* File layout options:
  * `header=1`: the `header` argument can be an `Int`, indicating the row to parse for column names; or a `Range`, indicating a span of rows to be concatenated together as column names; or an entire `Vector{Symbol}` or `Vector{String}` to use as column names; if a file doesn't have column names, either provide them as a `Vector`, or set `header=0` or `header=false` and column names will be auto-generated (`Column1`, `Column2`, etc.)
  * `normalizenames=false`: whether column names should be "normalized" into valid Julia identifier symbols; useful when iterating rows and accessing column values of a row via `getproperty` (e.g. `row.col1`)
  * `datarow`: an `Int` argument to specify the row where the data starts in the csv file; by default, the next row after the `header` row is used. If `header=0`, then the 1st row is assumed to be the start of data
  * `skipto::Int`: similar to `datarow`, specifies the number of rows to skip before starting to read data
  * `footerskip::Int`: number of rows at the end of a file to skip parsing
  * `limit`: an `Int` to indicate a limited number of rows to parse in a csv file; use in combination with `skipto` to read a specific, contiguous chunk within a file
  * `transpose::Bool`: read a csv file "transposed", i.e. each column is parsed as a row
  * `comment`: rows that begin with this `String` will be skipped while parsing
  * `use_mmap::Bool=!Sys.iswindows()`: whether the file should be mmapped for reading, which in some cases can be faster
  * `ignoreemptylines::Bool=false`: whether empty rows/lines in a file should be ignored (if `false`, each column will be assigned `missing` for that empty row)
  * `threaded::Bool`: whether parsing should utilize multiple threads; by default threads are used on large enough files, but isn't allowed when `transpose=true` or when `limit` is used; only available in Julia 1.3+
* Parsing options:
  * `missingstrings`, `missingstring`: either a `String`, or `Vector{String}` to use as sentinel values that will be parsed as `missing`; by default, only an empty field (two consecutive delimiters) is considered `missing`
  * `delim=','`: a `Char` or `String` that indicates how columns are delimited in a file; if no argument is provided, parsing will try to detect the most consistent delimiter on the first 10 rows of the file
  * `ignorerepeated::Bool=false`: whether repeated (consecutive) delimiters should be ignored while parsing; useful for fixed-width files with delimiter padding between cells
  * `quotechar='"'`, `openquotechar`, `closequotechar`: a `Char` (or different start and end characters) that indicate a quoted field which may contain textual delimiters or newline characters
  * `escapechar='"'`: the `Char` used to escape quote characters in a quoted field
  * `dateformat::Union{String, Dates.DateFormat, Nothing}`: a date format string to indicate how Date/DateTime columns are formatted for the entire file
  * `decimal='.'`: a `Char` indicating how decimals are separated in floats, i.e. `3.14` used '.', or `3,14` uses a comma ','
  * `truestrings`, `falsestrings`: `Vectors of Strings` that indicate how `true` or `false` values are represented; by default only `true` and `false` are treated as `Bool`
* Column Type Options:
  * `type`: a single type to use for parsing an entire file; i.e. all columns will be treated as the same type; useful for matrix-like data files
  * `types`: a Vector or Dict of types to be used for column types; a Dict can map column index `Int`, or name `Symbol` or `String` to type for a column, i.e. Dict(1=>Float64) will set the first column as a Float64, Dict(:column1=>Float64) will set the column named column1 to Float64 and, Dict("column1"=>Float64) will set the column1 to Float64; if a `Vector` if provided, it must match the # of columns provided or detected in `header`
  * `typemap::Dict{Type, Type}`: a mapping of a type that should be replaced in every instance with another type, i.e. `Dict(Float64=>String)` would change every detected `Float64` column to be parsed as `String`
  * `pool::Union{Bool, Float64}=0.1`: if `true`, *all* columns detected as `String` will be internally pooled; alternatively, the proportion of unique values below which `String` columns should be pooled (by default 0.1, meaning that if the # of unique strings in a column is under 10%, it will be pooled)
  * `categorical::Bool=false`: whether pooled columns should be copied as CategoricalArray instead of PooledArray; note that in `CSV.read`, by default, columns are not copied, so pooled columns will have type `CSV.Column{String, PooledString}`; to get `CategoricalArray` columns, also pass `copycols=true`
  * `strict::Bool=false`: whether invalid values should throw a parsing error or be replaced with `missing`
  * `silencewarnings::Bool=false`: if `strict=false`, whether invalid value warnings should be silenced
"""
function File(source;
    # file options
    # header can be a row number, range of rows, or actual string vector
    header::Union{Integer, Vector{Symbol}, Vector{String}, AbstractVector{<:Integer}}=1,
    normalizenames::Bool=false,
    # by default, data starts immediately after header or start of file
    datarow::Integer=-1,
    skipto::Union{Nothing, Integer}=nothing,
    footerskip::Integer=0,
    limit::Integer=typemax(Int64),
    transpose::Bool=false,
    comment::Union{String, Nothing}=nothing,
    use_mmap::Bool=!Sys.iswindows(),
    ignoreemptylines::Bool=false,
    # parsing options
    missingstrings=String[],
    missingstring="",
    delim::Union{Nothing, Char, String}=nothing,
    ignorerepeated::Bool=false,
    quotechar::Union{UInt8, Char}='"',
    openquotechar::Union{UInt8, Char, Nothing}=nothing,
    closequotechar::Union{UInt8, Char, Nothing}=nothing,
    escapechar::Union{UInt8, Char}='"',
    dateformat::Union{String, Dates.DateFormat, Nothing}=nothing,
    decimal::Union{UInt8, Char}=UInt8('.'),
    truestrings::Union{Vector{String}, Nothing}=nothing,
    falsestrings::Union{Vector{String}, Nothing}=nothing,
    # type options
    type=nothing,
    types=nothing,
    typemap::Dict=EMPTY_TYPEMAP,
    categorical::Union{Bool, Real}=false,
    pool::Union{Bool, Real}=0.1,
    strict::Bool=false,
    silencewarnings::Bool=false,
    threaded::Union{Bool, Nothing}=nothing,
    debug::Bool=false,
    parsingdebug::Bool=false,
    allowmissing::Union{Nothing, Symbol}=nothing)
    file(source, header, normalizenames, datarow, skipto, footerskip,
        limit, transpose, comment, use_mmap, ignoreemptylines, missingstrings, missingstring,
        delim, ignorerepeated, quotechar, openquotechar, closequotechar,
        escapechar, dateformat, decimal, truestrings, falsestrings, type,
        types, typemap, categorical, pool, strict, silencewarnings, threaded,
        debug, parsingdebug, allowmissing)
end

# @code_typed CSV.file(source,1,false,-1,nothing,0,typemax(Int64),false,nothing,!Sys.iswindows(),false,String[],"",nothing,false,'"',nothing,nothing,'"',nothing,UInt8('.'),nothing,nothing,nothing,nothing,CSV.EMPTY_TYPEMAP,false,0.1,false,false,nothing,false,false,nothing)
function file(source,
    # file options
    # header can be a row number, range of rows, or actual string vector
    header=1,
    normalizenames=false,
    # by default, data starts immediately after header or start of file
    datarow=-1,
    skipto=nothing,
    footerskip=0,
    limit=typemax(Int64),
    transpose=false,
    comment=nothing,
    use_mmap=!Sys.iswindows(),
    ignoreemptylines=false,
    # parsing options
    missingstrings=String[],
    missingstring="",
    delim=nothing,
    ignorerepeated=false,
    quotechar='"',
    openquotechar=nothing,
    closequotechar=nothing,
    escapechar='"',
    dateformat=nothing,
    decimal=UInt8('.'),
    truestrings=nothing,
    falsestrings=nothing,
    # type options
    type=nothing,
    types=nothing,
    typemap=EMPTY_TYPEMAP,
    categorical=false,
    pool=0.1,
    strict=false,
    silencewarnings=false,
    threaded=nothing,
    debug=false,
    parsingdebug=false,
    allowmissing=nothing)

    # initial argument validation and adjustment
    checkvalidsource(source)
    (types !== nothing && any(x->!isconcretetype(x) && !(x isa Union), types isa AbstractDict ? values(types) : types)) && throw(ArgumentError("Non-concrete types passed in `types` keyword argument, please provide concrete types for columns: $types"))
    if type !== nothing && typecode(type) == EMPTY
        throw(ArgumentError("$type isn't supported in the `type` keyword argument; must be one of: `Int64`, `Float64`, `Date`, `DateTime`, `Bool`, `Missing`, `PooledString`, `CategoricalString{UInt32}`, or `String`"))
    elseif types !== nothing && any(x->typecode(x) == EMPTY, types isa AbstractDict ? values(types) : types)
        T = nothing
        for x in (types isa AbstractDict ? values(types) : types)
            if typecode(x) == EMPTY
                T = x
                break
            end
        end
        throw(ArgumentError("unsupported type $T in the `types` keyword argument; must be one of: `Int64`, `Float64`, `Date`, `DateTime`, `Bool`, `Missing`, `PooledString`, `CategoricalString{UInt32}`, or `String`"))
    end
    checkvaliddelim(delim)
    ignorerepeated && delim === nothing && throw(ArgumentError("auto-delimiter detection not supported when `ignorerepeated=true`; please provide delimiter via `delim=','`"))
    allowmissing !== nothing && @warn "`allowmissing` is a deprecated keyword argument"
    if !(categorical isa Bool)
        @warn "categorical=$categorical is deprecated in favor of `pool=$categorical`; categorical is only used to determine CategoricalArray vs. PooledArrays"
        pool = categorical
        categorical = categorical > 0.0
    elseif categorical === true
        pool = categorical
    end
    header = (isa(header, Integer) && header == 1 && (datarow == 1 || skipto == 1)) ? -1 : header
    isa(header, Integer) && datarow != -1 && (datarow > header || throw(ArgumentError("data row ($datarow) must come after header row ($header)")))
    datarow = skipto !== nothing ? skipto : (datarow == -1 ? (isa(header, Vector{Symbol}) || isa(header, Vector{String}) ? 0 : last(header)) + 1 : datarow) # by default, data starts on line after header
    debug && println("header is: $header, datarow computed as: $datarow")
    # getsource will turn any input into a `Vector{UInt8}`
    buf = getsource(source, use_mmap)
    len = length(buf)
    # skip over initial BOM character, if present
    pos = consumeBOM(buf)

    oq = something(openquotechar, quotechar) % UInt8
    eq = escapechar % UInt8
    cq = something(closequotechar, quotechar) % UInt8
    trues = truestrings === nothing ? nothing : truestrings
    falses = falsestrings === nothing ? nothing : falsestrings
    sentinel = ((isempty(missingstrings) && missingstring == "") || (length(missingstrings) == 1 && missingstrings[1] == "")) ? missing : isempty(missingstrings) ? [missingstring] : missingstrings
    
    if delim === nothing
        del = isa(source, AbstractString) && endswith(source, ".tsv") ? UInt8('\t') :
            isa(source, AbstractString) && endswith(source, ".wsv") ? UInt8(' ') :
            UInt8('\n')
    else
        del = (delim isa Char && isascii(delim)) ? delim % UInt8 :
            (sizeof(delim) == 1 && isascii(delim)) ? delim[1] % UInt8 : delim
    end
    cmt = comment === nothing ? nothing : (pointer(comment), sizeof(comment))

    if footerskip > 0 && len > 0
        revlen = skiptorow(ReversedBuf(buf), 1 + (buf[end] == UInt('\n') || buf[end] == UInt8('\r')), len, oq, eq, cq, 0, footerskip) - 2
        len -= revlen
        debug && println("adjusted for footerskip, len = $(len + revlen - 1) => $len")
    end

    if !transpose
        # step 1: detect the byte position where the column names start (headerpos)
        # and where the first data row starts (datapos)
        headerpos, datapos = detectheaderdatapos(buf, pos, len, oq, eq, cq, cmt, ignoreemptylines, header, datarow)
        debug && println("headerpos = $headerpos, datapos = $datapos")

        # step 2: detect delimiter (or use given) and detect number of (estimated) rows and columns
        d, rowsguess = detectdelimandguessrows(buf, headerpos, datapos, len, oq, eq, cq, del, cmt, ignoreemptylines)
        debug && println("estimated rows: $rowsguess")
        debug && println("detected delimiter: \"$(escape_string(d isa UInt8 ? string(Char(d)) : d))\"")

        # step 3: build Parsers.Options w/ parsing arguments
        wh1 = d == UInt(' ') ? 0x00 : UInt8(' ')
        wh2 = d == UInt8('\t') ? 0x00 : UInt8('\t')
        options = Parsers.Options(sentinel, wh1, wh2, oq, cq, eq, d, decimal, trues, falses, dateformat, ignorerepeated, true, parsingdebug, strict, silencewarnings)

        # step 4: generate or parse column names
        names = detectcolumnnames(buf, headerpos, datapos, len, options, header, normalizenames)
        ncols = length(names)
        positions = EMPTY_POSITIONS
    else
        # transpose
        d, rowsguess = detectdelimandguessrows(buf, pos, pos, len, oq, eq, cq, del, cmt, ignoreemptylines)
        wh1 = d == UInt(' ') ? 0x00 : UInt8(' ')
        wh2 = d == UInt8('\t') ? 0x00 : UInt8('\t')
        options = Parsers.Options(sentinel, wh1, wh2, oq, cq, eq, d, decimal, trues, falses, dateformat, ignorerepeated, true, parsingdebug, strict, silencewarnings)
        rowsguess, names, positions = detecttranspose(buf, pos, len, options, header, datarow, normalizenames)
        ncols = length(names)
        datapos = isempty(positions) ? 0 : positions[1]
    end
    debug && println("column names detected: $names")
    debug && println("byte position of data computed at: $datapos")

    # determine if we can use threads while parsing
    if threaded === nothing && VERSION >= v"1.3-DEV" && Threads.nthreads() > 1 && !transpose && limit == typemax(Int64) && rowsguess > Threads.nthreads() && (rowsguess * ncols) >= 5_000
        threaded = true
    elseif threaded === true
        if VERSION < v"1.3-DEV"
            @warn "incompatible julia version for `threaded=true`: $VERSION, requires >= v\"1.3\", setting `threaded=false`"
            threaded = false
        elseif transpose
            @warn "`threaded=true` not supported on transposed files"
            threaded = false
        elseif limit != typemax(Int64)
            @warn "`threaded=true` not supported when limiting # of rows"
            threaded = false
        end
    end

    # deduce initial column types for parsing based on whether any user-provided types were provided or not
    T = type === nothing ? EMPTY : (typecode(type) | USER)
    if types isa Vector
        typecodes = TypeCode[typecode(T) | USER for T in types]
        categorical = categorical | any(x->x == CategoricalString{UInt32}, types)
    elseif types isa AbstractDict
        typecodes = initialtypes(T, types, names)
        categorical = categorical | any(x->x == CategoricalString{UInt32}, values(types))
    else
        typecodes = TypeCode[T for _ = 1:ncols]
    end
    debug && println("computed typecodes are: $typecodes")

    # we now do our parsing pass over the file, starting at datapos
    # we fill in our "tape", which has two UInt64 slots for each cell in row-major order (linearly indexed)
    # the 1st UInt64 is used for noting the byte position, len, and other metadata of the field within the file:
        # leftmost bit indicates a sentinel value was detected while parsing, resulting cell value will be `missing`
        # 2nd leftmost bit indicates a cell initially parsed as Int (used if column later gets promoted to Float64)
        # 3rd leftmost bit indicates if a field was quoted and included escape chararacters (will have to be unescaped later)
        # 45 bits for position (allows for maximum file size of 35TB)
        # 16 bits for field length (allows for maximum field size of 65K)
    # the 2nd UInt64 is used for storing the raw bits of a parsed, typed value: Int64, Float64, Date, DateTime, Bool, or categorical/pooled UInt32 ref
    pool = pool === true ? 1.0 : pool isa Float64 ? pool : 0.0
    if threaded === true
        # multithread
        rows, tapes, refs, typecodes = multithreadparse(typecodes, buf, datapos, len, options, rowsguess, pool, ncols, ignoreemptylines, typemap, limit, cmt, debug)
    else
        tapes = Vector{UInt64}[Mmap.mmap(Vector{UInt64}, rowsguess) for i = 1:ncols]
        poslens = Vector{Vector{UInt64}}(undef, ncols)
        for i = 1:ncols
            T = typecodes[i]
            if !user(T)
                poslens[i] = Mmap.mmap(Vector{UInt64}, rowsguess)
            end
        end
        refs = Vector{Dict{String, UInt64}}(undef, ncols)
        lastrefs = zeros(UInt64, ncols)
        t = Base.time()
        rows, tapes, poslens = parsetape(Val(transpose), ignoreemptylines, ncols, gettypecodes(typemap), tapes, poslens, buf, datapos, len, limit, cmt, positions, pool, refs, lastrefs, rowsguess, typecodes, debug, options, false)
        debug && println("time for initial parsing to tape: $(Base.time() - t)")
    end
    for i = 1:ncols
        typecodes[i] &= ~USER
    end
    finaltypes = Type[TYPECODES[T] for T in typecodes]
    debug && println("types after parsing: $finaltypes, pool = $pool")
    finalrefs = Vector{Vector{String}}(undef, ncols)
    if pool > 0.0
        for i = 1:ncols
            if isassigned(refs, i)
                finalrefs[i] = map(x->x[1], sort!(collect(refs[i]), by=x->x[2]))
            elseif typecodes[i] == POOL || typecodes[i] == (POOL | MISSING)
                # case where user manually specified types, but no rows were parsed
                # so the refs never got initialized; initialize them here to empty
                finalrefs[i] = Vector{String}[]
            end
        end
    end
    return File(getname(source), names, finaltypes, rows, ncols, eq, categorical, finalrefs, buf, tapes)
end

function multithreadparse(typecodes, buf, datapos, len, options, rowsguess, pool, ncols, ignoreemptylines, typemap, limit, cmt, debug)
    typecodes = AtomicVector(typecodes)
    N = Threads.nthreads()
    chunksize = div((len - datapos), N)
    ranges = [datapos, (chunksize * i for i = 1:N)...]
    ranges[end] = len
    debug && println("initial byte positions before adjusting for start of rows: $ranges")
    findrowstarts!(buf, len, options, cmt, ignoreemptylines, ranges, ncols)
    rowchunkguess = div(rowsguess, N)
    tapelen = rowchunkguess * 2
    debug && println("parsing using $N threads: $rowchunkguess rows chunked at positions: $ranges")
    rowsv = Vector{Int}(undef, N)
    tapesv = Vector{Vector{Vector{UInt64}}}(undef, N)
    refsv = Vector{Vector{Dict{String, UInt64}}}(undef, N)
    lastrefsv = Vector{Vector{UInt64}}(undef, N)
    @sync for i = 1:N
@static if VERSION >= v"1.3-DEV"
        Threads.@spawn begin
            tt = Base.time()
            trefs = Vector{Dict{String, UInt64}}(undef, ncols)
            tlastrefs = zeros(UInt64, ncols)
            ttapes = Vector{UInt64}[Mmap.mmap(Vector{UInt64}, tapelen) for i = 1:ncols]
            tdatapos = ranges[i]
            tlen = ranges[i + 1] - (i != N)
            ret = parsetape(Val(false), ignoreemptylines, ncols, gettypecodes(typemap), ttapes, tapelen, buf, tdatapos, tlen, limit, cmt, EMPTY_POSITIONS, pool, trefs, tlastrefs, rowchunkguess, typecodes, debug, options, true)
            debug && println("thread = $(Threads.threadid()): time for parsing: $(Base.time() - tt)")
            rowsv[i] = ret[1]
            tapesv[i] = ret[2]
            refsv[i] = trefs
            lastrefsv[i] = tlastrefs
        end
end # @static if VERSION >= v"1.3-DEV"
    end
    rows = sum(rowsv)
    tapes = Vector{UInt64}[Mmap.mmap(Vector{UInt64}, rows * 2) for i = 1:ncols]
    refs = Vector{Dict{String, UInt64}}(undef, ncols)
    lastrefs = zeros(UInt64, ncols)
    rngs = Matrix{Vector{UInt64}}(undef, N, ncols)
    recodes = falses(N, ncols)
    for i = 1:N
        rs = refsv[i]
        lrs = lastrefsv[i]
        for col = 1:ncols
            if isassigned(rs, col)
                # merge refs and recode if necessary
                if !isassigned(refs, col)
                    refs[col] = rs[col]
                    lastrefs[col] = lrs[col]
                else
                    rng = collect(UInt64(0):lrs[col])
                    recode = false
                    for (k, v) in rs[col]
                        refvalue = get(refs[col], k, UInt64(0))
                        if refvalue != v
                            recode = true
                            if refvalue == 0
                                refvalue = (lastrefs[col] += UInt64(1))
                            end
                            refs[col][k] = refvalue
                            rng[v + 1] = refvalue
                        end
                    end
                    recodes[i, col] = recode
                    rngs[i, col] = rng
                end
            end
        end
    end
    @sync for j = 1:N
@static if VERSION >= v"1.3-DEV"
        Threads.@spawn begin
            r, tps, rs, lrs = rowsv[j], tapesv[j], refsv[j], lastrefsv[j]
            tt = Base.time()
            for col = 1:ncols
                if recodes[j, col]
                    tp = tps[col]
                    rng = rngs[j, col]
                    @simd for k = 2:2:(r * 2)
                        @inbounds tp[k] = rng[tp[k] + 1]
                    end
                end
                # copy thread-tape to master tape
                copyto!(tapes[col], 1 + (2 * sum(rowsv[1:j-1])), tps[col], 1, r * 2)
            end
            debug && println("thread = $(Threads.threadid()): time for aggregating: $(Base.time() - tt)")
        end
end # @static if VERSION >= v"1.3-DEV"
    end
    return rows, tapes, refs, typecodes
end

function parsetape(::Val{transpose}, ignoreemptylines, ncols, typemap, tapes, poslens, buf, pos, len, limit, cmt, positions, pool, refs, lastrefs, rowsguess, typecodes, debug, options::Parsers.Options{ignorerepeated}, threaded) where {transpose, ignorerepeated}
    row = 0
    if pos <= len && len > 0
        while row < limit
            pos = checkcommentandemptyline(buf, pos, len, cmt, ignoreemptylines)
            if ignorerepeated
                pos = Parsers.checkdelim!(buf, pos, len, options)
            end
            pos > len && break
            row += 1
            for col = 1:ncols
                if transpose
                    @inbounds pos = positions[col]
                end
                @inbounds T = typecodes[col]
                @inbounds tape = tapes[col]
                type = typebits(T)
                if type === EMPTY
                    pos, code = detect(tape, buf, pos, len, options, row, col, typemap, pool, refs, lastrefs, debug, typecodes, threaded, poslens)
                elseif type === MISSINGTYPE
                    pos, code = detect(tape, buf, pos, len, options, row, col, typemap, pool, refs, lastrefs, debug, typecodes, threaded, poslens)
                elseif type === INT
                    pos, code = parseint!(T, tape, buf, pos, len, options, row, col, typecodes, poslens)
                elseif type === FLOAT
                    pos, code = parsevalue!(Float64, T, tape, buf, pos, len, options, row, col, typecodes, poslens)
                elseif type === DATE
                    pos, code = parsevalue!(Date, T, tape, buf, pos, len, options, row, col, typecodes, poslens)
                elseif type === DATETIME
                    pos, code = parsevalue!(DateTime, T, tape, buf, pos, len, options, row, col, typecodes, poslens)
                elseif type === TIME
                    pos, code = parsevalue!(Time, T, tape, buf, pos, len, options, row, col, typecodes, poslens)
                elseif type === BOOL
                    pos, code = parsevalue!(Bool, T, tape, buf, pos, len, options, row, col, typecodes, poslens)
                elseif type === POOL
                    pos, code = parsepooled!(T, tape, buf, pos, len, options, row, col, rowsguess, pool, refs, lastrefs, typecodes, threaded, poslens)
                else # STRING
                    pos, code = parsestring!(T, tape, buf, pos, len, options, row, col, typecodes)
                end
                if transpose
                    @inbounds positions[col] = pos
                else
                    if col < ncols
                        if Parsers.newline(code) || pos > len
                            options.silencewarnings || notenoughcolumns(col, ncols, row)
                            for j = (col + 1):ncols
                                # put in dummy missing values on the tape for missing columns
                                @inbounds tape = tapes[j]
                                tape[row] = MISSING_BIT
                                T = typecodes[j]
                                if T > MISSINGTYPE
                                    typecodes[j] |= MISSING
                                end
                            end
                            break # from for col = 1:ncols
                        end
                    else
                        if pos <= len && !Parsers.newline(code)
                            options.silencewarnings || toomanycolumns(ncols, row)
                            # ignore the rest of the line
                            pos = skiptorow(buf, pos, len, options.oq, options.e, options.cq, 1, 2)
                        end
                    end
                end
            end
            pos > len && break
            if row + 1 > rowsguess
                # (bytes left in file) / (avg bytes per row) == estimated rows left in file (+ 10 for kicks)
                estimated_rows_left = ceil(Int64, (len - pos) / (pos / row) + 10.0)
                newrowsguess = rowsguess + estimated_rows_left
                debug && reallocatetape(row, rowsguess, newrowsguess)
                newtapes = Vector{Vector{UInt64}}(undef, ncols)
                newposlens = Vector{Vector{UInt64}}(undef, ncols)
                for i = 1:ncols
                    newtapes[i] = Mmap.mmap(Vector{UInt64}, newrowsguess)
                    copyto!(newtapes[i], 1, tapes[i], 1, rowsguess)
                    finalize(tapes[i])
                    if !user(typecodes[i]) && typecodes[i] != STRING
                        newposlens[i] = Mmap.mmap(Vector{UInt64}, newrowsguess)
                        copyto!(newposlens[i], 1, poslens[i], 1, rowsguess)
                        finalize(poslens[i])
                    end
                end
                tapes = newtapes
                poslens = newposlens
                rowsguess = newrowsguess
            end
        end
    end
    return row, tapes
end

@noinline reallocatetape(row, old, new) = println("thread = $(Threads.threadid()) warning: didn't pre-allocate enough tape while parsing on row $row, re-allocating from $old to $new...")
@noinline notenoughcolumns(cols, ncols, row) = println("thread = $(Threads.threadid()) warning: only found $cols / $ncols columns on data row: $row. Filling remaining columns with `missing`")
@noinline toomanycolumns(cols, row) = println("thread = $(Threads.threadid()) warning: parsed expected $cols columns, but didn't reach end of line on data row: $row. Ignoring any extra columns on this row")
@noinline stricterror(T, buf, pos, len, code, row, col) = throw(Error("thread = $(Threads.threadid()) error parsing $T on row = $row, col = $col: \"$(String(buf[pos:pos+len-1]))\", error=$(Parsers.codes(code))"))
@noinline warning(T, buf, pos, len, code, row, col) = println("thread = $(Threads.threadid()) warning: error parsing $T on row = $row, col = $col: \"$(String(buf[pos:pos+len-1]))\", error=$(Parsers.codes(code))")
@noinline fatalerror(buf, pos, len, code, row, col) = throw(Error("thread = $(Threads.threadid()) fatal error, encountered an invalidly quoted field while parsing on row = $row, col = $col: \"$(String(buf[pos:pos+len-1]))\", error=$(Parsers.codes(code)), check your `quotechar` arguments or manually fix the field in the file itself"))

const INTVALUE = Val(true)
const NONINTVALUE = Val(false)

@inline function setposlen!(tape, tapeidx, code, pos, len, ::Val{IntValue}=NONINTVALUE) where {IntValue}
    pos = Core.bitcast(UInt64, pos) << 16
    pos |= ifelse(Parsers.sentinel(code), MISSING_BIT, UInt64(0))
    pos |= ifelse(Parsers.escapedstring(code), ESCAPE_BIT, UInt64(0))
    if IntValue
        pos |= INT_BIT
    end
    @inbounds tape[tapeidx] = pos | Core.bitcast(UInt64, len)
    return
end

function detect(tape, buf, pos, len, options, row, col, typemap, pool, refs, lastrefs, debug, typecodes, threaded, poslens)
    int, code, vpos, vlen, tlen = Parsers.xparse(Int64, buf, pos, len, options)
    if Parsers.invalidquotedfield(code)
        fatalerror(buf, pos, tlen, code, row, col)
    end
    if Parsers.sentinel(code) && code > 0
        @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
        @inbounds typecodes[col] = MISSINGTYPE
        @goto done
    end
    @inbounds T = typecodes[col]
    if Parsers.ok(code) && !haskey(typemap, INT)
        @inbounds setposlen!(poslens[col], row, code, vpos, vlen, INTVALUE)
        @inbounds tape[row] = uint64(int)
        @inbounds typecodes[col] = T == MISSINGTYPE ? (INT | MISSING) : INT
        @goto done
    end
    float, code, vpos, vlen, tlen = Parsers.xparse(Float64, buf, pos, len, options)
    if Parsers.ok(code) && !haskey(typemap, FLOAT)
        @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
        @inbounds tape[row] = uint64(float)
        @inbounds typecodes[col] = T == MISSINGTYPE ? (FLOAT | MISSING) : FLOAT
        @goto done
    end
    if options.dateformat === nothing
        try
            date, code, vpos, vlen, tlen = Parsers.xparse(Date, buf, pos, len, options)
            if Parsers.ok(code) && !haskey(typemap, DATE)
                @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
                @inbounds tape[row] = uint64(date)
                @inbounds typecodes[col] = T == MISSINGTYPE ? (DATE | MISSING) : DATE
                @goto done
            end
        catch e
        end
        try
            datetime, code, vpos, vlen, tlen = Parsers.xparse(DateTime, buf, pos, len, options)
            if Parsers.ok(code) && !haskey(typemap, DATETIME)
                @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
                @inbounds tape[row] = uint64(datetime)
                @inbounds typecodes[col] = T == MISSINGTYPE ? (DATETIME | MISSING) : DATETIME
                @goto done
            end
        catch e
        end
    else
        try
            # use user-provided dateformat
            DT = timetype(options.dateformat)
            dt, code, vpos, vlen, tlen = Parsers.xparse(DT, buf, pos, len, options)
            if Parsers.ok(code)
                @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
                @inbounds tape[row] = uint64(dt)
                @inbounds typecodes[col] = DT == Date ? (T == MISSINGTYPE ? (DATE | MISSING) : DATE) : DT == DateTime ? (T == MISSINGTYPE ? (DATETIME | MISSING) : DATETIME) : (T == MISSINGTYPE ? (TIME | MISSING) : TIME)
                @goto done
            end
        catch e
        end
    end
    bool, code, vpos, vlen, tlen = Parsers.xparse(Bool, buf, pos, len, options)
    if Parsers.ok(code) && !haskey(typemap, BOOL)
        @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
        @inbounds tape[row] = uint64(bool)
        @inbounds typecodes[col] = T == MISSINGTYPE ? (BOOL | MISSING) : BOOL
        @goto done
    end
    _, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
    setposlen!(tape, row, code, vpos, vlen)
    if pool > 0.0
        r = Dict{String, UInt64}()
        @inbounds refs[col] = r
        ref = getref!(r, PointerString(pointer(buf, vpos), vlen), lastrefs, col, code, options)
        @inbounds poslens[col][row] = tape[row]
        @inbounds tape[row] = ref
        @inbounds typecodes[col] = T == MISSINGTYPE ? (POOL | MISSING) : POOL
    else
        @inbounds typecodes[col] = T == MISSINGTYPE ? (STRING | MISSING) : STRING
    end
@label done
    return pos + tlen, code
end

@inline function parseint!(T, tape, buf, pos, len, options, row, col, typecodes, poslens)
    x, code, vpos, vlen, tlen = Parsers.xparse(Int64, buf, pos, len, options)
    if code > 0
        if !Parsers.sentinel(code)
            @inbounds tape[row] = uint64(x)
            if !user(T)
                @inbounds setposlen!(poslens[col], row, code, vpos, vlen, INTVALUE)
            end
        else
            @inbounds typecodes[col] = INT | MISSING
            @inbounds tape[row] = MISSING_BIT
        end
    else
        if Parsers.invalidquotedfield(code)
            # this usually means parsing is borked because of an invalidly quoted field, hard error
            fatalerror(buf, pos, tlen, code, row, col)
        end
        if user(T)
            if !options.strict
                options.silencewarnings || warning(Int64, buf, pos, tlen, code, row, col)
                @inbounds typecodes[col] = INT | MISSING
                @inbounds tape[row] = MISSING_BIT
            else
                stricterror(Int64, buf, pos, tlen, code, row, col)
            end
        else
            y, code, vpos, vlen, tlen = Parsers.xparse(Float64, buf, pos, len, options)
            if code > 0
                # recode past Int64 values
                for i = 1:(row - 1)
                    @inbounds tape[i] = uint64(Float64(int64(tape[i])))
                end
                @inbounds tape[row] = uint64(y)
                @inbounds typecodes[col] = missingtype(T) ? (FLOAT | MISSING) : FLOAT
                @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
            else
                _, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
                # recode tape w/ poslen
                copyto!(tape, 1, poslens[col], 1, row - 1)
                unset!(poslens, col)
                setposlen!(tape, row, code, vpos, vlen)
                @inbounds typecodes[col] = STRING | (missingtype(T) ? MISSING : EMPTY)
            end
        end
    end
    return pos + tlen, code
end

function parsevalue!(::Type{type}, T, tape, buf, pos, len, options, row, col, typecodes, poslens) where {type}
    x, code, vpos, vlen, tlen = Parsers.xparse(type, buf, pos, len, options)
    if code > 0
        if !Parsers.sentinel(code)
            @inbounds tape[row] = uint64(x)
        else
            @inbounds typecodes[col] = T | MISSING
            @inbounds tape[row] = MISSING_BIT
        end
        if !user(T)
            @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
        end
    else
        if Parsers.invalidquotedfield(code)
            # this usually means parsing is borked because of an invalidly quoted field, hard error
            fatalerror(buf, pos, tlen, code, row, col)
        end
        if user(T)
            if !options.strict
                code |= Parsers.SENTINEL
                options.silencewarnings || warning(type, buf, pos, tlen, code, row, col)
                @inbounds typecodes[col] = T | MISSING
                @inbounds tape[row] = MISSING_BIT
            else
                stricterror(type, buf, pos, tlen, code, row, col)
            end
        else
            _, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
            # recode tape w/ poslen
            copyto!(tape, 1, poslens[col], 1, row - 1)
            unset!(poslens, col)
            setposlen!(tape, row, code, vpos, vlen)
            @inbounds typecodes[col] = missingtype(T) ? (STRING | MISSING) : STRING
        end
    end
    return pos + tlen, code
end

@inline function parsestring!(T, tape, buf, pos, len, options, row, col, typecodes)
    x, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
    setposlen!(tape, row, code, vpos, vlen)
    if Parsers.invalidquotedfield(code)
        # this usually means parsing is borked because of an invalidly quoted field, hard error
        fatalerror(buf, pos, tlen, code, row, col)
    end
    if Parsers.sentinel(code)
        @inbounds typecodes[col] = STRING | MISSING
    end
    return pos + tlen, code
end

@inline function getref!(x::Dict, key::PointerString, lastrefs, col, code, options)
    if Parsers.escapedstring(code)
        key2 = unescape(key, options.e)
        index = Base.ht_keyindex2!(x, key2)
    else
        index = Base.ht_keyindex2!(x, key)
    end
    if index > 0
        @inbounds found_key = x.vals[index]
        return found_key::UInt64
    else
        @inbounds new = (lastrefs[col] += UInt64(1))
        @inbounds Base._setindex!(x, new, Parsers.escapedstring(code) ? key2 : String(key), -index)
        return new
    end
end

@inline function parsepooled!(T, tape, buf, pos, len, options, row, col, rowsguess, pool, refs, lastrefs, typecodes, threaded, poslens)
    x, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
    if Parsers.invalidquotedfield(code)
        # this usually means parsing is borked because of an invalidly quoted field, hard error
        fatalerror(buf, pos, tlen, code, row, col)
    end
    if Parsers.sentinel(code)
        @inbounds typecodes[col] = T | MISSING
        ref = UInt64(0)
    else
        if !isassigned(refs, col)
            r = Dict{String, UInt64}()
            @inbounds refs[col] = r
        else
            @inbounds r = refs[col]
        end
        ref = getref!(r, PointerString(pointer(buf, vpos), vlen), lastrefs, col, code, options)
    end
    if !user(T) && isassigned(refs, col) && (length(refs[col]) / rowsguess) > pool
        # promote to string
        copyto!(tape, 1, poslens[col], 1, row - 1)
        unset!(poslens, col)
        setposlen!(tape, row, code, vpos, vlen)
        @inbounds typecodes[col] = STRING | (missingtype(typecodes[col]) ? MISSING : EMPTY)
    else
        if !user(T)
            @inbounds setposlen!(poslens[col], row, code, vpos, vlen)
        end
        @inbounds tape[tapeidx + 1] = ref
    end
    return pos + tlen, code
end

include("tables.jl")
include("iteration.jl")
include("rows.jl")
include("write.jl")

"""
`CSV.read(source; copycols::Bool=false, kwargs...)` => `DataFrame`

Parses a delimited file into a `DataFrame`. `copycols` determines whether a copy of columns should be made when creating the DataFrame; by default, no copy is made, and the DataFrame is built with immutable, read-only `CSV.Column` vectors. If mutable operations are needed on the DataFrame columns, set `copycols=true`.

`CSV.read` supports the same keyword arguments as [`CSV.File`](@ref).
"""
read(source; copycols::Bool=false, kwargs...) = DataFrame(CSV.File(source; kwargs...), copycols=copycols)

function __init__()
    # Threads.resize_nthreads!(VALUE_BUFFERS)
    return
end

end # module
