"""
    JLBind

Write R entrypoints in Julia, for a library compiled with `juliac --trim=safe`
that R loads with `dyn.load` and calls with `.Call`.

A client R package's binding package (`inst/julia/` by convention) declares its
entrypoints with [`@rcall`](@ref), converting arguments and results with
[`from_sexp`](@ref) and [`to_sexp`](@ref), which it can extend for its own
types. Julia objects that cannot cross into R as values do so as external
pointers, through [`RRef`](@ref).

The jlbind R package compiles the binding packages of every installed client
into one library, since an R process can host only one Julia image.
"""
module JLBind

import Dates
using Dates: Date, DateTime

export SEXP, @rcall, from_sexp, to_sexp, RRef, RVector, RDataFrame

public @R, @r_global, r_class, object_count
public nil, rtypeof, rlength, protect, unprotect, preserve, release
public alloc, string_elt, set_string_elt, vector_elt, set_vector_elt
public real_ptr, int_ptr, logical_ptr, complex_ptr, raw_ptr
public mkchar, get_attrib, set_attrib, data_frame
public NILSXP, LGLSXP, INTSXP, REALSXP, CPLXSXP, STRSXP, VECSXP, EXTPTRSXP, RAWSXP
public NA_INTEGER, NA_REAL

include("rapi.jl")
include("convert.jl")
include("refs.jl")
include("rcall.jl")

end
