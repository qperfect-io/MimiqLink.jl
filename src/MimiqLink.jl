#
# Copyright © 2023 University of Strasbourg. All Rights Reserved.
# See AUTHORS.md for the list of authors.
#
#
module MimiqLink

using FileTypes
using HTTP
using Sockets
using JSON
using URIs

"""
   const QPERFECT_CLOUD

Fallback address for the QPerfect Cloud services
"""
const QPERFECT_CLOUD = URI("http://vps-f8c698f6.vps.ovh.net/")

# headers to have request send json content
const JSONHEADERS = ["Content-Type" => "application/json"]

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

function Tokens(dict::Dict{String,T}) where {T}
  Tokens(dict["token"], dict["refreshToken"])
end

JSON.lower(t::Tokens) = Dict("token" => t.accesstoken, "refreshToken" => t.refreshtoken)

function refresh(t::Tokens, uri::URI)
  res = HTTP.post(joinpath(uri, "/api/access-token"), JSONHEADERS, JSON.json(Dict("refreshToken" => t.refreshtoken)); status_exception=false)

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

function Connection(uri::URI, token::Tokens; interval=60)
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
        @info "Closing refresher"
      end
    end
  end

  return Connection(uri, ch, task)
end

function login(uri::URI, req::HTTP.Request, c::Condition)
  data = JSON.parse(String(HTTP.payload(req)))

  res = HTTP.post(joinpath(uri, "/api/sign-in"), JSONHEADERS, JSON.json(Dict("email" => data["email"], "password" => data["password"])); status_exception=false)

  json_res = JSON.parse(String(HTTP.payload(res)))

  if HTTP.iserror(res)
    reason = json_res["message"]
    @warn "Failed with status code $(res.status) and reason: \"$reason\"."
    return HTTP.Response(res.status, JSONHEADERS, JSON.json(json_res))
  end

  tokens = Tokens(json_res)
  notify(c, tokens)

  return HTTP.Response(200, JSONHEADERS, JSON.json(Dict("message" => "Login successfull.")))
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
  mime = extension == ".js" ? "application/javascript" :
         extension == ".html" ? "text/html" :
         extension == ".css" ? "text/css" :
         try
    matcher(file).mime
  catch
    ""
  end

  if isfile(file)
    return HTTP.Response(200, ["Content-Type" => mime], read(file))
  end

  return HTTP.Response(404)
end

function connect(uri::URI=QPERFECT_CLOUD; interval=15 * 60)
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

  return Connection(uri, tokens; interval=interval)
end

function Base.close(conn::Connection)
  @info "Closing MIMIQ connection to $(conn.uri)"
  schedule(conn.refresher, InterruptException(); error=true)
end

struct Execution
  id::String
end

function request(conn::Connection, name, label, files...)
  data = Pair{String,Any}[
    "name"=>name,
    "label"=>label
  ]

  for file in files
    push!(data, "uploads" => file)
  end

  body = HTTP.Form(data)
  tokens = fetch(conn.tokens_channel)
  headers = ["Authorization" => "Bearer " * tokens.accesstoken]
  res = HTTP.post(joinpath(conn.uri, "/api/request"), headers, body)

  #res = JSON.parse(String(HTTP.payload(res)))
  #return Execution(res["executionRequestId"])
  return Execution("640f112300514323466c0e35")
end

function getrequestinfo(conn::Connection, req::Execution)
  tokens = fetch(conn.tokens_channel)
  headers = ["Authorization" => "Bearer " * tokens.accesstoken]

  res = HTTP.get(joinpath(conn.uri, "/request/$(req.id)"), headers, "")

  #return JSON.parse(String(HTTP.payload(res)))
  return res
end

end # module MimiqLink
