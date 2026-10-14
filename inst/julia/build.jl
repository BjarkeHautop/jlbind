# Compile the binding packages of jlbind's clients into one shared library.
#
#     julia --startup-file=no build.jl <output directory> [options] <binding package>...
#
# Run by the R package's build_library() (from the installed jlbind's `julia`
# directory), so the library is built by, and links against, the user's own
# Julia. Each <binding package> is the directory of a client's binding package
# (its Project.toml and src/). The library, `jlbind.so` (`.dylib`, `.dll`),
# exports the `@rcall` entrypoints of every one of them, plus JLBind's own.
#
# A release of a client is tested with the dependency versions in its shipped
# Manifest.toml, so the build starts from the first client's manifest and adds
# the others keeping as many versions as their compat bounds allow, then says
# which versions differ from a client's manifest. A client whose [compat]
# bounds conflict with those of the clients before it is left out, and listed
# in <output directory>/conflicts with the clients it conflicts with. `--update` instead resolves
# the newest versions every [compat] allows. `--develop=<dir>` (repeatable)
# uses the Julia package in <dir>, e.g. a local checkout of a dependency,
# instead of its registered release. `--no-trim` compiles without `--trim`,
# for clients whose code relies on dynamic dispatch.

import Pkg
import TOML

const HERE = @__DIR__
const OUT = abspath(ARGS[1])
const UPDATE = "--update" in ARGS
const TRIM = !("--no-trim" in ARGS)
const SOURCES = [abspath(a) for a in ARGS[2:end] if !startswith(a, "--")]
const DEVELOP = [abspath(chopprefix(a, "--develop=")) for a in ARGS if startswith(a, "--develop=")]
isempty(SOURCES) && error("No binding packages to build.")
mkpath(OUT)

# Everything is built from a scratch copy, so nothing is ever written into an
# installed package or the user's projects. The copies are made writable,
# since an installed package's files may not be.
function copy_writable(src, dst)
    cp(src, dst)
    for (root, dirs, files) in walkdir(dst), f in [dirs; files]
        p = joinpath(root, f)
        islink(p) || chmod(p, filemode(p) | 0o200)
    end
    chmod(dst, filemode(dst) | 0o200)
end

const WORK = mktempdir()
const JLBIND = joinpath(WORK, "JLBind")
copy_writable(joinpath(HERE, "JLBind"), JLBIND)
const JLBIND_UUID = TOML.parsefile(joinpath(JLBIND, "Project.toml"))["uuid"]

struct Client
    name::String
    uuid::String
    path::String              # the scratch copy
    project::Dict{String,Any}
    manifest::Union{Nothing,Dict{String,Any}}
end

clients = Client[]
for src in SOURCES
    isfile(joinpath(src, "Project.toml")) || error("No Project.toml in $src.")
    project = TOML.parsefile(joinpath(src, "Project.toml"))
    name = project["name"]
    any(c -> c.name == name, clients) &&
        error("Two clients have a binding package named $name; each needs its own name.")
    haskey(get(project, "deps", Dict()), "JLBind") ||
        error("The binding package $name (in $src) does not depend on JLBind.")
    manifest_file = joinpath(src, "Manifest.toml")
    manifest = isfile(manifest_file) ? TOML.parsefile(manifest_file) : nothing
    dst = joinpath(WORK, "clients", name)
    mkpath(dirname(dst))
    copy_writable(src, dst)
    # A developer's manifest, or [sources], records where they had JLBind;
    # the copy here is developed instead.
    rm(joinpath(dst, "Manifest.toml"); force = true)
    sources = get(project, "sources", Dict())
    if haskey(sources, "JLBind")
        delete!(sources, "JLBind")
        isempty(sources) && delete!(project, "sources")
        open(io -> TOML.print(io, project), joinpath(dst, "Project.toml"), "w")
    end
    push!(clients, Client(name, project["uuid"], dst, project, manifest))
end

const IMAGE = joinpath(WORK, "JLBindImage")
const SKIPPED = Set([JLBIND_UUID; [c.uuid for c in clients]])

# Sets up the image, a package that loads every binding package in `cs`
# (juliac exports the `@ccallable`s of every package in the image, not only
# its own), with its dependencies seeded from `base`'s manifest, if any,
# without the packages developed here.
function write_image(cs, base)
    rm(IMAGE; recursive = true, force = true)
    mkpath(joinpath(IMAGE, "src"))
    write(joinpath(IMAGE, "src", "JLBindImage.jl"), """
        module JLBindImage
        import JLBind
        $(join(("import " * c.name for c in cs), "\n"))
        end
        """)
    deps = Dict{String,Any}()
    if base !== nothing
        for (name, uuid) in get(base.project, "deps", Dict())
            uuid in SKIPPED || (deps[name] = uuid)
        end
        manifest = copy(base.manifest)
        entries = Dict{String,Any}()
        for (name, es) in get(manifest, "deps", Dict())
            kept = [e for e in es if !(get(e, "uuid", "") in SKIPPED)]
            isempty(kept) || (entries[name] = kept)
        end
        manifest["deps"] = entries
        open(io -> TOML.print(io, manifest), joinpath(IMAGE, "Manifest.toml"), "w")
    end
    open(joinpath(IMAGE, "Project.toml"), "w") do io
        TOML.print(io, Dict(
            "name" => "JLBindImage",
            "uuid" => "8dd3c9ef-211f-46b0-9785-0c10c04cf634",
            "version" => "0.1.0",
            "deps" => deps,
        ))
    end
