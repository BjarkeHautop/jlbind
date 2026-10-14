# --- R -> Julia --------------------------------------------------------------

"""
    from_sexp(T, x::SEXP) -> T

Convert the R object `x` to a `T`, throwing an `ArgumentError` with a message
for the R user if it is not one. `@rcall` converts each argument with it.

Methods are provided for `SEXP` (no conversion), `String`, `Symbol`, `Bool`,
`Int64`, `Float64`, vectors of each, and `Union{Nothing,T}` (`NULL` is
`nothing`). A binding package adds methods for its own types.
"""
function from_sexp end

from_sexp(::Type{SEXP}, x::SEXP) = x

function from_sexp(::Type{Union{Nothing,T}}, x::SEXP) where {T}
    x == nil() && return nothing
    return from_sexp(T, x)
end

function _check_type(x::SEXP, t::Cint, what::String)
    rtypeof(x) == t || throw(ArgumentError("expected " * what))
    return nothing
end

function _check_scalar(x::SEXP, what::String)
    rlength(x) == 1 || throw(ArgumentError("expected a single " * what))
    return nothing
end

function _string_at(x::SEXP, i::Int)
    c = string_elt(x, i)
    _isna_string(c) && throw(ArgumentError("expected a string, not NA"))
    # R refuses to translate such a string, with an R error.
    _isbytes(c) && throw(ArgumentError("expected text, not a string in \"bytes\" encoding"))
    return _utf8(c)
end

function from_sexp(::Type{String}, x::SEXP)
    _check_type(x, STRSXP, "a character string")
    _check_scalar(x, "character string")
    return unsafe_string(_string_at(x, 0))
end

function from_sexp(::Type{Symbol}, x::SEXP)
    _check_type(x, STRSXP, "a character string")
    _check_scalar(x, "character string")
    return _symbol(_string_at(x, 0))
end

function from_sexp(::Type{Vector{String}}, x::SEXP)
    _check_type(x, STRSXP, "a character vector")
    return String[unsafe_string(_string_at(x, i - 1)) for i = 1:rlength(x)]
end

function from_sexp(::Type{Vector{Symbol}}, x::SEXP)
    _check_type(x, STRSXP, "a character vector")
    return Symbol[_symbol(_string_at(x, i - 1)) for i = 1:rlength(x)]
end

# The scalars are read directly rather than with R's `asLogical`/`asReal`,
# which raise R errors (e.g. on a raw vector) and coercion warnings (an error
# under `options(warn = 2)`) that would unwind through Julia.
function from_sexp(::Type{Bool}, x::SEXP)
    _check_type(x, LGLSXP, "TRUE or FALSE")
    _check_scalar(x, "logical value")
    v = unsafe_load(logical_ptr(x))
    v == typemin(Cint) && throw(ArgumentError("expected TRUE or FALSE, not NA"))
    return v != 0
end

function from_sexp(::Type{Float64}, x::SEXP)
    t = rtypeof(x)
    t == REALSXP || t == INTSXP || throw(ArgumentError("expected a number"))
    _check_scalar(x, "number")
    if t == INTSXP
        i = unsafe_load(int_ptr(x))
        i == typemin(Cint) && throw(ArgumentError("expected a number, not NA"))
        return Float64(i)
    end
    v = unsafe_load(real_ptr(x))
    isnan(v) && throw(ArgumentError("expected a number, not NA"))
    return v
end

function _whole(v::Float64)
    isinteger(v) && abs(v) <= 2.0^53 ||
        throw(ArgumentError("expected a whole number, not " * string(v)))
    return Int64(v)
end

from_sexp(::Type{Int64}, x::SEXP) = _whole(from_sexp(Float64, x))

# An integer or double vector, as doubles; NA is an error.
function _doubles(x::SEXP)
    n = rlength(x)
    out = Vector{Float64}(undef, n)
    t = rtypeof(x)
    if t == REALSXP
        unsafe_copyto!(pointer(out), real_ptr(x), n)
        any(isnan, out) && throw(ArgumentError("expected numbers, not NA"))
    elseif t == INTSXP
        p = int_ptr(x)
        for i = 1:n
            v = unsafe_load(p, i)
            v == typemin(Cint) && throw(ArgumentError("expected numbers, not NA"))
            out[i] = v
        end
    else
        throw(ArgumentError("expected a numeric vector"))
    end
    return out
end

from_sexp(::Type{Vector{Float64}}, x::SEXP) = _doubles(x)
from_sexp(::Type{Vector{Int64}}, x::SEXP) = Int64[_whole(v) for v in _doubles(x)]

function from_sexp(::Type{Vector{Bool}}, x::SEXP)
    _check_type(x, LGLSXP, "a logical vector")
    p = logical_ptr(x)
    out = Vector{Bool}(undef, rlength(x))
    for i in eachindex(out)
        v = unsafe_load(p, i)
        v == typemin(Cint) && throw(ArgumentError("expected TRUE or FALSE, not NA"))
        out[i] = v != 0
    end
    return out
