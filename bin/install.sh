#!/bin/env bash
cd $1
set -ex

ls -alh
# 
# tar xvf ./sysimg.tar.gz
rm -rf /tmp/julia
cp -r /opt/julia-1.6.1/ /tmp/julia/
chown -R $USER:$USER /tmp/julia
rm -rf ~/.julia-bk
mv ~/.julia ~/.julia-bk

# Recreates ~/.julia with defaults
/tmp/julia/bin/julia -e 'using Pkg; Pkg.resolve()'
rm -rf  ~/.julia/artifacts
pwd
ls -alh
cp -r js_sysimg/artifacts ~/.julia/
cp -r js_sysimg/PinnedProject/* ~/.julia/environments/v1.6/
cp -r js_sysimg/SrclessPackages/* /tmp/julia/share/julia/stdlib/v1.6/
