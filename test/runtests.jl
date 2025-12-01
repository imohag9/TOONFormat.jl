using TOONFormat
using Test
using Aqua
using JSON
using Dates
using OrderedCollections

@testset "TOONFormat.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(TOONFormat;deps_compat = false)
    end
    
    @testset "TOON Implementation" begin
        
        @testset "Primitives" begin
            @test TOONFormat.decode("true") === true
            @test TOONFormat.decode("false") === false
            @test TOONFormat.decode("null") === nothing
            @test TOONFormat.decode("123") === 123
            @test TOONFormat.decode("12.34") == 12.34
            @test TOONFormat.decode("\"hello\"") == "hello"
            
            # Canonical Numbers (Spec §2)
            @test TOONFormat.encode(1e6) == "1000000\n"
            @test TOONFormat.encode(1.500) == "1.5\n"
            @test TOONFormat.encode(-0.0) == "0\n"
        end

        @testset "Objects" begin
            # Basic Object
            obj_str = """
            id: 123
            name: "Ada"
            """
            decoded = TOONFormat.decode(obj_str)
            @test decoded["id"] == 123
            @test decoded["name"] == "Ada"
            
            # Nested Object
            nested_str = """
            user:
              id: 1
              meta:
                active: true
            """
            d = TOONFormat.decode(nested_str)
            @test d["user"]["id"] == 1
            @test d["user"]["meta"]["active"] === true
            
            # Round trip
            @test strip(TOONFormat.encode(d)) == strip(nested_str)
        end

        @testset "Arrays" begin
            # Inline Primitive
            inline_str = "tags[3]: a,b,c\n"
            d = TOONFormat.decode(inline_str)
            @test d["tags"] == ["a", "b", "c"]
            
            # Tabular
            tabular_str = """
            users[2]{id,name}:
              1,Alice
              2,Bob
            """
            d = TOONFormat.decode(tabular_str)
            @test length(d["users"]) == 2
            @test d["users"][1]["id"] == 1
            @test d["users"][1]["name"] == "Alice"
            
            # Expanded List
            list_str = """
            items[2]:
              - A
              - B
            """
            d = TOONFormat.decode(list_str)
            @test d["items"] == ["A", "B"]
        end
        
        @testset "Complex List Items" begin
            # Object as list item (Spec §10)
            complex_str = """
            items[2]:
              - id: 1
                val: A
              - id: 2
                val: B
            """
            d = TOONFormat.decode(complex_str)
            @test d["items"][1]["id"] == 1
            @test d["items"][2]["val"] == "B"
            
            # Nested Array in list
            nested_arr_str = """
            matrix[2]:
              - [2]: 1,2
              - [2]: 3,4
            """
            d = TOONFormat.decode(nested_arr_str)
            @test d["matrix"][1] == [1, 2]
            @test d["matrix"][2] == [3, 4]
        end
        
        @testset "Strict Mode" begin
            # Wrong count
            bad_count = "items[3]: a,b\n"
            @test_throws TOONFormat.ParseError TOONFormat.decode(bad_count; strict=true)
            
            # Bad Indent
            bad_indent = """
            obj:
             key: val
            """
            @test_throws TOONFormat.ParseError TOONFormat.decode(bad_indent; indent_size=2, strict=true)
        end
        
        @testset "Quoting Rules" begin
            # Colon in string
            colon_str = """
            key: "a:b"
            """
            d = TOONFormat.decode(colon_str)
            @test d["key"] == "a:b"
            
            # Delimiter in tabular
            opts = TOONFormat.TOONOptions(delimiter='|')
            
            pipe_correct = """
            data[1|]{col1|col2}:
              a,b|c
            """
            # col1="a,b", col2="c"
            d = TOONFormat.decode(pipe_correct)
            @test d["data"][1]["col1"] == "a,b"
            @test d["data"][1]["col2"] == "c"
        end
    end
    include("encoding_tests.jl")
    include("decoding_tests.jl")
    include("conformance.jl")

    # Run the automated JSON-based conformance suite
    include("conformance_tests.jl") 

end
