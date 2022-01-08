using Pkg

Pkg.develop(PackageSpec(path="/opt/juliahub/packages/Pluto"))

Pkg.add([
    Pkg.PackageSpec(name = "JSON", version = "0.21"),
    Pkg.PackageSpec(name = "HTTP", version = "0.9.17"),
])

Pkg.precompile()
