# TOONFormat [![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://imohag9.github.io/TOONFormat.jl/dev/) [![Build Status](https://github.com/imohag9/TOONFormat.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/imohag9/TOONFormat.jl/actions/workflows/CI.yml?query=branch%3Amain) [![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

**TOONFormat.jl** is a pure Julia implementation of the TOON format (The Object-Oriented Notation), a modern data serialization format designed to be a strict, type-safe, and dense alternative to JSON and YAML.

## Why TOONFormat?

TOONFormat combines the hierarchy of YAML, the structure of JSON, and the density of CSV.

1.  **Tabular Optimization**: Automatically detects arrays of uniform objects and encodes them as headers+rows, reducing file size by 40-60% compared to JSON.
2.  **Configuration Friendly**: Supports **Key Folding** (Dot-Notation) to flatten deeply nested configuration files without losing structure.
3.  **Strict Validation**: Headers include item counts (e.g., `items[50]`), allowing the parser to instantly detect truncated files or transmission errors.
4.  **Type Safety**: Distinguishes between integers and floats, minimizing parsing ambiguity.


| Feature | JSON | YAML | TOON |
| :--- | :---: | :---: | :---: |
| **Strict Arrays** | ❌ | ❌ | ✅ (Includes length headers) |
| **Tabular Compression** | ❌ | ❌ | ✅ (Up to 50% smaller) |
| **Config Friendly** | ❌ | ✅ | ✅ (Dot-notation) |
| **Parsing Speed** | Fast | Slow | Moderate |

## Installation

```julia
using Pkg
Pkg.add("TOONFormat")
```

## Quick Start

### Decoding

TOONFormat.jl can automatically expand dotted keys into nested objects using `expand_paths="safe"`.

```julia
using TOONFormat

toon_str = """
server.host: localhost
server.port: 8080

users[2]{id,name}:
  1,Alice
  2,Bob
"""

data = TOONFormat.decode(toon_str; expand_paths="safe")

# Result:
# OrderedCollections.OrderedDict{String, Any}("server" =>
#  OrderedCollections.OrderedDict{String, Any}("host" =>
#   "localhost", "port" => 8080), "users" => Any[OrderedCollections.
#   OrderedDict{String, Any}("id" => 1, "name" => "Alice"), 
#   OrderedCollections.OrderedDict{String, Any}("id" => 2, "name" 
#   => "Bob")])

```

### Encoding

The encoder automatically detects tabular data and uses key folding if requested.

```julia
using TOONFormat


data = Dict(
    "meta" => Dict("version" => "1.0", "env" => "prod"),
    "inventory" => [
        Dict("sku" => "A100", "qty" => 15),
        Dict("sku" => "B200", "qty" => 5),
        Dict("sku" => "C300", "qty" => 0)
    ]
)

# Encode with key folding enabled for compact config style
print(TOONFormat.encode(data; key_folding="safe"))
```

**Output:**
```TOONFormat
meta.version: 1.0
meta.env: prod

inventory[3]{sku,qty}:
  A100,15
  B200,5
  C300,0
```

## API Reference

### `decode(str; kw...)` 

Parses TOONFormat data into Julia `OrderedDict`, `Vector`, and primitive types.

*   **`strict::Bool`** (default: `true`): If true, enforces strict array length checks (`[N]`) and indentation rules.
*   **`expand_paths::String`** (default: `"off"`):
    *   `"off"`: Keeps keys as-is (e.g., `"server.port"`).
    *   `"safe"`: Expands `"server.port"` into nested Dictionaries.

### `encode(data; kw...)`

Serializes Julia data to TOONFormat.

*   **`key_folding::String`** (default: `"off"`):
    *   `"safe"`: Collapses nested dictionaries into dotted keys (e.g., `a.b.c: val`) to save vertical space.
*   **`delimiter::Char`** (default: `,`): The separator for array items. Use `'|'` or `'\t'` if your data contains many commas.
*   **`flatten_depth::Float64`** (default: `Inf`): Controls how deep key folding should go before stopping.

## Specification Compliance

This package implements **Version 3.0** of the TOONFormat specification.

*   **Reference:** [https://github.com/TOONFormat-format/spec](https://github.com/TOONFormat-format/spec)
*   **Conformance:** Validated against the standard TOONFormat conformance test suite.

## Development Disclosure

Multiple AI-powered tools were used in various aspects of the development of this package, including drafting implementation logic, generating test fixtures, and formatting documentation. All code has been manually reviewed, tested against the conformance suite, and verified for correctness.

## License

MIT License. See [LICENSE](LICENSE) for details.
