host = ARGS[1]
port = parse(Int, ARGS[2])
# using Pkg # Already uses Pkg
# Pkg.develop(PackageSpec(path="/opt/juliahub/packages/Pluto"))
# Code that can be added
try
    # Resolve explodes, but that's okey right? :) 
    Pkg.instantiate()
catch e
    @warn e
end

Pkg.add([
    Pkg.PackageSpec(name = "Pluto", version = "0.17.7"),
    Pkg.PackageSpec(name = "JSON", version = "0.21"),
    Pkg.PackageSpec(name = "HTTP", version = "0.9.17"),
])

import Base64

# import TOML # Already here
using HTTP
using JSON
using Downloads
using UUIDs
import Pluto



import Base: @kwdef
@kwdef mutable struct JHubPlutoSession
    jh_server::String = Pkg.pkg_server()
    jh_cached_username = ""
    jh_cached_headers = Dict()
    notebook_params = Dict()
    session::Union{Pluto.ServerSession,Nothing} = nothing
end

function get_jhub_params(jhub_session::JHubPlutoSession, notebook::Pluto.Notebook)
    get(jhub_session.notebook_params, notebook.notebook_id, nothing)
end

function set_jhub_params!(
    jhub_session::JHubPlutoSession,
    notebook::Pluto.Notebook,
    params::Dict,
)
    jhub_session.notebook_params[notebook.notebook_id] = params
end

function jh_auth_headers!(jhub_session::JHubPlutoSession)
    headers = Dict()
    auth = Pkg.PlatformEngines.get_auth_header(Pkg.pkg_server(); verbose = true)
    !isnothing(auth) && (auth = auth[2])
    push!(headers, "Authorization" => auth)
    push!(headers, "Julia-Version" => string(VERSION))
    jhub_session.jh_cached_headers = headers
end

function jh_username!(jhub_session)
    resp = try
        HTTP.get(
            joinpath(jhub_session.jh_server, "app/users"),
            headers = jhub_session.jh_cached_headers,
        )
    catch e
        @error "Cannot fetch username from server\n$(e)"
        return nothing
    end
    datum = JSON.parse(String(resp.body))
    jhub_session.jh_cached_username = datum["username"]
end

jhub_session = JHubPlutoSession()

jh_auth_headers!(jhub_session)
jh_username!(jhub_session)

@async while true
    try
        jh_auth_headers!(jhub_session)
        jh_username!(jhub_session)
        sleep(600)  # This should loosly match the token refresh time
    catch exc
        @info "Error while refreshing token!\n$(exc)"
    end
end

@info "Welcome to Pluto on JuliaHub"
@info "Server: $(jhub_session.jh_server)"
@info "Username: $(jhub_session.jh_cached_username)"



####  

# JuliaHub Responses
Pluto.responses[:juliahub_initiate] = function (🙋::Pluto.ClientRequest)
    user_notebooks_path = joinpath(
        jhub_session.jh_server,
        "notebooks",
        jhub_session.jh_cached_username,
        "folders",
    )
    d = Dict()
    resp = try
        HTTP.get(user_notebooks_path; headers = jhub_session.jh_cached_headers)
    catch e
        @error "Could not fetch user notebooks for :juliahub_initiate\n$e"
    end
    if !isnothing(resp) && resp.status == 200
        push!(d, :username => jhub_session.jh_cached_username)
        push!(d, :folders => JSON.parse(String(resp.body))["folders"])
        push!(d, :success => true)
    else
        @info "Most likely this is due to expired tokens"
        push!(:success => false, :message => "Failed to update notebook metadata.")
    end
    msg = Pluto.UpdateMessage(:write_file_reply, d, nothing, nothing, 🙋.initiator)
    Pluto.putclientupdates!(🙋.session, 🙋.initiator, msg)
end

