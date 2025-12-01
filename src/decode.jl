"""
    ParseError <: Exception

Exception thrown when the TOON decoder encounters invalid syntax or structural issues.

# Fields
- `msg::String`: A description of the error.
- `line::Int`: The line number in the source string where the error occurred (0 if unknown or global).
"""
struct ParseError <: Exception
    msg::String
    line::Int
end

"""
    DecoderState

Maintains the internal state during the decoding process.

# Fields
- `lines::Vector{String}`: The input document split into lines.
- `current_line_idx::Int`: The current 1-based line index being parsed.
- `opts::TOONOptions`: Configuration options controlling the decoder's behavior (strictness, indentation, etc.).
"""
mutable struct DecoderState
    lines::Vector{String}
    current_line_idx::Int
    opts::TOONOptions
end

"""
    decode(str::AbstractString; kw...) -> Any

Decodes a TOON-formatted string into native Julia data structures.

# Return Values
Returns a `OrderedDict` (ordered dictionary), `Vector`, or primitive value (String, Number, Bool, Nothing) 
depending on the root element of the TOON document.

# Keywords
- `strict::Bool=true`: If true, enforces strict indentation rules and array length checks.
- `expand_paths::String="off"`: Controls dot-notation key expansion (e.g., "a.b: 1" -> `Dict("a" => Dict("b" => 1))`). 
   Options are "off" or "safe".
- `indent_size::Int=2`: The number of spaces used for one level of indentation.

```
"""
function decode(str::AbstractString; kw...)#::AbstractDict
    opts = TOONOptions(; kw...)
    clean_str = replace(str, "\r\n" => "\n", "\r" => "\n")
    lines = split(clean_str, '\n')
    if !isempty(lines) && isempty(lines[end])
        pop!(lines)
    end
    state = DecoderState(lines, 1, opts)
    skip_blank_lines!(state)
    if state.current_line_idx > length(state.lines)
        return OrderedDict{String,Any}()
    end
    line = state.lines[state.current_line_idx]
    
    # Check for multiple primitives at root (invalid)
    if count_non_blank_lines(state) > 1 && !occursin(r":", line) && !startswith(line, "[") && !occursin(r"^[^:]+:$", line)
         if opts.strict
             next_idx = state.current_line_idx + 1
             while next_idx <= length(state.lines)
                 next_l = strip(state.lines[next_idx])
                 if !isempty(next_l)
                     throw(ParseError("Line $(state.current_line_idx): Missing colon after key.", state.current_line_idx))
                 end
                 next_idx += 1
             end
         end
    end

    header = parse_header_line(line)
    if !isnothing(header)
        arr = parse_array(state, header, 0)
        if !isnothing(header.key)
            obj = OrderedDict{String, Any}()
            set_value_with_path!(obj, header.key, arr, opts; is_quoted=startswith(header.key, "\""))
            return obj
        else
            return arr
        end
    end

    header_vals = parse_header_with_values(line)
    if !isnothing(header_vals)
        h_info, val_part = header_vals
        arr = parse_inline_values(val_part, h_info, opts)
        state.current_line_idx += 1
        if !isnothing(h_info.key)
            obj = OrderedDict{String, Any}()
            set_value_with_path!(obj, h_info.key, arr, opts; is_quoted=startswith(h_info.key, "\""))
            return obj
        else
            return arr
        end
    end

    col_idx = find_split_colon(line)
    is_obj_syntax = col_idx > 0
    
    if is_obj_syntax
        return parse_object(state, 0)
    else
        if count_non_blank_lines(state) > 1
            if opts.strict
                throw(ParseError("Line $(state.current_line_idx): Missing colon after key.", state.current_line_idx))
            else
                return parse_object(state, 0)
            end
        end
        return parse_primitive_token(strip(line); strict=opts.strict)
    end
end


# --- Parsing Primitives ---

function parse_primitive_token(token::AbstractString; strict=false)
    if isempty(token); return ""; end

    if startswith(token, "\"")
        if !endswith(token, "\"") || length(token) < 2
             if strict; throw(ParseError("Unterminated string", 0)); end
             return String(token)
        end
        inner = token[2:end-1]
        
        if strict
            i = 1
            while i <= length(inner)
                if inner[i] == '\\'
                    if i == length(inner)
                        throw(ParseError("Invalid escape sequence at end of string", 0))
                    end
                    next_char = inner[i+1]
                    if !(next_char in ['"', '\\', 'n', 'r', 't'])
                        throw(ParseError("Invalid escape sequence \\$next_char", 0))
                    end
                    i += 2
                else
                    i += 1
                end
            end
        end
        
        return unescape_toon_string(inner)
    elseif token == "true"
        return true
    elseif token == "false"
        return false
    elseif token == "null"
        return nothing
    else
        if occursin(r"^-?0\d+", token)
            return String(token)
        end
        num = tryparse(Float64, token)
        if !isnothing(num)
            if isinteger(num)
                return Int(num)
            end
            return num
        end
        return String(token)
    end
