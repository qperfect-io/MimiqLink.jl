#
# Copyright © 2022-2023 University of Strasbourg. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

"""
    module MimiqLink end

This module contains convenience tools to establish and keep up a connection
to the QPerfect MIMIQ services, both remote or on premises.

It allows for three different connection modes: via login page, via token, via
credentials.

## Login Page

This method will open a browser pointing to a login page. The user will be asked
to insert username/email and password.

```
julia> using MimiqLink

julia> connection = MimiqLink.connect()
```

optionally an address for the MIMIQ services can be specified

```
julia> connection = MimiqLink.connect(url = "http://127.0.0.1/api")
```

## Token

This method will allow the user to save a token file (by login via a login
page), and then load it also from another julia session.

```
julia> using MimiqLink

julia> MimiqLink.savetoken(url = "http://127.0.0.1/api")
```

this will save a token in the `qperfect.json` file in the current directory.
In another julia session is then possible to do:

```
julia> using MimiqLink

julia> connection = MimiqLink.loadtoken("path/to/my/qperfect.json")
```

## Credentials

This method will allow users to access by directly use their own credentials.

!!! warning
    It is strongly discuraged to use this method. If files with credentials will
    be shared the access to the qperfect account might be compromised.

```
julia> using MimiqLink

julia> connection = MimiqLink.connect("me@mymail.com", "myweakpassword")
```

```
julia> MimiqLink.connect("me@mymail.com", "myweakpassword"; url = "http://127.0.0.1/api")
```
"""
module MimiqLink

using FileTypes
using HTTP
using Sockets
using JSON
using URIs
using ProgressLogging

export connect
export loadtoken
export savetoken
export request
export requestinfo
export isjobdone
export isjobfailed
export isjobstarted
export isjobcanceled
export downloadresults
export downloadjobfiles
export QPERFECT_CLOUD
export QPERFECT_CLOUD2

# How does the library works?
# When using connect() the library will spawn a little file server that will serve the files contained in the /public folder.
# A browser page will open showing the served login page
# The user can insert its username and password.
# After receiving the username and password the server will try to login at the remote endpoint.
# If login is successfull it will store the received token and spawn a process that will refresh the token every 15 minutes
# A Connection object will contain all the information required to send requests with the request(...) function.
# The user can close the connection, shutting down the automatic refresher, by using the close(...) function.

include("utils.jl")

"""
   const QPERFECT_CLOUD

Address for the QPerfect Cloud services
"""
const QPERFECT_CLOUD = URI("https://mimiq.qperfect.io/api")

"""
   const QPERFECT_CLOUD2

Addressfor secondary QPerfect Cloud services
"""
const QPERFECT_CLOUD2 = URI("https://mimiqfast.qperfect.io/api")

"""
  const DEFAULT_INTERVAL

Default refresh interval for tokens (in seconds)
"""
const DEFAULT_INTERVAL = 15 * 60

# headers to have request send json content
const JSONHEADERS = ["Content-Type" => "application/json"]

# include _download function (taken and modified from HTTP.jl to allow progress reporting)
include("download.jl")

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
        joinpath(uri, "access-token"),
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
    struct Connection

Connection with the MIMIQ Services.

# Attributes

* `uri`: the URI of the connected instance
* `tokens_channel`: channel updated with the latest refreshed token
* `refresher`: task that refreshes the token on a configured interval
"""
struct Connection
    uri::URI
    tokens_channel::Channel{Tokens}
    refresher::Task
end

function Connection(uri::URI, token::Tokens; interval=DEFAULT_INTERVAL)
    ch = Channel{Tokens}(1)

    put!(ch, token)

    task = @async begin
        try
            while true
                sleep(interval)

                @debug "Refreshing tokens"

                token = take!(ch)
                newtoken = refresh(token, uri)

                @debug "Received new token" newtoken

                put!(ch, newtoken)
            end
        catch ex
            if isa(ex, InterruptException)
                @info "Gracefully shutting down token refresher"
            else
                put!(ch, Tokens())
                @warn "Connection to MIMIQ services dropped."
            end
        end
    end

    return Connection(uri, ch, task)
end

function Base.show(io::IO, conn::Connection)
    compact = get(io, :compact, false)

    if !compact
        status = istaskdone(conn.refresher) ? "closed" : "open"
        println(io, "Connection:")
        println(io, "├── url: ", conn.uri)
        print(io, "└── status: ", status)
    else
        print(io, typeof(conn), "($(conn.uri)")
    end

    nothing
end

function remotelogin(uri::URI, email, password)
    res = HTTP.post(
        joinpath(uri, "sign-in"),
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
        joinpath(uri, "sign-in"),
        JSONHEADERS,
        JSON.json(Dict("email" => data["email"], "password" => data["password"]));
        status_exception=false,
    )

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

function gettoken(uri)
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
    tokens = gettoken(uri)
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

"""
    connect([; url=QPREFECT_CLOUD])
    connect(token[; url=QPREFECT_CLOUD])
    connect(username, password[; url=QPREFECT_CLOUD])

Establish a connection to the MIMIQ Services.

A refresh process will be spawned in the background to refresh the access credentials.
An active connection can be closed by using the `close(connection)` method. As an example:

```julia
connection = connect("john.doe@example.com", "johnspassword")
close(connection)
```

!!! warning

    The first method will open a login page in the default browser and ask for
    your email and password. This method is encouraged, as it will avoid saving
    your password as plain text in your scripts or notebooks.

