"""
    @rcall f(a::A, b::B, ...)::R

Export the R entrypoint `<module>_f(a::SEXP, b::SEXP, ...)::SEXP`, where
`<module>` is the name of the binding package the declaration is in. It
converts each argument with `from_sexp(A, a)`, calls `f`, and converts the
result with `to_sexp(::R)`; an argument or result type `RRef{T}` passes a
Julia object by reference instead (see [`RRef`](@ref)). The compiled library
can only call `f` statically if each argument type it receives is concrete, or
is `@nospecialize`d in `f`'s signature.

R must never unwind through Julia frames, so an entrypoint does not raise an R
error: a Julia exception is returned as a character vector of class
`jlbind_error`, which the client package's C shim raises once the call has
returned. The message of an `ArgumentError`, `ErrorException`,
`DimensionMismatch`, `OverflowError` or `AssertionError` is passed on;
any other exception is summarized, since rendering an arbitrary exception
needs a call the compiler cannot resolve.

The jlbind R package's `update_entrypoints()` reads these declarations to
generate the client's C shim, so declare each entrypoint with a literal
`@rcall` at the top level of the binding package's source files.
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
        Meta.isexpr(a, :(::)) && length(a.args) == 2 ||
            error("@rcall needs every argument typed: $a")
        push!(argnames, a.args[1])
        push!(argtypes, a.args[2])
    end
    prefix = nameof(Base.moduleroot(__module__))
    cname = Symbol(prefix, :_, fname)
    from = GlobalRef(JLBind, :from_sexp)
    params = [:($n::$SEXP) for n in argnames]
    converted = [:($from($T, $n)) for (n, T) in zip(argnames, argtypes)]
    result = :($(GlobalRef(JLBind, :_result))($R, $fname($(converted...))))
    on_error = GlobalRef(JLBind, :_error_sexp)
    return esc(quote
        Base.@ccallable function $cname($(params...))::$SEXP
            try
                return $result
            catch e
                return $on_error(e)
            end
        end
    end)
end

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