end

function unescape_toon_string(s::AbstractString)
    buf = IOBuffer()
    i = 1
    len = length(s)
    while i <= len
        c = s[i]
        if c == '\\' && i < len
            next_c = s[i+1]
            if next_c == '"'
                write(buf, '"')
            elseif next_c == '\\'
                write(buf, '\\')
            elseif next_c == 'n'
                write(buf, '\n')
            elseif next_c == 'r'
                write(buf, '\r')
            elseif next_c == 't'
                write(buf, '\t')
            else
                write(buf, '\\')
                write(buf, next_c)
            end
            i += 2
        else
            write(buf, c)
            i += 1
        end
    end
    return String(take!(buf))
end

# --- Parsing Objects ---

function parse_object(state::DecoderState, depth::Int)
    obj = OrderedDict{String, Any}()
    
    while state.current_line_idx <= length(state.lines)
        line = state.lines[state.current_line_idx]
        
        if isempty(strip(line))
            state.current_line_idx += 1
            continue
        end
        
        indent, content = get_indentation(line, state.opts)
        
        if indent < depth
            return obj
        elseif indent > depth
            throw(ParseError("Indentation error: Unexpected nesting", state.current_line_idx))
        end
        
        col_idx = find_split_colon(String(content))
        key_str = ""
        val_part = ""
        
        if col_idx > 0
            key_str = strip(content[1:col_idx-1])
            val_part = strip(content[col_idx+1:end])
        else
            if state.opts.strict
                throw(ParseError("Missing colon in object field", state.current_line_idx))
            end
            space_idx = findfirst(isspace, content)
            if isnothing(space_idx)
                key_str = content
                val_part = ""
            else
                key_str = content[1:space_idx-1]
                val_part = lstrip(content[space_idx:end])
            end
        end
        
        is_quoted_key = startswith(key_str, "\"")
        key = parse_primitive_token(key_str; strict=state.opts.strict)
        if !isa(key, String); key = string(key); end
        
        state.current_line_idx += 1
        
        if isempty(val_part)
            next_indent = peek_indent(state)
            if next_indent > depth
                parsed_val = parse_object(state, depth + 1)
                set_value_with_path!(obj, key, parsed_val, state.opts; is_quoted=is_quoted_key)
            else
                set_value_with_path!(obj, key, OrderedDict{String, Any}(), state.opts; is_quoted=is_quoted_key)
            end
        else
            full_header = parse_header_with_values(content)
            if !isnothing(full_header)
                 h_info, inline_vals = full_header
                 real_key = h_info.key
                 is_q = !isnothing(real_key) && startswith(real_key, "\"")
                 if isnothing(real_key); throw(ParseError("Root array inside object must have key", state.current_line_idx)); end
                 arr = parse_inline_values(inline_vals, h_info, state.opts)
                 set_value_with_path!(obj, real_key, arr, state.opts; is_quoted=is_q)
            else
                 set_value_with_path!(obj, key, parse_primitive_token(val_part; strict=state.opts.strict), state.opts; is_quoted=is_quoted_key)
            end
        end
    end
    return obj
end

# --- Parsing Arrays ---

