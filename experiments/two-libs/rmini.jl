# Minimal subset of CausalStructures' rapi.jl for the experiment.
const SEXP = Ptr{Cvoid}
const REALSXP = Cint(14)
const STRSXP = Cint(16)
_length(x::SEXP) = ccall(:Rf_xlength, Int, (SEXP,), x)
_real_ptr(x::SEXP) = ccall(:REAL, Ptr{Float64}, (SEXP,), x)
_scalar_real(x::Float64) = ccall(:Rf_ScalarReal, SEXP, (Float64,), x)
function _string(s::String)
    out = ccall(:Rf_protect, SEXP, (SEXP,), ccall(:Rf_allocVector, SEXP, (Cint, Int), STRSXP, 1))
    c = GC.@preserve s ccall(:Rf_mkCharLenCE, SEXP, (Ptr{UInt8}, Cint, Cint), pointer(s), sizeof(s), 1)
    ccall(:SET_STRING_ELT, Cvoid, (SEXP, Int, SEXP), out, 0, c)
    ccall(:Rf_unprotect, Cvoid, (Cint,), 1)
    return out
end
_utf8(x::SEXP) = unsafe_string(ccall(:Rf_translateCharUTF8, Ptr{UInt8}, (SEXP,),
    ccall(:STRING_ELT, SEXP, (SEXP, Int), x, 0)))
