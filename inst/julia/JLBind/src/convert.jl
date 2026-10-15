# --- R -> Julia --------------------------------------------------------------

"""
    from_sexp(T, x::SEXP) -> T

Convert the R object `x` to a `T`, throwing an `ArgumentError` with a message
for the R user if it is not one. `@rcall` converts each argument with it.

Methods are provided for

- `SEXP` (no conversion);
- `String` and `Symbol` (from a character vector or a factor), `Bool`,
  `Float64`, `Int64`, `Int32` and `ComplexF64`, `Date` (from a `Date`) and
  `DateTime` (from a `POSIXct`, to the millisecond), and vectors of each;
- `Float32`, `Float16`, `Int16`, `Int8`, `UInt32` and `UInt16`, from a number
  in their range, and vectors of each;
- `Union{Missing,T}` and `Vector{Union{Missing,T}}`, where `NA` is `missing`,
  for each `T` above (`NA` is otherwise an error);
- `Vector{UInt8}` (a raw vector) and [`RVector{T}`](@ref) (a view of a double,
  integer or raw vector);
- `Array{T,N}`, including `Matrix{T}`, from an R array of `N` dimensions;
- from a list: other `Vector`s, `Tuple`s, `NamedTuple`s (from a list named
  exactly by their fields, such as a `data.frame`), `Dict{String,T}` and
  `Dict{Symbol,T}`;
- [`RDataFrame`](@ref), from a `data.frame`;
- `Union{Nothing,T}` (`NULL` is `nothing`).

A binding package adds methods for its own types.
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

# `NA` and `c(NA, NA)` are logical vectors, so where `missing` is allowed, a
# logical vector of only NA is missing values of any type.
function _all_na(x::SEXP)
    rtypeof(x) == LGLSXP || return false
    n = rlength(x)
    p = logical_ptr(x)
    return n > 0 && all(i -> unsafe_load(p, i) == NA_INTEGER, 1:n)
end

function _missing1(x::SEXP, what::String)
    _check_scalar(x, what)
    return missing
end

# --- Strings

# The levels of `x` if it is a factor, `C_NULL` if it is a character vector.
function _string_levels(x::SEXP, what::String)
    t = rtypeof(x)
    t == STRSXP && return C_NULL
    if t == INTSXP && _inherits(x, "factor")
        levels = get_attrib(x, @r_global(R_LevelsSymbol))
        rtypeof(levels) == STRSXP && return levels
    end
    throw(ArgumentError("expected " * what))
end

# The CHARSXP of element `i` (0-based) of a character vector or factor.
function _charsxp(x::SEXP, levels::SEXP, i::Int)
    levels == C_NULL && return string_elt(x, i)
    code = unsafe_load(int_ptr(x), i + 1)
    code == NA_INTEGER && return @r_global(R_NaString)
    1 <= code <= rlength(levels) || throw(ArgumentError("expected a valid factor"))
    return string_elt(levels, code - 1)
end

function _chars(c::SEXP)
    # R refuses to translate such a string, with an R error.
    _isbytes(c) && throw(ArgumentError("expected text, not a string in \"bytes\" encoding"))
    return _utf8(c)
end

_text(::Type{String}, p::Ptr{UInt8}) = unsafe_string(p)
_text(::Type{Symbol}, p::Ptr{UInt8}) = _symbol(p)

function _string(::Type{T}, c::SEXP) where {T}
    _isna_string(c) && throw(ArgumentError("expected a string, not NA"))
    return _text(T, _chars(c))
end
_maybe_string(::Type{T}, c::SEXP) where {T} = _isna_string(c) ? missing : _text(T, _chars(c))

function _strings(f::F, ::Type{E}, x::SEXP) where {F,E}
    levels = _string_levels(x, "a character vector")
    out = Vector{E}(undef, rlength(x))
    for i in eachindex(out)
        out[i] = f(_charsxp(x, levels, i - 1))
    end
    return out
end

function _string1(x::SEXP)
    levels = _string_levels(x, "a character string")
    _check_scalar(x, "character string")
    return _charsxp(x, levels, 0)
end

for T in (String, Symbol)
    @eval begin
        from_sexp(::Type{$T}, x::SEXP) = _string($T, _string1(x))
        from_sexp(::Type{Union{Missing,$T}}, x::SEXP) =
            _all_na(x) ? _missing1(x, "character string") : _maybe_string($T, _string1(x))
        from_sexp(::Type{Vector{$T}}, x::SEXP) = _strings(c -> _string($T, c), $T, x)
        function from_sexp(::Type{Vector{Union{Missing,$T}}}, x::SEXP)
            _all_na(x) && return Vector{Union{Missing,$T}}(missing, rlength(x))
            return _strings(c -> _maybe_string($T, c), Union{Missing,$T}, x)
        end
    end
end

# --- Logicals

# The scalars are read directly rather than with R's `asLogical`/`asReal`,
# which raise R errors (e.g. on a raw vector) and coercion warnings (an error
# under `options(warn = 2)`) that would unwind through Julia.
function _bool(v::Cint)
    v == NA_INTEGER && throw(ArgumentError("expected TRUE or FALSE, not NA"))
    return v != 0
end
_maybe_bool(v::Cint) = v == NA_INTEGER ? missing : v != 0

function from_sexp(::Type{Bool}, x::SEXP)
    _check_type(x, LGLSXP, "TRUE or FALSE")
    _check_scalar(x, "logical value")
    return _bool(unsafe_load(logical_ptr(x)))
end

function from_sexp(::Type{Union{Missing,Bool}}, x::SEXP)
    _check_type(x, LGLSXP, "TRUE, FALSE or NA")
    _check_scalar(x, "logical value")
    return _maybe_bool(unsafe_load(logical_ptr(x)))
end

function _logicals(f::F, ::Type{E}, x::SEXP) where {F,E}
    _check_type(x, LGLSXP, "a logical vector")
    p = logical_ptr(x)
    out = Vector{E}(undef, rlength(x))
    for i in eachindex(out)
        out[i] = f(unsafe_load(p, i))
    end
    return out
end

from_sexp(::Type{Vector{Bool}}, x::SEXP) = _logicals(_bool, Bool, x)
from_sexp(::Type{Vector{Union{Missing,Bool}}}, x::SEXP) =
    _logicals(_maybe_bool, Union{Missing,Bool}, x)

# --- Numbers

const _Real = Union{Float64,Float32,Float16,Int64,Int32,Int16,Int8,UInt32,UInt16}

_isna(v::Float64) = reinterpret(UInt64, v) % UInt32 == 0x000007a2 && isnan(v)
# How R prints the NaN `v`.
_nan_name(v::Float64) = _isna(v) ? "NA" : "NaN"

# An integer or double vector, as doubles, with NA as `NA_REAL`.
function _numbers(x::SEXP, what::String)
    n = rlength(x)
    out = Vector{Float64}(undef, n)
    t = rtypeof(x)
    if t == REALSXP
        unsafe_copyto!(pointer(out), real_ptr(x), n)
    elseif t == INTSXP
        p = int_ptr(x)
        for i = 1:n
            v = unsafe_load(p, i)
            out[i] = v == NA_INTEGER ? NA_REAL : Float64(v)
        end
    else
        throw(ArgumentError("expected " * what))
    end
    return out
end

function _no_nan(xs::Vector{Float64})
    i = findfirst(isnan, xs)
    i === nothing || throw(ArgumentError("expected numbers, not " * _nan_name(xs[i])))
    return xs
end

# A single integer or double, as a double, with NA as `NA_REAL`.
function _number1(x::SEXP)
    t = rtypeof(x)
    t == REALSXP || t == INTSXP || throw(ArgumentError("expected a number"))
    _check_scalar(x, "number")
    t == REALSXP && return unsafe_load(real_ptr(x))
    i = unsafe_load(int_ptr(x))
    return i == NA_INTEGER ? NA_REAL : Float64(i)
end

function _whole(v::Float64)
    isinteger(v) && abs(v) <= 2.0^53 ||
        throw(ArgumentError("expected a whole number, not " * string(v)))
    return Int64(v)
end

# The whole numbers a `T` holds; R's integers exclude typemin(Int32), which is
# NA.
_whole_range(::Type{T}) where {T} = (Int64(typemin(T)), Int64(typemax(T)))
_whole_range(::Type{Int32}) = (Int64(typemin(Int32)) + 1, Int64(typemax(Int32)))

function _whole_in(::Type{T}, v::Float64) where {T}
    lo, hi = _whole_range(T)
    isinteger(v) && lo <= v <= hi || throw(ArgumentError(
        "expected a whole number between " * string(lo) * " and " * string(hi) *
        ", not " * string(v),
    ))
    return T(v)
end

# A smaller float is rounded to the nearest; a number beyond its range is an
# error rather than an infinity.
function _float_in(::Type{T}, v::Float64) where {T}
    y = T(v)
    if isinf(y) && !isinf(v)
        m = string(Float64(floatmax(T)))
        throw(ArgumentError(
            "expected a number between -" * m * " and " * m * ", not " * string(v),
        ))
    end
    return y
end

# A double that is not NA as a `T`; NaN is an error unless `T` is a float.
_number(::Type{Float64}, v::Float64) = v
_number(::Type{T}, v::Float64) where {T<:Union{Float32,Float16}} = _float_in(T, v)
_number(::Type{Int64}, v::Float64) = _whole(v)
_number(::Type{T}, v::Float64) where {T<:Union{Int32,Int16,Int8,UInt32,UInt16}} =
    _whole_in(T, v)

function from_sexp(::Type{T}, x::SEXP) where {T<:_Real}
    v = _number1(x)
    isnan(v) && throw(ArgumentError("expected a number, not " * _nan_name(v)))
    return _number(T, v)
end

function from_sexp(::Type{Union{Missing,T}}, x::SEXP) where {T<:_Real}
    _all_na(x) && return _missing1(x, "number")
    v = _number1(x)
    # NaN is a Float64, but not a whole number.
    return _isna(v) ? missing : _number(T, v)
end

from_sexp(::Type{Vector{Float64}}, x::SEXP) = _no_nan(_numbers(x, "a numeric vector"))
from_sexp(::Type{Vector{T}}, x::SEXP) where {T<:_Real} =
    T[_number(T, v) for v in _no_nan(_numbers(x, "a numeric vector"))]

function from_sexp(::Type{Vector{Int32}}, x::SEXP)
    rtypeof(x) == INTSXP ||
        return Int32[_number(Int32, v) for v in _no_nan(_numbers(x, "a numeric vector"))]
    n = rlength(x)
    out = Vector{Int32}(undef, n)
    unsafe_copyto!(pointer(out), int_ptr(x), n)
    NA_INTEGER in out && throw(ArgumentError("expected numbers, not NA"))
    return out
end

function from_sexp(::Type{Vector{Union{Missing,T}}}, x::SEXP) where {T<:_Real}
    _all_na(x) && return Vector{Union{Missing,T}}(missing, rlength(x))
    vs = _numbers(x, "a numeric vector")
    return Union{Missing,T}[_isna(v) ? missing : _number(T, v) for v in vs]
end

# --- Complex numbers and bytes

# R's `NA_complex_`, and whether `z` is an NA: R counts one with either part NA.
const _NA_COMPLEX = ComplexF64(NA_REAL, NA_REAL)
_isna(z::ComplexF64) = _isna(real(z)) || _isna(imag(z))

# A complex, double or integer vector as complex numbers, NA included.
function _complex_values(x::SEXP, what::String)
    rtypeof(x) == CPLXSXP || return ComplexF64[complex(v) for v in _numbers(x, what)]
    n = rlength(x)
    out = Vector{ComplexF64}(undef, n)
    unsafe_copyto!(pointer(out), complex_ptr(x), n)
    return out
end

function _complexes(x::SEXP, what::String, nan_what::String)
    out = _complex_values(x, what)
    for z in out
        if isnan(real(z)) || isnan(imag(z))
            throw(ArgumentError("expected " * nan_what * ", not " * (_isna(z) ? "NA" : "NaN")))
        end
    end
    return out
end

function _complex1(x::SEXP)
    t = rtypeof(x)
    t == CPLXSXP || t == REALSXP || t == INTSXP ||
        throw(ArgumentError("expected a complex number"))
    _check_scalar(x, "complex number")
    return x
end

from_sexp(::Type{ComplexF64}, x::SEXP) =
    _complexes(_complex1(x), "a complex number", "a complex number")[1]

function from_sexp(::Type{Union{Missing,ComplexF64}}, x::SEXP)
    _all_na(x) && return _missing1(x, "complex number")
    z = _complex_values(_complex1(x), "a complex number")[1]
    return _isna(z) ? missing : z
end

from_sexp(::Type{Vector{ComplexF64}}, x::SEXP) =
    _complexes(x, "a complex vector", "complex numbers")

function from_sexp(::Type{Vector{Union{Missing,ComplexF64}}}, x::SEXP)
    _all_na(x) && return Vector{Union{Missing,ComplexF64}}(missing, rlength(x))
    zs = _complex_values(x, "a complex vector")
    return Union{Missing,ComplexF64}[_isna(z) ? missing : z for z in zs]
end

function from_sexp(::Type{Vector{UInt8}}, x::SEXP)
    _check_type(x, RAWSXP, "a raw vector")
    n = rlength(x)
    out = Vector{UInt8}(undef, n)
    unsafe_copyto!(pointer(out), raw_ptr(x), n)
    return out
end

"""
    RVector{T} <: AbstractVector{T}

