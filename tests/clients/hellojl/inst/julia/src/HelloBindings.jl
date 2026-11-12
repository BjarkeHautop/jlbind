# The binding package of the hellojl test client: plain values both ways.
module HelloBindings

using JLBind
import Dates

greet(name) = "Hello, " * name * "!"
shift(x, by) = by === nothing ? x : x .+ by
describe(x) =
    (n = length(x), mean = sum(x) / length(x), range = [minimum(x), maximum(x)])
fail(msg) = throw(ArgumentError(msg))
threads() = Int64(Threads.nthreads())
upper(xs) = [Symbol(uppercase(String(x))) for x in xs]
evens(n) = Int32[i for i = 2:2:n]
negate(x) = !x
with_nul(s) = s * "\0"

# Round trips through the other conversions.
na_doubles(x) = x
na_wholes(x) = x
na_ints(x) = x
na_bools(x) = x
na_strings(x) = x
maybe_double(x) = x
maybe_string(x) = x
ints(x) = x
transposed(x) = permutedims(x)
cube(x) = x
strings(x) = x
reverse_raw(x) = reverse(x)
conjugate(x) = conj.(x)
view_sum(x) = sum(x)
view_same(x) = x
list_lengths(x) = Int64[length(v) for v in x]
pair(x) = x
columns(df) = df
counts(x) = x
int_min() = Int32[1, typemin(Int32)]
dates(x) = x
next_day(x) = x + Dates.Day(1)
times(x) = x
na_complex(x) = x
maybe_complex(x) = x
symbol_counts(x) = x
singles(x) = x .* 2.0f0
shorts(x) = x
small_types(a, b, c, d) = (a, b, c, d)
const Groups = RDataFrame{(:group, :x),Tuple{Vector{String},Vector{Union{Missing,Float64}}}}
function group_means(df)
    gs = sort(unique(df.group))
    means = Union{Missing,Float64}[sum(df.x[df.group .== g]) / count(==(g), df.group) for g in gs]
    return RDataFrame((group = gs, mean = means, first = [Dates.Date(2024) for _ in gs]))
end
uneven() = RDataFrame((a = [1.0], b = [1.0, 2.0]))

@rcall greet(name::String)::String
@rcall shift(x::Vector{Float64}, by::Union{Nothing,Float64} = nothing)::Vector{Float64}
@rcall describe(x::Vector{Float64})::NamedTuple{(:n, :mean, :range),Tuple{Int64,Float64,Vector{Float64}}}
@rcall fail(msg::String)::Nothing
@rcall threads()::Int64
@rcall upper(xs::Vector{Symbol})::Vector{Symbol}
@rcall evens(n::Int64)::Vector{Int32}
@rcall negate(x::Bool)::Bool
@rcall with_nul(s::String)::String
@rcall na_doubles(x::Vector{Union{Missing,Float64}})::Vector{Union{Missing,Float64}}
@rcall na_wholes(x::Vector{Union{Missing,Int64}})::Vector{Union{Missing,Int64}}
@rcall na_ints(x::Vector{Union{Missing,Int32}})::Vector{Union{Missing,Int32}}
@rcall na_bools(x::Vector{Union{Missing,Bool}})::Vector{Union{Missing,Bool}}
@rcall na_strings(x::Vector{Union{Missing,String}})::Vector{Union{Missing,String}}
@rcall maybe_double(x::Union{Missing,Float64})::Union{Missing,Float64}
@rcall maybe_string(x::Union{Missing,String})::Union{Missing,String}
@rcall ints(x::Vector{Int32})::Vector{Int32}
@rcall transposed(x::Matrix{Int32})::Matrix{Int32}
@rcall cube(x::Array{Float64,3})::Array{Float64,3}
@rcall strings(x::Vector{String})::Vector{String}
@rcall reverse_raw(x::Vector{UInt8})::Vector{UInt8}
@rcall conjugate(x::Vector{ComplexF64})::Vector{ComplexF64}
@rcall view_sum(x::RVector{Float64})::Float64
@rcall view_same(x::RVector{Int32})::RVector{Int32}
@rcall list_lengths(x::Vector{Vector{Float64}})::Vector{Int64}
@rcall pair(x::Tuple{String,Int64})::Tuple{String,Int64}
@rcall columns(df::NamedTuple{(:a, :b),Tuple{Vector{Float64},Vector{String}}})::NamedTuple{(:a, :b),Tuple{Vector{Float64},Vector{String}}}
@rcall counts(x::Dict{String,Int64})::Dict{String,Int64}
@rcall int_min()::Vector{Int32}
@rcall dates(x::Vector{Union{Missing,Dates.Date}})::Vector{Union{Missing,Dates.Date}}
@rcall next_day(x::Dates.Date)::Dates.Date
@rcall times(x::Vector{Union{Missing,Dates.DateTime}})::Vector{Union{Missing,Dates.DateTime}}
@rcall na_complex(x::Vector{Union{Missing,ComplexF64}})::Vector{Union{Missing,ComplexF64}}
@rcall maybe_complex(x::Union{Missing,ComplexF64})::Union{Missing,ComplexF64}
@rcall symbol_counts(x::Dict{Symbol,Int64})::Dict{Symbol,Int64}
@rcall singles(x::Vector{Float32})::Vector{Float32}
@rcall shorts(x::Vector{Union{Missing,Int16}})::Vector{Union{Missing,Int16}}
@rcall small_types(a::Int8, b::UInt16, c::UInt32, d::Float16)::Tuple{Int8,UInt16,UInt32,Float16}
@rcall group_means(df::Groups)::RDataFrame{(:group, :mean, :first),Tuple{Vector{String},Vector{Union{Missing,Float64}},Vector{Dates.Date}}}
@rcall uneven()::RDataFrame{(:a, :b),Tuple{Vector{Float64},Vector{Float64}}}

end # module HelloBindings
