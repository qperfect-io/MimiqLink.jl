"""
    struct Tokens

Store access and refresh tokens
"""
struct Tokens
    accesstoken::String
    refreshtoken::String
end

Tokens() = Tokens("", "")

function Tokens(d::Dict)
    Tokens(d["token"], d["refreshToken"])
end

function Tokens(dict::Dict{String, T}) where {T}
    Tokens(dict["token"], dict["refreshToken"])
end

function Base.show(io::IO, tokens::Tokens)
    compact = get(io, :compact, false)

    if !compact
        println(io, "Tokens:")
        println(io, "├── access: ", tokens.accesstoken)
        print(io, "└── refresh: ", tokens.refreshtoken)
    else
        print(io, "Tokens(\"$(tokens.accesstoken)\", \"$(tokens.refreshtoken)\")")
    end

    nothing
end

JSON.lower(t::Tokens) = Dict("token" => t.accesstoken, "refreshToken" => t.refreshtoken)

"""
  refresh(tokens, uri)

Refresh the tokens at the given uri / instance of MIMIQ.
"""
function refresh(t::Tokens, uri::URI)
    res = HTTP.post(
        geturi(MimiqConnection, uri, "access-token"),
        JSONHEADERS,
        JSON.json(Dict("refreshToken" => t.refreshtoken));
        status_exception=false,
    )

    if HTTP.iserror(res)
        error("Failed to refresh connection to MIMIQ, please try to connect again.")
    end

    resbody = JSON.parse(String(HTTP.payload(res)))

    return Tokens(resbody["token"], resbody["refreshToken"])
end
"""
    struct MimiqConnection

Connection with the MIMIQ Services.

# Attributes

* `uri`: the URI of the connected instance
* `tokens_channel`: channel updated with the latest refreshed token
* `refresher`: task that refreshes the token on a configured interval
"""
struct MimiqConnection <: AbstractConnection
    uri::URI
    tokens_channel::Channel{Tokens}
    userlimits_channel::Channel{Dict{String, Any}}
    refresher::Task
end

function MimiqConnection(uri::URI, token::Tokens; interval=DEFAULT_INTERVAL)
    ch = Channel{Tokens}(1)
    ch_limits = Channel{Dict{String, Any}}(1)

    put!(ch, token)

    let limits = userlimits(uri, token)
        put!(ch_limits, limits)
        checklimits(limits)
    end

    task = @async begin
        try
            while true
                sleep(interval)

                @debug "Refreshing tokens"

                token = take!(ch)
                newtoken = refresh(token, geturi(uri))

                @debug "Received new token" newtoken

                put!(ch, newtoken)

                @debug "Refreshing user limits"

                take!(ch_limits)
                limits = userlimits(uri, newtoken)

                @debug "Received new limits" limits

                checklimits(limits)
                put!(ch_limits, limits)
            end
        catch ex
            if isa(ex, InterruptException)
                @info "Gracefully shutting down token refresher"
            else
                put!(ch, Tokens())
                put!(ch_limits, Dict())
                @warn "Connection to MIMIQ services dropped."
            end
        end
    end

    return MimiqConnection(uri, ch, ch_limits, task)
end

function Base.show(io::IO, conn::MimiqConnection)
    compact = get(io, :compact, false)

    if !compact
        status = istaskdone(conn.refresher) ? "closed" : "open"
        println(io, "MimiqConnection:")
        println(io, "├── url: ", conn.uri)

        limits = fetch(conn.userlimits_channel)
        if limits["enabledMaxExecutions"]
            println(
                io,
                "├── executions: ",
                limits["usedExecutions"],
                "/",
                limits["maxExecutions"],
            )
        end
        if limits["enabledExecutionTime"]
            println(
                io,
                "├── computing time: ",
                round(Int, limits["usedExecutionTime"] / 60),
                "/",
                round(Int, limits["maxExecutionTime"] / 60),
                " minutes",
            )
        end
        if limits["enabledMaxTimeout"]
            maxtimeout = round(Int, limits["maxTimeout"])
            println(io, "├── max time limit: ", maxtimeout, " minutes")
            println(
                io,
                "├── Default time limit is equal to max time limit: ",
                maxtimeout,
                " minutes",
            )
        else
            println(io, "├── Max time limit is: Infinite")
            println(io, "├── Default time limit is: 30 minutes")
        end
        print(io, "└── status: ", status)

    else
        print(io, typeof(conn), "($(conn.uri))")
    end

    nothing
