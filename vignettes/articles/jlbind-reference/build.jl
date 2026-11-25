# Writes vignettes/articles/jlbind-reference.qmd, the reference of JLBind's
# public names, from their docstrings. Run from the repository root:
#
#     julia --startup-file=no --project=inst/julia/JLBind vignettes/articles/jlbind-reference/build.jl
#
# With `--check`, writes nothing and fails if the page is out of date (the
# pre-commit hook). Every public name must be listed in `SECTIONS` below, and
# the names listed together must share one docstring. The page is formatted
# with panache, which must be on the PATH.

using JLBind

const OUT = joinpath(@__DIR__, "..", "jlbind-reference.qmd")

const SECTIONS = [
    ("Declaring entrypoints", "", [["@rcall"]]),
    (
        "Converting values",
        "`@rcall` converts arguments and return values with these.",
        [["from_sexp"], ["to_sexp"], ["RVector"], ["RDataFrame"]],
    ),
    (
        "Julia objects in R",
        "",
        [["RRef"], ["r_class"], ["r_saved_by"], ["r_restore"], ["object_count"]],
    ),
    ("Trimming", "", [["@narrow"]]),
    (
        "Building R objects",
        "To build a result yourself, without a copy, declare the entrypoint to return " *
        "`SEXP` and use these, which call R's C API directly. Most don't check their " *
        "arguments, so a wrong type or index crashes R instead of giving an error.",
        [
            ["SEXP"],
            ["@R"],
            ["@r_global"],
            ["nil"],
            ["rtypeof", "rlength"],
            [
                "NILSXP",
                "LGLSXP",
                "INTSXP",
                "REALSXP",
                "CPLXSXP",
                "STRSXP",
                "VECSXP",
                "EXTPTRSXP",
                "RAWSXP",
            ],
            ["NA_INTEGER", "NA_REAL"],
            ["protect", "unprotect"],
            ["preserve", "release"],
            ["alloc", "alloc_matrix"],
            ["mkchar"],
            ["string_elt", "set_string_elt", "vector_elt", "set_vector_elt"],
            ["real_ptr", "int_ptr", "logical_ptr", "complex_ptr", "raw_ptr"],
            ["get_attrib", "set_attrib"],
            ["data_frame"],
        ],
    ),
]

function docstring(name::String)
    b = Base.Docs.Binding(JLBind, Symbol(name))
    md = get(Base.Docs.meta(JLBind), b, nothing)
    md === nothing && error("JLBind.$name has no docstring")
    length(md.docs) == 1 || error("JLBind.$name has more than one docstring")
    return only(values(md.docs)).text[1]::String
end

anchor(name::String) =
    startswith(name, "@") ? "macro-" * lowercase(name[2:end]) : lowercase(name)

# The names a cross-reference such as [`RRef{T}`](@ref) or [`r_class(T)`](@ref
# r_class) points to.
function ref_target(text::AbstractString, target)
    name = target === nothing ? strip(text, '`') : strip(target)
    return String(split(name, ('(', '{'))[1])
end

# Documenter's `(@ref)` links become links to the entry on this page, a
# docstring's `# Section` headings move below the entry's heading, and code
# indented by four spaces (the signatures heading each docstring) becomes a
# fenced block.
function render(doc::String, anchors::Dict{String,String})
    doc = replace(
        doc,
        r"\[([^\]]+)\]\(@ref(?: ([^)]+))?\)" => function (m)
            c = match(r"\[([^\]]+)\]\(@ref(?: ([^)]+))?\)", m)
            name = ref_target(c[1], c[2])
            haskey(anchors, name) || error("cross-reference to unknown name `$name`")
            return "[" * c[1] * "](#" * anchors[name] * ")"
        end,
    )
    out = String[]
    lines = split(chomp(doc), '\n')
    i = 1
    infence = false
    while i <= length(lines)
        line = lines[i]
        if startswith(line, "```")
            infence = !infence
        elseif !infence && startswith(line, "#")
            # A section of a docstring, below the heading of its entry.
            line = "###" * line
        elseif !infence &&
               startswith(line, "    ") &&
               (i == 1 || isempty(strip(lines[i-1])))
            push!(out, "```julia")
            while i <= length(lines) && startswith(lines[i], "    ")
                push!(out, lines[i][5:end])
                i += 1
            end
            push!(out, "```")
            continue
        end
        push!(out, line)
        i += 1
    end
    return join(out, '\n')
end

function page()
    listed = String[]
    anchors = Dict{String,String}()
    for (_, _, entries) in SECTIONS, names in entries, name in names
        name in listed && error("`$name` is listed twice")
        push!(listed, name)
        anchors[name] = anchor(names[1])
    end
    public = sort!([String(n) for n in names(JLBind) if n !== :JLBind])
    unlisted = setdiff(public, listed)
    isempty(unlisted) ||
        error("public names missing from SECTIONS: " * join(unlisted, ", "))
    stale = setdiff(listed, public)
    isempty(stale) || error("names in SECTIONS that are not public: " * join(stale, ", "))

    io = IOBuffer()
    print(
        io,
        """
---
title: "JLBind reference"
---

<!-- Generated by vignettes/articles/jlbind-reference/build.jl from the
docstrings in inst/julia/JLBind/src: do not edit by hand. -->

JLBind is the Julia package your binding package uses to talk to R.
`using JLBind` gives you `@rcall`, `@narrow`, `from_sexp`, `to_sexp`, `SEXP`,
`RRef`, `RVector` and `RDataFrame`; use the rest as `JLBind.name`.
""",
    )
    for (title, intro, entries) in SECTIONS
        print(io, "\n## ", title, "\n")
        isempty(intro) || print(io, "\n", intro, "\n")
        for names in entries
            doc = docstring(names[1])
            for name in names[2:end]
                docstring(name) == doc ||
                    error("`$name` is listed with `$(names[1])` but has another docstring")
            end
            heading = join(("`" * n * "`" for n in names), ", ")
            print(io, "\n### ", heading, " {#", anchor(names[1]), "}\n\n")
            print(io, render(doc, anchors), "\n")
        end
    end
    return String(take!(io))
end

# The page as the panache pre-commit hook formats it, so that the hook leaves it
# as written. Run from the repository root, where panache.toml is.
function format(text::String)
    Sys.which("panache") === nothing &&
        error("panache is not on the PATH: see https://github.com/jolars/panache")
    root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    return cd(root) do
        read(pipeline(`panache format -`; stdin = IOBuffer(text)), String)
    end
end

function main(args)
    text = format(page())
    if "--check" in args
        current = isfile(OUT) ? read(OUT, String) : ""
        if current != text
            println(stderr, "vignettes/articles/jlbind-reference.qmd is out of date; run")
            println(
                stderr,
                "  julia --startup-file=no --project=inst/julia/JLBind vignettes/articles/jlbind-reference/build.jl",
            )
            exit(1)
        end
    else
        write(OUT, text)
        println("Wrote ", normpath(OUT))
    end
end

main(ARGS)