There are two main servers for the MIMIQ Services: the main one and a secondary one.
Users are supposed to use the main one.

```jldoctests
julia> QPERFECT_CLOUD
URI("https://mimiq.qperfect.io/api")

julia> QPERFECT_CLOUD2
URI("https://mimiqfast.qperfect.io/api")
```

"""
function connect end

function connect(; url=QPERFECT_CLOUD, kwargs...)
    uri = _url_to_uri(url)
    tokens = gettoken(uri)
    return Connection(uri, tokens; kwargs...)
end

function connect(token::AbstractString; url=QPERFECT_CLOUD, kwargs...)
    uri = _url_to_uri(url)
    @info "Obtaining access token for connection"
    t = refresh(Tokens("", token), uri)
    @info "Access token obtained. You should now be connected to MIMIQ Services."
    return Connection(uri, t; kwargs...)
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
    return Connection(uri, t; kwargs...)
end

function Base.close(conn::Connection)
    @info "Closing MIMIQ connection to $(conn.uri)"
    schedule(conn.refresher, InterruptException(); error=true)
end

"""
    struct Execution

Structure referring to an execution on the MIMIQ Services.
"""
struct Execution
    id::String
end

function Base.show(io::IO, ex::Execution)
    compact = get(io, :compact, false)

    if !compact
        println(io, "Execution")
        print(io, "└── ", ex.id)
    else
        print(io, Base.typename(ex), "($(ex.id))")
    end
end

function _checkresponse(res::HTTP.Response, prefix="Error")
    if res.status < 300
        return nothing
    end

    if isempty(HTTP.payload(res))
        error("$prefix: Server responded with code $(res.status).")
    end

    json = JSON.parse(String(HTTP.payload(res)))

    if haskey(json, "message")
        message = json["message"]
        error(lazy"$(prefix): $(message)")
    else
        error(lazy"$prefix: Server responded with code $(res.status).")
    end

    return nothing
end

# TODO: add support for progress bars when uploading files
function request(
    conn::Connection,
    emulatortype::AbstractString,
    name::AbstractString,
    label::AbstractString,
    timeout::Integer,
    files...,
)
    if timeout <= 0
        throw(ArgumentError("Timeout must be a positive integer"))
    end

    data = Pair{String, Any}[
        "name" => name,
        "label" => label,
        "emulatorType" => emulatortype,
        "timeout" => string(timeout),
    ]

    for file in files
        if file isa AbstractString
            push!(data, "uploads" => open(file, "r"))
        else
            push!(data, "uploads" => file)
        end
    end

    body = HTTP.Form(data)

    res = HTTP.post(
        joinpath(conn.uri, "request"),
        [_authheader(conn)],
        body;
        status_exception=false,
    )

    _checkresponse(res, "Error creating execution request")

    res = JSON.parse(String(HTTP.payload(res)))
    return Execution(res["executionRequestId"])
end

function stopexecution(conn::Connection, req::Execution)
    uri = joinpath(conn.uri, "request", "stop-execution", req.id)

    res = HTTP.post(uri, [_authheader(conn)], ""; status_exception=false)

    _checkresponse(res, "Error stopping execution")

    return true
end

function requestinfo(conn::Connection, req::Execution)
    uri = joinpath(conn.uri, "request", req.id)

    res = HTTP.get(uri, [_authheader(conn)], "")

    _checkresponse(res, "Error retrieving execution information")

    return JSON.parse(String(HTTP.payload(res)))
end

function isjobdone(conn::Connection, req::Execution)
    infos = requestinfo(conn, req)
    status = infos["status"]
    return status != "NEW" || status != "RUNNING"
end

function isjobfailed(conn::Connection, req::Execution)
    infos = requestinfo(conn, req)
    return infos["status"] == "ERROR"
end

function isjobstarted(conn::Connection, req::Execution)
    infos = requestinfo(conn, req)
    return infos["status"] != "NEW"
end

function isjobcanceled(conn::Connection, req::Execution)
    infos = requestinfo(conn, req)
    return infos["status"] == "CANCELED"
end

function _downloadfiles(conn, req, destdir, type)
    @debug "Downloading jobfiles in $destdir"

    if !isdir(destdir)
        mkdir(destdir)
    end

    infos = requestinfo(conn, req)
    names = []

    nf = get(infos, "numberOf$(type == :uploads ? "Uploaded" : "Resulted")Files", 0)

    if nf == 0 || !(nf isa Number)
        @warn "No files to download."
        return names
    end

    for idx in 0:(nf - 1)
        uri = URI(
            joinpath(conn.uri, "files", req.id, string(idx));
            query=Dict("source" => string(type)),
        )
        fname = _download(string(uri), destdir, [_authheader(conn)]; update_period=Inf)
        push!(names, fname)
    end

    return names
end

function downloadjobfiles(conn::Connection, req::Execution, destdir=joinpath("./", req.id))
    _downloadfiles(conn, req, destdir, :uploads)
end

function downloadresults(conn::Connection, req::Execution, destdir=joinpath("./", req.id))
    _downloadfiles(conn, req, destdir, :results)
end

# Authentication header. To be used in function with
# `headers = [_authheader(conn), "OtherHeader" => "headervalue", ...]`
function _authheader(conn::Connection)
    # fetch, not take!, otherwise next time we have to wait for a put! in the channel
    tokens = fetch(conn.tokens_channel)
    "Authorization" => "Bearer " * tokens.accesstoken
end

end # module MimiqLink
