# julia build.jl <project dir> <out dir>
import Pkg
const PROJ = abspath(ARGS[1]); const OUT = abspath(ARGS[2]); mkpath(OUT)
name = basename(PROJ)
Pkg.activate(PROJ); Pkg.instantiate()
Pkg.activate(; temp = true)
Pkg.add(Pkg.PackageSpec(name = "JuliaC", version = "0.3"))
using JuliaC
image = JuliaC.ImageRecipe(; output_type = "--output-lib",
    file = joinpath(PROJ, "src", name * ".jl"), project = PROJ,
    trim_mode = "safe", add_ccallables = true, julia_args = ["--experimental"])
JuliaC.compile_products(image)
JuliaC.link_products(JuliaC.LinkRecipe(; image_recipe = image, outname = joinpath(OUT, name)))
