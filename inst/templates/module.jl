"""
    {{module}}

The R entrypoints of the R package {{package}}. Each `@rcall` declaration
exports a function R calls as `.Call(C_<name>, ...)`; after changing them, run
`jlbind::update_entrypoints()` to regenerate `src/entrypoints.h`.
"""
module {{module}}

using JLBind

hello(name::String) = "Hello, " * name * ", from Julia!"

@rcall hello(name::String)::String

end
