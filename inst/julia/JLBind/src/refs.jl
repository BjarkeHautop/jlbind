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

"""
    r_saved_by(T) -> Union{String,Nothing}

The name of the R package whose entrypoints return references to objects of type
`T`, which can then be saved with `saveRDS()`, `save()` or `serialize()`, or
`nothing` (the default) if they can't. R writes an external pointer as a null pointer, so a reference alone
loses its object. Define a method, along with [`r_restore`](@ref), and an R
function `.jlbind_saved_state(x)` in that package's `R/` code, with no need to
export it, that returns plain R data, a list, to rebuild `x` from:

```julia
JLBind.r_saved_by(::Type{Model}) = "mypackage"
JLBind.r_restore(::Type{Model}, state::SEXP) =
    Model(from_sexp(NamedTuple{(:weights,),Tuple{Vector{Float64}}}, state).weights)
```

```r
.jlbind_saved_state <- function(x) list(weights = model_weights(x))
```

Each reference then holds a small hook, an ALTREP vector, costing about 400 ns to
create; `.jlbind_saved_state()` only runs if the reference is saved. Loading
stores the state, and the first entrypoint that receives the reference rebuilds
the object, in place, so every copy of the reference gets it. `saveRDS(version =
2)` has no ALTREP support and writes no state.

"""
r_saved_by(::Type) = nothing

"""
    r_restore(T, state::SEXP) -> T

Rebuild an object of type `T` from the list `.jlbind_saved_state()` returned;
see [`r_saved_by`](@ref). It should check any version the state records, as the
state may come from another version of the package.
"""
function r_restore end

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

function _finalizer()
    if _FINALIZER[] == C_NULL
        _FINALIZER[] = @cfunction(_finalize, Cvoid, (SEXP,))
    end
    return _FINALIZER[]
end

function _register_finalizer(x::SEXP)
    ccall(@R(R_RegisterCFinalizerEx), Cvoid, (SEXP, Ptr{Cvoid}, Cint), x, _finalizer(), 1)
end

# The attribute that holds a reference's hook, and after loading its state. An
# attribute rather than the pointer's protected value, since identical() only
# compares the addresses of external pointers, which are all null after loading,
# but does compare attributes.
const _STATE_SYMBOL = Ref{SEXP}(C_NULL)

function _state_symbol()
    if _STATE_SYMBOL[] == C_NULL
        _STATE_SYMBOL[] = _install("jlbind_state")
    end
    return _STATE_SYMBOL[]
end

# The routine of the jlbind R package (src/state.c) making the hook of a reference.
# Looked up when first needed, as binding a package must not start Julia. jlbind
# is always loaded by then, as it is what loads this library.
const _STATE_HOOK = Ref{Ptr{Cvoid}}(C_NULL)

function _state_hook()
    if _STATE_HOOK[] == C_NULL
        _STATE_HOOK[] = ccall(
            @R(R_GetCCallable), Ptr{Cvoid}, (Cstring, Cstring),
            "jlbind", "jlbind_state_hook",
        )
    end
    return _STATE_HOOK[]
end

function _ref_sexp(@nospecialize(x), class::String, package::Union{String,Nothing})
    h = _store(x)
    out = protect(ccall(
        @R(R_MakeExternalPtr), SEXP, (Ptr{Cvoid}, SEXP, SEXP),
        Ptr{Cvoid}(UInt(h)), _tag(), nil(),
    ))
    _register_finalizer(out)
    if package !== nothing
        hook = ccall(_state_hook(), SEXP, (SEXP, SEXP), out, _class_sexp(package))
        set_attrib(out, _state_symbol(), hook)
    end
    set_attrib(out, @r_global(R_ClassSymbol), _class_sexp(class))
    unprotect(1)
    return out
end

# A reference with no object: one R has just loaded, whose address is null.
# Rebuilds the object from the saved state, if the type can be saved.
function _restored(::Type{T}, x::SEXP, class::String)::T where {T}
    saved = r_saved_by(T) !== nothing && _address(x) == 0 && _inherits(x, class)
    state = saved ? get_attrib(x, _state_symbol()) : nil()
    # The shim writes the state inside a list of length one.
    if rtypeof(state) == VECSXP && rlength(state) == 1
        obj = r_restore(T, vector_elt(state, 0))::T
        ccall(
            @R(R_SetExternalPtrAddr), Cvoid, (SEXP, Ptr{Cvoid}),
            x, Ptr{Cvoid}(UInt(_store(obj))),
        )
        _register_finalizer(x)
        return obj
    end
    saved && throw(ArgumentError(
        "this `" * class * "` object was saved without its contents, probably " *
        "with `saveRDS(version = 2)`, which can't store it",
    ))
    throw(ArgumentError(
        "this `" * class * "` object no longer exists; objects do not " *
        "survive saving and reloading, or a restart of R",
    ))
end

function from_sexp(::Type{RRef{T}}, x::SEXP)::T where {T}
    class = r_class(T)
    if rtypeof(x) != EXTPTRSXP ||
       ccall(@R(R_ExternalPtrTag), SEXP, (SEXP,), x) != _tag()
        throw(ArgumentError("expected a `" * class * "` object"))
    end
    obj = get(OBJECTS, _address(x), nothing)
    obj === nothing && return _restored(T, x, class)
    obj isa T || throw(ArgumentError("expected a `" * class * "` object"))
    return obj
end

# A list of references, as the `T`s they refer to.
function from_sexp(::Type{Vector{RRef{T}}}, x::SEXP) where {T}
    _check_type(x, VECSXP, "a list")
    return T[_element(RRef{T}, x, i - 1, string(i)) for i = 1:rlength(x)]
end

# Converts the result of an entrypoint declared to return `R`.
_result(::Type{RRef{T}}, x) where {T} = _ref_sexp(x::T, r_class(T), r_saved_by(T))

function _result(::Type{Vector{RRef{T}}}, xs) where {T}
    class = r_class(T)
    package = r_saved_by(T)
    out = protect(alloc(VECSXP, length(xs)))
    for (i, x) in enumerate(xs::AbstractVector{<:T})
        set_vector_elt(out, i - 1, _ref_sexp(x, class, package))
    end
    unprotect(1)
    return out
end

# `missing` declared as a `Union{Missing,T}` is the NA of `T`'s R type.
_result(::Type{Union{Missing,T}}, x) where {T<:Union{_Real,Bool,String,Symbol,ComplexF64,Date,DateTime}} =
    to_sexp(Union{Missing,T}[x])

_result(::Type{R}, x) where {R} = to_sexp(x::R)
