module TOONFormat

using JSON
using StructUtils

using Dates
using OrderedCollections

include("shared.jl")
include("encode.jl")
include("decode.jl")


"""
    spec_version() -> String
Return the version of the TOONFormat specification that this implementation supports.
"""
function spec_version()
    return "3.0"  
end

export encode, decode, TOONOptions, ParseError,
        spec_version


end
