```@meta
CurrentModule = TOONFormat
```

# TOONFormat.jl

**TOONFormat.jl** is a pure Julia implementation of **TOON** (The Object-Oriented Notation). It is a modern data serialization format designed to be a strict, type-safe, and dense alternative to JSON and YAML.

## Overview

TOON combines the best features of existing formats:
1.  **JSON's Structure:** It maps directly to Dictionaries, Arrays, and Primitives.
2.  **YAML's Readability:** It supports clean syntax, key folding, and comments.
3.  **CSV's Density:** It automatically compresses arrays of objects into tabular headers and rows.

## Installation

The package is available for Julia 1.11+.

```julia
using Pkg
Pkg.add("TOONFormat")
```

## Quick Start

### Encoding (Writing)

TOONFormat automatically detects if your data can be compressed into a table.

```julia
using TOONFormat

data = Dict(
    "users" => [
        Dict("id" => 1, "name" => "Alice", "role" => "admin"),
        Dict("id" => 2, "name" => "Bob", "role" => "dev")
    ]
)

# Output is compact and type-safe
println(TOONFormat.encode(data))
```

**Output:**
```toon
users[2]{id,name,role}:
  1,Alice,admin
  2,Bob,dev
```

### Decoding (Reading)

```julia
toon_str = """
server.host: localhost
server.port: 8080
"""

# "safe" expansion turns dot-notation into nested Dicts
config = TOONFormat.decode(toon_str; expand_paths="safe")

println(config["server"]["port"]) # 8080
```



Check out the documentationfor deep dives into features like **Key Folding**, **Tabular Arrays**, and **Strict Mode**.