Pluto.responses[:juliahub_notebook_patch] = function (🙋::Pluto.ClientRequest)
    req = 🙋.body
    body = Dict()
    if haskey(req, "notebook")
        push!(body, :name => req["notebook"])
    end
    if haskey(req, "folder")
        push!(body, :folder => req["folder"])
    end

    path = joinpath(jhub_session.jh_server, "notebooks", "uuid", req["id"], "metadata")
    headers = merge(
        jhub_session.jh_cached_headers,
        Dict("JuliaHub-HTTP-Method" => "PATCH"),
        Dict("X-HTTP-Method-Override" => "PATCH"),
    )
    resp = try
        HTTP.post(path, headers, JSON.json(body))
    catch e
        @error "Could not PATCH notebook with metadata: $(body) due to \n$(e)"
        nothing
    end
    response = if !isnothing(resp) && resp.status == 200
        nbbyid = 🙋.session.notebooks[UUID(req["id"])]
        session_params = get_jhub_params(jhub_session, nbbyid)
        if haskey(req, "id")
            session_params[:id] = req["id"]
        end
        if haskey(req, "folder")
            session_params[:folder] = req["folder"]
        end
        Dict(:success => true, :message => "Successfully changed notebook metadata.")
    else
        Dict(:success => false, :message => "Failed to update notebook metadata.")
    end

    msg =
        Pluto.UpdateMessage(:write_file_reply, response, nothing, nothing, 🙋.initiator)
    Pluto.putclientupdates!(🙋.session, 🙋.initiator, msg)
end

# From SessionActions.jl
function open_jhnb(session::Pluto.ServerSession, path::AbstractString; kwargs...)
    # TODO: Check working with arbitrary unicode characters
    # TODO: Make these proper regex groups
    # TODO: Error handling
    # ** TODO **: Add someone else's notebook and wait for the user to save it.
    # Parse path:
    # example = "Ellipse0934/foo/bar.jl"
    @info "Received request to open notebook: $(path)"
    ## Get notebook metadata
    src_notebook_id = tryparse(UUID, path)
    nb_path = if src_notebook_id === nothing
        path_regex = r"(?<namespace>.*)\/(?<folder>.*)\/(?<notebook>.*\.jl)"
        m = match(path_regex, path)
        !(m isa RegexMatch) && return error("Invalid link")
        joinpath(
            jhub_session.jh_server,
            "notebooks",
            m[:namespace],
            "folders",
            m[:folder],
            "notebooks",
            m[:notebook],
        )
    else
        joinpath(jhub_session.jh_server, "notebooks", "uuid", string(src_notebook_id))
    end

    resp = try
        HTTP.get(joinpath(nb_path, "metadata"); headers = jhub_session.jh_cached_headers)
    catch e
        error("Cannot access notebook. Invalid reference or Unauthorized\n $(e)")
    end
    nb_metadata = JSON.parse(String(resp.body))

    jhub_params = Dict(
        :id => nb_metadata["notebook_id"],
        :namespace => nb_metadata["namespace"],
        :folder => nb_metadata["folder"],
        :notebook => nb_metadata["notebook"],
    )
    ## Clone public notebook
    if (nb_metadata["namespace"] != jhub_session.jh_cached_username)
        @info "Cloning notebook to 'Default' folder..."
        name = nb_metadata["notebook"]
        # Get current list of notebooks
        list_path = joinpath(
            jhub_session.jh_server,
            "notebooks",
            jhub_session.jh_cached_username,
            "folders",
        )
        resp = try
            HTTP.get(list_path; headers = jhub_session.jh_cached_headers)
        catch
            throw(error("Unable to fetch user notebooks"))
        end

        d = JSON.parse(String(resp.body))
        notebooks = only(filter(x -> x["name"] == "Default", d["folders"]))["notebooks"]

        # Find a non-conflicting name
        i = 1
        first_name = match(r"(.*)\.jl", name)[1]
        while length(
            filter(x -> x["name"] == first_name * (i == 1 ? ".jl" : "($i).jl"), notebooks),
        ) != 0
            i += 1
        end
        name = first_name * (i == 1 ? ".jl" : "($i).jl")

        # Download original notebook
        resp = try
            HTTP.get(joinpath(nb_path, "source"); headers = jhub_session.jh_cached_headers)
        catch e
            error("Unable to download original source file.\n $(e)")
        end

        source = String(resp.body)

        # Create new notebook with same name
        # TODO: Maybe a fork endpoint

        create_path = joinpath(
            jhub_session.jh_server,
            "notebooks",
            jhub_session.jh_cached_username,
            "folders",
            "Default",
            "notebooks",
        )
        body = Dict(:file => source, :name => "$(name)")
        resp = try
            HTTP.post(create_path, jhub_session.jh_cached_headers, JSON.json(body))
        catch
            error(
                "Unable to create new notebook with name: '$(name).jl' in Default Folder\nReport this to Admin: $(resp)\n$(String(resp.body))",
            )
        end
        d = JSON.parse(String(resp.body))
        jhub_params[:id] = d["notebook_id"]
        jhub_params[:namespace] = jhub_session.jh_cached_username
        jhub_params[:folder] = "Default"
        jhub_params[:notebook] = name
    end

    download_path =
        joinpath(jhub_session.jh_server, "notebooks", "uuid", jhub_params[:id], "source")
    jhnb_path = joinpath("./Notebooks/JuliaHub", jhub_params[:id])
    mkpath(jhnb_path)
    jhnb_path = joinpath(jhnb_path, "source.jl")
    @info "Downloading notebook $(path) to $(jhnb_path)"

    resp = try
        HTTP.get(download_path; headers = jhub_session.jh_cached_headers)
    catch
        error("Unable to fetch file $download_path $(jhub_params[:notebook])")
    end
    write(jhnb_path, String(resp.body)) # Add: Timeout
    sleep(0.5)
    nb = Pluto.SessionActions.open(
        session,
        string(jhnb_path);
        notebook_id = UUID(jhub_params[:id]),
    )
    set_jhub_params!(jhub_session, nb, jhub_params)
    nb
