# encoding_tests.jl

@testset "TOON Encoding: Key Folding & Path Generation" begin


    @testset "Simple Julia Types" begin
        # Integers
        @test TOONFormat.encode(123) == "123\n"
        @test TOONFormat.encode(-5) == "-5\n"
        
        # Floats (Canonicalization)
        @test TOONFormat.encode(1.5) == "1.5\n"
        @test TOONFormat.encode(1.0) == "1\n"         # Spec: No trailing .0
        @test TOONFormat.encode(0.0) == "0\n"         # Spec: -0 -> 0
        @test TOONFormat.encode(-0.0) == "0\n"
        
        # Booleans
        @test TOONFormat.encode(true) == "true\n"
        @test TOONFormat.encode(false) == "false\n"
        
        # Null / Nothing
        @test TOONFormat.encode(nothing) == "null\n"
        
        # Symbols (Converted to String)
        @test TOONFormat.encode(:my_symbol) == "my_symbol\n"
    end

    @testset "Strings & Quoting" begin
        # Simple string (no quotes)
        @test TOONFormat.encode("hello") == "hello\n"
        
        # Strings requiring quotes
        @test TOONFormat.encode("has space") == "has space\n"
        @test TOONFormat.encode("has:colon") == "\"has:colon\"\n"
        @test TOONFormat.encode("123") == "\"123\"\n" # Looks like number -> quoted
        @test TOONFormat.encode("true") == "\"true\"\n" # Keyword -> quoted
        @test TOONFormat.encode("") == "\"\"\n" # Empty -> quoted
    end

    @testset "Dates" begin
        # Dates are treated as strings and quoted to preserve formatting
        d = Date(2025, 1, 1)
        @test TOONFormat.encode(d) == "\"2025-01-01\"\n"
    end

    @testset "Arrays: Inline Primitives" begin
        # Empty array
        @test TOONFormat.encode([]) == "[0]:\n"
        @test TOONFormat.encode(Int[]) == "[0]:\n"
        
        # Homogeneous primitives
        @test TOONFormat.encode([1, 2, 3]) == "[3]: 1,2,3\n"
        

        @test TOONFormat.encode([1, "a", "b c"]) == "[3]: 1,a,b c\n"
    end

    @testset "Arrays: Tabular" begin
        # Using OrderedDict to ensure deterministic column order for tests
        data = [
            OrderedDict("id" => 1, "name" => "Alice"),
            OrderedDict("id" => 2, "name" => "Bob")
        ]
        
        # Header should be [2]{id,name}:
        # Rows should follow
        expected = """
        [2]{id,name}:
          1,Alice
          2,Bob
        """
        @test TOONFormat.encode(data) == expected

        # Tabular with quoting in cells
        data_quoted = [
            OrderedDict("col1" => "val,ue", "col2" => 1)
        ]
        # "val,ue" contains delimiter, must be quoted
        expected_quoted = """
        [1]{col1,col2}:
          "val,ue",1
        """
        @test TOONFormat.encode(data_quoted) == expected_quoted
    end

    @testset "Arrays: Expanded List" begin
        # Non-tabular data (different keys) force List format
        data = [
            OrderedDict("a" => 1),
            OrderedDict("b" => 2)
        ]
        
        expected = """
        [2]:
          - a: 1
          - b: 2
        """
        @test TOONFormat.encode(data) == expected
        
        # List of primitives (mixed types prevented inline array)
        # Note: In TOONFormat.jl current logic, `is_primitive_array` checks if all are primitives.
        # So [1, "string"] is inline.
        # To force expanded list with primitives, we might need nested arrays or objects.
        
        # List of Lists
        nested = [
            [1, 2],
            [3, 4]
        ]
        expected_nested = """
        [2]:
          - [2]: 1,2
          - [2]: 3,4
        """
        @test TOONFormat.encode(nested) == expected_nested
    end

    @testset "Custom Delimiters" begin
        # Use Pipe | to avoid quoting commas
        data = ["1,2", "3,4"]
        
        # With default comma, these would be quoted: "1,2", "3,4"
        # With pipe, they are clean strings
        opts = (delimiter='|',)
        
        expected = "[2|]: 1,2|3,4\n"
        @test TOONFormat.encode(data; opts...) == expected
        
        # Tabular with Pipe
        table = [OrderedDict("x" => "1,1", "y" => "2,2")]
        expected_table = """
        [1|]{x|y}:
          1,1|2,2
        """
        @test TOONFormat.encode(table; opts...) == expected_table
    end

    # Key Folding (Encoding side) generates the dotted paths that the 
    # Path Expansion (Decoding side) consumes.
    
    @testset "Basic Key Folding" begin
        # 1. Single level nesting
        # Input: {"server": {"port": 8080}}
        # Expected: server.port: 8080
        data = Dict("server" => Dict("port" => 8080))
        
        # Without folding (Control)
        std_out = TOONFormat.encode(data; key_folding="off")
        @test contains(std_out, "server:\n  port: 8080")
        
        # With folding
        folded_out = TOONFormat.encode(data; key_folding="safe")
        @test strip(folded_out) == "server.port: 8080"
    end

    @testset "Deep Nesting" begin
        # Input: {"a": {"b": {"c": "val"}}}
        # Expected: a.b.c: val
        data = Dict("a" => Dict("b" => Dict("c" => "val")))
        
        folded_out = TOONFormat.encode(data; key_folding="safe")
        @test strip(folded_out) == "a.b.c: val"
    end

    @testset "Branching Paths (Sibling Folding)" begin
        # Input: {"config": {"min": 1, "max": 10}}
        # Expected:
        # config.min: 1
        # config.max: 10
        data = Dict(
            "config" => Dict(
                "min" => 1, 
                "max" => 10
            )
        )
        
        encoded = TOONFormat.encode(data; key_folding="safe")
        
        # Verify lines exist (split by newline to handle order if implementation varies, 
        # though Dict should keep it stable)
        lines = split(strip(encoded), '\n')
        @test "config.min: 1" in lines
        @test "config.max: 10" in lines
    end

    @testset "Folding Stops at Arrays" begin
        # Folding should collapse objects up to the array definition, 
        # then the array header should take over.
        # Input: {"data": {"items": [1, 2]}}
        # Expected: data.items[2]: 1, 2
        
        data = Dict("data" => Dict("items" => [1, 2]))
        
        encoded = TOONFormat.encode(data; key_folding="safe")
        @test strip(encoded) == "data.items[2]: 1,2"
        
        # Tabular Array Case
        # Input: {"users": {"list": [{"id": 1}, {"id": 2}]}}
        # Expected: users.list[2]{id}: ...
        
        tabular_data = Dict(
            "users" => Dict(
                "list" => [
                    Dict("id" => 1), 
                    Dict("id" => 2)
                ]
            )
        )
        
        enc_tab = TOONFormat.encode(tabular_data; key_folding="safe")
        @test contains(enc_tab, "users.list[2]{id}:")
        @test contains(enc_tab, "  1")
        @test contains(enc_tab, "  2")
    end

    @testset "Safe Mode: Identifier Validity" begin
        # Spec: Keys should only fold if they are valid identifiers (alphanumeric + underscore).
        # If a key contains spaces or special chars, folding should stop or handle quoting carefully.
        
        # Case: Key with space
        # Input: {"my server": {"port": 80}}
        # Expected behavior: Should typically NOT fold if it requires quoting the parent part,
        # OR it should output "my server".port: 80 if the implementation is aggressive.
        # Assuming conservative "safe" mode stops folding at non-identifiers:
        
        data = Dict("my server" => Dict("port" => 80))
        encoded = TOONFormat.encode(data; key_folding="safe")
        
        # We expect it NOT to fold into "my server".port, but retain structure
        # (Implementation dependent, but testing for safety)
        @test contains(encoded, "\"my server\":")
        @test contains(encoded, "  port: 80")
    end

    @testset "Round Trip: Key Folding <-> Path Expansion" begin
        # This is the critical integration test.
        # Encode with key_folding="safe" -> Decode with expand_paths="safe"
        
        complex_data = Dict(
            "app" => Dict(
                "name" => "TestApp",
                "version" => "1.0.0"
            ),
            "db" => Dict(
                "primary" => Dict("host" => "10.0.0.1"),
                "replica" => Dict("host" => "10.0.0.2")
            )
        )
        
        # 1. Encode with Folding
        toon_str = TOONFormat.encode(complex_data; key_folding="safe")
        
        # Verify it actually folded (Requires sibling object folding support)
        @test contains(toon_str, "app.name:")
        @test contains(toon_str, "db.primary.host:")
        
        # 2. Decode with Expansion
        decoded = TOONFormat.decode(toon_str; expand_paths="safe")
        
        # 3. Verify Structure
        @test decoded["app"]["name"] == "TestApp"
        @test decoded["db"]["primary"]["host"] == "10.0.0.1"
        @test decoded == complex_data
    end
    
    @testset "Partial Folding (Flatten Depth)" begin
        # If the implementation supports flatten_depth
        # Input: {"a": {"b": {"c": 1}}}
        # flatten_depth = 1
        # Expected: 
        # a.b:
        #   c: 1
        # OR
        # a:
        #   b.c: 1 
        # (Depending on implementation direction. Usually top-down).
        
        data = Dict("a" => Dict("b" => Dict("c" => 1)))
        
        # This test is tentative based on `flatten_depth` presence in TOONOptions

        encoded = TOONFormat.encode(data; key_folding="safe", flatten_depth=1.0)
        
        # Basic check: verify valid TOON is produced regardless of depth logic
        @test !isempty(encoded)
        decoded = TOONFormat.decode(encoded; expand_paths="safe")
        @test decoded["a"]["b"]["c"] == 1
    end


