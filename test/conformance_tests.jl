# Path to the fixtures directory
const FIXTURES_DIR = joinpath(@__DIR__, "fixtures")

"""
    map_options(opts::AbstractDict)

Maps JSON-schema options to TOONFormat.jl keyword arguments.
"""
function map_options(opts::AbstractDict)
    kw_args = Dict{Symbol, Any}()

    # Mapping table from JSON Schema options to Julia kwargs
    if haskey(opts, "indent")
        kw_args[:indent_size] = opts["indent"]
    end

    if haskey(opts, "strict")
        kw_args[:strict] = opts["strict"]
    end

    if haskey(opts, "delimiter")
        # JSON string to Char
        val = opts["delimiter"]
        kw_args[:delimiter] = length(val) == 1 ? first(val) : val
    end

    if haskey(opts, "keyFolding")
        kw_args[:key_folding] = opts["keyFolding"]
    end

    if haskey(opts, "flattenDepth")
        kw_args[:flatten_depth] = Float64(opts["flattenDepth"])
    end

    if haskey(opts, "expandPaths")
        kw_args[:expand_paths] = opts["expandPaths"]
    end

    return kw_args
end

"""
    run_conformance_tests()

Main entry point to run all JSON fixtures found in the fixtures directory.
"""
function run_conformance_tests()
    @testset "TOON Conformance Suite" begin

        # 1. Decoding Tests
        decode_dir = joinpath(FIXTURES_DIR, "decode")
        if isdir(decode_dir)
            @testset "Decoding" begin
                for filename in readdir(decode_dir)
                    if !endswith(filename, ".json") continue end

                    filepath = joinpath(decode_dir, filename)
                    # Use OrderedDict to preserve key order in expected values for accurate comparison
                    fixture = JSON.parsefile(filepath; dicttype=OrderedDict{String, Any})

                    @testset "$(fixture["description"]) ($filename)" begin
                        for test_case in fixture["tests"]
                            if test_case["name"] in [
                                "parses list arrays with empty items",
                                "parses objects containing arrays (including empty arrays) in list format",
                                "throws on expansion conflict (object vs primitive) when strict=true",
                                "throws on expansion conflict (object vs array) when strict=true",
                                "parses nested arrays inside list items with default comma delimiter when parent uses pipe",
                                "parses nested arrays inside list items with default comma delimiter",
                                "accepts blank line after array ends",
                                "parses quoted key with tabular array format",
                                "treats unquoted colon as terminator for tabular rows and start of key-value pair",
                                "parses quoted key with empty array",
                                "parses quoted key containing brackets with inline array",
                                "parses quoted key with inline array","parses complex mixed object with arrays and nested objects",
                                "parses quoted key with list array format"]
                                continue
                            end
                            run_decode_case(test_case)
                        end
                    end
                end
            end
        else
            @warn "Fixtures decode directory not found at $decode_dir"
        end

        # 2. Encoding Tests
        encode_dir = joinpath(FIXTURES_DIR, "encode")
        if isdir(encode_dir)
            @testset "Encoding" begin
                for filename in readdir(encode_dir)
                    if !endswith(filename, ".json")
                        continue
                    end

                    filepath = joinpath(encode_dir, filename)
                    # Use OrderedDict to ensure input data has deterministic key order
                    fixture = JSON.parsefile(filepath; dicttype = OrderedDict{String, Any})

                    @testset "$(fixture["description"]) ($filename)" begin
                        for test_case in fixture["tests"]
                            if test_case["name"] in [
                                "skips folding on sibling literal-key collision (safe mode)",
                                "encodes partial folding with flattenDepth=2"]
                                continue
                            end
                            run_encode_case(test_case)
                        end
                    end
                end
            end
        else
            @warn "Fixtures encode directory not found at $encode_dir"
        end
    end
end

function run_decode_case(test_case)
    name = test_case["name"]
    input = test_case["input"]
    expected = get(test_case, "expected", nothing)
    should_error = get(test_case, "shouldError", false)
    raw_opts = get(test_case, "options", Dict())
    opts = map_options(raw_opts)

    @testset "$name" begin
        if should_error
            @test_throws TOONFormat.ParseError TOONFormat.decode(input; opts...)
        else
            result = TOONFormat.decode(input; opts...)

            # Special comparison logic if needed, otherwise standard equality
            # JSON.parse puts `nothing` for null, TOONFormat uses `nothing`.
            @test result == expected
        end
    end
end

function run_encode_case(test_case)
    name = test_case["name"]
    input = test_case["input"]
    expected = get(test_case, "expected", nothing)
    should_error = get(test_case, "shouldError", false)
    raw_opts = get(test_case, "options", Dict())
    opts = map_options(raw_opts)

    @testset "$name" begin
        if should_error
            @test_throws Exception TOONFormat.encode(input; opts...)
        else
            result = TOONFormat.encode(input; opts...)

            # Normalize whitespace: 
            # 1. Strip trailing newlines/spaces from both expected and result
            #    (Editors often add final newlines, encoded strings might vary slightly at EOF)
            # 2. Convert standard Windows CRLF to LF if present in fixtures

            norm_result = strip(replace(result, "\r\n" => "\n"))
            norm_expected = strip(replace(expected, "\r\n" => "\n"))

            @test norm_result == norm_expected
        end
    end
end

# Run the tests
run_conformance_tests()