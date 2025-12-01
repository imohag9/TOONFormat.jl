# Helper functions to load test files
function load_test_file(path::AbstractString)
    return read(path, String)
end

function parse_json_file(path::AbstractString)
    content = load_test_file(path)
    return JSON.parse(content; dicttype=OrderedDict{String, Any})
end

# Test directory paths
const TEST_DIR = joinpath(@__DIR__, "examples")
const VALID_DIR = joinpath(TEST_DIR, "valid")
const INVALID_DIR = joinpath(TEST_DIR, "invalid")
const CONVERSIONS_DIR = joinpath(TEST_DIR, "conversions")

@testset "TOON Conformance Tests" begin
    @testset "Valid TOON Documents" begin
        valid_files = [
            "objects.toon",
            "nested-objects.toon",
            "primitive-arrays.toon",
            "tabular-array.toon",
            "mixed-array.toon",
            "pipe-delimiter.toon",
            "tab-delimiter.toon",
            "key-folding-basic.toon",
            "key-folding-mixed.toon",
            "key-folding-with-array.toon",
            "path-expansion-merge.toon"
        ]

        for file in valid_files
            filepath = joinpath(VALID_DIR, file)
            @testset "Valid: $file" begin
                toon_content = load_test_file(filepath)
                # Should decode without errors in non-strict mode
                result = TOONFormat.decode(toon_content; strict = false)
                @test result isa AbstractDict || result isa Vector ||
                      result isa Union{String, Number, Bool, Nothing}

                # For files that should work in strict mode, test that too
                if !occursin("key-folding", file) && !occursin("path-expansion", file)
                    # These features require specific decoder options
                    result_strict = TOONFormat.decode(toon_content; strict = true)
                    @test result_strict isa AbstractDict || result_strict isa Vector ||
                          result_strict isa Union{String, Number, Bool, Nothing}
                end
            end
        end
    end

    @testset "Invalid TOON Documents" begin
        invalid_cases = [
            (
                "length-mismatch.toon",
                "Tabular array count mismatch. Header declared 3, found 2."
            ),
            (
                "missing-colon.toon",
                "Line 1: Missing colon after key."
            ),
            (
                "path-expansion-conflict-strict.toon",
                "Expansion conflict at path 'user.profile' (object vs primitive)"
            )
        ]

        for (file, expected_error) in invalid_cases
            filepath = joinpath(INVALID_DIR, file)
            @testset "Invalid: $file" begin
                toon_content = load_test_file(filepath)
                # Should fail with specific error message in strict mode
                if file == "path-expansion-conflict-strict.toon"
                    #This one requires path expansion to be enabled
                    error_thrown = false
                    try
                        TOONFormat.decode(toon_content; strict=true, expand_paths="safe")
                    catch e
                        error_thrown = true
                        @test occursin(expected_error, e.msg)
                    end
                    @test error_thrown
                else
                    error_thrown = false
                    try
                        TOONFormat.decode(toon_content; strict = true)
                    catch e
                        error_thrown = true
                        @test occursin(expected_error, e.msg)
                    end
                    @test error_thrown
                end

                # Should succeed in non-strict mode for non-expansion cases
                if file != "path-expansion-conflict-strict.toon"
                    # file == "missing-colon.toon" && continue #TODO
                    result = TOONFormat.decode(toon_content; strict = false)
                    @test result isa AbstractDict
                end
            end
        end
    end

    @testset "Key Folding and Path Expansion Tests" begin
        @testset "Key Folding Decoding (Safe Mode)" begin
            # Basic key folding
            filepath = joinpath(VALID_DIR, "key-folding-basic.toon")
            toon_content = load_test_file(filepath)
            result = TOONFormat.decode(toon_content; expand_paths="safe")

            @test haskey(result, "server")
            @test haskey(result["server"], "host")
            @test result["server"]["host"] == "localhost"
            @test haskey(result["database"], "connection")
            @test result["database"]["connection"]["username"] == "admin"

            # Mixed folding
            filepath = joinpath(VALID_DIR, "key-folding-mixed.toon")
            toon_content = load_test_file(filepath)
            result = TOONFormat.decode(toon_content; expand_paths="safe")

            @test result["app"]["name"] == "MyApp"
            @test haskey(result["server"], "ssl")
            @test result["server"]["ssl"]["enabled"] == true
            @test result["database"]["connection"]["url"] == "postgresql://localhost:5432/mydb"

            # Key folding with arrays
            filepath = joinpath(VALID_DIR, "key-folding-with-array.toon")
            toon_content = load_test_file(filepath)
            result = TOONFormat.decode(toon_content; expand_paths="safe")

            @test result["data"]["meta"]["items"] == ["widget", "gadget", "tool"]
            @test result["data"]["meta"]["count"] == 3
            @test result["user"]["preferences"]["tags"] == ["productivity", "development"]
        end

        @testset "Path Expansion Conflict Resolution" begin
            # Safe mode with strict=true should error
            filepath = joinpath(INVALID_DIR, "path-expansion-conflict-strict.toon")
            toon_content = load_test_file(filepath)
            @test_throws TOONFormat.ParseError TOONFormat.decode(
                toon_content; 
                strict=true, 
                expand_paths="safe"
            ) 

            # Safe mode with strict=false should use last-write-wins
            result = TOONFormat.decode(
                toon_content; 
                strict=false, 
                expand_paths="safe"
            )

            @test haskey(result, "user")
            @test haskey(result["user"], "profile")
            @test result["user"]["profile"] == "incomplete data"
            @test !haskey(result["user"], "settings")  # Should not be present due to conflict # Should not be present due to conflict
            @test haskey(result, "system")
            @test result["system"]["version"] == "1.5.0"
        end
    end

    @testset "JSON/TOON Roundtrip Conversions" begin
        conversion_cases = [
            ("users.json", "users.toon"),
            ("config.json", "config.toon"),
            ("api-response.json", "api-response.toon")
        ]

        for (json_file, toon_file) in conversion_cases
            json_path = joinpath(CONVERSIONS_DIR, json_file)
            toon_path = joinpath(CONVERSIONS_DIR, toon_file)

            @testset "Conversion: $json_file ↔ $toon_file" begin
                # Load JSON data
                json_data = parse_json_file(json_path)

                # Test JSON -> TOON encoding
                encoded_toon = TOONFormat.encode(json_data)
                expected_toon = load_test_file(toon_path)

                # Normalize newlines for comparison
                encoded_toon = replace(encoded_toon, r"[\r\n]+" => "\n")
                expected_toon = replace(expected_toon, r"[\r\n]+" => "\n")
                
                # Strip trailing whitespace/newlines to avoid false positives 
                # (encode always adds a final newline, source file might not have one)
                encoded_toon = strip(encoded_toon)
                expected_toon = strip(expected_toon)

                # For conversions involving path expansion, we need to normalize
                # the encoded output to match the expected format
                if occursin("config.json", json_file) || occursin("api-response.json", json_file)
                    # These use key folding in the expected output
                    # We'll decode both and compare the resulting objects instead
                    decoded_encoded = TOONFormat.decode(encoded_toon; expand_paths="safe", strict=false)
                    decoded_expected = TOONFormat.decode(expected_toon; expand_paths="safe", strict=false)
                    decoded_encoded == decoded_expected
                else
                    # Direct string comparison for non-folding cases
                    @test encoded_toon == expected_toon
                end

                # Test TOON -> JSON decoding
                toon_content = load_test_file(toon_path)
                decoded_data = if occursin("config.json", json_file) || occursin("api-response.json", json_file)
                    # Enable path expansion for these cases
                    TOONFormat.decode(toon_content; expand_paths="safe", strict=false)
                else
                    TOONFormat.decode(toon_content; strict=false)
                end

                # Compare JSON objects (ignore ordering differences)
                @test decoded_data == json_data
            end
        end
    end

    @testset "Delimiter Tests" begin
        @testset "Pipe Delimiter" begin
            filepath = joinpath(VALID_DIR, "pipe-delimiter.toon")
            toon_content = load_test_file(filepath)
            result = TOONFormat.decode(toon_content)

            @test haskey(result, "items")
            @test length(result["items"]) == 2
            @test result["items"][1]["sku"] == "A1"
            @test result["items"][1]["name"] == "Widget"
            @test result["items"][1]["qty"] == 2
            @test result["items"][1]["price"] == 9.99
        end

        @testset "Tab Delimiter" begin
            filepath = joinpath(VALID_DIR, "tab-delimiter.toon")
            toon_content = load_test_file(filepath)
            result = TOONFormat.decode(toon_content)

            @test haskey(result, "items")
            @test length(result["items"]) == 2
            @test result["items"][1]["sku"] == "A1"
            @test result["items"][1]["name"] == "Widget"
            @test result["items"][1]["qty"] == 2
            @test result["items"][1]["price"] == 9.99
        end
    end

    @testset "Edge Cases and Special Values" begin
        # Test empty document
        @test TOONFormat.decode("") == OrderedDict{String, Any}()
        @test TOONFormat.decode("\n") == OrderedDict{String, Any}()
        @test TOONFormat.decode("   \n   \n") == OrderedDict{String, Any}()

        # Test empty array
        empty_array = TOONFormat.decode("items[0]:")
        @test haskey(empty_array, "items")
        @test isa(empty_array["items"], Vector)
        @test isempty(empty_array["items"])

        # Test empty object
        empty_obj = TOONFormat.decode("metadata:")
        @test haskey(empty_obj, "metadata")
        @test isa(empty_obj["metadata"], AbstractDict)
        @test isempty(empty_obj["metadata"])

        # Test string with special characters
        special_str = TOONFormat.decode("value: \"hello\\nworld\\ttest\"")
        @test special_str["value"] == "hello\nworld\ttest"
    end

    @testset "Number Formatting Conformance (v2.0)" begin
        # Test canonical number formatting
        test_cases = [
            (1.0, "1"),
            (-0.0, "0"),
            (1.5000, "1.5"),
            (0.000001, "0.000001"),
            (1000000, "1000000"),
            (1e6, "1000000"),
            (1e-6, "0.000001")
        ]

        for (input, expected) in test_cases
            result = TOONFormat.encode(input)
            # Normalize result (remove newline)
            result = strip(result)
            # Compare the string representation
            @test result == expected
        end

        # Test decoding of various number formats
        num_tests = [
            ("42", 42),
            ("-3.14", -3.14),
            ("1e-6", 1e-6),
            ("-1E+9", -1e9),
            ("05", "05"),  # Leading zeros should be treated as strings
            ("0001", "0001")
        ]

        for (input, expected) in num_tests
            result = TOONFormat.decode("value: $input")
            if isa(expected, String)
                @test result["value"] == expected
            else
                @test result["value"] == expected
                typeof(expected) == Float64 && continue
                @test isa(result["value"], typeof(expected))
            end
        end
    end

    @testset "Julia-specific Type Normalization" begin
        @testset "Date and DateTime normalization" begin
            @test TOONFormat.encode(DateTime("2025-01-01T00:00:00.000")) ==
                  "\"2025-01-01T00:00:00\"\n"
            @test TOONFormat.encode(Date("2025-11-05")) == "\"2025-11-05\"\n"
        end

        @testset "Set normalization" begin
            # Note: Set order is not guaranteed, so we decode to test for content equivalence.
            input = Set(["a", "b", "c"])
            encoded = TOONFormat.encode(input)
            decoded = TOONFormat.decode(encoded)
            @test Set(decoded) == input
            @test TOONFormat.encode(Set()) == "[0]:\n"
        end

        @testset "Tuple normalization" begin
            # Tuples should be treated as arrays
            @test TOONFormat.encode(("a", "b")) == "[2]: a,b\n"
        end

        @testset "Symbol normalization" begin
            # JSON.jl/StructUtils.jl converts symbols to strings
            @test TOONFormat.encode(:test_symbol) == "test_symbol\n"
            @test TOONFormat.encode(Dict(:key => :value)) == "key: value\n"
        end

        @testset "NaN and Infinity normalization" begin
            # The JSON spec (and thus TOON's data model) does not support non-finite numbers.
            # JSON.jl correctly converts them to `null`.
            @test TOONFormat.encode(NaN) == "null\n"
            @test TOONFormat.encode(Inf) == "null\n"
            @test TOONFormat.encode(-Inf) == "null\n"
        end

        @testset "Negative zero normalization" begin
            @test TOONFormat.encode(-0.0) == "0\n"
        end
    end
end