In an `@rcall` signature, a read-only view of the data of an R vector, without
copying it: `RVector{Float64}` of a double vector, `RVector{Int32}` of an
integer vector and `RVector{UInt8}` of a raw vector. R's `NA` is not checked
for: it is a NaN in a double vector and `typemin(Int32)` in an integer vector.

The view is valid only until the call that received it returns, so do not keep
it, or anything sharing its memory, past that. Returned, it is the R vector it
views.
"""
struct RVector{T} <: AbstractVector{T}
    sexp::SEXP
    ptr::Ptr{T}
    len::Int
end

Base.size(v::RVector) = (v.len,)
Base.IndexStyle(::Type{<:RVector}) = IndexLinear()
Base.@propagate_inbounds function Base.getindex(v::RVector, i::Int)
    @boundscheck checkbounds(v, i)
    return unsafe_load(v.ptr, i)
end

function _view(x::SEXP, t::Cint, what::String, ptr::F) where {F}
    _check_type(x, t, what)
    return RVector(x, ptr(x), rlength(x))
end

from_sexp(::Type{RVector{Float64}}, x::SEXP) = _view(x, REALSXP, "a double vector", real_ptr)
from_sexp(::Type{RVector{Int32}}, x::SEXP) = _view(x, INTSXP, "an integer vector", int_ptr)
from_sexp(::Type{RVector{UInt8}}, x::SEXP) = _view(x, RAWSXP, "a raw vector", raw_ptr)

# --- Dates and times

# R's `Date` is a double (or integer) vector of days since 1970-01-01, and its
# `POSIXct` a double vector of seconds since 1970-01-01 UTC, whatever its time
# zone.
const _UNIX_DAY = Dates.value(Date(1970))
const _UNIX_MS = Dates.value(DateTime(1970))

_noun(::Type{Date}) = "Date"
_noun(::Type{DateTime}) = "date-time"
_rclasses(::Type{Date}) = ["Date"]
_rclasses(::Type{DateTime}) = ["POSIXct", "POSIXt"]

# A fractional day is floored, as R prints it; seconds are rounded to
# milliseconds, `DateTime`'s precision.
_time(::Type{Date}, v::Float64) = Date(Dates.UTD(_UNIX_DAY + floor(Int64, v)))
_time(::Type{DateTime}, v::Float64) = DateTime(Dates.UTM(_UNIX_MS + round(Int64, 1000 * v)))
_rtime(x::Date) = Float64(Dates.value(x) - _UNIX_DAY)
_rtime(x::DateTime) = (Dates.value(x) - _UNIX_MS) / 1000

# The numbers of the `Date` or `POSIXct` vector `x`, with NA as `NA_REAL`.
function _times(::Type{D}, x::SEXP) where {D}
    what = "a " * _noun(D)
    _inherits(x, _rclasses(D)[1]) || throw(ArgumentError("expected " * what))
    return _numbers(x, what)
end

function _time1(::Type{D}, v::Float64) where {D}
    isfinite(v) || throw(ArgumentError(
        "expected a " * _noun(D) * ", not " * (isnan(v) ? _nan_name(v) : string(v)),
    ))
    return _time(D, v)
end

for D in (Date, DateTime)
    @eval begin
        function from_sexp(::Type{$D}, x::SEXP)
            vs = _times($D, x)
            _check_scalar(x, _noun($D))
            return _time1($D, vs[1])
        end
        function from_sexp(::Type{Union{Missing,$D}}, x::SEXP)
            _all_na(x) && return _missing1(x, _noun($D))
            vs = _times($D, x)
            _check_scalar(x, _noun($D))
            return _isna(vs[1]) ? missing : _time1($D, vs[1])
        end
        from_sexp(::Type{Vector{$D}}, x::SEXP) = $D[_time1($D, v) for v in _times($D, x)]
        function from_sexp(::Type{Vector{Union{Missing,$D}}}, x::SEXP)
            _all_na(x) && return Vector{Union{Missing,$D}}(missing, rlength(x))
            return Union{Missing,$D}[_isna(v) ? missing : _time1($D, v) for v in _times($D, x)]
        end
    end
end

# --- Arrays

function from_sexp(::Type{Array{T,N}}, x::SEXP) where {T,N}
    d = get_attrib(x, @r_global(R_DimSymbol))
    if rtypeof(d) != INTSXP || rlength(d) != N
        throw(ArgumentError(N == 2 ? "expected a matrix" :
                            "expected an array of " * string(N) * " dimensions"))
    end
    p = int_ptr(d)
    dims = ntuple(i -> Int(unsafe_load(p, i)), Val(N))
    return reshape(from_sexp(Vector{T}, x), dims)
end

# --- Lists

# Converts element `i` (0-based) of the list `x`, saying which element an
# error is in.
function _element(::Type{T}, x::SEXP, i::Int, name::String) where {T}
    try
        return from_sexp(T, vector_elt(x, i))
    catch e
        e isa ArgumentError && throw(ArgumentError("element " * name * ": " * _msg(e.msg)))
        rethrow()
    end
end

function from_sexp(::Type{Vector{T}}, x::SEXP) where {T}
    _check_type(x, VECSXP, "a list")
    return T[_element(T, x, i - 1, string(i)) for i = 1:rlength(x)]
end

# Each element is converted with its own type, which the generated code
# resolves statically.
@generated function _tuple(::Type{T}, x::SEXP) where {T<:Tuple}
    elts = [:(_element($(fieldtype(T, i)), x, $(i - 1), $(string(i)))) for i = 1:fieldcount(T)]
    return :(($(elts...),))
end

function from_sexp(::Type{T}, x::SEXP) where {T<:Tuple}
    _check_type(x, VECSXP, "a list")
    n = fieldcount(T)
    rlength(x) == n || throw(ArgumentError("expected a list of length " * string(n)))
    return _tuple(T, x)
end

# The names of the list `x`; `""` for an element without one.
function _list_names(x::SEXP)
    names = get_attrib(x, @r_global(R_NamesSymbol))
    rtypeof(names) == STRSXP || throw(ArgumentError("expected a named list"))
    return _strings(c -> _isna_string(c) ? "" : _text(String, _chars(c)), String, names)
end

# The position (0-based) in the list `x` of each of `fields`, which must be
# all of its names.
function _positions(x::SEXP, fields::NTuple{N,Symbol}) where {N}
    names = rlength(x) == 0 ? String[] : _list_names(x)
    any(isempty, names) && throw(ArgumentError("expected a named list"))
    pos = Vector{Int}(undef, N)
    for (k, field) in enumerate(fields)
        i = findfirst(==(String(field)), names)
        i === nothing &&
            throw(ArgumentError("expected a list with an element `" * String(field) * "`"))
        pos[k] = i - 1
    end
    for (i, name) in enumerate(names)
        i - 1 in pos && continue
        throw(ArgumentError(
            (Symbol(name) in fields ? "duplicate element `" : "unexpected element `") *
            name * "`",
        ))
    end
    return pos
end

@generated function _fields(::Type{NamedTuple{names,T}}, x::SEXP, pos::Vector{Int}) where {names,T}
    elts = [:(_element($(fieldtype(T, i)), x, pos[$i], $("`" * String(names[i]) * "`")))
            for i = 1:fieldcount(T)]
    return :($(NamedTuple{names,T})(($(elts...),)))
end

function from_sexp(::Type{NamedTuple{names,T}}, x::SEXP) where {names,T<:Tuple}
    _check_type(x, VECSXP, "a named list")
    return _fields(NamedTuple{names,T}, x, _positions(x, names))
end

for K in (String, Symbol)
    @eval function from_sexp(::Type{Dict{$K,T}}, x::SEXP) where {T}
        _check_type(x, VECSXP, "a named list")
        out = Dict{$K,T}()
        rlength(x) == 0 && return out
        for (i, name) in enumerate(_list_names(x))
            isempty(name) && throw(ArgumentError("expected a named list"))
            key = $K(name)
            haskey(out, key) && throw(ArgumentError("duplicate element `" * name * "`"))
            out[key] = _element(T, x, i - 1, "`" * name * "`")
        end
        return out
    end
end

# --- Julia -> R --------------------------------------------------------------

"""
    to_sexp(x) -> SEXP

