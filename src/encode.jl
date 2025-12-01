"""
    EncoderState

Maintains the internal state during the encoding process.

# Fields
- `io::IO`: The output stream where the TOON document is written.
- `opts::TOONOptions`: Configuration options (indent size, delimiter, etc.).
- `depth::Int`: The current indentation depth level (0-indexed).
- `active_delimiter::Char`: The delimiter used in the current array scope, used for decision making on quoting.
"""
mutable struct EncoderState
    io::IO
    opts::TOONOptions
    depth::Int
    active_delimiter::Char # Tracks the delimiter of the CURRENT array scope
end

"""
    write_indent(state::EncoderState)

Writes indentation based on current depth and indent_size.
"""
function write_indent(state::EncoderState)
    # Indent is space-only (Spec §12)
    n = state.depth * state.opts.indent_size
    for _ in 1:n
        write(state.io, ' ')
    end
end

"""
    encode(io::IO, data, opts::TOONOptions=DEFAULT_OPTS)

Main entry point for encoding data to TOON into an IO stream.
"""
function encode(io::IO, data, opts::TOONOptions=DEFAULT_OPTS)
    # Normalization: Spec §3 requires converting types to JSON model first.
    # We rely on JSON.lower/StructUtils logic implicitly, or handle it here.
    
    state = EncoderState(io, opts, 0, opts.delimiter)
    
    # Root form discovery (Spec §5)
    # If data is array, we write a root header.
    # If object, we write fields.
    # If primitive, write single line.
    
    encode_value(state, data, nothing; is_root=true)
end

"""
    encode(data; kw...) -> String

Serializes a Julia data structure into the TOON format.

# Arguments
- `data`: The data to encode. Supported types include Dicts, Arrays, Strings, Numbers, Bools, `nothing`, and structs supported by `JSON.lower`.

# Keywords
- `indent_size::Int=2`: Number of spaces per indentation level.
- `delimiter::Char=','`: The preferred delimiter for arrays (e.g., `,`, `|`, `\t`).
- `key_folding::String="off"`: If "safe", collapses nested objects into dotted keys where possible (e.g., `server.port: 80`).
"""
function encode(data; kw...) 
    buf = IOBuffer()
    opts = TOONOptions(; kw...)
    encode(buf, data, opts)
    return String(take!(buf))
end


function encode_value(state::EncoderState, val::Nothing, key; is_root=false, indent_first=true)
    write_line(state, key, "null")
end

function encode_value(state::EncoderState, val::Bool, key; is_root=false, indent_first=true)
    write_line(state, key, val ? "true" : "false")
end

function encode_value(state::EncoderState, val::Number, key; is_root=false, indent_first=true)
    # Spec §2: Canonical number form
    # Spec §3: NaN/Inf -> null
    if !isfinite(val)
        write_line(state, key, "null")
    else
        write_line(state, key, canonical_number(val))
    end
end

function encode_value(state::EncoderState, val::AbstractString, key; is_root=false, indent_first=true)
    # Value quoting uses Document Delimiter for Object values (Spec §11)
    q = should_quote(val, state.opts.delimiter, state.opts.delimiter)
    s = q ? "\"" * escape_toon_string(val) * "\"" : val
    write_line(state, key, s)
end

# --- Julia Type Normalization Overloads ---

function encode_value(state::EncoderState, val::Symbol, key; is_root=false, indent_first=true)
    # Normalize Symbols to String
    encode_value(state, string(val), key; is_root=is_root, indent_first=indent_first)
end

function encode_value(state::EncoderState, val::Union{Date, DateTime}, key; is_root=false, indent_first=true)
    # Normalize Dates to String
    # Explicitly quote to ensure string interpretation and match test expectations
    s_val = string(val)
    write_line(state, key, "\"" * s_val * "\"")
end

function encode_value(state::EncoderState, val::Union{AbstractSet, Tuple}, key; is_root=false, indent_first=true)
    # Normalize Sets and Tuples to Array
    encode_value(state, collect(val), key; is_root=is_root, indent_first=indent_first)
end

# --- Arrays ---