end

"""
Handles the creation of the entities on JuliaHub and the dice roll for UUID
"""
function jhub_new_notebook(notebook)
    # Get current list of notebooks
    path = joinpath(
        jhub_session.jh_server,
        "notebooks",
        jhub_session.jh_cached_username,
        "folders",
    )
    resp = try
        HTTP.get(path; headers = jhub_session.jh_cached_headers)
    catch
        throw(error("Unable to fetch user notebooks"))
    end
    body = String(resp.body)
    d = JSON.parse(body)

    name = Pluto.cutename()

    notebooks = only(filter(x -> x["name"] == "Default", d["folders"]))["notebooks"]

    # Find a non-conflicting name
    i = 1
    while length(
        filter(x -> x["name"] == name * (i == 1 ? ".jl" : "($i).jl"), notebooks),
    ) != 0
        i += 1
    end
    name = name * (i == 1 ? ".jl" : "($i).jl")

    body = Dict(:file => "### A Pluto.jl notebook ###", :name => "$(name)")
    path = joinpath(path, "Default", "notebooks")

    @info "Creating new notebook with name: '$(name)' in Default Folder"
    resp = try
        HTTP.post(path, jhub_session.jh_cached_headers, JSON.json(body))
    catch
        error("Unable to create new notebook with name: '$(name)' in Default Folder")
    end

    body = String(resp.body)
    d = JSON.parse(body)
    println(body)
    notebook_id = d["notebook_id"]

    jhub_params = Dict(
        :namespace => jhub_session.jh_cached_username,
        :folder => "Default",
        :notebook => name,
        :id => notebook_id,
    )
    notebook.notebook_id = notebook_id
    set_jhub_params!(jhub_session, notebook, jhub_params)
    return notebook_id
end

function open_url(session::Pluto.ServerSession, url::AbstractString; kwargs...)
    file = try
        String(HTTP.get(url).body)
    catch
        error("Unable to fetch notebook from $(url)")
    end

    path = joinpath(
        jhub_session.jh_server,
        "notebooks",
        jhub_session.jh_cached_username,
        "folders",
    )
    resp = try
        HTTP.get(path; headers = jhub_session.jh_cached_headers)
    catch
        throw(error("Unable to fetch user notebooks"))
    end

    d = JSON.parse(String(resp.body))
    name = try
        match(r"(.*)/(.*)\.jl", url)[2]
    catch
        cutename()
    end

    notebooks = only(filter(x -> x["name"] == "Default", d["folders"]))["notebooks"]

    # Find a non-conflicting name
    i = 1
    while length(
        filter(x -> x["name"] == name * (i == 1 ? ".jl" : "($i).jl"), notebooks),
    ) != 0
        i += 1
    end
    name = name * (i == 1 ? ".jl" : "($i).jl")

    body = Dict(:file => file, :name => "$(name)")
    path = joinpath(path, "Default", "notebooks")

    @info "Creating new notebook with name: '$(name)' in Default Folder"
    resp = try
        HTTP.post(path, jhub_session.jh_cached_headers, JSON.json(body))
    catch e
        error("Unable to create new notebook with name: '$(name)' in Default Folder\n$e")
    end

    d = JSON.parse(String(resp.body))
    notebook_id = d["notebook_id"]

    jhub_params = Dict(
        :namespace => jhub_session.jh_cached_username,
        :folder => "Default",
        :notebook => name,
        :id => notebook_id,
    )

    jhnb_path = joinpath("./Notebooks/JuliaHub", jhub_params[:id])
    mkpath(jhnb_path)
    jhnb_path = joinpath(jhnb_path, "source.jl")
    write(jhnb_path, file)
    sleep(0.5)
    Pluto.SessionActions.open(session, jhnb_path; notebook_id = UUID(jhub_params[:id]))
