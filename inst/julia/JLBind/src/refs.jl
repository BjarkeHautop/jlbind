# Julia objects that cannot cross into R as values live in a registry here, and
# R holds an external pointer whose address is the object's handle, tagged so
# that a foreign external pointer is never taken for one, with a C finalizer
# that releases the handle. One registry serves every binding package.

"""
    RRef{T}

In an `@rcall` signature, a Julia object of type `T` held by R as an external
pointer. As an argument type, `f` is passed the `T` the pointer refers to (or,
for `Vector{RRef{T}}`, a `Vector{T}` from a list of them); as the result type
(or `Vector{RRef{T}}`, a list of them), the `T` that `f` returns is stored and R gets an external pointer to it, with class
[`r_class(T)`](@ref r_class). The object is released when R garbage-collects
the pointer.

If `T` is abstract, `f` must not specialize on the argument:
`f(@nospecialize(x::T))`. A call with an abstractly typed argument stays
dynamic otherwise, which `--trim` rejects ("unresolved call"); inside `f`,
branch on the concrete types (`x isa A`) to get statically resolved calls.
"""
struct RRef{T} end

"""
    r_class(T) -> String

The R class of the external pointers to objects of type `T` (see
[`RRef`](@ref)). Define a method for each type a binding package hands to R,
e.g. `JLBind.r_class(::Type{<:Model}) = "mymodel"`; the default is
`"jlbind_ref"`.
"""
r_class(::Type) = "jlbind_ref"

const OBJECTS = Dict{Int64,Any}()
const NEXT_HANDLE = Ref{Int64}(0)

# Handles released by R finalizers, dropped on the next store. A finalizer can
# run while an entrypoint is mid-call (any R allocation can run R's GC), so it
# never touches `OBJECTS`.
const RELEASED = Int64[]

function _store(@nospecialize(x))::Int64
    for h in RELEASED
        delete!(OBJECTS, h)
    end
    empty!(RELEASED)
    NEXT_HANDLE[] += 1
    OBJECTS[NEXT_HANDLE[]] = x
    return NEXT_HANDLE[]
end

"""
    object_count() -> Int64

The number of Julia objects R currently holds through [`RRef`](@ref)s.
"""
object_count() = Int64(length(OBJECTS) - length(RELEASED))

# Created on first use: a function pointer, or an R object, cannot be baked
# into the compiled image.
const _FINALIZER = Ref{Ptr{Cvoid}}(C_NULL)
const _TAG = Ref{SEXP}(C_NULL)
const _CLASSES = Dict{String,SEXP}()

function _tag()
    if _TAG[] == C_NULL
        # A symbol, which R never collects.
        _TAG[] = ccall(@R(Rf_install), SEXP, (Cstring,), "jlbind_ref")
    end
    return _TAG[]
end

_address(x::SEXP) = Int64(UInt(ccall(@R(R_ExternalPtrAddr), Ptr{Cvoid}, (SEXP,), x)))

function _finalize(x::SEXP)::Cvoid
    h = _address(x)
    h == 0 || push!(RELEASED, h)
    ccall(@R(R_ClearExternalPtr), Cvoid, (SEXP,), x)
    return nothing
end

function _class_sexp(class::String)
    c = get(_CLASSES, class, C_NULL)
    c == C_NULL || return c
    c = preserve(to_sexp(class))
    _CLASSES[class] = c
    return c
end

function _ref_sexp(@nospecialize(x), class::String)
    if _FINALIZER[] == C_NULL
        _FINALIZER[] = @cfunction(_finalize, Cvoid, (SEXP,))
    end
    h = _store(x)
    out = protect(ccall(
        @R(R_MakeExternalPtr), SEXP, (Ptr{Cvoid}, SEXP, SEXP),
        Ptr{Cvoid}(UInt(h)), _tag(), nil(),
    ))
    ccall(@R(R_RegisterCFinalizerEx), Cvoid, (SEXP, Ptr{Cvoid}, Cint), out, _FINALIZER[], 1)
    set_attrib(out, @r_global(R_ClassSymbol), _class_sexp(class))
    unprotect(1)
    return out
end

function from_sexp(::Type{RRef{T}}, x::SEXP)::T where {T}
    class = r_class(T)
    if rtypeof(x) != EXTPTRSXP ||
       ccall(@R(R_ExternalPtrTag), SEXP, (SEXP,), x) != _tag()
        throw(ArgumentError("expected a `" * class * "` object"))
    end
    obj = get(OBJECTS, _address(x), nothing)
    if obj === nothing
        throw(ArgumentError(
            "this `" * class * "` object no longer exists; objects do not " *
            "survive saving and reloading, or a restart of R",
        ))
    end
    obj isa T || throw(ArgumentError("expected a `" * class * "` object"))
    return obj
end

# A list of references, as the `T`s they refer to.
function from_sexp(::Type{Vector{RRef{T}}}, x::SEXP) where {T}
    _check_type(x, VECSXP, "a list")
    return T[_element(RRef{T}, x, i - 1, string(i)) for i = 1:rlength(x)]
end

# Converts the result of an entrypoint declared to return `R`.
_result(::Type{RRef{T}}, x) where {T} = _ref_sexp(x::T, r_class(T))

function _result(::Type{Vector{RRef{T}}}, xs) where {T}
    class = r_class(T)
    out = protect(alloc(VECSXP, length(xs)))
    for (i, x) in enumerate(xs::AbstractVector{<:T})
        set_vector_elt(out, i - 1, _ref_sexp(x, class))
    end
    unprotect(1)
    return out
end

# `missing` declared as a `Union{Missing,T}` is the NA of `T`'s R type.
_result(::Type{Union{Missing,T}}, x) where {T<:Union{_Real,Bool,String,Symbol,ComplexF64,Date,DateTime}} =
    to_sexp(Union{Missing,T}[x])

_result(::Type{R}, x) where {R} = to_sexp(x::R)
