```@meta
CurrentModule = TOONFormat
```

# User Guide

This guide details the specific features and configuration options available in TOONFormat.jl.

## Decoding

The `decode` function parses TOON strings into native Julia types. By default, it produces `OrderedDict`s to preserve key order.

### Strict Mode
By default, decoding is **strict**. This ensures data integrity by enforcing:
1.  **Array Counts:** The `[N]` header must match the actual number of items.
2.  **Indentation:** Lines must align exactly with the `indent_size`.
3.  **Tabular Width:** Rows must match the number of fields in the header.

```julia
using TOONFormat

# This will throw a ParseError because [3] is declared, but only 2 items exist.
bad_data = """
items[3]:
  1, 2
"""

try
    TOONFormat.decode(bad_data)
catch e
    println(e) # ParseError: Inline array length mismatch...
end

# Disable strict mode to recover data
data = TOONFormat.decode(bad_data; strict=false)
```

### Path Expansion (Configuration Mode)
TOON is excellent for configuration files. The **Path Expansion** feature allows you to write flat, dotted keys that parse into deeply nested objects.

*   **`expand_paths="off"`** (Default): Keys are read exactly as written.
*   **`expand_paths="safe"`**: Keys containing dots are split into nested dictionaries.

**Input:**
```toon
database.primary.host: 10.0.0.1
database.primary.port: 5432
```

**Usage:**
```julia
# Default behavior
d1 = TOONFormat.decode(input)
# d1["database.primary.host"] == "10.0.0.1"

# With expansion
d2 = TOONFormat.decode(input; expand_paths="safe")
# d2["database"]["primary"]["host"] == "10.0.0.1"
```

!!! warning "Conflicts"
    In strict mode, if a path expansion conflicts with an existing value (e.g., `a: 1` vs `a.b: 2`), a `ParseError` is thrown. In non-strict mode, the last value wins or merges strictly.

---

## Encoding

The `encode` function serializes Julia data. It performs automatic optimization to reduce output size.

### Tabular Optimization
The encoder automatically analyzes arrays of dictionaries (`Vector{<:AbstractDict}`). If all dictionaries in the array share the exact same keys and contain primitive values, it switches to **Tabular Format**.

```julia
data = [
    Dict("x" => 1, "y" => 2),
    Dict("x" => 3, "y" => 4)
]

print(TOONFormat.encode(data))
```

**Output:**
```toon
[2]{x,y}:
  1,2
  3,4
```

### Key Folding
Key folding is the inverse of path expansion. It flattens nested dictionaries into dotted keys to reduce indentation depth and file line count.

*   **`key_folding="off"`** (Default): Standard nested objects.
*   **`key_folding="safe"`**: Collapses keys only if they are valid identifiers (alphanumeric).

```julia
config = Dict(
    "server" => Dict(
        "http" => Dict("port" => 80),
        "ssh"  => Dict("port" => 22)
    )
)

print(TOONFormat.encode(config; key_folding="safe"))
```

**Output:**
```toon
server.http.port: 80
server.ssh.port: 22
```

You can limit how deep the folding goes using the `flatten_depth` argument.

### Custom Delimiters
If your data contains many commas (e.g., text descriptions), you can change the delimiter to a pipe `|` or tab `\t` to avoid excessive quoting.

```julia
data = ["Hello, World", "Coordinates: 1,2"]

# Default (uses quotes because of commas)
# [2]: "Hello, World", "Coordinates: 1,2"

# With Pipe Delimiter
print(TOONFormat.encode(data; delimiter='|'))
```

**Output:**
```toon
[2|]: Hello, World|Coordinates: 1,2
```

---

## Type Mapping

TOONFormat.jl maps TOON types to standard Julia types:

| TOON Type | Julia Type | Notes |
| :--- | :--- | :--- |
| **Object** | `OrderedDict{String, Any}` | Preserves insertion order. |
| **Array** | `Vector{Any}` | Can be heterogeneous. |
| **String** | `String` | Handles escaping automatically. |
| **Number** | `Int` or `Float64` | Distinction is preserved. |
| **Boolean** | `Bool` | `true` / `false`. |
| **Null** | `Nothing` | `null` maps to `nothing`. |

### Julia-Specific Types
The encoder handles some Julia specific types gracefully:
*   **`Symbol`**: Converted to String.
*   **`Date` / `DateTime`**: Converted to ISO Strings.
*   **`Set` / `Tuple`**: Converted to Arrays.
*   **`NaN` / `Inf`**: Converted to `null` (as per JSON/TOON spec).