function encode_value(state::EncoderState, val::AbstractArray, key; is_root=false, indent_first=true)
    # Spec §9: Array Handling
    len = length(val)
    
    # 1. Detect if Tabular (Spec §9.3)
    fields = detect_tabular_schema(val)
    
    # Determine Header
    delim = state.opts.delimiter
    delim_str = (delim == ',') ? "" : string(delim)
    
    header = IOBuffer()
    if !isnothing(key)
        write(header, encode_key(key))
    end
    write(header, "[$(len)$(delim_str)]")
    
    if !isnothing(fields)
        # Tabular Header
        # Schema keys are joined by the delimiter inside the brackets
        write(header, "{")
        # Use delimiter for joining header fields to match tests
        join(header, [encode_key(f) for f in fields], delim)
        write(header, "}")
    end
    
    write(header, ":")
    
    # Write Header Line
    if !is_root && indent_first
        write_indent(state)
    end
    write(state.io, take!(header))
    
    # Handle Empty Array
    if len == 0
        write(state.io, "\n")
        return
    end

    # 2. Write Body
    if !isnothing(fields)
        # TABULAR BODY
        write(state.io, "\n")
        state.depth += 1
        old_delim = state.active_delimiter
        state.active_delimiter = delim
        
        for item in val
            write_indent(state)
            # Write row values joined by delimiter
            first_col = true
            for f in fields
                if !first_col; write(state.io, delim); end
                v = item[f]
                # Tabular cells use Active Delimiter for quoting rules (Spec §11)
                s_val = stringify_primitive(v)
                
                # Only apply quoting logic to Strings.
                if isa(v, AbstractString)
                    q = should_quote(s_val, delim, state.opts.delimiter)
                    write(state.io, q ? "\"" * escape_toon_string(s_val) * "\"" : s_val)
                else
                    write(state.io, s_val)
                end
                
                first_col = false
            end
            write(state.io, "\n")
        end
        
        state.active_delimiter = old_delim
        state.depth -= 1
        
    elseif is_primitive_array(val)
        # INLINE PRIMITIVE ARRAY (Spec §9.1)
        # Header is already written ending in colon
        write(state.io, " ") # Mandatory space after colon
        
        first_item = true
        for item in val
            if !first_item
                write(state.io, delim)
            end
            
            s_val = stringify_primitive(item)
            
            if isa(item, AbstractString)
                q = should_quote(s_val, delim, state.opts.delimiter)
                write(state.io, q ? "\"" * escape_toon_string(s_val) * "\"" : s_val)
            else
                write(state.io, s_val)
            end
            
            first_item = false
        end
        write(state.io, "\n")
        
    else
        # EXPANDED LIST (Spec §9.2 / 9.4)
        write(state.io, "\n")
        state.depth += 1
        
        for item in val
            # List Item Prefix
            write_indent(state)
            write(state.io, "- ") 
            
            # Complex case: Objects as list items (Spec §10)
            if isa(item, AbstractDict)
                pairs_l = collect(pairs(item))
                if isempty(pairs_l)
                    write(state.io, "\n")
                else
                    k1, v1 = pairs_l[1]
                    s_key = encode_key(string(k1))
                    
                    # Check for Tabular Array as first field (Spec §10)
                    # Encoders MUST emit the tabular header on the hyphen line.
                    # Rows MUST appear at depth +2 (relative to hyphen line).
                    is_tabular_first = isa(v1, AbstractArray) && !isnothing(detect_tabular_schema(v1))
                    
                    if is_tabular_first
                        write(state.io, s_key)
                        
                        # Temporarily increase depth so encode_value writes rows at depth+2
                        state.depth += 1
                        
                        # Write array (header + body). indent_first=false prevents newline/indent before header.
                        encode_value(state, v1, nothing; is_root=false, indent_first=false)
                        
                        state.depth -= 1
                    else
                        # Standard first field
                        write(state.io, s_key)
                        
                        if isa(v1, AbstractArray) || isa(v1, AbstractDict)
                             if isa(v1, AbstractArray)
                                 # For inline nested array, we need to indent body relative to key.
                                 # Key is at current indent level. Array body should be +1 level.
                                 state.depth += 1
                                 encode_value(state, v1, nothing; is_root=false, indent_first=false) 
                                 state.depth -= 1
                             else
                                 write(state.io, ":\n")
                                 state.depth += 1
                                 encode_value(state, v1, nothing)
                                 state.depth -= 1
                             end
                        else
                            write(state.io, ": ")
                            encode_value(state, v1, nothing)
                        end
                    end
                    
                    if length(pairs_l) > 1
                        state.depth += 1
                        for (k, v) in pairs_l[2:end]
                            encode_value(state, v, string(k))
                        end
                        state.depth -= 1
                    end
                end
            elseif isa(item, AbstractArray)
                 # Nested Array inside list
                 # The "- " prefix effectively acts as the indentation for the nested array's header
                 # So we suppress the initial indent
                 encode_value(state, item, nothing; is_root=false, indent_first=false)
            else
                encode_value(state, item, nothing)
            end
        end
        
        state.depth -= 1
    end
end

# --- Objects ---

