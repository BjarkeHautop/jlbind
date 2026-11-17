"""
    @rcall f(arg::T, ...)::R

Make `f` callable from R. `jlbind::update_entrypoints()` writes a matching R
function for each `@rcall`.

```julia
greet(name) = "Hello, " * name * "!"

@rcall greet(name::String)::String
```

Every argument and the return value need a type, which decides how they are
converted (see [`from_sexp`](@ref) and [`to_sexp`](@ref)). Use
[`RRef{T}`](@ref RRef) to give R a Julia object by reference. An argument of
type `Union{Nothing,T}` accepts `NULL`, and `Union{Missing,T}` accepts `NA`.

An argument can have a default, which the R function gets too: a number,
string, `true`, `false`, `missing` (`NA`), `nothing` (`NULL`), or a vector of
these such as `[1, 2]`.

If `f` throws, R gets an error. The message of an `ArgumentError`, `error()` and
a few other common exceptions is passed on; others get a generic message.

Write each `@rcall` at the top level of a file, as `update_entrypoints()` reads
the source.
"""
macro rcall(sig)
    Meta.isexpr(sig, :(::)) || error("@rcall needs a return type: @rcall f(...)::R")
    call, R = sig.args
    Meta.isexpr(call, :call) || error("@rcall needs a call signature: @rcall f(...)::R")
    fname = call.args[1]
    fname isa Symbol || error("@rcall needs a plain function name, not $fname")
    argnames = Symbol[]
    argtypes = Any[]
    for a in call.args[2:end]
        if Meta.isexpr(a, :kw)
            # A default is used only by the generated R wrapper, which always
            # passes every argument.
            a, default = a.args
            _literal_default(default) ||
                error("@rcall: the default of $a must be a literal number, " *
                      "string, true, false, missing or nothing, or a vector " *
                      "of these such as [1, 2] or Float64[]")
        end
        Meta.isexpr(a, :(::)) && length(a.args) == 2 ||
            error("@rcall needs every argument typed: $a")
        push!(argnames, a.args[1])
        push!(argtypes, a.args[2])
    end
    prefix = nameof(Base.moduleroot(__module__))
    cname = Symbol(prefix, :_, fname)
    nargs = length(argnames)
    from = GlobalRef(JLBind, :from_sexp)
    args = gensym("args")
    n = gensym("n")
    vals = [gensym(string(a)) for a in argnames]
    converted = [:($(vals[i]) = $from($T, unsafe_load($args, $i)))
                 for (i, T) in enumerate(argtypes)]
    # A call with more than a few union-typed arguments is not union-split, and
    # so stays dynamic, which `--trim` rejects. So the call is made in a branch
    # per `nothing` or `missing` an argument can be, where its type is known.
    body = :(return $(GlobalRef(JLBind, :_result))($R, $fname($(vals...))))
    for (v, T) in zip(vals, argtypes)
        for s in (:Nothing, :Missing)
            if _union_with(T, s)
                body = :(if $v === $(s === :Nothing ? :nothing : :missing)
                    $body
                else
                    $body
                end)
            end
        end
    end
    on_error = GlobalRef(JLBind, :_error_sexp)
    wrong = "$fname() takes $nargs argument$(nargs == 1 ? "" : "s"), but was given "
    return esc(quote
        Base.@ccallable function $cname($args::Ptr{$SEXP}, $n::Cint)::$SEXP
            try
                $n == $nargs || throw(ArgumentError(string($wrong, $n)))
                $(converted...)
                $body
            catch e
                return $on_error(e)
            end
        end
    end)
end

# Whether the type expression `T` is a `Union{...}` with the member `s`.
_union_with(T, s::Symbol) =
    Meta.isexpr(T, :curly) && T.args[1] in (:Union, :(Base.Union)) &&
    any(a -> a === s || a == :(Base.$s), T.args[2:end])

# The defaults `@rcall` accepts, which the R package's `update_entrypoints()`
# translates to R: a literal number, string, `true`, `false`, `missing` or
# `nothing`, or a vector of these (other than `nothing`), `[1, 2]` or
# `T[1, 2]`, where an empty one names its element type, `T[]`.
const _DEFAULT_ELTYPES = (:String, :Symbol, :Float64, :Float32, :Float16,
    :Int64, :UInt32, :Int32, :Int16, :Int8, :UInt16, :Bool, :ComplexF64, :UInt8)

_scalar_default(x) = x isa Union{Number,String} || x === :missing
_literal_default(x) =
    _scalar_default(x) || x === :nothing ||
    (Meta.isexpr(x, :vect) && !isempty(x.args) && all(_scalar_default, x.args)) ||
    (Meta.isexpr(x, :ref) && x.args[1] in _DEFAULT_ELTYPES &&
     all(_scalar_default, x.args[2:end]))

function _error_sexp(@nospecialize(e))
    out = protect(to_sexp(_error_message(e)))
    set_attrib(out, @r_global(R_ClassSymbol), _class_sexp("jlbind_error"))
    unprotect(1)
    return out
end

function _error_message(@nospecialize(e))::String
    e isa ArgumentError && return _msg(e.msg)
    e isa ErrorException && return _msg(e.msg)
    e isa DimensionMismatch && return _msg(e.msg)
    e isa OverflowError && return _msg(e.msg)
    e isa AssertionError && return _msg(e.msg)
    e isa KeyError && return "key not found"
    e isa BoundsError && return "index out of bounds"
    e isa DomainError && return "domain error"
    e isa InexactError && return "inexact conversion"
    e isa DivideError && return "integer division error"
    e isa OutOfMemoryError && return "out of memory"
    e isa StackOverflowError && return "stack overflow"
    return "internal error in the compiled Julia library"
end

_msg(@nospecialize(m::AbstractString))::String = m isa String ? m : "error"

# The library's own entrypoints, for the jlbind R package.
@rcall object_count()::Int64