end

geturi(::Type{MimiqConnection}, uri::URI) = joinpath(uri, "api")
geturi(::Type{MimiqConnection}, uri::URI, paths...) = joinpath(uri, "api", paths...)
geturi(conn::MimiqConnection) = joinpath(conn.uri, "api")
geturi(conn::MimiqConnection, paths...) = joinpath(conn.uri, "api", paths...)

# Authentication header. To be used in function with
# `headers = [_authheader(conn), "OtherHeader" => "headervalue", ...]`
function authheader(conn::MimiqConnection)
    # fetch, not take!, otherwise next time we have to wait for a put! in the channel
    tokens = fetch(conn.tokens_channel)
    "Authorization" => "Bearer " * tokens.accesstoken
end

function Base.close(conn::MimiqConnection)
    @info "Closing MIMIQ connection to $(conn.uri)"
    schedule(conn.refresher, InterruptException(); error=true)
end

function checklimits(limits::Dict)
    if limits["enabledExecutionTime"]
        usedtime = round(Int, limits["usedExecutionTime"] / 60)
        maxtime = round(Int, limits["maxExecutionTime"] / 60)

        if usedtime > maxtime
            @warn "You exceeded your computing time limit of $maxtime minutes"
        end
    end

    if limits["enabledMaxExecutions"]
        usedexec = limits["usedExecutions"]
        maxexec = limits["maxExecutions"]
        if usedexec > maxexec
            @warn "You exceeded your number of executions limit of $maxexec"
        end
    end
end

function userlimits(uri::URI, tokens::Tokens)
    res = HTTP.get(
        geturi(MimiqConnection, uri, "users/limits"),
        ["Authorization" => "Bearer " * tokens.accesstoken],
        "",
        status_exception=false,
    )
    json_res = JSON.parse(String(HTTP.payload(res)))


    if HTTP.iserror(res)
        reason = json_res["message"]
        error(
            "Failed to request user data with status code $(res.status) and reason: \"$reason\".",
        )
    end

    return json_res
end

function remotelogin(uri::URI, email, password)
    res = HTTP.post(
        geturi(MimiqConnection, uri, "sign-in"),
        JSONHEADERS,
        JSON.json(Dict("email" => email, "password" => password));
        status_exception=false,
    )
    json_res = JSON.parse(String(HTTP.payload(res)))
    if HTTP.iserror(res)
        reason = json_res["message"]
        error("Failed login with status code $(res.status) and reason: \"$reason\".")
    end
    Tokens(json_res)
end

function login(uri::URI, req::HTTP.Request, c::Condition)
    data = JSON.parse(String(HTTP.payload(req)))

    res = HTTP.post(
        geturi(MimiqConnection, uri, "sign-in"),
        JSONHEADERS,
        JSON.json(Dict("email" => data["email"], "password" => data["password"]));
        status_exception=false,
    )

    @show res

    json_res = JSON.parse(String(HTTP.payload(res)))

    if HTTP.iserror(res)
        reason = json_res["message"]
        @warn "Failed with status code $(res.status) and reason: \"$reason\"."
        return HTTP.Response(res.status, JSONHEADERS, JSON.json(json_res))
    end

    tokens = Tokens(json_res)
    notify(c, tokens)

    return HTTP.Response(
        200,
        JSONHEADERS,
        JSON.json(Dict("message" => "Login successfull.")),
    )
end

# from https://github.com/JuliaLang/julia/pull/36425
function detectwsl()
    Sys.islinux() &&
        isfile("/proc/sys/kernel/osrelease") &&
        occursin(r"Microsoft|WSL"i, read("/proc/sys/kernel/osrelease", String))
end

function open_in_default_browser(url::AbstractString)::Bool
    try
        if Sys.isapple()
            Base.run(`open $url`)
            true
        elseif Sys.iswindows() || detectwsl()
            Base.run(`powershell.exe Start "'$url'"`)
            true
        elseif Sys.islinux()
            Base.run(`xdg-open $url`)
            true
        else
            false
        end
    catch _
        false
    end
