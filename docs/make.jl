using CodeTracer
using Documenter

makedocs(;
    modules=[CodeTracer],
    authors="Robert Feldt",
    repo="https://github.com/robertfeldt/CodeTracer.jl/blob/{commit}{path}#L{line}",
    sitename="CodeTracer.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://robertfeldt.github.io/CodeTracer.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/robertfeldt/CodeTracer.jl",
)
