# R's C API, called directly: the library is loaded into the R process, so
# every symbol below resolves against the already-loaded libR (`@R`).
#
# R signals errors (and warnings, under `options(warn = 2)`) by longjmp, which
# must never cross Julia frames: Julia's state is left corrupt, and R crashes
# on the next Julia exception. So R functions that can raise one are only
# called once their arguments are checked (e.g. `STRING_ELT` on a character
# vector, `Rf_translateCharUTF8` on a string not in "bytes" encoding,
# `Rf_mkCharLenCE` on a string without NUL), and never R's coercions
# (`Rf_asReal` and the like). What is left are allocations, which fail only
# when R is out of memory. Every other failure is a Julia exception, which
# `@rcall` returns to R as a `jlbind_error` object, raised there.

"""
    SEXP

An R object, as R's C API passes it. Declare an entrypoint to return `SEXP` to
build its result yourself.
"""
const SEXP = Ptr{Cvoid}

"""
    NILSXP, LGLSXP, INTSXP, REALSXP, CPLXSXP, STRSXP, VECSXP, EXTPTRSXP, RAWSXP

R's object types, as [`rtypeof`](@ref) returns them and [`alloc`](@ref) takes
them: `NULL`, logical, integer, double, complex, character and raw vectors, a
list, and an external pointer.
"""
const NILSXP = Cint(0)
const LGLSXP = Cint(10)
const INTSXP = Cint(13)
const REALSXP = Cint(14)
const CPLXSXP = Cint(15)
const STRSXP = Cint(16)
const VECSXP = Cint(19)
const EXTPTRSXP = Cint(22)
const RAWSXP = Cint(24)
for t in (:LGLSXP, :INTSXP, :REALSXP, :CPLXSXP, :STRSXP, :VECSXP, :EXTPTRSXP, :RAWSXP)
    @eval @doc (@doc NILSXP) $t
end
const CE_UTF8 = Cint(1)
const CE_BYTES = Cint(3)

"""
    NA_INTEGER, NA_REAL

R's `NA` in an integer or logical vector, and in a double vector.
"""
const NA_INTEGER = typemin(Cint)
const NA_REAL = reinterpret(Float64, 0x7ff00000000007a2)
@doc (@doc NA_INTEGER) NA_REAL

"""
    @R(name)

A function or variable of R's C API, for `ccall` or `cglobal`:

```julia
ccall(@R(Rf_xlength), Int, (SEXP,), x)
```
"""
macro R(name)
    return Sys.iswindows() ? :(($(QuoteNode(name)), "R.dll")) : QuoteNode(name)
end

"""
    @r_global(name)

The value of one of R's global `SEXP` variables, such as
`@r_global(R_NaString)`.
"""
macro r_global(name)
    return :(unsafe_load(cglobal(@R($name), SEXP)))
end

"""
    nil() -> SEXP

R's `NULL`.
"""
nil() = @r_global(R_NilValue)
"""
    rtypeof(x::SEXP) -> Cint
    rlength(x::SEXP) -> Int

The type of `x` (such as [`REALSXP`](@ref NILSXP)), and its length.
"""
rtypeof(x::SEXP) = ccall(@R(TYPEOF), Cint, (SEXP,), x)
rlength(x::SEXP) = ccall(@R(Rf_xlength), Int, (SEXP,), x)
@doc (@doc rtypeof) rlength

"""
    protect(x::SEXP) -> x
    unprotect(n)

Keep `x` from R's garbage collector while you allocate other R objects, and
release the last `n` objects protected, before returning. These are R's
`PROTECT` and `UNPROTECT`.
"""
protect(x::SEXP) = ccall(@R(Rf_protect), SEXP, (SEXP,), x)
unprotect(n::Integer) = ccall(@R(Rf_unprotect), Cvoid, (Cint,), n)
@doc (@doc protect) unprotect

"""
    preserve(x::SEXP) -> x
    release(x::SEXP)

Keep `x` alive across calls, until it is released.
"""
preserve(x::SEXP) = (ccall(@R(R_PreserveObject), Cvoid, (SEXP,), x); x)
release(x::SEXP) = ccall(@R(R_ReleaseObject), Cvoid, (SEXP,), x)
@doc (@doc preserve) release

"""
    alloc(t, n) -> SEXP
    alloc_matrix(t, nrow, ncol) -> SEXP

A new R vector of type `t` and length `n`, or matrix of `nrow` rows and `ncol`
columns, to fill in. [`protect`](@ref) it before allocating anything else.
"""
alloc(t::Cint, n::Integer) = ccall(@R(Rf_allocVector), SEXP, (Cint, Int), t, n)

function alloc_matrix(t::Cint, nrow::Integer, ncol::Integer)
    # R raises an R error for a dimension beyond an `int`.
    0 <= nrow <= typemax(Cint) && 0 <= ncol <= typemax(Cint) ||
        throw(ArgumentError("cannot return a matrix with a dimension over 2^31 - 1 to R"))
    return ccall(@R(Rf_allocMatrix), SEXP, (Cint, Cint, Cint), t, nrow, ncol)
end
@doc (@doc alloc) alloc_matrix