function encode_value(state::EncoderState, val::AbstractDict, key; is_root=false, indent_first=true)
    # Spec §8: Objects
    
    if !isnothing(key)
        if !is_root && indent_first
            write_indent(state)
        end
        write(state.io, encode_key(key))
        write(state.io, ":")
        
        if isempty(val)
             write(state.io, "\n")
             return
        end
        
        write(state.io, "\n")
    end
    
    new_depth = (!isnothing(key) && !is_root) ? state.depth + 1 : state.depth
    old_depth = state.depth
    state.depth = new_depth
    
    for (k, v) in val
        k_str = string(k)

        # CHECK KEY FOLDING CONDITION
        # 1. Enabled
        # 2. Value is Dict (nesting)
        # 3. Value is NOT empty
        # 4. Key is a valid identifier (alphanumeric).
        # 5. Flatten depth allows at least 2 segments (current + next).
        
        should_fold = false
        if state.opts.key_folding == "safe" && 
           isa(v, AbstractDict) && 
           !isempty(v) &&
           is_foldable_key(k_str) &&
           (1 + 1 <= state.opts.flatten_depth)
           
           # Collision Detection:
           # If folding 'k' results in 'k.child...', we must ensure 'k.child...' doesn't 
           # conflict with literal keys in this object.
           has_collision = false
           prefix_check = k_str * "."
           for other_k in keys(val)
               if other_k != k && startswith(string(other_k), prefix_check)
                   has_collision = true
                   break
               end
           end
           
           should_fold = !has_collision
        end
           
        if should_fold
            encode_folded_dict(state, v, k_str)
        else
            # Standard logic
            encode_value(state, v, k_str)
        end
    end
    
    state.depth = old_depth
end

"""
    encode_folded_dict(state, val, prefix)

Recursively flattens nested dictionaries into dotted keys until a terminal value
(primitive, array, non-foldable key, or depth limit) is reached.
"""
function encode_folded_dict(state::EncoderState, val::AbstractDict, prefix::String)
    # val can have multiple keys. We iterate and fold each branch if possible.
    for (k, v) in val
        k_str = string(k)
        
        # Calculate resulting segment count if we folded this key
        # prefix segments + 1
        result_segments = count(c -> c == '.', prefix) + 1 + 1
        
        # Check if we can continue folding recursively
        # 1. v must be Dict
        # 2. k must be foldable
        # 3. Resulting key (prefix.k.child) would fit in limit
        
        can_recurse = state.opts.key_folding == "safe" && 
                      isa(v, AbstractDict) && 
                      !isempty(v) &&
                      is_foldable_key(k_str) &&
                      (result_segments + 1 <= state.opts.flatten_depth)
        
        if can_recurse
           # Recurse with extended prefix
           encode_folded_dict(state, v, prefix * "." * k_str)
        elseif is_foldable_key(k_str) && (result_segments <= state.opts.flatten_depth)
           # Terminal: Write the combined key and value
           full_key = prefix * "." * k_str
           encode_value(state, v, full_key)
        else
           # Unfoldable key encountered in chain (e.g., "invalid-key")
           # OR limit reached.
           # We cannot dot-append this key.
           # We must treat 'prefix' as the parent key for this branch.
           
           # Write prefix as a key
           write_indent(state)
           write(state.io, encode_key(prefix))
           write(state.io, ":\n")
           
           # Write current k/v nested under prefix
           state.depth += 1
           encode_value(state, v, k_str)
           state.depth -= 1
        end
    end
end

"""
    is_foldable_key(k)

Returns true if k contains only characters valid for an unquoted TOON key segment 
(alphanumeric + underscore). If it contains dots or special chars, it shouldn't be folded.
"""
function is_foldable_key(k::AbstractString)
    return occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", k)
end


# --- Helpers ---

function write_line(state::EncoderState, key::Union{Nothing, AbstractString}, content::String)
    if !isnothing(key)
        write_indent(state)
        write(state.io, encode_key(key))
        write(state.io, ": ")
    elseif !isempty(content)
        # Primitives inside lists (handled by - prefix in caller) or inline context
        # If we are here, caller handled indentation/prefix
        write(state.io, "") 
    end
    
    write(state.io, content)
    write(state.io, "\n")
end

function stringify_primitive(x)
    if x === nothing; return "null"; end
    if x === true; return "true"; end
    if x === false; return "false"; end
    if isa(x, Number); return canonical_number(x); end
    return string(x)
end

function is_primitive(x)
    return isa(x, Number) || isa(x, AbstractString) || isa(x, Bool) || isnothing(x) || isa(x, Symbol) || isa(x, Date) || isa(x, DateTime)
end

function is_primitive_array(arr::AbstractArray)
    # Efficiently check all elements are primitive
    return all(is_primitive, arr)
end

function detect_tabular_schema(arr::AbstractArray)
    if isempty(arr); return nothing; end
    if !all(x -> isa(x, AbstractDict), arr); return nothing; end
    
    first_item = arr[1]
    schema_keys = keys(first_item)
    
    valid_schema = all(item -> keys(item) == schema_keys, arr)
    if !valid_schema; return nothing; end
    
    valid_values = all(item -> all(is_primitive, values(item)), arr)
    if !valid_values; return nothing; end
    
    # Return keys in their natural order (important for OrderedDict)
    return string.(collect(schema_keys))
end