function parse_array(state::DecoderState, header::HeaderInfo, depth::Int; consumed_header=false)
    if !consumed_header
        state.current_line_idx += 1
    end
    
    if !isempty(header.fields)
        return parse_tabular_array(state, header, depth)
    end
    
    arr = []
    
    while state.current_line_idx <= length(state.lines)
        line = state.lines[state.current_line_idx]
        
        # 1. Blank Line Check with Lookahead for Termination
        if isempty(strip(line))
            # If strict, blank lines are forbidden INSIDE array.
            # But they are allowed AFTER array.
            # We must peek to see if next non-blank is indented as array item.
            peek_idx = state.current_line_idx + 1
            is_inside = false
            has_next = false
            
            while peek_idx <= length(state.lines)
                peek_l = state.lines[peek_idx]
                if !isempty(strip(peek_l))
                    has_next = true
                    p_indent, _ = get_indentation(peek_l, state.opts)
                    # If indentation matches array items, it's inside.
                    if p_indent == depth + 1
                        is_inside = true
                    end
                    break
                end
                peek_idx += 1
            end
            
            if is_inside && state.opts.strict
                 throw(ParseError("Strict mode: Blank line inside array", state.current_line_idx))
            end
            
            # If not strict or not inside, skip blank lines logic
            state.current_line_idx += 1
            continue
        end
        
        indent, content = get_indentation(line, state.opts)
        
        expected_indent = depth + 1
        if indent < expected_indent
            break
        elseif indent > expected_indent
             throw(ParseError("Indentation error in array list", state.current_line_idx))
        end
        
        if !startswith(content, "- ")
             if state.opts.strict || !isempty(content)
                 throw(ParseError("Array item must start with '- '", state.current_line_idx))
             end
             state.current_line_idx += 1; continue
        end
        
        item_content = strip(content[3:end])
        state.current_line_idx += 1 
        
        nested_header = parse_header_line(item_content)
        if !isnothing(nested_header) && isnothing(nested_header.key)
            push!(arr, parse_array(state, nested_header, expected_indent; consumed_header=true))
            continue
        end

        nested_inline_header = parse_header_with_values(item_content)
        if !isnothing(nested_inline_header)
            h_info, inline_vals = nested_inline_header
            if isnothing(h_info.key)
                push!(arr, parse_inline_values(inline_vals, h_info, state.opts))
                continue
            end
        end

        hyphen_header = parse_header_line(item_content)
        if !isnothing(hyphen_header) && !isnothing(hyphen_header.key)
            obj = OrderedDict{String, Any}()
            arr_val = parse_array(state, hyphen_header, indent + 1; consumed_header=true)
            set_value_with_path!(obj, hyphen_header.key, arr_val, state.opts; is_quoted=startswith(hyphen_header.key, "\""))
            sibling_obj = parse_object(state, indent + 1)
            deep_merge!(obj, sibling_obj)
            push!(arr, obj)
            continue
        end
        
        col_idx = find_split_colon(String(item_content))
        
        if col_idx > 0
            obj = OrderedDict{String, Any}()
            k_str = strip(item_content[1:col_idx-1])
            v_str = strip(item_content[col_idx+1:end])
            
            is_q = startswith(k_str, "\"")
            key = parse_primitive_token(k_str; strict=state.opts.strict)
            if !isa(key, String); key = string(key); end
            
            if isempty(v_str)
                 # Check deeper nesting for this key's value
                 if peek_indent(state) > expected_indent
                     parsed_val = parse_object(state, expected_indent + 2)
                     set_value_with_path!(obj, key, parsed_val, state.opts; is_quoted=is_q)
                 else
                     set_value_with_path!(obj, key, OrderedDict{String, Any}(), state.opts; is_quoted=is_q)
                 end
            else
                 set_value_with_path!(obj, key, parse_primitive_token(v_str; strict=state.opts.strict), state.opts; is_quoted=is_q)
            end
            
            sibling_obj = parse_object(state, expected_indent + 1)
            deep_merge!(obj, sibling_obj)
            
            push!(arr, obj)
            
        elseif isempty(item_content)
             if peek_indent(state) > expected_indent
                 push!(arr, parse_object(state, expected_indent + 1))
             else
                 push!(arr, OrderedDict{String, Any}())
             end
        else
            push!(arr, parse_primitive_token(item_content; strict=state.opts.strict))
        end
    end
    
    if state.opts.strict && length(arr) != header.length
        throw(ParseError("Array count mismatch. Header declared $(header.length), found $(length(arr)).", state.current_line_idx))
    end
    
    return arr
end

function parse_tabular_array(state::DecoderState, header::HeaderInfo, depth::Int)
    arr = []
    fields = header.fields
    delim = header.delimiter
    
    while state.current_line_idx <= length(state.lines)
        line = state.lines[state.current_line_idx]
        
        if isempty(strip(line))
             if state.opts.strict
                 throw(ParseError("Strict mode: Blank line inside tabular array", state.current_line_idx))
             end
             state.current_line_idx += 1; continue
        end
        
        indent, content = get_indentation(line, state.opts)
        
        if indent <= depth
            break
        end
        
        vals = split_row(String(content), delim)
        
        if state.opts.strict && length(vals) != length(fields)
            throw(ParseError("Strict mode: Tabular row width mismatch", state.current_line_idx))
        end
        
        obj = OrderedDict{String, Any}()
        for (i, f) in enumerate(fields)
            if i <= length(vals)
                f_key = parse_primitive_token(f; strict=state.opts.strict)
                is_q = startswith(f, "\"")
                val = parse_primitive_token(vals[i]; strict=state.opts.strict)
                set_value_with_path!(obj, f_key, val, state.opts; is_quoted=is_q)
            end
        end
        push!(arr, obj)
        
        state.current_line_idx += 1
    end
    
    if state.opts.strict && length(arr) != header.length
        throw(ParseError("Tabular array count mismatch. Header declared $(header.length), found $(length(arr)).", state.current_line_idx))
    end
    
    return arr
end

function parse_inline_values(content::AbstractString, header::HeaderInfo, opts::TOONOptions)
    vals = split_row(String(content), header.delimiter)
    
    parsed = [parse_primitive_token(v; strict=opts.strict) for v in vals]
    
    if opts.strict && length(parsed) != header.length
        throw(ParseError("Strict mode: Inline array length mismatch", 0))
    end
    
    return parsed
