"""
    setfield(x::T, field::Symbol, value) -> ::T
"""
function setfield(x::T, field::Symbol, value) where {T}
    fvals = ((getfield(x, f) for f in fieldnames(T))...,)
    fidx = findfirst(==(field), fieldnames(T))
    isnothing(fidx) && throw(ArgumentError("Field $field not found in $T"))
    value isa fieldtype(T, field) || throw(ArgumentError("Field $field must be of type $(fieldtype(T, field)), got $(typeof(value))"))
    fvals = Base.setindex(fvals, value, fidx)
    T(fvals...)
end

"""
    @jsondef [kind] struct ... end

Define a struct that can be used with `JSON3`.

This macro conveniently combines the following pieces:
- `@kwdef` to define keyword constructors for the struct.
- Custom `Base.show` method to show the struct with keyword arguments,
  omitting default values.
- `StructTypes.StructType` to define the struct type, and
  `StructTypes.names` (if needed) to define the JSON field mapping.
- `RestClient.dataformat` to declare that this struct is JSON-formatted.

Optionally the JSON representation `kind` can be specified. It
defaults to `Struct`, but can any of: `Struct`, `Dict`, `Array`,
`Vector`, `String`, `Number`, `Bool`, `Nothing`.

!!! warning "Soft JSON3 dependency"
    This macro is implemented in a package extension, and so
    requires `JSON3` to be loaded before it can be used.

# Examples

```julia
@jsondef struct DocumentStatus
    exists::Bool  # Required, goes by 'exists' in JSON too
    status:"document_status"::Union{String, Nothing} = nothing
    url:"document_url"::Union{String, Nothing} = nothing
    age::Int = 0  # Known as 'age' in JSON too, defaults to 0
end
```
"""
macro jsondef(arg::Any)
    if arg isa Expr
        throw(ArgumentError("@jsondef requires JSON3 to be loaded"))
    else
        throw(ArgumentError("@jsondef expects a struct definition"))
    end
end

const ANAPHORIC_VAR = :self

