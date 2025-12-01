
@testset "TOON Decoding" begin

    @testset "Primitives" begin
        # Booleans
        @test TOONFormat.decode("true") === true
        @test TOONFormat.decode("false") === false
        
        # Null
        @test TOONFormat.decode("null") === nothing
        
        # Numbers
        @test TOONFormat.decode("123") === 123
        @test TOONFormat.decode("-50") === -50
        @test TOONFormat.decode("12.5") === 12.5
        @test TOONFormat.decode("0.001") === 0.001
        
        # Strings
        @test TOONFormat.decode("hello") == "hello"
        @test TOONFormat.decode("\"quoted string\"") == "quoted string"
        @test TOONFormat.decode("\"escaped \\\"quote\\\"\"") == "escaped \"quote\""
        
        # Leading zero numbers are strings
        @test TOONFormat.decode("0123") == "0123" 
    end

    @testset "Simple Objects" begin
        str = """
        name: Alice
        role: Admin
        active: true
        """
        data = TOONFormat.decode(str)
        @test data isa OrderedDict
        @test data["name"] == "Alice"
        @test data["role"] == "Admin"
        @test data["active"] === true
    end

    @testset "Nested Objects" begin
        str = """
        server:
          config:
            port: 8080
            host: localhost
          enabled: true
        """
        data = TOONFormat.decode(str)
        @test data["server"]["config"]["port"] == 8080
        @test data["server"]["config"]["host"] == "localhost"
        @test data["server"]["enabled"] === true
    end

    @testset "Arrays: Inline" begin
        # Standard inline
        data = TOONFormat.decode("items[3]: 1, 2, 3")
        @test data isa OrderedDict
        @test data["items"] == [1, 2, 3]

        # Root inline array
        arr = TOONFormat.decode("[3]: a, b, c")
        @test arr == ["a", "b", "c"]
        
        # Mixed types
        arr = TOONFormat.decode("[3]: 1, true, string")
        @test arr == [1, true, "string"]
    end

    @testset "Arrays: Expanded List" begin
        str = """
        users[2]:
          - Alice
          - Bob
        """
        data = TOONFormat.decode(str)
        @test data["users"] == ["Alice", "Bob"]

        # List of objects
        str_obj = """
        items[2]:
          - id: 1
            val: A
          - id: 2
            val: B
        """
        data_obj = TOONFormat.decode(str_obj)
        @test data_obj["items"][1]["id"] == 1
        @test data_obj["items"][2]["val"] == "B"
    end

    @testset "Path Expansion (Dot Notation)" begin
        str = """
        server.port: 8080
        server.logs.path: /var/log
        """
        
        # Default: Off
        data_off = TOONFormat.decode(str)
        @test haskey(data_off, "server.port")
        @test data_off["server.port"] == 8080

        # Safe Mode: On
        data_safe = TOONFormat.decode(str; expand_paths="safe")
        @test !haskey(data_safe, "server.port")
        @test data_safe["server"]["port"] == 8080
        @test data_safe["server"]["logs"]["path"] == "/var/log"
    end

    @testset "Strict Mode Validation" begin
        # 1. Array Count Mismatch (Inline)
        # Header says 3, but only 2 provided
        @test_throws TOONFormat.ParseError TOONFormat.decode("items[3]: 1, 2")

        # 2. Array Count Mismatch (Tabular)
        bad_tab = """
        data[3]{a}:
          1
          2
        """
        @test_throws TOONFormat.ParseError TOONFormat.decode(bad_tab)

        # 3. Array Count Mismatch (List)
        bad_list = """
        list[3]:
          - A
          - B
        """
        @test_throws TOONFormat.ParseError TOONFormat.decode(bad_list)

        # 4. Indentation Error
        # Default indent is 2, using 3 spaces should fail strict check
        bad_indent = """
        root:
           child: val
        """
        @test_throws TOONFormat.ParseError TOONFormat.decode(bad_indent; strict=true)
    end

    @testset "Non-Strict Mode Recovery" begin
        # Mismatch count shouldn't throw
        data = TOONFormat.decode("items[3]: 1, 2"; strict=false)
        @test length(data["items"]) == 2

    end


end