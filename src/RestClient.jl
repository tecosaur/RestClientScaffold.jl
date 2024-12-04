module RestClient

using Downloads
using StyledStrings: @styled_str as @S_str

export AbstractEndpoint, SingleEndpoint, ListEndpoint,
    Request, RequestConfig, SingleResponse, ListResponse, Single, List,
    api_get, api_post, pagename, parameters, headers, payload, responsetype,
    dataformat, interpretresponse, validate, postprocess, thispagenumber,
    nextpage, remainingpages
export AbstractFormat, RawFormat, @endpoint, JSONFormat, @jsondef
export setfield

include("types.jl")
include("interface.jl")
include("requests.jl")
include("utilities.jl")

macro importapi()
    :(import $(__module__): pagename, parameters, responsetype,
      validate, postprocess, thispagenumber, nextpage, remainingpages,
      contents, metadata) |> esc
end

macro reexport()
    :(export Single, List, nextpage)
end

end