end

function jhub_save_notebook_hook(notebook::Pluto.Notebook)
    jhub_params = get_jhub_params(jhub_session, notebook)

    if !isnothing(jhub_params)
        io = IOBuffer()
        Pluto.save_notebook(io, notebook)
        body = String(take!(io))
        notebook_id = jhub_params[:id]
        path = joinpath(jhub_session.jh_server, "notebooks", "uuid", notebook_id, "source")
        headers = merge(
            jhub_session.jh_cached_headers,
            Dict("JuliaHub-HTTP-Method" => "PATCH"),
            Dict("X-HTTP-Method-Override" => "PATCH"),
        )
        try
            HTTP.post(path, headers, body)
        catch e
            @info "Failed to save: " exception = e
            nothing
        end
    end
end


### jh_event_handling ###

function jh_event_handling(ev::Pluto.PlutoEvent)
    # We're ignoring everything not further specified!
    nothing
end

function jh_event_handling(ev::Pluto.NewNotebookEvent)
    jhub_new_notebook(ev.notebook)
end

function jh_event_handling(ev::Pluto.OpenNotebookEvent)
    notebook = ev.notebook
    # Check to see if notebook exists already; if not, we need to create a new one!
    @info "Open Notebook Event !!"
    nb_metadata = try
        resp = HTTP.get(
            joinpath(
                jhub_session.jh_server,
                "notebooks",
                "uuid",
                string(notebook.notebook_id),
                "metadata",
            );
            headers = jhub_session.jh_cached_headers,
        )
        JSON.parse(String(resp.body))
    catch e  # TODO: Do this only on specific issue
        error("Notebook seems not to exist OR expired credentials $(e)")
    end

    jhub_params = Dict(
        :id => nb_metadata["notebook_id"],
        :namespace => nb_metadata["namespace"],
        :folder => nb_metadata["folder"],
        :notebook => nb_metadata["notebook"],
    )
    @info "Open notebook stats:  $(notebook.notebook_id) $(jhub_params)"
    set_jhub_params!(jhub_session, notebook, jhub_params)
    return nothing
end

"JuliaHub on file save"
function jh_event_handling(ev::Pluto.FileSaveEvent)
    notebook = ev.notebook
    jhub_save_notebook_hook(notebook)
end

"""
Handler for non-standard pluto open command url params.
This function needs to return redirect to /edit?id={jhub_id}.
"""
function jh_event_handling(ev::Pluto.CustomLaunchEvent)::HTTP.Messages.Response
    query = ev.params
    request = ev.request
    haskey(query, "jhnb")
    path = query["jhnb"]
    redirect = try
        ev.try_launch_notebook_response(
            (a, b) -> open_jhnb(a, b),
            path,
            as_redirect = true,
            title = "Failed to load notebook",
            advice = """The notebook from
              <code>$(Pluto.htmlesc(path))</code> could not be loaded.
              Please <a href='https://github.com/JuliaComputing/JuliaHub/issues'>
                      report this error
              </a>!""",
        )
    catch e
        @info "Exception while trying to open and redirect\n$(e)"
        throw(e)
    end
    return redirect
end

###                   ###

env_javascript = "data:text/javascript;base64,$(Base64.base64encode(read(joinpath(@__DIR__, "environment.js"), String)))"

pluto_server_options = Pluto.Configuration.from_flat_kwargs(;
    port = port,
    host = host,
    launch_browser = false,
    dismiss_update_notification = true,
    auto_reload_from_file = false,
    disable_writing_notebook_files = true,
    require_secret_for_open_links = false,
    require_secret_for_access = false,
    # injected_javascript_data_url = env_javascript,
)

jhub_session.session = Pluto.ServerSession(;
    options = pluto_server_options,
    event_listener = jh_event_handling,
)

Pluto.run(jhub_session.session)