Convert `x` to a new R object. `@rcall` converts each result with it.

Methods are provided for

- `SEXP` (no conversion), `nothing` (`NULL`) and `missing` (`NA`);
- `Bool`, `Int64` and `Float64` (double), `Int32` (integer), `ComplexF64`,
  `String` and `Symbol` (character), `Date` (`Date`) and `DateTime` (`POSIXct`
  in UTC), and vectors of each;
- `Int16`, `Int8` and `UInt16` (integer), and `UInt32`, `Float32` and
  `Float16` (double), and vectors of each;
- `Vector{Union{Missing,T}}`, where `missing` is `NA`, for each `T` above;
- `Vector{UInt8}` (a raw vector) and [`RVector`](@ref) (the R vector it views);
- `Array{T,N}`, including `Matrix{T}` (an R array of `N` dimensions);
- as lists, other vectors and tuples, and, as named lists, named tuples and
  `Dict{String,T}` and `Dict{Symbol,T}` (in the order of their keys);
- [`RDataFrame`](@ref) (a `data.frame`).

Integers become doubles, since R's integers have 32 bits. A binding package
adds methods for its own types.
"""
function to_sexp end

to_sexp(x::SEXP) = x
to_sexp(::Nothing) = nil()
to_sexp(::Missing) = ccall(@R(Rf_ScalarLogical), SEXP, (Cint,), NA_INTEGER)
to_sexp(x::Bool) = ccall(@R(Rf_ScalarLogical), SEXP, (Cint,), x)
to_sexp(x::Int64) = ccall(@R(Rf_ScalarReal), SEXP, (Float64,), Float64(x))
to_sexp(x::Int32) = ccall(@R(Rf_ScalarInteger), SEXP, (Cint,), _rint(x))
to_sexp(x::Float64) = ccall(@R(Rf_ScalarReal), SEXP, (Float64,), x)
to_sexp(x::ComplexF64) = to_sexp([x])
to_sexp(x::Union{String,Symbol}) = to_sexp([x])

# typemin(Int32) is R's NA, so it cannot be returned as a value.
function _rint(x::Int32)
    x == NA_INTEGER &&
        throw(ArgumentError("cannot return -2147483648 to R as an integer, where it is NA"))
    return x
end
to_sexp(x::RVector) = x.sexp

function _fill_strings(f::F, xs) where {F}
    out = protect(alloc(STRSXP, length(xs)))
    for (i, x) in enumerate(xs)
        set_string_elt(out, i - 1, f(x))
    end
    unprotect(1)
    return out
end

to_sexp(xs::Union{Vector{String},Vector{Symbol}}) = _fill_strings(mkchar, xs)
to_sexp(xs::Union{Vector{Union{Missing,String}},Vector{Union{Missing,Symbol}}}) =
    _fill_strings(x -> x === missing ? @r_global(R_NaString) : mkchar(x), xs)

function _fill(t::Cint, ptr::P, xs, f::F) where {P,F}
    out = alloc(t, length(xs))
    p = ptr(out)
    for (i, x) in enumerate(xs)
        unsafe_store!(p, f(x), i)
    end
    return out
end

to_sexp(xs::Vector{Float64}) = _fill(REALSXP, real_ptr, xs, Float64)
to_sexp(xs::Vector{Int64}) = _fill(REALSXP, real_ptr, xs, Float64)
to_sexp(xs::Vector{Int32}) = _fill(INTSXP, int_ptr, xs, _rint)
to_sexp(xs::Vector{Bool}) = _fill(LGLSXP, logical_ptr, xs, Cint)
to_sexp(xs::Vector{ComplexF64}) = _fill(CPLXSXP, complex_ptr, xs, identity)
to_sexp(xs::Vector{UInt8}) = _fill(RAWSXP, raw_ptr, xs, identity)
to_sexp(xs::Vector{Union{Missing,Float64}}) =
    _fill(REALSXP, real_ptr, xs, x -> x === missing ? NA_REAL : x)
to_sexp(xs::Vector{Union{Missing,Int64}}) =
    _fill(REALSXP, real_ptr, xs, x -> x === missing ? NA_REAL : Float64(x))
to_sexp(xs::Vector{Union{Missing,Int32}}) =
    _fill(INTSXP, int_ptr, xs, x -> x === missing ? NA_INTEGER : _rint(x))
to_sexp(xs::Vector{Union{Missing,Bool}}) =
    _fill(LGLSXP, logical_ptr, xs, x -> x === missing ? NA_INTEGER : Cint(x))

# The smaller number types: integers that R's integers hold as integers, the
# rest as doubles. Every value fits, so none is NA.
for (T, t, ptr, R, na) in (
    (Int16, INTSXP, int_ptr, Cint, NA_INTEGER),
    (Int8, INTSXP, int_ptr, Cint, NA_INTEGER),
    (UInt16, INTSXP, int_ptr, Cint, NA_INTEGER),
    (UInt32, REALSXP, real_ptr, Float64, NA_REAL),
    (Float32, REALSXP, real_ptr, Float64, NA_REAL),
    (Float16, REALSXP, real_ptr, Float64, NA_REAL),
)
    @eval begin
        to_sexp(x::$T) = to_sexp([x])
        to_sexp(xs::Vector{$T}) = _fill($t, $ptr, xs, $R)
        to_sexp(xs::Vector{Union{Missing,$T}}) =
            _fill($t, $ptr, xs, x -> x === missing ? $na : $R(x))
    end
end

to_sexp(xs::Vector{Union{Missing,ComplexF64}}) =
    _fill(CPLXSXP, complex_ptr, xs, x -> x === missing ? _NA_COMPLEX : x)

# A `Date` or `POSIXct` vector (in UTC) of the `D`s or `missing`s `xs`.
function _fill_times(::Type{D}, xs) where {D}
    out = protect(_fill(REALSXP, real_ptr, xs, x -> x === missing ? NA_REAL : _rtime(x)))
    set_attrib(out, @r_global(R_ClassSymbol), to_sexp(_rclasses(D)))
    D === DateTime && set_attrib(out, _install("tzone"), to_sexp("UTC"))
    unprotect(1)
    return out
end

for D in (Date, DateTime)
    @eval begin
        to_sexp(x::$D) = to_sexp([x])
        to_sexp(xs::Vector{$D}) = _fill_times($D, xs)
        to_sexp(xs::Vector{Union{Missing,$D}}) = _fill_times($D, xs)
    end
end

function to_sexp(xs::Array{T,N}) where {T,N}
    N == 0 && throw(ArgumentError("cannot return a zero-dimensional array to R"))
    all(<=(typemax(Cint)), size(xs)) ||
        throw(ArgumentError("cannot return an array with a dimension over 2^31 - 1 to R"))
    out = protect(to_sexp(vec(xs)))
    dims = protect(alloc(INTSXP, N))
    for (i, d) in enumerate(size(xs))
        unsafe_store!(int_ptr(dims), Cint(d), i)
    end
    set_attrib(out, @r_global(R_DimSymbol), dims)
    unprotect(2)
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

function to_sexp(d::Dict{<:Union{String,Symbol}})
    keys = sort!(collect(Base.keys(d)))
    out = protect(alloc(VECSXP, length(keys)))
    for (i, k) in enumerate(keys)
        set_vector_elt(out, i - 1, to_sexp(d[k]))
    end
    set_attrib(out, @r_global(R_NamesSymbol), to_sexp(keys))
    unprotect(1)
    return out
end

"""
    data_frame(names::Vector{String}, columns::Vector{SEXP}) -> SEXP

