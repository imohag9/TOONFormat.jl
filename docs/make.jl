using TOONFormat
using Documenter

DocMeta.setdocmeta!(TOONFormat, :DocTestSetup, :(using TOONFormat); recursive=true)

makedocs(;
    modules=[TOONFormat],
    authors="imohag9 <souidi.hamza90@gmail.com> and contributors",
    sitename="TOONFormat.jl",
    format=Documenter.HTML(;
        canonical="https://imohag9.github.io/TOONFormat.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "User Guide" => "guide.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/imohag9/TOONFormat.jl",
    devbranch="main",
)
