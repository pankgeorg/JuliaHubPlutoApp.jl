import Downloads
host = get(ENV, "HOST", "0.0.0.0")
port = parse(Int, get(ENV, "PORT", "1234"))
APIKEY = get(ENV, "APIKEY", "")
ARTIFACT_URL = "https://api.buildkite.com/v2/organizations/julia-computing-1/pipelines/juliasim/builds/388/jobs//839cc464-f212-4745-a5b6-ab0a1e85a771/artifacts/5a2c4fa6-991b-4fe6-98d7-02e1f12560f1/download"
ARTIFACT_URL = get(ENV, "ARTIFACT_URL", ARTIFACT_URL)

# buildkite API Key
headers = Dict("Authorization" => "Bearer $(APIKEY)")

# progress = (b,a) -> print("\r$(a/b)%                                           ")
# tarfile = joinpath(@__DIR__, "../JuliaSimSysimg_0.3.3.tar.gz")
tarfile = Downloads.download(ARTIFACT_URL; headers=headers)
@info tarfile
oldpwd = pwd()
cd(@__DIR__)
run(`cp $tarfile ./sysimg.tar.gz`)
run(`./install.sh`)
runjl = joinpath(@__DIR__, "./run.jl")

run(`/tmp/julia/bin/julia -J ./js_sysimg/JuliaSimSysimg_0.3.3.so $runjl`)
cd(oldpwd)