@testset "Flatten Depth Tests" begin
    
    # Structure: {a: {b: {c: {d: 1}}}}
    # Chain: a -> b -> c -> d -> 1
    data = Dict("a" => Dict("b" => Dict("c" => Dict("d" => 1))))

    @testset "Depth = Inf (Full Folding)" begin
        # Should fold completely: a.b.c.d: 1
        encoded = TOONFormat.encode(data; key_folding="safe", flatten_depth=Inf)
        @test strip(encoded) == "a.b.c.d: 1"
    end

    @testset "Depth = 2" begin
        # a (1). b (2).
        # Fold a.b.
        # Next is c (3). Stop.
        # Terminal "a.b". Value {c: {d: 1}}
        # Inside a.b:
        # c (1). d (2).
        # Fold c.d.
        # Output: a.b:\n  c.d: 1
        
        encoded = TOONFormat.encode(data; key_folding="safe", flatten_depth=2)
        expected = """
        a.b:
          c.d: 1
        """
        @test strip(encoded) == strip(expected)
    end



    @testset "Branching Structure" begin
        # {
        #   "server": {
        #     "http": { "port": 80 },
        #     "db": { "config": { "host": "localhost" } }
        #   }
        # }
        # server -> http (2 segs). Fold to server.http. 
        # server.http -> port (3 segs). No fold. Output server.http: ...
        # server -> db (2 segs). Fold to server.db.
        # server.db -> config (3 segs). No fold. Output server.db: ...
        # Inside server.db:
        # config -> host (2 segs). Fold to config.host.
        
        # Use OrderedDict to match output order
        branch_data = OrderedDict("server" => OrderedDict(
            "http" => Dict("port" => 80),
            "db" => Dict("config" => Dict("host" => "localhost"))
        ))

        encoded = TOONFormat.encode(branch_data; key_folding="safe", flatten_depth=2)
        expected = """
        server.http:
          port: 80
        server.db:
          config.host: localhost
        """
        @test strip(encoded) == strip(expected)
    end
    
    @testset "Edge Case: Depth 1" begin
        # Depth 1 allows prefix "a".
        # Next key "b". 1+1 <= 1 is False.
        # Stop. Terminal "a".
        # Value {b: {c: {d: 1}}}
        
        encoded = TOONFormat.encode(data; key_folding="safe", flatten_depth=1)
        expected = """
        a:
          b:
            c:
              d: 1
        """
        @test strip(encoded) == strip(expected)
    end
end

end