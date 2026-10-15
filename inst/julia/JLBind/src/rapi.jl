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

An R object, as R's C API passes it.
"""
const SEXP = Ptr{Cvoid}

const NILSXP = Cint(0)
const LGLSXP = Cint(10)
const INTSXP = Cint(13)
const REALSXP = Cint(14)
const CPLXSXP = Cint(15)
const STRSXP = Cint(16)
const VECSXP = Cint(19)
const EXTPTRSXP = Cint(22)
const RAWSXP = Cint(24)
const CE_UTF8 = Cint(1)
const CE_BYTES = Cint(3)

# R's NA in an integer or logical vector, and in a double vector: a NaN whose
# low word is 1954 (what `R_IsNA` checks).
const NA_INTEGER = typemin(Cint)
const NA_REAL = reinterpret(Float64, 0x7ff00000000007a2)

"""
    @R(name)

The `ccall`/`cglobal` target for R's symbol `name`, e.g.
`ccall(@R(Rf_xlength), Int, (SEXP,), x)`. On Windows a `ccall` without a
library only searches Julia's own DLLs, so R's symbols are looked up in
`R.dll`, which is already loaded into the process.
"""
macro R(name)
    return Sys.iswindows() ? :(($(QuoteNode(name)), "R.dll")) : QuoteNode(name)
end

"""
    @r_global(name)

The value of R's global `SEXP` `name`, e.g. `@r_global(R_ClassSymbol)`.
"""
macro r_global(name)
    return :(unsafe_load(cglobal(@R($name), SEXP)))
end

nil() = @r_global(R_NilValue)
rtypeof(x::SEXP) = ccall(@R(TYPEOF), Cint, (SEXP,), x)
rlength(x::SEXP) = ccall(@R(Rf_xlength), Int, (SEXP,), x)

"""
    protect(x::SEXP) -> x
    unprotect(n)

R's `PROTECT` and `UNPROTECT`: an object allocated by R and not yet reachable
from R must be protected while anything else is allocated.
"""
protect(x::SEXP) = ccall(@R(Rf_protect), SEXP, (SEXP,), x)
unprotect(n::Integer) = ccall(@R(Rf_unprotect), Cvoid, (Cint,), n)

"""
    preserve(x::SEXP) -> x
    release(x::SEXP)

Keep `x` alive across calls (`R_PreserveObject`), until released.
"""
preserve(x::SEXP) = (ccall(@R(R_PreserveObject), Cvoid, (SEXP,), x); x)
release(x::SEXP) = ccall(@R(R_ReleaseObject), Cvoid, (SEXP,), x)

alloc(t::Cint, n::Integer) = ccall(@R(Rf_allocVector), SEXP, (Cint, Int), t, n)

# Element accessors take 0-based indices, as in C.
string_elt(x::SEXP, i::Integer) = ccall(@R(STRING_ELT), SEXP, (SEXP, Int), x, i)
set_string_elt(x::SEXP, i::Integer, v::SEXP) =
    ccall(@R(SET_STRING_ELT), Cvoid, (SEXP, Int, SEXP), x, i, v)
vector_elt(x::SEXP, i::Integer) = ccall(@R(VECTOR_ELT), SEXP, (SEXP, Int), x, i)
set_vector_elt(x::SEXP, i::Integer, v::SEXP) =
    ccall(@R(SET_VECTOR_ELT), SEXP, (SEXP, Int, SEXP), x, i, v)

real_ptr(x::SEXP) = ccall(@R(REAL), Ptr{Float64}, (SEXP,), x)
int_ptr(x::SEXP) = ccall(@R(INTEGER), Ptr{Cint}, (SEXP,), x)
logical_ptr(x::SEXP) = ccall(@R(LOGICAL), Ptr{Cint}, (SEXP,), x)
complex_ptr(x::SEXP) = ccall(@R(COMPLEX), Ptr{ComplexF64}, (SEXP,), x)
raw_ptr(x::SEXP) = ccall(@R(RAW), Ptr{UInt8}, (SEXP,), x)

get_attrib(x::SEXP, name::SEXP) = ccall(@R(Rf_getAttrib), SEXP, (SEXP, SEXP), x, name)
set_attrib(x::SEXP, name::SEXP, value::SEXP) =
    ccall(@R(Rf_setAttrib), SEXP, (SEXP, SEXP, SEXP), x, name, value)

# The UTF-8 text of a CHARSXP (an element of a character vector).
_utf8(charsxp::SEXP) = ccall(@R(Rf_translateCharUTF8), Ptr{UInt8}, (SEXP,), charsxp)
_isna_string(charsxp::SEXP) = charsxp == @r_global(R_NaString)
_isbytes(charsxp::SEXP) = ccall(@R(Rf_getCharCE), Cint, (SEXP,), charsxp) == CE_BYTES
_inherits(x::SEXP, class::String) = ccall(@R(Rf_inherits), Cint, (SEXP, Cstring), x, class) != 0
# A symbol, which R never collects.
_install(name::String) = ccall(@R(Rf_install), SEXP, (Cstring,), name)

"""
    mkchar(s::Union{String,Symbol}) -> SEXP

The R string (CHARSXP) for `s`, an element for `set_string_elt`. Strings of
symbols are cached: R hashes every string it makes, which dominates the cost
of returning many names, while a symbol is looked up here by identity.
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
