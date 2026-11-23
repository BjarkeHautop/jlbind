# JLBind's own tests, run in an ordinary Julia session with R embedded by RCall,
# which JLBind's `ccall`s into R's C API resolve against.

using Test, Dates, Libdl
using RCall
using JLBind
using JLBind: SEXP, nil, rtypeof, rlength, alloc, alloc_matrix, protect, unprotect

# Outside Windows, `@R` names a bare symbol, which resolves only against
# libraries in the global namespace, as libR is in an R process. RCall loads
# libR locally, so it is opened again globally.
Sys.iswindows() || Libdl.dlopen(RCall.libR, Libdl.RTLD_LAZY | Libdl.RTLD_GLOBAL)

# --- Helpers

# The R value of the R code `code`, kept alive by the `RObject`.
r(code::AbstractString) = reval(code)
sx(o::RObject) = Ptr{Cvoid}(o.p)
# An `SEXP` made by JLBind, protected by an `RObject`.
robj(p::SEXP) = RObject(RCall.sexp(Ptr{RCall.UnknownSxp}(p)))

# `from_sexp(T, <the value of code>)`.
from(T, code::AbstractString) = (o = r(code); GC.@preserve o from_sexp(T, sx(o)))
# Whether `to_sexp(x)` is identical to the value of the R code `code`.
same(x, code::AbstractString) = rcopy(rcall(:identical, robj(to_sexp(x)), r(code)))

# The message of the `ArgumentError` `f()` throws.
function argerror(f)
    try
        f()
    catch e
        e isa ArgumentError && return e.msg
        rethrow()
    end
    error("no error thrown")
end

# Calls an `@rcall` entrypoint with the values of the R code `codes`, returning
# the result as an `RObject`.
function call(f, codes::AbstractString...)
    os = [r(c) for c in codes]
    args = SEXP[sx(o) for o in os]
    GC.@preserve os args robj(f(pointer(args), Cint(length(args))))
end
iserror(o::RObject) = rcopy(rcall(:inherits, o, "jlbind_error"))
message(o::RObject) = (@assert iserror(o); rcopy(String, rcall(:as_character, o)))
rcall(:assign, "as_character", r("function(x) as.character(unclass(x))"))

# --- Entrypoints, declared at the top level as in a binding package

struct Counter
    n::Int64
end
abstract type Shape end
struct Circle <: Shape
    r::Float64
end
struct Square <: Shape
    s::Float64
end
area(c::Circle) = pi * c.r^2
area(s::Square) = s.s^2
struct Kept
    x::Float64
end
JLBind.r_class(::Type{Kept}) = "kept"
# Saved through `.jlbind_saved_state()` in the base namespace, whose enclosure
# is the global environment, where it is defined below.
JLBind.r_saved_by(::Type{Kept}) = "base"
JLBind.r_restore(::Type{Kept}, state::SEXP) = Kept(from_sexp(Float64, state))

greet(name) = "Hello, " * name * "!"
add(x, y) = x + y
describe(x::Nothing) = "nothing"
describe(x::Int64) = "int"
fill_na(x::Missing, y::Missing) = "both"
fill_na(x::Missing, y) = "x"
fill_na(x, y::Missing) = "y"
fill_na(x, y) = "none"
fail(kind) = kind == "argument" ? throw(ArgumentError("bad argument")) :
             kind == "error" ? error("plain error") :
             kind == "key" ? Dict{String,Int}()["k"] :
             kind == "bounds" ? [1][2] :
             throw(Base.IOError("io", 0))
new_counter(n) = Counter(n)
counter_value(c) = c.n
new_counters(n) = [Counter(i) for i = 1:n]
counters_total(cs) = sum(c.n for c in cs)
new_shape(kind) = kind == "circle" ? Circle(1.0) : Square(2.0)
shape_area(@nospecialize(s::Shape)) = @narrow s (Circle, Square) area(s)
new_kept(x) = Kept(x)
kept_value(k) = k.x
maybe_number(x) = x < 0 ? missing : x