A `data.frame` with the equal-length R vectors `columns`. The columns must be
protected (or reachable from R) until the call returns. For columns whose types
are known when the library is compiled, return an [`RDataFrame`](@ref) instead.
"""
function data_frame(names::Vector{String}, columns::Vector{SEXP})
    n = length(columns) == 0 ? 0 : rlength(columns[1])
    out = protect(alloc(VECSXP, length(columns)))
    for (i, col) in enumerate(columns)
        set_vector_elt(out, i - 1, col)
    end
    set_attrib(out, @r_global(R_NamesSymbol), to_sexp(names))
    _set_frame(out, n)
    unprotect(1)
    return out
end

# Makes the named list `out` a `data.frame` of `n` rows, with compact row names.
function _set_frame(out::SEXP, n::Int)
    n <= typemax(Cint) ||
        throw(ArgumentError("cannot return a data frame of over 2^31 - 1 rows to R"))
    set_attrib(out, @r_global(R_ClassSymbol), to_sexp("data.frame"))
    rownames = protect(alloc(INTSXP, 2))
    unsafe_store!(int_ptr(rownames), typemin(Cint), 1)
    unsafe_store!(int_ptr(rownames), Cint(-n), 2)
    set_attrib(out, @r_global(R_RowNamesSymbol), rownames)
    unprotect(1)
    return nothing
end

# --- Data frames -------------------------------------------------------------

"""
    RDataFrame{names,T}(columns::NamedTuple{names,T})
    RDataFrame(columns::NamedTuple)

