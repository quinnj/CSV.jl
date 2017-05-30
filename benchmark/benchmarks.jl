using PkgBenchmark, CSV, WeakRefStrings
if !is_windows()
    using DecFP
end

prep(io::IO, ::Type{Int64}) = write(io, "10")
prep(io::IO, ::Type{Float64}) = write(io, "10.0")
prep(io::IO, ::Type{WeakRefString{UInt8}}) = write(io, "hey there sailor")
prep(io::IO, ::Type{String}) = write(io, "hey there sailor")
prep(io::IO, ::Type{Date}) = write(io, "2016-09-28")
prep(io::IO, ::Type{DateTime}) = write(io, "2016-09-28T03:21:00")
if !is_windows()
    prep(io::IO, ::Type{Dec64}) = write(io, "10.0")
end

function prep{T}(::Type{IOBuffer}, ::Type{T})
    io = IOBuffer()
    prep(io, T)
    seekstart(io)
    return io, ()->return
end
function prep{T}(::Type{IOStream}, ::Type{T})
    t = tempname()
    io = open(t, "w")
    prep(io, T)
    close(io)
    io = open(t, "r")
    return io, ()->rm(t)
end

TYPES = !is_windows() ? (Int, Float64, WeakRefString{UInt8}, String, Date, DateTime, Dec64) : (Int, Float64, WeakRefString{UInt8}, String, Date, DateTime)

@benchgroup "CSV" begin
    @benchgroup "CSV.parsefield" begin
        opts = CSV.Options()
        row = col = 1
        state = Ref{CSV.ParsingState}(CSV.None)
        for I in (IOBuffer, IOStream)
            for T in TYPES
                io, f = prep(I, T)
                @bench "$I - $T" CSV.parsefield($io, $T, opts, row, col, state)
                f()
            end
        end
    end
    FILE = joinpath(dirname(@__FILE__), "randoms_small.csv")

    @benchgroup "CSV.read" begin
        @bench "CSV.read" CSV.read(FILE)
    end

    @benchgroup "CSV.write" begin
        df = CSV.read(FILE)
        t = tempname()
        @bench "CSV.write" CSV.write(t, df)
    end

end




# generate single column files w/ 1M rows for each type
using WeakRefStrings

val = "hey"
for i in (1001, 100.1, WeakRefString{UInt8}(pointer(val), 3, 0), Date(2008, 1, 3), DateTime(2008, 3, 4))
    open("/Users/jacobquinn/Downloads/randoms_$(typeof(i)).csv", "w") do f
        for j = 1:1_000_000
            write(f, string(i))
            write(f, "\n")
        end
    end
end

using CSV, TextParse
for T in (Int, Float64, WeakRefString{UInt8}, Date, DateTime)
    println("comparing for T = $T...")
    @time CSV.read("/Users/jacobquinn/Downloads/randoms_$(T).csv"; nullable=false, rows=999999)
    @time TextParse.csvread("/Users/jacobquinn/Downloads/randoms_$(T).csv")
end
# julia> for T in (Int, Float64, WeakRefString{UInt8}, Date, DateTime)
#            println("comparing for T = $T...")
#            @time CSV.read("/Users/jacobquinn/Downloads/randoms_$(T).csv"; nullable=false)
#            @time TextParse.csvread("/Users/jacobquinn/Downloads/randoms_$(T).csv")
#        end
# comparing for T = Int64...
# pre-allocating DataFrame w/ rows = 999999
#   0.035043 seconds (2.40 k allocations: 7.758 MiB, 24.25% gc time)
#   0.052334 seconds (457 allocations: 15.574 MiB)
# comparing for T = Float64...
# pre-allocating DataFrame w/ rows = 999999
#   0.086990 seconds (3.90 k allocations: 7.841 MiB, 6.02% gc time)
#   0.088458 seconds (457 allocations: 16.528 MiB)
# comparing for T = WeakRefString{UInt8}...
# pre-allocating DataFrame w/ rows = 999999
#   0.147004 seconds (9.31 k allocations: 23.408 MiB, 3.91% gc time)
#   0.074228 seconds (595 allocations: 5.188 MiB)
# comparing for T = Date...
# pre-allocating DataFrame w/ rows = 999999
#   0.207697 seconds (6.01 M allocations: 114.772 MiB, 14.71% gc time)
#   0.158652 seconds (1.00 M allocations: 51.846 MiB, 4.77% gc time)
# comparing for T = DateTime...
# pre-allocating DataFrame w/ rows = 999999
#   0.282168 seconds (6.01 M allocations: 114.899 MiB, 12.61% gc time)
#   0.192103 seconds (1.00 M allocations: 60.516 MiB, 4.63% gc time)

T = Int64
@time source = CSV.Source("/Users/jacobquinn/Downloads/randoms_$(T).csv"; nullable=false, row)
@time CSV.read(source)
sink = Si = DataFrames.DataFrame
transforms = Dict{Int,Function}()
append = false
args = kwargs = ()
source_schema = DataStreams.Data.schema(source)
@code_warntype DataStreams.Data.transform(source_schema, transforms)
sink_schema, transforms2 = DataStreams.Data.transform(source_schema, transforms)
sinkstreamtype = DataStreams.Data.Field
sink = Si(sink_schema, sinkstreamtype, append, args...; kwargs...)
columns = []
filter = x->true
@code_warntype DataStreams.Data.stream!(source, sinkstreamtype, sink, source_schema, sink_schema, transforms2, filter, columns)
@time DataStreams.Data.stream!(source, sinkstreamtype, sink, source_schema, sink_schema, transforms2, filter, columns)

@code_warntype @time CSV.parsefield(IOBuffer(), ?Int, CSV.Options(), 0, 0, CSV.STATE)

# having CSV.parsefield(io, T) where T !>: Null decreases allocations by 1.00M
# inlining CSV.parsefield also dropped allocations
# making CSV.Options not have a type parameter also sped things up
#

using BenchmarkTools

g(x) = x < 5 ? x : -1
A = [i for i = 1:10]
function get_then_set(A)
    @simd for i = 1:10
        @inbounds A[i] = g(i)
    end
    return A
end
@code_warntype g(1)
@code_warntype get_then_set(A)
@benchmark get_then_set(A) # 20ns

g2(x) = x < 5 ? x : nothing
@inline function g2(x)
    if x < 20
        return x * 20
    end

    if x < 15
        return nothing
    end

    if x < 12
        return 2x
    end

    if x * 20 / 4 % 2 == 0
        return 1
    end

    if x < 0
        return nothing
    end
    return nothing
end

A = Union{Int, Void}[i for i = 1:10]
function get_then_set2(A)
    @simd for i = 1:10
        # Base.arrayset(A, g2(i), i)
        @inbounds A[i] = g2(i)#::Union{Int, Void}
    end
    return A
end
@code_warntype g2(1)
@code_warntype get_then_set2(A)
@code_llvm get_then_set2(A)
@benchmark get_then_set2(A) # 155ns


g4(x::Int) = 1
g4(x::Void) = 0

A = [i for i = 1:10]
function get_sum(A)
    s = 0
    for a in A
        s += g4(a)
    end
    return s
end
@code_warntype get_sum(A)
@code_llvm get_sum(A)
@benchmark get_sum(A) # 24ns

A = Union{Int, Void}[i for i = 1:10]
A[[3, 5, 7]] = nothing
function get_sum2(A)
    s = 0
    for a in A
        s += g4(a)
    end
    return s
end
@code_warntype get_sum2(A)
@code_llvm get_sum(A)
@benchmark get_sum2(A) # 100ns


function getstatic{T}(t::T)
    return t[1]
end