end

# --- Helper Utils ---

function get_indentation(line::String, opts::TOONOptions)
    s_line = strip(line, ['\n', '\r'])
    
    if opts.strict
        if occursin('\t', s_line[1:findfirst(c -> !isspace(c), s_line) |> (x -> isnothing(x) ? length(s_line) : x)])
             throw(ParseError("Strict mode: Tab characters not allowed in indentation", 0))
        end
    end

    trimmed = lstrip(s_line)
    n_spaces = length(s_line) - length(trimmed)
    
    if opts.strict && (n_spaces % opts.indent_size != 0)
        throw(ParseError("Strict mode: Invalid indentation", 0))
    end
    
    depth = div(n_spaces, opts.indent_size)
    return depth, trimmed
end

function find_split_colon(s::AbstractString)
    in_quote = false
    esc = false
    for (i, c) in enumerate(s)
        if esc
            esc = false
            continue
        end
        
        if c == '\\'
            esc = true
        elseif c == '"'
            in_quote = !in_quote
        elseif c == ':' && !in_quote
            return i
        end
    end
    return 0
end

function split_row(s::String, delim::Char)
    parts = String[]
    start = 1
    in_quote = false
    esc = false
    
    for (i, c) in enumerate(s)
        if esc
            esc = false
            continue
        end
        
        if c == '\\'
            esc = true
        elseif c == '"'
            in_quote = !in_quote
        elseif c == delim && !in_quote
            push!(parts, strip(s[start:i-1]))
            start = i + 1
        end
    end
    
    push!(parts, strip(s[start:end]))
    return parts
end

function peek_indent(state::DecoderState)
    idx = state.current_line_idx
    while idx <= length(state.lines)
        line = state.lines[idx]
        if !isempty(strip(line))
            d, _ = get_indentation(line, state.opts)
            return d
        end
        idx += 1
    end
    return -1
end

function skip_blank_lines!(state::DecoderState)
    while state.current_line_idx <= length(state.lines)
        if isempty(strip(state.lines[state.current_line_idx]))
            state.current_line_idx += 1
        else
            break
        end
    end
end

function count_non_blank_lines(state::DecoderState)
    return count(l -> !isempty(strip(l)), state.lines)
end

function parse_header_with_values(line::AbstractString)
    col_idx = find_split_colon(line)
    if col_idx == 0; return nothing; end
    
    header_part = line[1:col_idx] 
    val_part = strip(line[col_idx+1:end])
    
    if isempty(val_part); return nothing; end
    
    h_info = parse_header_line(header_part)
    if isnothing(h_info); return nothing; end
    
    return h_info, val_part
end

"""
    set_value_with_path!(obj, key, value, opts; is_quoted=false)

Sets a value in the object, expanding the key into nested objects if
`opts.expand_paths` is enabled. Also handles conflicts and merging.
"""
function set_value_with_path!(obj::OrderedDict, key::AbstractString, value::Any, opts::TOONOptions; is_quoted=false)
    is_identifier = !is_quoted && occursin(r"^[A-Za-z_][A-Za-z0-9_.]*$", key)

    if opts.expand_paths == "off" || !is_identifier || !contains(key, '.')
        if haskey(obj, key) && isa(obj[key], AbstractDict) && isa(value, AbstractDict)
            deep_merge!(obj[key], value)
        else
            obj[key] = value
        end
        return
    end

    parts = split(key, '.')
    current = obj
    
    for i in 1:length(parts)-1
        part = String(parts[i])
        if !haskey(current, part)
            current[part] = OrderedDict{String, Any}()
        elseif !isa(current[part], AbstractDict)
            if opts.strict
                throw(ParseError("Expansion conflict at path '$(join(parts[1:i], '.'))' (object vs primitive)", 0))
            else
                current[part] = OrderedDict{String, Any}() 
            end
        end
        current = current[part]
    end
    
    last_part = String(parts[end])
    
    if haskey(current, last_part)
        existing = current[last_part]
        if isa(existing, AbstractDict) && isa(value, AbstractDict)
            deep_merge!(existing, value)
            return
        elseif isa(existing, AbstractDict) && !isa(value, AbstractDict)
            if opts.strict
                throw(ParseError("Expansion conflict at path '$key' (object vs primitive)", 0))
            end
             current[last_part] = value
        elseif !isa(existing, AbstractDict) && isa(value, AbstractDict)
             if opts.strict
                throw(ParseError("Expansion conflict at path '$key' (primitive vs object)", 0))
            end
            current[last_part] = value
        else
             current[last_part] = value
        end
    else
        current[last_part] = value
    end
end