end

# Resolves the dependencies of the binding packages in `cs` into the image,
# starting from the first manifest among them; returns the client whose
# manifest was used, or `nothing`. Throws a `Pkg.Resolve.ResolverError` if
# their [compat] bounds conflict.
function resolve(cs)
    base = UPDATE ? nothing : findfirst(c -> c.manifest !== nothing, cs)
    base = base === nothing ? nothing : cs[base]
    write_image(cs, base)
    Pkg.activate(IMAGE)
    specs = [
        Pkg.PackageSpec(path = JLBIND);
        [Pkg.PackageSpec(path = c.path) for c in cs];
        [Pkg.PackageSpec(path = d) for d in DEVELOP]
    ]
    try
        # Keeps the manifest's versions where the compat bounds allow it.
        Pkg.develop(specs)
        Pkg.instantiate()
    catch e
        # A manifest resolved with another Julia version can fail to
        # instantiate (e.g. on different standard library versions), so fall
        # back to the newest compatible versions rather than not building.
        base === nothing && rethrow()
        @warn "Could not use the Manifest.toml of $(base.name); resolving " *
            "the newest versions the binding packages allow instead." exception = e
        rm(joinpath(IMAGE, "Manifest.toml"))
        Pkg.develop(specs)
        Pkg.instantiate()
    end
    return base
end

resolves(cs) = try
    resolve(cs)
    true
catch e
    e isa Pkg.Resolve.ResolverError || rethrow()
    false
end

# There is one environment, so one version of each dependency. If the clients'
# bounds conflict, they are added in order and a client that conflicts with
# those before it is left out, rather than failing the build for all of them.
# `excluded` maps a left-out client to the kept clients it conflicts with
# (none if it cannot be resolved even on its own).
function choose_clients(clients)
    resolves(clients) && return clients, Dict{String,Vector{String}}()
    kept = Client[]
    excluded = Dict{String,Vector{String}}()
    for c in clients
        if resolves([kept; c])
            push!(kept, c)
        else
            excluded[c.name] = resolves([c]) ?
                [k.name for k in kept if !resolves([k, c])] : String[]
            @warn "Leaving $(c.name) out of the library: its dependencies " *
                (isempty(excluded[c.name]) ? "cannot be resolved." :
                 "conflict with those of $(join(excluded[c.name], ", ")).")
        end
    end
    isempty(kept) && error("The dependencies of no binding package can be resolved.")
    resolve(kept)
    return kept, excluded
end

clients, excluded = choose_clients(clients)
open(joinpath(OUT, "conflicts"), "w") do io
    for (name, with) in excluded
        println(io, name, "\t", join(with, ","))
    end
end

# Report the dependency versions that differ from a client's manifest.
resolved = Dict{String,String}()
for (uuid, entry) in Pkg.dependencies()
    entry.version === nothing || (resolved[string(uuid)] = string(entry.version))
end
for c in clients
    c.manifest === nothing && continue
    differ = String[]
    for (name, es) in get(c.manifest, "deps", Dict()), e in es
        v = get(e, "version", nothing)
        r = get(resolved, get(e, "uuid", ""), nothing)
        v === nothing || r === nothing || v == r || push!(differ, "$name $r (manifest: $v)")
    end
    isempty(differ) || @info "Dependencies of $(c.name) built with other versions than its " *
        "Manifest.toml has:\n  " * join(sort!(differ), "\n  ")
end
cp(joinpath(IMAGE, "Manifest.toml"), joinpath(OUT, "Manifest.toml"); force = true)

# JuliaC gets its own environment, so it is never compiled into the library.
Pkg.activate(; temp = true)
Pkg.add(Pkg.PackageSpec(name = "JuliaC", version = "0.3"))

using JuliaC

# The CLI's `--output-lib --trim=safe --experimental --compile-ccallable`
# (without `--trim` for `--no-trim`), plus `set_threads.c`, which the CLI
# cannot add.
image = JuliaC.ImageRecipe(;
    output_type = "--output-lib",
    file = joinpath(IMAGE, "src", "JLBindImage.jl"),
    project = IMAGE,
    trim_mode = TRIM ? "safe" : nothing,
    add_ccallables = true,
    julia_args = ["--experimental"],
    c_sources = [joinpath(JLBIND, "src", "set_threads.c")],
)
JuliaC.compile_products(image)
JuliaC.link_products(JuliaC.LinkRecipe(; image_recipe = image, outname = joinpath(OUT, "jlbind")))

# A Windows DLL has no RUNPATH, so record where the Julia runtime it links
# against lives; the R package puts it on the DLL search path before loading.
if Sys.iswindows()
    write(joinpath(OUT, "julia_bindir"), Sys.BINDIR)
end