"""
    @endpoint struct ... end

Define a struct that serves as an API endpoint.

This macro serves as a shorthand way of defining the basic endpoint methods:
- [`pagename`](@ref)
- [`parameters`](@ref) (if needed)
- [`responsetype`](@ref)
- [`payload`](@ref) (optionally)

Definitions for these methods are generated based on a non-standard endpoint
declaration line at the top of the struct definition. This line takes the forms

```julia
"page/path?params..." -> ResultType           # Get request
input -> "page/path?params..." -> ResultType  # Post request
```

Both the page path and the parameters can contain references to global variables
or fields of the struct, surrounded by curly braces. For convenience, a
parameter by the same name as the field can be referred to by the field name
alone (e.g. `?{var}` instead of `?var={var}`). The `ResultType` can be any type,
but is typically a struct defined with `@jsondef`.

```julia
"page/{somefield}?param={another}&{globalvar}=7" -> ResultType
```

In more complex cases, arbitrary Julia code can be included in the curly braces.
This code will be evaluated with the endpoint value bound the the anaphoric
variable `$ANAPHORIC_VAR`. You can also reference type parameters of the struct.

```julia
"page/{if self.new \"new\" else \"fetch\" end}/{id}" -> ResultType
```

If that's not enough, you can also use an arbitrary expression in place of the
endpoint string:

```julia
if self.create "pages/create/" else "pages/fetch/id/" * self.id end -> ResultType
```

When using an `input -> page -> ResultType` form for a post request, `input`
should follow the form of a curly brace interpolation — be either a field
name, global variable, or expression. It is used to define [`payload`](@ref) for
the endpoint.

# Examples

```julia
@endpoint struct ShuffleEndpoint <: SingleEndpoint
    "deck/{deck}/shuffle?remaining={ifelse(self.remaining, '1', '0')}" -> Deck
    deck::String
    remaining::Bool
end
```

This is equivalent to defining the struct by itself, and then separately
defining the three basic endpoint methods.

```julia
struct ShuffleEndpoint <: SingleEndpoint
    deck::String
    remaining::Bool
end

$(@__MODULE__).pagename(shuf::ShuffleEndpoint) =
    "deck/\$(shuf.deck)/shuffle"
$(@__MODULE__).parameters(shuf::ShuffleEndpoint) =
    ["remaining" => string(shuf.remaining)]
$(@__MODULE__).responsetype(shuf::ShuffleEndpoint) = Deck
```
"""
macro endpoint(strux::Expr)
    anavar = :self
    Meta.isexpr(strux, :struct, 3) ||
        throw(ArgumentError("@endpoint expects a struct definition"))
    Meta.isexpr(strux.args[3], :block) ||
        throw(ArgumentError("@endpoint expects a block definition within the struct"))
    _, structdecl, structdef = strux.args
    structlabel = if Meta.isexpr(structdecl, :(<:))
        first(structdecl.args)
    else
        throw(ArgumentError("@endpoint struct definition must be a subtype of an abstract endpoint type, such as SingleEndpoint or ListEndpoint"))
    end
    structname, structparams = if Meta.isexpr(structlabel, :curly)
        first(structlabel.args)::Symbol, Vector{Symbol}(structlabel.args[2:end])
    else
        structlabel::Symbol, nothing
    end
    # Extract struct contents/info
    specstatement = nothing
    fields = Symbol[]
    for line in structdef.args
        if line isa LineNumberNode
            continue
        elseif isnothing(specstatement)
            if Meta.isexpr(line, :(->), 2)
                specstatement = line
                continue
            else
                throw(ArgumentError("First line of @endpoint struct must be a `\"path\" -> Type` statement"))
            end
        end
        if Meta.isexpr(line, :(=), 2)
            line, _ = line.args
        end
        if Meta.isexpr(line, :(::), 2)
            line, _ = line.args
        end
        name::Symbol = line
        push!(fields, name)
    end
    isnothing(specstatement) && throw(ArgumentError("First line of @endpoint struct must be a `\"path\" -> Type` statement"))
    # Generate the struct definition
    body = Expr[]
    structredef = Expr(:struct, false, structdecl, Expr(:block, structdef.args[3:end]...))
    push!(body, Expr(:macrocall, GlobalRef(Base, Symbol("@kwdef")), __source__, structredef))
    # Generate the endpoint definition
    if Meta.isexpr(specstatement, :->, 2)
        spec1, spec2 = specstatement.args
        inform, urlform, retform = if Meta.isexpr(spec2, :block, 2) && Meta.isexpr(spec2.args[2], :->, 2)
            spec1, spec2.args[2].args...
        else
            nothing, spec1, spec2
        end
        if !isnothing(inform)
            inval = varform(inform, varname = ANAPHORIC_VAR, knownfields = fields, mod=__module__)
            push!(body, :($(@__MODULE__).payload($ANAPHORIC_VAR::$structname) = $inval))
        end
        path, params = if urlform isa String
            parse_endpoint_url(urlform, varname = ANAPHORIC_VAR, knownfields = fields, mod=__module__, filename = string(__source__.file))
        elseif urlform isa Expr || urlform isa Symbol
            varform(urlform), nothing
        else
            throw(ArgumentError("First line of @endpoint struct must be a `\"path\" -> Type` statement"))
        end
        defform(func::Symbol, ::Nothing, body) = :($(@__MODULE__).$func($ANAPHORIC_VAR::$structname) = $body)
        defform(func::Symbol, params::Vector{Symbol}, body) =
            :($(@__MODULE__).$func($ANAPHORIC_VAR::$structname{$(params...)}) where {$(params...)} = $body)
        push!(body, defform(:pagename, structparams, path))
        !isnothing(params) && push!(body, defform(:parameters, structparams, Expr(:vect, params...)))
        Meta.isexpr(retform, :block, 2) && (last(retform.args) isa Symbol || Meta.isexpr(last(retform.args), :., 2)) ||
            throw(ArgumentError("Malformed `\"path\" -> Type` line in @endpoint struct"))
        push!(body, defform(:responsetype, structparams, last(retform.args)))
    else
        throw(ArgumentError("First line of @endpoint struct must be a `\"path\" -> Type` statement"))
    end
    esc(Expr(:block, body...))
