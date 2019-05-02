Tables.istable(::Type{<:File}) = true
Tables.columnaccess(::Type{<:File}) = true
Tables.schema(f::File)  = Tables.Schema(getnames(f), _eltype.(gettypes(f)))
Tables.columns(f::File) = f
Base.propertynames(f::File) = getnames(f)

struct Column{T, P} <: AbstractVector{T}
    f::File
    col::Int
    r::StepRange{Int, Int}
end

_eltype(::Type{T}) where {T} = T
_eltype(::Type{PooledString}) = String
_eltype(::Type{Union{PooledString, Missing}}) = Union{String, Missing}

function Column(f::File, i::Int)
    T = gettypes(f)[i]
    r = range(2 + ((i - 1) * 2), step=getcols(f) * 2, length=getrows(f))
    return Column{_eltype(T), T}(f, i, r)
end

Base.size(c::Column) = (length(c.r),)
Base.IndexStyle(::Type{<:Column}) = Base.IndexLinear()
function Base.copy(c::Column{T}) where {T}
    len = length(c)
    A = Vector{T}(undef, len)
    @simd for i = 1:len
        @inbounds A[i] = c[i]
    end
    return A
end

reinterp_func(::Type{Int64}) = int64
reinterp_func(::Type{Float64}) = float64
reinterp_func(::Type{Date}) = date
reinterp_func(::Type{DateTime}) = datetime
reinterp_func(::Type{Bool}) = bool

@inline Base.@propagate_inbounds function Base.getindex(c::Column{Missing}, row::Int)
    @boundscheck checkbounds(c, row)
    return missing
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{T}, row::Int) where {T}
    @boundscheck checkbounds(c, row)
    @inbounds x = reinterp_func(T)(gettape(c.f)[c.r[row]])
    return x
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{Union{T, Missing}}, row::Int) where {T}
    @boundscheck checkbounds(c, row)
    @inbounds offlen = gettape(c.f)[c.r[row] - 1]
    @inbounds x = ifelse(missingvalue(offlen), missing, reinterp_func(T)(gettape(c.f)[c.r[row]]))
    return x
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{Float64}, row::Int)
    @boundscheck checkbounds(c, row)
    @inbounds offlen = gettape(c.f)[c.r[row] - 1]
    @inbounds v = gettape(c.f)[c.r[row]]
    @inbounds x = ifelse(intvalue(offlen), Float64(int64(v)), float64(v))
    return x
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{Union{Float64, Missing}}, row::Int)
    @boundscheck checkbounds(c, row)
    @inbounds offlen = gettape(c.f)[c.r[row] - 1]
    @inbounds v = gettape(c.f)[c.r[row]]
    @inbounds x = ifelse(missingvalue(offlen), missing, ifelse(intvalue(offlen), Float64(int64(v)), float64(v)))
    return x
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{String, PooledString}, row::Int)
    @boundscheck checkbounds(c, row)
    @inbounds x = getrefs(c.f)[c.col][gettape(c.f)[c.r[row]]]
    return x
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{Union{String, Missing}, Union{PooledString, Missing}}, row::Int)
    @boundscheck checkbounds(c, row)
    @inbounds offlen = gettape(c.f)[c.r[row] - 1]
    if missingvalue(offlen)
        return missing
    else
        @inbounds x = getrefs(c.f)[c.col][gettape(c.f)[c.r[row]]]
        return x
    end
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{String}, row::Int)
    @boundscheck checkbounds(c, row)
    @inbounds offlen = gettape(c.f)[c.r[row] - 1]
    s = PointerString(pointer(getbuf(c.f), getpos(offlen)), getlen(offlen))
    return escapedvalue(offlen) ? unescape(s, gete(c.f)) : String(s)
end

@inline Base.@propagate_inbounds function Base.getindex(c::Column{Union{String, Missing}}, row::Int)
    @boundscheck checkbounds(c, row)
    @inbounds offlen = gettape(c.f)[c.r[row] - 1]
    if missingvalue(offlen)
        return missing
    else
        s = PointerString(pointer(getbuf(c.f), getpos(offlen)), getlen(offlen))
        return escapedvalue(offlen) ? unescape(s, gete(c.f)) : String(s)
    end
end

function Base.getproperty(f::File, col::Symbol)
    i = findfirst(==(col), getnames(f))
    i === nothing && return getfield(f, col)
    return Column(f, i)
end
