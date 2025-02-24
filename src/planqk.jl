using Base64
using URIs

const PLANQK_API = URI("https://gateway.platform.planqk.de")

struct JWTtoken
    access_token::String
    scope::String
    token_type::String
    expires_in::Int
end

function Base.show(io::IO, token::JWTtoken)
    compact = get(io, :compact, false)

    if !compact
        println(io, "JWT Token:")
        println(io, "├── access_token: ", token.access_token)
        println(io, "├── scope: ", token.scope)
        println(io, "├── token_type: ", token.token_type)
        print(io, "└── expires_in: ", token.expires_in)
    else
        print(io, typeof(token), "(", token.access_token, ")")
    end

    nothing
end

function get_planqk_token(consumer_key::String, consumer_secret::String)
    path = joinpath(PLANQK_API, "token")

    creds = base64encode("$consumer_key:$consumer_secret")
    res = HTTP.post(
        path,
        ["Authorization" => "Basic $(creds)"],
        "grant_type=client_credentials",
    )

    resbody = JSON.parse(String(HTTP.payload(res)))

    return JWTtoken(
        resbody["access_token"],
        resbody["scope"],
        resbody["token_type"],
        resbody["expires_in"],
    )
end

struct PlanqkConnection <: AbstractConnection
    uri::URI
    token_channel::Channel{JWTtoken}
    refresher::Task
end

function PlanqkConnection(endpoint::URI, consumer_key::String, consumer_secret::String)
    ch = Channel{JWTtoken}(1)

    token = get_planqk_token(consumer_key, consumer_secret)
    put!(ch, token)

    refresher = @async begin
        try
            sleep(floor(Int, token.expires_in * 0.8))
            while true
                @debug "Refreshing token"

                take!(ch)
                newtoken = get_planqk_token(consumer_key, consumer_secret)

                @debug "Received new token" newtoken

                put!(ch, newtoken)

                sleep(ceil(Int, newtoken.expires_in * 0.8))
            end
        catch ex
            if isa(ex, InterruptException)
                @info "Gracefully shutting down token refresher"
            else
                put!(ch, "")
                @warn "Connection to MIMIQ services dropped."
            end
        end
    end

    return PlanqkConnection(endpoint, ch, refresher)
end

PlanqkConnection(uri::String, consumer_key::String, consumer_secret::String) =
    PlanqkConnection(_url_to_uri(uri), consumer_key, consumer_secret)

function Base.show(io::IO, conn::PlanqkConnection)
    compact = get(io, :compact, false)

    if !compact
        status = istaskdone(conn.refresher) ? "closed" : "open"
        println(io, "PlanQK Connection:")
        println(io, "├── url: ", conn.uri)
        print(io, "└── status: ", status)
    else
        print(io, typeof(conn), "($(conn.uri))")
    end

    nothing
end

geturi(::Type{PlanqkConnection}, uri::URI) = joinpath(uri, "api/planqk")
geturi(conn::PlanqkConnection) = joinpath(conn.uri, "api/planqk")
geturi(conn::PlanqkConnection, paths...) = joinpath(conn.uri, "api/planqk", paths...)

# Authentication header. To be used in function with
# `headers = [_authheader(conn), "OtherHeader" => "headervalue", ...]`
function authheader(conn::PlanqkConnection)
    # fetch, not take!, otherwise next time we have to wait for a put! in the channel
    token = fetch(conn.token_channel)
    return "Authorization" => "Bearer " * token.access_token
end

function Base.close(conn::PlanqkConnection)
    @info "Closing PlanQK connection to $(conn.uri)"
    schedule(conn.refresher, InterruptException(); error=true)
end

function connect(
    ::Type{PlanqkConnection},
    url::Union{URI, String},
    consumer_key::String,
    consumer_secret::String,
)
    return PlanqkConnection(_url_to_uri(url), consumer_key, consumer_secret)
end

# check if PLANKQ_API, PLANQK_CONSUMER_KEY and PLANQK_CONSUMER_SECRET are set as environment variable, and if so connect
function connect(
    ::Type{PlanqkConnection};
    url=nothing,
    consumer_key=nothing,
    consumer_secret=nothing,
)
    DotEnv.load!()

    url = isnothing(url) ? get(ENV, "PLANQK_API", nothing) : url
    consumer_key =
        isnothing(consumer_key) ? get(ENV, "PLANQK_CONSUMER_KEY", nothing) : consumer_key
    consumer_secret =
        isnothing(consumer_secret) ? get(ENV, "PLANQK_CONSUMER_SECRET", nothing) :
        consumer_secret

    if isnothing(url)
        error("No URL provided and PLANQK_API not set in environment.")
    end

    if isnothing(consumer_key)
        error("No consumer key provided and PLANQK_CONSUMER_KEY not set in environment.")
    end

    if isnothing(consumer_secret)
        error(
            "No consumer secret provided and PLANQK_CONSUMER_SECRET not set in environment.",
        )
    end

    return PlanqkConnection(url, consumer_key, consumer_secret)
end