end

"""
    parse_endpoint_url(url::String; kwargs...)

Split
"""
function parse_endpoint_url(url::String; kwargs...)
    path, query = if '?' in url
        split(url, '?', limit=2)
    else
        url, nothing
    end
    isnothing(query) && return interp_curlies(path; kwargs...), nothing
    components = split(query, '&')
    parameters = Expr[]
    for comp in components
        if '=' in comp
            key, value = split(comp, '=', limit=2)
            keyex, valex = interp_curlies(String(key); kwargs...), interp_curlies(String(value); kwargs...)
            push!(parameters, :($keyex => $valex))
        elseif startswith(comp, '{') && endswith(comp, '}')
            compparsed = Meta.parse(comp)
            Meta.isexpr(compparsed, :braces, 1) || throw(ArgumentError("Invalid query component $comp"))
            compvar = first(compparsed.args)
            compvar isa Symbol || throw(ArgumentError("Invalid query component $comp"))
            kwargs2 = ((; filename, k...) -> k)(; kwargs...)
            compex = Expr(:call, GlobalRef(Base, :string), varform(compvar; kwargs2...))
            push!(parameters, :($(String(compvar)) => $compex))
        else
            throw(ArgumentError("Invalid query component $comp"))
        end
    end
    interp_curlies(String(path); kwargs...), parameters
end

"""
    interp_curlies(str::String; filename::String = "unknown", kwargs...)

Interpret `{curly}` expressions in `str` with `varform` (passing through `kwargs`).
"""
function interp_curlies(str::String; filename::String = "unknown", kwargs...)
    components = Union{String, Expr}[]
    lastidx = idx = firstindex(str)
    escaped = false
    while idx < ncodeunits(str)
        if escaped
            escaped = false
            idx += 1
        elseif str[idx] == '\\'
            escaped = true
            idx += 1
        elseif str[idx] == '{'
            lastidx < idx &&
                push!(components, str[lastidx:prevind(str, idx)])
            expr, idx = Meta.parseatom(str, idx; filename)
            Meta.isexpr(expr, :braces, 1) ||
                throw(ArgumentError("Expected single {curly} form in URL, instead saw $expr"))
            exval = first(expr.args)
            push!(components, Expr(:call, GlobalRef(Base, :string), varform(exval; kwargs...)))
            lastidx = idx
        else
            idx = nextind(str, idx)
        end
    end
    if lastidx <= lastindex(str)
        push!(components, str[lastidx:end])
    end
    if length(components) == 1
        first(components)
    else
        Expr(:call, GlobalRef(Base, :string), components...)
    end
end

"""
    varform(exval; varname::Symbol, knownfields::Vector{Symbol}, mod::Module)

Convert implicit references to a field of a variable `varname` into explicit references.

A field reference is recognised when `exval` is one of `knownfields`. If `exval` is a variable
but not a member of `knownfields` or a global variable, an `ArgumentError` is thrown.
"""
function varform(exval; varname::Symbol, knownfields::Vector{Symbol}, mod::Module)
    if exval isa Symbol
        if exval ∈ knownfields
            :($varname.$exval)
        elseif isdefined(mod, exval)
            exval
        else
            throw(ArgumentError("$exval is not a known field or global variable"))
        end
    elseif Meta.isexpr(exval, :., 2)
        dotpath = Any[exval]
        while Meta.isexpr(dotpath[end], :., 2)
            elt = dotpath[end]
            dotpath[end] = elt.args[2]
            push!(dotpath, elt.args[1])
        end
        last(dotpath) isa Symbol || return exval
        if last(dotpath) ∈ knownfields
            dotpath[end] = QuoteNode(last(dotpath))
            newpath = foldl((d, x) -> Expr(:., d, x), dotpath, init=varname)
            :($varname.$newpath)
        elseif isdefined(mod, last(dotpath))
            exval
        else
            throw(ArgumentError("$exval is not a known field or global variable"))
        end
    else
        exval
    end
end