end

function fileserver(req::HTTP.Request)
    requested_file = req.target == "/" ? "/index.html" : req.target

    if isnothing(requested_file)
        return HTTP.(403)
    end

    file = joinpath(@__DIR__, "..", "public", HTTP.unescapeuri(requested_file[2:end]))

    extension = splitext(file)[2]
    mime =
        extension == ".js" ? "application/javascript" :
        extension == ".html" ? "text/html" :
        extension == ".css" ? "text/css" : try
            matcher(file).mime
        catch
            ""
        end

    if isfile(file)
        return HTTP.Response(200, ["Content-Type" => mime], read(file))
    end

    return HTTP.Response(404)
end

function get_mimiq_token_from_login_page(uri::URI)
    APIROUTER = HTTP.Router()

    logged = Condition()

    HTTP.register!(APIROUTER, "POST", "/api/login", req -> login(uri, req, logged))
    HTTP.register!(APIROUTER, "GET", "/", fileserver)
    HTTP.register!(APIROUTER, "GET", "/**", fileserver)

    server = HTTP.serve!(APIROUTER, Sockets.localhost, 1444; listenany=true)

    p = HTTP.port(server)
    @info "Please login in your browser at http://127.0.0.1:$p"
    open_in_default_browser("http://127.0.0.1:$p/")

    tokens = wait(logged)

    close(server)

    return tokens
end

"""
    savetoken([filename][; url=QPERFECT_CLOUD)

Establish a connection to the MIMIQ Services and save the credentials
in a JSON file.

## Arguments

* `filename`: file where to save the credentials (default: `qperfect.json`)

## Keyword arguments

* `url`: the uri of the MIMIQ Services (default: `QPERFECT_CLOUD` value)

## Examples

```julia
julia> savetoken("myqperfectcredentials.json")

julia> connection = loadtoken("myqperfectcredentials.json")

```
"""
function savetoken(filename::AbstractString="qperfect.json"; url=QPERFECT_CLOUD)
    uri = _url_to_uri(url)
    tokens = get_mimiq_token_from_login_page(uri)
    open(filename, "w") do io
        JSON.print(io, Dict("url" => string(url), "token" => tokens.refreshtoken))
    end
    @info "Token saved in `$(filename)`"
end

"""
    loadtoken([filename])

Establish a connection to the MIMIQ Services by loading the credentials from a
JSON file.

## Arguments

* `filename`: file where to load the credentials (default: `qperfect.json`)

!!! note
The credentials are usually valid only for a small amount of time, so you may
need to regenerate them from time to time.

## Examples

```
julia> savetoken("myqperfectcredentials.json")

julia> connection = loadtoken("myqperfectcredentials.json")

```
"""
function loadtoken(filename::AbstractString="qperfect.json")
    dict = JSON.parsefile(filename)

    if !haskey(dict, "url") || !haskey(dict, "token")
        error("Malformed token file")
    end

    url = URI(dict["url"])
    @info "Loaded connection file to $url"

    return connect(dict["token"]; url=url)
end

function connect(; url=QPERFECT_CLOUD, kwargs...)
    uri = _url_to_uri(url)
    tokens = get_mimiq_token_from_login_page(uri)
    return MimiqConnection(uri, tokens; kwargs...)
end

function connect(token::AbstractString; url=QPERFECT_CLOUD, kwargs...)
    uri = _url_to_uri(url)
    @info "Obtaining access token for connection"
    t = refresh(Tokens("", token), uri)
    @info "Access token obtained. You should now be connected to MIMIQ Services."
    return MimiqConnection(uri, t; kwargs...)
end

function connect(
    email::AbstractString,
    password::AbstractString;
    url=QPERFECT_CLOUD,
    kwargs...,
)
    uri = _url_to_uri(url)
    @warn "This connection methods is discuraged. Please use `connect()`, `connect(url)` or `connect(token[, url])`, if possible."
    t = remotelogin(uri, email, password)
    return MimiqConnection(uri, t; kwargs...)
end