@rcall greet(name::String)::String
@rcall add(x::Int64, y::Int64 = 2)::Int64
@rcall describe(x::Union{Nothing,Int64})::String
@rcall fill_na(x::Union{Missing,Float64}, y::Union{Missing,Float64})::String
@rcall fail(kind::String)::Int64
@rcall new_counter(n::Int64)::RRef{Counter}
@rcall counter_value(c::RRef{Counter})::Int64
@rcall new_counters(n::Int64)::Vector{RRef{Counter}}
@rcall counters_total(cs::Vector{RRef{Counter}})::Int64
@rcall new_shape(kind::String)::RRef{Shape}
@rcall shape_area(s::RRef{Shape})::Float64
@rcall new_kept(x::Float64)::RRef{Kept}
@rcall kept_value(k::RRef{Kept})::Float64
@rcall maybe_number(x::Float64)::Union{Missing,Float64}

# --- Tests

@testset "JLBind" begin
    @testset "strings" begin
        @test from(String, "'a'") == "a"
        @test from(String, "'é'") == "é"
        @test from(String, "factor('b')") == "b"
        @test from(Symbol, "'s'") === :s
        @test from(Vector{String}, "c('a', 'b')") == ["a", "b"]
        @test from(Vector{String}, "factor(c('x', 'y', 'x'))") == ["x", "y", "x"]
        @test from(Vector{Symbol}, "character()") == Symbol[]
        @test isequal(from(Vector{Union{Missing,String}}, "c('a', NA)"), ["a", missing])
        @test isequal(from(Vector{Union{Missing,String}}, "factor(c('a', NA))"), ["a", missing])
        @test isequal(from(Vector{Union{Missing,Symbol}}, "c(NA, NA)"), [missing, missing])
        @test from(Union{Missing,String}, "NA") === missing
        @test from(Union{Missing,String}, "NA_character_") === missing
        @test from(Union{Missing,String}, "'a'") == "a"
        @test argerror(() -> from(String, "1")) == "expected a character string"
        @test argerror(() -> from(String, "c('a', 'b')")) == "expected a single character string"
        @test argerror(() -> from(String, "NA_character_")) == "expected a string, not NA"
        @test argerror(() -> from(Union{Missing,String}, "c(NA, NA)")) ==
              "expected a single character string"
        @test argerror(() -> from(Vector{String}, "list()")) == "expected a character vector"
        @test argerror(() -> from(String, "structure(5L, levels = 'a', class = 'factor')")) ==
              "expected a valid factor"
        @test argerror(() -> from(String, "{x <- '\\xff'; Encoding(x) <- 'bytes'; x}")) ==
              "expected text, not a string in \"bytes\" encoding"

        @test same("a", "'a'")
        @test same(:a, "'a'")
        @test same(["a", "b"], "c('a', 'b')")
        @test same([:a, :b, :a], "c('a', 'b', 'a')")
        @test same(Union{Missing,String}["a", missing], "c('a', NA)")
        @test same(Union{Missing,Symbol}[missing], "NA_character_")
        @test same("é", "'é'")
        @test argerror(() -> to_sexp("a\0b")) == "cannot return a string containing NUL to R"
    end

    @testset "logicals" begin
        @test from(Bool, "TRUE") === true
        @test from(Union{Missing,Bool}, "NA") === missing
        @test from(Union{Missing,Bool}, "FALSE") === false
        @test from(Vector{Bool}, "c(TRUE, FALSE)") == [true, false]
        @test isequal(from(Vector{Union{Missing,Bool}}, "c(TRUE, NA)"), [true, missing])
        @test argerror(() -> from(Bool, "1")) == "expected TRUE or FALSE"
        @test argerror(() -> from(Bool, "NA")) == "expected TRUE or FALSE, not NA"
        @test argerror(() -> from(Bool, "logical()")) == "expected a single logical value"
        @test argerror(() -> from(Union{Missing,Bool}, "1")) == "expected TRUE, FALSE or NA"
        @test argerror(() -> from(Vector{Bool}, "1")) == "expected a logical vector"
        @test argerror(() -> from(Vector{Bool}, "c(TRUE, NA)")) == "expected TRUE or FALSE, not NA"

        @test same(true, "TRUE")
        @test same([true, false], "c(TRUE, FALSE)")
        @test same(Union{Missing,Bool}[missing, true], "c(NA, TRUE)")
        @test same(missing, "NA")
        @test same(nothing, "NULL")
    end

    @testset "numbers" begin
        @test from(Float64, "1.5") === 1.5
        @test from(Float64, "2L") === 2.0
        @test from(Int64, "3") === Int64(3)
        @test from(Int32, "3") === Int32(3)
        @test from(Int8, "-4L") === Int8(-4)
        @test from(UInt16, "7") === UInt16(7)
        @test from(Float32, "0.5") === 0.5f0
        @test from(Float64, "NaN") === NaN
        @test from(Union{Missing,Float64}, "NA") === missing
        @test from(Union{Missing,Float64}, "NA_real_") === missing
        @test from(Union{Missing,Int64}, "NA_integer_") === missing
        @test from(Union{Missing,Int32}, "5L") === Int32(5)
        @test from(Vector{Float64}, "c(1, 2.5)") == [1.0, 2.5]
        @test from(Vector{Float64}, "1:3") == [1.0, 2.0, 3.0]
        @test from(Vector{Int64}, "c(1, 2)") == [1, 2]
        @test from(Vector{Int32}, "1:2") == Int32[1, 2]
        @test from(Vector{Int32}, "c(1, 2)") == Int32[1, 2]
        @test from(Vector{Float16}, "c(1, 2)") == Float16[1, 2]
        @test isequal(from(Vector{Union{Missing,Int64}}, "c(1L, NA)"), [1, missing])
        @test isequal(from(Vector{Union{Missing,Float64}}, "c(NA, NA)"), [missing, missing])
        @test argerror(() -> from(Float64, "'1'")) == "expected a number"
        @test argerror(() -> from(Float64, "c(1, 2)")) == "expected a single number"
        @test argerror(() -> from(Float64, "NA_real_")) == "expected a number, not NA"
        @test argerror(() -> from(Int64, "1.5")) == "expected a whole number, not 1.5"
        @test argerror(() -> from(Int64, "2^60")) == "expected a whole number, not 1.152921504606847e18"
        @test argerror(() -> from(Int8, "200")) ==
              "expected a whole number between -128 and 127, not 200.0"
        @test argerror(() -> from(Int32, "-2^31")) ==
              "expected a whole number between -2147483647 and 2147483647, not -2.147483648e9"
        @test argerror(() -> from(Int32, "NaN")) ==
              "expected a whole number between -2147483647 and 2147483647, not NaN"
        @test startswith(argerror(() -> from(Float16, "1e6")), "expected a number between -65504.0")
        @test argerror(() -> from(Vector{Float64}, "c(1, NA)")) == "expected numbers, not NA"
        @test argerror(() -> from(Vector{Int32}, "c(1L, NA)")) == "expected numbers, not NA"
        @test argerror(() -> from(Vector{Float64}, "'a'")) == "expected a numeric vector"

        @test same(1.5, "1.5")
        @test same(3, "3")
        @test same(Int32(3), "3L")
        @test same(Int16(3), "3L")
        @test same(UInt32(3), "3")
        @test same(0.5f0, "0.5")
        @test same([1, 2], "c(1, 2)")
        @test same([1.5], "1.5")
        @test same(Int32[1, 2], "1:2")
        @test same(Int8[1], "1L")
        @test same(Union{Missing,Float64}[1.0, missing], "c(1, NA)")
        @test same(Union{Missing,Int64}[missing], "NA_real_")
        @test same(Union{Missing,Int32}[missing, 2], "c(NA, 2L)")
        @test same(Union{Missing,Int16}[missing], "NA_integer_")
        @test same(Union{Missing,Float32}[missing], "NA_real_")
        @test argerror(() -> to_sexp(typemin(Int32))) ==
              "cannot return -2147483648 to R as an integer, where it is NA"
        @test argerror(() -> to_sexp([typemin(Int32)])) ==
              "cannot return -2147483648 to R as an integer, where it is NA"
    end

    @testset "complex numbers and bytes" begin
        @test from(ComplexF64, "1+2i") === 1.0 + 2.0im
        @test from(ComplexF64, "3") === 3.0 + 0.0im
        @test from(Union{Missing,ComplexF64}, "NA_complex_") === missing
        @test from(Union{Missing,ComplexF64}, "NA") === missing
        @test from(Union{Missing,ComplexF64}, "1i") === 1.0im
        @test from(Vector{ComplexF64}, "c(1i, 2)") == [1.0im, 2.0 + 0im]
        @test isequal(from(Vector{Union{Missing,ComplexF64}}, "c(1i, NA)"), [1.0im, missing])
        @test isequal(from(Vector{Union{Missing,ComplexF64}}, "NA"), [missing])
        @test argerror(() -> from(ComplexF64, "'a'")) == "expected a complex number"
        @test argerror(() -> from(ComplexF64, "NA_complex_")) == "expected a complex number, not NA"
        @test argerror(() -> from(Vector{ComplexF64}, "c(1i, NA)")) == "expected complex numbers, not NA"
        @test from(Vector{UInt8}, "as.raw(c(1, 255))") == UInt8[1, 255]
        @test argerror(() -> from(Vector{UInt8}, "1")) == "expected a raw vector"

        @test same(1.0 + 2.0im, "1+2i")
        @test same(Union{Missing,ComplexF64}[missing], "NA_complex_")
        @test same(UInt8[1, 255], "as.raw(c(1, 255))")
    end

    @testset "RVector" begin
        o = r("c(1.5, 2.5)")
        GC.@preserve o begin
            v = from_sexp(RVector{Float64}, sx(o))
            @test v == [1.5, 2.5]
            @test size(v) == (2,)
            @test_throws BoundsError v[3]
            @test to_sexp(v) == sx(o)
        end
        @test from(RVector{Int32}, "1:3") == Int32[1, 2, 3]
        @test from(RVector{UInt8}, "as.raw(7)") == UInt8[7]
        @test argerror(() -> from(RVector{Float64}, "1L")) == "expected a double vector"
    end

    @testset "dates and times" begin
        @test from(Date, "as.Date('2024-02-29')") == Date(2024, 2, 29)
        @test from(Date, "structure(1.5, class = 'Date')") == Date(1970, 1, 2)
        @test from(Date, "structure(-1L, class = 'Date')") == Date(1969, 12, 31)
        @test from(DateTime, "as.POSIXct('2024-01-02 03:04:05.25', tz = 'UTC')") ==
              DateTime(2024, 1, 2, 3, 4, 5, 250)
        @test from(DateTime, "as.POSIXct('2024-01-02 03:04:05', tz = 'Europe/Copenhagen')") ==
              DateTime(2024, 1, 2, 2, 4, 5)
        @test from(Union{Missing,Date}, "as.Date(NA)") === missing
        @test from(Union{Missing,Date}, "NA") === missing
        @test from(Union{Missing,DateTime}, "as.POSIXct('1970-01-01', tz = 'UTC')") == DateTime(1970)
        @test from(Vector{Date}, "as.Date(c('2020-01-01', '2021-01-01'))") ==
              [Date(2020), Date(2021)]
        @test isequal(from(Vector{Union{Missing,Date}}, "as.Date(c('2020-01-01', NA))"),
                      [Date(2020), missing])
        @test isequal(from(Vector{Union{Missing,DateTime}}, "c(NA, NA)"), [missing, missing])
        @test argerror(() -> from(Date, "1")) == "expected a Date"
        @test argerror(() -> from(DateTime, "as.Date('2020-01-01')")) == "expected a date-time"
        @test argerror(() -> from(Date, "as.Date(c('2020-01-01', '2021-01-01'))")) ==
              "expected a single Date"
        @test argerror(() -> from(Date, "as.Date(NA)")) == "expected a Date, not NA"
        @test argerror(() -> from(Date, "structure(NaN, class = 'Date')")) == "expected a Date, not NaN"
        @test argerror(() -> from(DateTime, "structure(Inf, class = c('POSIXct', 'POSIXt'))")) ==
              "expected a date-time, not Inf"

        @test same(Date(2024, 2, 29), "as.Date('2024-02-29')")
        @test same(Union{Missing,Date}[missing], "as.Date(NA)")
        @test same(DateTime(2024, 1, 2, 3, 4, 5),
                   "as.POSIXct('2024-01-02 03:04:05', tz = 'UTC')")
        @test same(Union{Missing,DateTime}[missing],
                   "structure(NA_real_, class = c('POSIXct', 'POSIXt'), tzone = 'UTC')")
    end

    @testset "arrays" begin
        @test from(Matrix{Float64}, "matrix(1:6, 2)") == [1.0 3 5; 2 4 6]
        @test from(Array{Int32,3}, "array(1:8, c(2, 2, 2))") == reshape(Int32.(1:8), 2, 2, 2)
        @test from(Matrix{String}, "matrix(c('a', 'b'), 1)") == ["a" "b"]
        @test argerror(() -> from(Matrix{Float64}, "1:3")) == "expected a matrix"
        @test argerror(() -> from(Array{Float64,3}, "matrix(1)")) == "expected an array of 3 dimensions"

        @test same([1.0 3; 2 4], "matrix(c(1, 2, 3, 4), 2)")
        @test same(reshape(Int32.(1:8), 2, 2, 2), "array(1:8, c(2, 2, 2))")
        @test argerror(() -> to_sexp(fill(1.0))) == "cannot return a zero-dimensional array to R"
        m = robj(alloc_matrix(JLBind.REALSXP, 2, 3))
        @test rcopy(rcall(:dim, m)) == [2, 3]
        @test argerror(() -> alloc_matrix(JLBind.REALSXP, -1, 1)) ==
              "cannot return a matrix with a dimension over 2^31 - 1 to R"
    end

    @testset "lists" begin
        @test from(Vector{Vector{Int64}}, "list(1, c(2, 3))") == [[1], [2, 3]]
        @test from(Vector{Tuple{String}}, "list(list('a'))") == [("a",)]
        @test from(Tuple{String,Float64}, "list('a', 1)") == ("a", 1.0)
        @test from(@NamedTuple{a::Int64, b::String}, "list(b = 'x', a = 1)") == (a = 1, b = "x")
        @test from(NamedTuple{(),Tuple{}}, "list()") == NamedTuple()
        @test from(Dict{String,Float64}, "list(a = 1, b = 2)") == Dict("a" => 1.0, "b" => 2.0)
        @test from(Dict{Symbol,String}, "list(k = 'v')") == Dict(:k => "v")
        @test from(Dict{String,Int64}, "list()") == Dict{String,Int64}()
        @test from(Union{Nothing,Int64}, "NULL") === nothing
        @test from(Union{Nothing,Int64}, "1") === Int64(1)
        @test from(SEXP, "NULL") == nil()
        @test argerror(() -> from(Vector{Float64}, "list(1, 'a')")) == "expected a numeric vector"
        @test argerror(() -> from(Vector{Vector{Int64}}, "list(1, 'a')")) ==
              "element 2: expected a numeric vector"
        @test argerror(() -> from(Vector{Vector{Int64}}, "1")) == "expected a list"
        @test argerror(() -> from(Tuple{Int64}, "list(1, 2)")) == "expected a list of length 1"
        @test argerror(() -> from(Tuple{Int64}, "1")) == "expected a list"
        @test argerror(() -> from(Tuple{Int64,String}, "list(1, 2)")) ==
              "element 2: expected a character string"
        @test argerror(() -> from(@NamedTuple{a::Int64}, "list(1)")) == "expected a named list"
        @test argerror(() -> from(@NamedTuple{a::Int64}, "list(a = 1, 2)")) == "expected a named list"
        @test argerror(() -> from(@NamedTuple{a::Int64}, "list(b = 1)")) ==
              "expected a list with an element `a`"
        @test argerror(() -> from(@NamedTuple{a::Int64}, "list(a = 1, b = 2)")) ==
              "unexpected element `b`"
        @test argerror(() -> from(@NamedTuple{a::Int64}, "list(a = 1, a = 2)")) ==
              "duplicate element `a`"
        @test argerror(() -> from(@NamedTuple{a::Int64}, "list(a = 'x')")) ==
              "element `a`: expected a number"
        @test argerror(() -> from(Dict{String,Int64}, "list(a = 1, a = 2)")) == "duplicate element `a`"
        @test argerror(() -> from(Dict{String,Int64}, "list(a = 1, 2)")) == "expected a named list"
        @test argerror(() -> from(Dict{String,Int64}, "1")) == "expected a named list"

        @test same(Any[], "list()")
        @test same([[1], [2, 3]], "list(1, c(2, 3))")
        @test same(Union{Int64,String}[1, "a"], "list(1, 'a')")
        @test same(("a", 1, nothing), "list('a', 1, NULL)")
        @test same((a = 1, b = "x"), "list(a = 1, b = 'x')")
        @test same(Dict("b" => 2, "a" => 1), "list(a = 1, b = 2)")
        @test same(Dict(:k => "v"), "list(k = 'v')")
    end

    @testset "data frames" begin
        Sales = RDataFrame{(:group, :amount),Tuple{Vector{String},Vector{Float64}}}
        df = from(Sales, "data.frame(amount = c(1, 2), group = c('a', 'b'))")
        @test df.group == ["a", "b"]
        @test df.amount == [1.0, 2.0]
        @test propertynames(df) == (:group, :amount)
        @test argerror(() -> from(Sales, "list(group = 'a', amount = 1)")) == "expected a data frame"
        @test_throws DimensionMismatch RDataFrame((a = [1, 2], b = [1]))

        @test same(RDataFrame((x = [1.0, 2.0], y = ["a", "b"])),
                   "data.frame(x = c(1, 2), y = c('a', 'b'))")
        @test same(RDataFrame(NamedTuple()), "data.frame()")
        cols = SEXP[protect(to_sexp([1, 2])), protect(to_sexp(["a", "b"]))]
        out = robj(JLBind.data_frame(["x", "y"], cols))
        unprotect(2)
        @test rcopy(rcall(:identical, out, r("data.frame(x = c(1, 2), y = c('a', 'b'))")))
        @test rcopy(rcall(:identical, robj(JLBind.data_frame(String[], SEXP[])), r("data.frame()")))
    end

    @testset "R API" begin
        @test rtypeof(nil()) == JLBind.NILSXP
        x = robj(alloc(JLBind.STRSXP, 2))
        GC.@preserve x begin
            JLBind.set_string_elt(sx(x), 0, JLBind.mkchar(:sym))
            JLBind.set_string_elt(sx(x), 1, JLBind.mkchar(:sym))
            @test rlength(sx(x)) == 2
            @test JLBind.string_elt(sx(x), 0) == JLBind.string_elt(sx(x), 1)
        end
        @test rcopy(x) == ["sym", "sym"]
        p = JLBind.preserve(to_sexp(1.0))
        JLBind.release(p)
        @test JLBind.@r_global(R_NilValue) == nil()
    end

    @testset "@rcall" begin
        @test rcopy(call(jlbind4_Main_greet, "'R'")) == "Hello, R!"
        @test rcopy(call(jlbind4_Main_add, "1", "2")) == 3
        @test message(call(jlbind4_Main_add, "1")) == "add() takes 2 arguments, but was given 1"
        @test message(call(jlbind4_Main_greet)) == "greet() takes 1 argument, but was given 0"
        @test message(call(jlbind4_Main_greet, "1")) == "expected a character string"
        @test rcopy(call(jlbind4_Main_describe, "NULL")) == "nothing"
        @test rcopy(call(jlbind4_Main_describe, "1")) == "int"
        @test rcopy(call(jlbind4_Main_fill_na, "NA", "NA")) == "both"
        @test rcopy(call(jlbind4_Main_fill_na, "NA", "1")) == "x"
        @test rcopy(call(jlbind4_Main_fill_na, "1", "NA")) == "y"
        @test rcopy(call(jlbind4_Main_fill_na, "1", "1")) == "none"
        @test message(call(jlbind4_Main_fail, "'argument'")) == "bad argument"
        @test message(call(jlbind4_Main_fail, "'error'")) == "plain error"
        @test message(call(jlbind4_Main_fail, "'key'")) == "key not found"
        @test message(call(jlbind4_Main_fail, "'bounds'")) == "index out of bounds"
        @test message(call(jlbind4_Main_fail, "'other'")) == "internal error in the compiled Julia library"
        @test rcopy(rcall(:identical, call(jlbind4_Main_maybe_number, "-1"), r("NA_real_")))
        @test rcopy(call(jlbind4_Main_maybe_number, "1")) == 1.0

        @test JLBind._error_message(DimensionMismatch("dims")) == "dims"
        @test JLBind._error_message(OverflowError("over")) == "over"
        @test JLBind._error_message(AssertionError("assert")) == "assert"
        @test JLBind._error_message(DomainError(-1)) == "domain error"
        @test JLBind._error_message(InexactError(:f, Int, 1.5)) == "inexact conversion"
        @test JLBind._error_message(DivideError()) == "integer division error"
        @test JLBind._error_message(OutOfMemoryError()) == "out of memory"
        @test JLBind._error_message(StackOverflowError()) == "stack overflow"
        @test JLBind._msg(SubString("abc", 1, 2)) == "error"

        @test JLBind._entry_symbol(:a_b, :c) === :jlbind3_a_b_c
        @test JLBind._entry_symbol(:a, :b_c) === :jlbind1_a_b_c
        @test JLBind._union_with(:(Union{Nothing,Int}), :Nothing)
        @test JLBind._union_with(:(Base.Union{Int,Base.Missing}), :Missing)
        @test !JLBind._union_with(:(Union{Nothing,Int}), :Missing)
        @test !JLBind._union_with(:Int, :Nothing)
        for d in (1, 1.5, "a", true, :missing, :nothing, :([1, 2]), :(Float64[]), :(String["a"]))
            @test JLBind._literal_default(d)
        end
        for d in (:x, :(f()), :([]), :([x]), :(Foo[1]), :([nothing]))
            @test !JLBind._literal_default(d)
        end

        bad(ex) = try
            macroexpand(Main, ex)
            nothing
        catch e
            sprint(showerror, e isa LoadError ? e.error : e)
        end
        @test occursin("needs a return type", bad(:(@rcall f(x::Int))))
        @test occursin("needs a call signature", bad(:(@rcall f::Int)))
        @test occursin("plain function name", bad(:(@rcall M.f(x::Int)::Int)))
        @test occursin("needs every argument typed", bad(:(@rcall f(x)::Int)))
        @test occursin("the default of x::Int must be", bad(:(@rcall f(x::Int = y)::Int)))
        @test bad(:(@rcall f(x::Int = 1)::Int)) === nothing
    end

    @testset "RRef" begin
        before = JLBind.object_count()
        c = call(jlbind4_Main_new_counter, "5")
        @test rcopy(rcall(:class, c)) == "jlbind_ref"
        @test JLBind.object_count() == before + 1
        rcall(:assign, "c", c)
        @test rcopy(call(jlbind4_Main_counter_value, "c")) == 5
        @test message(call(jlbind4_Main_counter_value, "1")) == "expected a `jlbind_ref` object"
        @test message(call(jlbind4_Main_counter_value, "new('externalptr')")) ==
              "expected a `jlbind_ref` object"
        # A reference to an object of another type
        rcall(:assign, "s", call(jlbind4_Main_new_shape, "'circle'"))
        @test message(call(jlbind4_Main_counter_value, "s")) == "expected a `jlbind_ref` object"
        @test rcopy(call(jlbind4_Main_shape_area, "s")) ≈ pi
        rcall(:assign, "s2", call(jlbind4_Main_new_shape, "'square'"))
        @test rcopy(call(jlbind4_Main_shape_area, "s2")) == 4.0
        @test_throws ArgumentError (x = 1; @narrow x (String,) x)
        @test (@narrow c (Int,) 1 :other) === :other

        # A list of references
        rcall(:assign, "cs", call(jlbind4_Main_new_counters, "3"))
        @test rcopy(r("length(cs)")) == 3
        @test rcopy(call(jlbind4_Main_counters_total, "cs")) == 6
        @test message(call(jlbind4_Main_counters_total, "1")) == "expected a list"
        @test message(call(jlbind4_Main_counters_total, "list(c, 1)")) ==
              "element 2: expected a `jlbind_ref` object"

        # A reference whose type can't be saved, saved and loaded again
        @test message(call(jlbind4_Main_counter_value, "unserialize(serialize(c, NULL))")) ==
              "this `jlbind_ref` object no longer exists; objects do not survive " *
              "saving and reloading, or a restart of R"
        # A live reference from another runtime, as a private library makes
        o = call(jlbind4_Main_new_counter, "1")
        ccall(JLBind.@R(R_SetExternalPtrProtected), Cvoid, (SEXP, SEXP),
              sx(o), JLBind._install("jlbind_runtime_other"))
        rcall(:assign, "o", o)
        @test message(call(jlbind4_Main_counter_value, "o")) ==
              "this `jlbind_ref` object belongs to another of the Julia libraries " *
              "loaded, which runs separately"
        reval("rm(c, s, s2, cs, o)")
        o = nothing
        c = nothing

        # Freed once R no longer uses them. The references are made in a
        # function, as the top level keeps its temporaries alive.
        function make_counters(k)
            for i = 1:k
                call(jlbind4_Main_new_counter, string(i))
            end
        end
        n = JLBind.object_count()
        make_counters(3)
        @test JLBind.object_count() == n + 3
        GC.gc()
        rcall(:gc)
        # Including the references above, which R no longer has either
        @test JLBind.object_count() == 0
        @test length(JLBind.RELEASED) >= n + 3
        make_counters(1)  # drops the released handles
        @test isempty(JLBind.RELEASED)
        @test rcopy(call(JLBind.jlbind6_JLBind_object_count)) == 1
    end

    if rcopy(r("requireNamespace('jlbind', quietly = TRUE)"))
        @testset "saved RRef" begin
            reval(".jlbind_saved_state <- function(x) 2.5")
            rcall(:assign, "k", call(jlbind4_Main_new_kept, "1.5"))
            @test rcopy(r("class(k)")) == "kept"
            @test rcopy(call(jlbind4_Main_kept_value, "k")) == 1.5
            reval("k2 <- unserialize(serialize(k, NULL))")
            @test rcopy(call(jlbind4_Main_kept_value, "k2")) == 2.5
            # Restored on first use only
            reval(".jlbind_saved_state <- function(x) 3.5")
            @test rcopy(call(jlbind4_Main_kept_value, "k2")) == 2.5
            reval("k3 <- unserialize(serialize(k, NULL, version = 2))")
            @test message(call(jlbind4_Main_kept_value, "k3")) ==
                  "this `kept` object was saved without its contents, probably " *
                  "with `saveRDS(version = 2)`, which can't store it"
            reval("rm(k, k2, k3, .jlbind_saved_state)")
        end
    else
        @warn "Skipping the tests of saved references, which need the jlbind R package"
    end
end