"""
    string_elt(x::SEXP, i) -> SEXP
    set_string_elt(x::SEXP, i, v::SEXP)
    vector_elt(x::SEXP, i) -> SEXP
    set_vector_elt(x::SEXP, i, v::SEXP)

Get and set element `i` of a character vector or list. Indices start at 0, as
in C, and aren't checked. Make an element of a character vector with
[`mkchar`](@ref).
"""
string_elt(x::SEXP, i::Integer) = ccall(@R(STRING_ELT), SEXP, (SEXP, Int), x, i)
set_string_elt(x::SEXP, i::Integer, v::SEXP) =
    ccall(@R(SET_STRING_ELT), Cvoid, (SEXP, Int, SEXP), x, i, v)
vector_elt(x::SEXP, i::Integer) = ccall(@R(VECTOR_ELT), SEXP, (SEXP, Int), x, i)
set_vector_elt(x::SEXP, i::Integer, v::SEXP) =
    ccall(@R(SET_VECTOR_ELT), SEXP, (SEXP, Int, SEXP), x, i, v)
for f in (:set_string_elt, :vector_elt, :set_vector_elt)
    @eval @doc (@doc string_elt) $f
end

"""
    real_ptr(x::SEXP) -> Ptr{Float64}
    int_ptr(x::SEXP) -> Ptr{Cint}
    logical_ptr(x::SEXP) -> Ptr{Cint}
    complex_ptr(x::SEXP) -> Ptr{ComplexF64}
    raw_ptr(x::SEXP) -> Ptr{UInt8}

A pointer to the data of a double, integer, logical, complex or raw vector, to
read with `unsafe_load` or fill with `unsafe_store!`. The type of `x` isn't
checked.
"""
real_ptr(x::SEXP) = ccall(@R(REAL), Ptr{Float64}, (SEXP,), x)
int_ptr(x::SEXP) = ccall(@R(INTEGER), Ptr{Cint}, (SEXP,), x)
logical_ptr(x::SEXP) = ccall(@R(LOGICAL), Ptr{Cint}, (SEXP,), x)
complex_ptr(x::SEXP) = ccall(@R(COMPLEX), Ptr{ComplexF64}, (SEXP,), x)
raw_ptr(x::SEXP) = ccall(@R(RAW), Ptr{UInt8}, (SEXP,), x)
for f in (:int_ptr, :logical_ptr, :complex_ptr, :raw_ptr)
    @eval @doc (@doc real_ptr) $f
end

"""
    get_attrib(x::SEXP, name::SEXP) -> SEXP
    set_attrib(x::SEXP, name::SEXP, value::SEXP)

Get and set the attribute `name` of `x`, where `name` is an R symbol such as
`@r_global(R_NamesSymbol)`. A missing attribute is `NULL`.
"""
get_attrib(x::SEXP, name::SEXP) = ccall(@R(Rf_getAttrib), SEXP, (SEXP, SEXP), x, name)
set_attrib(x::SEXP, name::SEXP, value::SEXP) =
    ccall(@R(Rf_setAttrib), SEXP, (SEXP, SEXP, SEXP), x, name, value)
@doc (@doc get_attrib) set_attrib

# The UTF-8 text of a CHARSXP (an element of a character vector).
_utf8(charsxp::SEXP) = ccall(@R(Rf_translateCharUTF8), Ptr{UInt8}, (SEXP,), charsxp)
_isna_string(charsxp::SEXP) = charsxp == @r_global(R_NaString)
_isbytes(charsxp::SEXP) = ccall(@R(Rf_getCharCE), Cint, (SEXP,), charsxp) == CE_BYTES
_inherits(x::SEXP, class::String) =
    ccall(@R(Rf_inherits), Cint, (SEXP, Cstring), x, class) != 0
# A symbol, which R never collects.
_install(name::String) = ccall(@R(Rf_install), SEXP, (Cstring,), name)

"""
    mkchar(s::Union{String,Symbol}) -> SEXP

An R string, the element of a character vector. Strings of symbols are cached,
which makes returning many names faster.
"""
function mkchar(s::String)
    # R strings cannot hold NUL; R would raise an R error.
    occursin('\0', s) && throw(ArgumentError("cannot return a string containing NUL to R"))
    return GC.@preserve s _mkchar(pointer(s), sizeof(s))
end
_mkchar(p::Ptr{UInt8}, n::Integer) =
    ccall(@R(Rf_mkCharLenCE), SEXP, (Ptr{UInt8}, Cint, Cint), p, n, CE_UTF8)

const _CHARSXPS = Dict{Symbol,SEXP}()
const _CHARSXP_CAP = 1_000_000

function mkchar(s::Symbol)
    c = get(_CHARSXPS, s, C_NULL)
    c == C_NULL || return c
    c = ccall(@R(Rf_mkCharCE), SEXP, (Ptr{UInt8}, Cint), s, CE_UTF8)
    length(_CHARSXPS) < _CHARSXP_CAP || return c
    protect(c)
    preserve(c)
    unprotect(1)
    _CHARSXPS[s] = c
    return c
end

# A symbol from a C string, without going through `String`.
_symbol(p::Ptr{UInt8}) = ccall(:jl_symbol, Ref{Symbol}, (Ptr{UInt8},), p)
