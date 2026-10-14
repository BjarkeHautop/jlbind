# R's C API, called directly: the library is loaded into the R process, so
# every symbol below resolves against the already-loaded libR (`@R`).
#
# R signals allocation failures by longjmp, which must never cross Julia
# frames; the only R calls made here that can do so are allocations, which
# fail only when R is out of memory. Every other failure is a Julia exception,
# which `@rcall` returns to R as a `jlbind_error` object, raised there.

"""
    SEXP

An R object, as R's C API passes it.
"""
const SEXP = Ptr{Cvoid}

const NILSXP = Cint(0)
const LGLSXP = Cint(10)
const INTSXP = Cint(13)
const REALSXP = Cint(14)
const STRSXP = Cint(16)
const VECSXP = Cint(19)
const EXTPTRSXP = Cint(22)
const CE_UTF8 = Cint(1)

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
alloc_matrix(t::Cint, nrow::Integer, ncol::Integer) =
    ccall(@R(Rf_allocMatrix), SEXP, (Cint, Cint, Cint), t, nrow, ncol)

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

set_attrib(x::SEXP, name::SEXP, value::SEXP) =
    ccall(@R(Rf_setAttrib), SEXP, (SEXP, SEXP, SEXP), x, name, value)

# The UTF-8 text of a CHARSXP (an element of a character vector).
_utf8(charsxp::SEXP) = ccall(@R(Rf_translateCharUTF8), Ptr{UInt8}, (SEXP,), charsxp)
_isna_string(charsxp::SEXP) = charsxp == @r_global(R_NaString)

"""
    mkchar(s::Union{String,Symbol}) -> SEXP

The R string (CHARSXP) for `s`, an element for `set_string_elt`. Strings of
symbols are cached: R hashes every string it makes, which dominates the cost
of returning many names, while a symbol is looked up here by identity.
"""
mkchar(s::String) = GC.@preserve s _mkchar(pointer(s), sizeof(s))
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
