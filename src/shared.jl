"""
    TOONOptions

Configuration for TOON encoding and decoding.
"""
struct TOONOptions
    indent_size::Int
    delimiter::Char # Document delimiter (default ',')
    strict::Bool    # Decoder: enforce counts, indentation (default true)
    key_folding::String # "off", "safe"
    flatten_depth::Float64 
    expand_paths::String # "off", "safe"
end

function TOONOptions(; 
    indent_size=2, 
    delimiter=',', 
    strict=true,
    key_folding="off",
    flatten_depth=Inf,
    expand_paths="off"
)
    !(key_folding in ["off","safe"]) && throw(ArgumentError("valid values for key_folding argument : off , safe"))
    !(expand_paths in ["off","safe"]) && throw(ArgumentError("valid values for expand_paths argument : off , safe"))
    return TOONOptions(indent_size, delimiter, strict, key_folding, flatten_depth, expand_paths)
end

const DEFAULT_OPTS = TOONOptions()
export DEFAULT_OPTS

"""
    canonical_number(x::Real) -> String

Encodes numbers according to TOON Spec §2:
- No exponent notation (1e6 -> 1000000).
- No leading zeros.
- No trailing zeros in fractional part.
- -0 normalized to 0.
- Finite numbers only (NaN/Inf -> null, handled elsewhere).
"""
function canonical_number(x::Integer)
    return string(x)
end

using Printf

function canonical_number(x::AbstractFloat)
    if x == 0.0
        return "0"
    end
    
    s = string(x)
    
    if occursin('e', s) || occursin('E', s)
        str = @sprintf("%.20f", x)
        str = replace(str, r"0+$" => "")
        if endswith(str, ".")
            str = str[1:end-1]
        end
        return str
    else
        if occursin('.', s)
             s = replace(s, r"0+$" => "")
             if endswith(s, ".")
                 s = s[1:end-1]
             end
        end
        return s
    end
end

function escape_toon_string(s::AbstractString)
    buf = IOBuffer()
    for c in s
        if c == '\\'
            write(buf, "\\\\")
        elseif c == '"'
            write(buf, "\\\"")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        else
            write(buf, c)
        end
    end
    return String(take!(buf))
end

"""
    should_quote(s::AbstractString, active_delim::Char, doc_delim::Char) -> Bool

Determines if a string MUST be quoted according to TOON Spec §7.2.
"""
function should_quote(s::AbstractString, active_delim::Char, doc_delim::Char)
    if isempty(s) && return true; end
    if (isspace(first(s)) || isspace(last(s))) && return true; end
    if (s == "true" || s == "false" || s == "null") && return true; end
    if occursin(r"^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$"i, s) || occursin(r"^0\d+$", s)
        return true
    end
    if occursin(r"[:\"\\\[\]\{\}]", s)
        return true
    end
    if any(iscntrl, s)
        return true
    end
    if contains(s, active_delim) || contains(s, doc_delim)
        return true
    end
    if startswith(s, "-")
        return true
    end
    return false
end

"""
    encode_key(k::AbstractString) -> String

Encodes object keys. Spec §7.3: Unquoted if ^[A-Za-z_][A-Za-z0-9_.]*
"""
function encode_key(k::AbstractString)
    if occursin(r"^[A-Za-z_][A-Za-z0-9_.]*$", k)
        return k
    else
        return "\"" * escape_toon_string(k) * "\""
    end
end

# ============================================================================
# 4. Header Parsing Utilities (Spec §6)
# ============================================================================

struct HeaderInfo
    key::Union{Nothing, String}
    length::Int
    delimiter::Char # ',' | '\t' | '|'
    fields::Vector{String} # For tabular
end

"""
    parse_header_line(line::AbstractString) -> Union{HeaderInfo, Nothing}

Parses a header line like `key[N]:` or `key[N]{f1,f2}:`. 
Returns nothing if not a valid header.
"""
function parse_header_line(line::AbstractString)
    if !endswith(line, ":")
        return nothing
    end
    
    content = line[1:end-1] 
    
    bracket_end = findlast(']', content)
    isnothing(bracket_end) && return nothing
    
    bracket_start = findlast('[', content[1:bracket_end])
    isnothing(bracket_start) && return nothing
    
    len_seg = content[bracket_start+1 : bracket_end-1]
    
    delimiter = ','
    len_str = len_seg
    
    if !isempty(len_seg)
        last_char = len_seg[end]
        if last_char == '\t' || last_char == '|'
            delimiter = last_char
            len_str = len_seg[1:end-1]
        end
    end
    
    length_val = tryparse(Int, len_str)
    isnothing(length_val) && return nothing
    
    key_part = content[1:bracket_start-1]
    key = nothing
    if !isempty(key_part)
        if startswith(key_part, "\"") && endswith(key_part, "\"")
             key = key_part
        else
             key = key_part
        end
    end
    
    fields_part = content[bracket_end+1:end]
    fields = String[]
    
    if startswith(fields_part, "{") && endswith(fields_part, "}")
        inner = fields_part[2:end-1]
        
        parts = String[]
        start = 1
        in_quote = false
        esc = false
        

        
        h_delim = delimiter
        

        
        for (i, c) in enumerate(inner)
            if esc
                esc = false; continue
            end
            if c == '\\'; esc = true; continue; end
            if c == '"'; in_quote = !in_quote; end
            
            if c == h_delim && !in_quote
                push!(fields, strip(inner[start:i-1]))
                start = i + 1
            end
        end
        push!(fields, strip(inner[start:end]))
        

        
    elseif !isempty(fields_part)
        return nothing
    end
    
    return HeaderInfo(key, length_val, delimiter, fields)
end

"""
    deep_merge!(target, source)

Recursively merges source dict into target dict using `mergewith!`.
"""
function deep_merge!(target::AbstractDict, source::AbstractDict)
    mergewith!(target, source) do v1, v2
        if isa(v1, AbstractDict) && isa(v2, AbstractDict)
            deep_merge!(v1, v2)
        else
            v2
        end
    end
end