A data frame of the equal-length column vectors `columns`, which converts to
and from an R `data.frame` (a tibble is one too). As an argument it must be a
`data.frame` with exactly the columns `names`, in any order; as a result it is
a `data.frame` with compact row names. Each column converts by the usual rules,
so it can be a `Vector{Union{Missing,Float64}}`, a `Vector{Date}`, and so on.

Its columns are its properties, `df.x`, and `NamedTuple(df)` is the named tuple
of them.
"""
struct RDataFrame{names,T<:Tuple}
    columns::NamedTuple{names,T}
    function RDataFrame{names,T}(columns::NamedTuple{names,T}) where {names,T<:Tuple}
        # The columns' types differ, so their lengths are taken by a `map`,
        # which resolves statically, not by indexing them in a loop.
        lengths = Tuple(map(length, columns))
        for i = 2:length(lengths)
            lengths[i] == lengths[1] || throw(DimensionMismatch(
                "the columns of a data frame must have equal lengths, but `" *
                String(names[1]) * "` has " * string(lengths[1]) *
                " and `" * String(names[i]) * "` " * string(lengths[i]),
            ))
        end
        return new{names,T}(columns)
    end
end

RDataFrame(columns::NamedTuple{names,T}) where {names,T<:Tuple} =
    RDataFrame{names,T}(columns)

Base.NamedTuple(df::RDataFrame) = getfield(df, :columns)
Base.getproperty(df::RDataFrame, name::Symbol) = getproperty(NamedTuple(df), name)
Base.propertynames(df::RDataFrame) = propertynames(NamedTuple(df))

function from_sexp(::Type{RDataFrame{names,T}}, x::SEXP) where {names,T<:Tuple}
    rtypeof(x) == VECSXP && _inherits(x, "data.frame") ||
        throw(ArgumentError("expected a data frame"))
    return RDataFrame{names,T}(from_sexp(NamedTuple{names,T}, x))
end

function to_sexp(df::RDataFrame)
    columns = NamedTuple(df)
    out = protect(to_sexp(columns))
    _set_frame(out, length(columns) == 0 ? 0 : length(first(columns)))
    unprotect(1)
    return out
end