end

# --- Julia -> R --------------------------------------------------------------

"""
    to_sexp(x) -> SEXP

Convert `x` to a new R object. `@rcall` converts each result with it.

Methods are provided for `SEXP` (no conversion), `nothing` (`NULL`), `Bool`,
`Int64` and `Float64` (double), `Int32` (integer), `String` and `Symbol`
(character), vectors of each, `Matrix{Float64}`, and, as lists, other vectors,
tuples and named tuples (a named list). Integers become doubles, since R's
integers have 32 bits. A binding package adds methods for its own types.
"""
function to_sexp end

to_sexp(x::SEXP) = x
to_sexp(::Nothing) = nil()
to_sexp(x::Bool) = ccall(@R(Rf_ScalarLogical), SEXP, (Cint,), x)
to_sexp(x::Int64) = ccall(@R(Rf_ScalarReal), SEXP, (Float64,), Float64(x))
to_sexp(x::Int32) = ccall(@R(Rf_ScalarInteger), SEXP, (Cint,), x)
to_sexp(x::Float64) = ccall(@R(Rf_ScalarReal), SEXP, (Float64,), x)
to_sexp(x::Union{String,Symbol}) = to_sexp([x])

function to_sexp(xs::Union{Vector{String},Vector{Symbol}})
    out = protect(alloc(STRSXP, length(xs)))
    for (i, x) in enumerate(xs)
        set_string_elt(out, i - 1, mkchar(x))
    end
    unprotect(1)
    return out
end

function _fill(t::Cint, ptr::F, xs, ::Type{T}) where {F,T}
    out = alloc(t, length(xs))
    p = ptr(out)
    for (i, x) in enumerate(xs)
        unsafe_store!(p, T(x), i)
    end
    return out
end

to_sexp(xs::Vector{Float64}) = _fill(REALSXP, real_ptr, xs, Float64)
to_sexp(xs::Vector{Int64}) = _fill(REALSXP, real_ptr, xs, Float64)
to_sexp(xs::Vector{Int32}) = _fill(INTSXP, int_ptr, xs, Cint)
to_sexp(xs::Vector{Bool}) = _fill(LGLSXP, logical_ptr, xs, Cint)

function to_sexp(xs::Matrix{Float64})
    out = alloc_matrix(REALSXP, size(xs, 1), size(xs, 2))
    unsafe_copyto!(real_ptr(out), pointer(xs), length(xs))
    return out
end

# A list, one element per item. Each item is converted with a call that is
# resolved when the library is compiled, so the element type must be concrete
# or a small union.
function to_sexp(xs::Vector)
    out = protect(alloc(VECSXP, length(xs)))
    for (i, x) in enumerate(xs)
        set_vector_elt(out, i - 1, to_sexp(x))
    end
    unprotect(1)
    return out
end

# A tuple's elements may all have different types, so it is converted by a
# recursion specialized on every element (`Vararg{Any,N}` forces that), which
# resolves each conversion statically.
function to_sexp(xs::Tuple)
    out = protect(alloc(VECSXP, length(xs)))
    _set_elements(out, 0, xs...)
    unprotect(1)
    return out
end

_set_elements(::SEXP, ::Int) = nothing
function _set_elements(out::SEXP, i::Int, x, rest::Vararg{Any,N}) where {N}
    set_vector_elt(out, i, to_sexp(x))
    _set_elements(out, i + 1, rest...)
end

function to_sexp(xs::NamedTuple{names}) where {names}
    out = protect(to_sexp(Tuple(xs)))
    set_attrib(out, @r_global(R_NamesSymbol), to_sexp(String[String(n) for n in names]))
    unprotect(1)
    return out
end

"""
    data_frame(names::Vector{String}, columns::Vector{SEXP}) -> SEXP

A `data.frame` with the equal-length R vectors `columns`. The columns must be
protected (or reachable from R) until the call returns.
"""
function data_frame(names::Vector{String}, columns::Vector{SEXP})
    n = length(columns) == 0 ? 0 : rlength(columns[1])
    out = protect(alloc(VECSXP, length(columns)))
    for (i, col) in enumerate(columns)
        set_vector_elt(out, i - 1, col)
    end
    set_attrib(out, @r_global(R_NamesSymbol), to_sexp(names))
    set_attrib(out, @r_global(R_ClassSymbol), to_sexp("data.frame"))
    rownames = protect(alloc(INTSXP, 2))
    unsafe_store!(int_ptr(rownames), typemin(Cint), 1)
    unsafe_store!(int_ptr(rownames), Cint(-n), 2)
    set_attrib(out, @r_global(R_RowNamesSymbol), rownames)
    unprotect(2)
    return out
end
