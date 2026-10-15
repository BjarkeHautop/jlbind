"""
    {{module}}

The R entrypoints of the R package {{package}}. Each `@rcall` declaration
exports a Julia function to R; after changing them, run
`jlbind::update_entrypoints()` to regenerate the R functions that call them, in
`R/jlbind-wrappers.R`.
"""
module {{module}}

using JLBind

hello(name::String) = "Hello, " * name * ", from Julia!"

@rcall hello(name::String)::String

end
