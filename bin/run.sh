#!/usr/bin/env bash

. /opt/juliahub/bin/common_init.sh

export PATH=${PATH}:/opt/juliahub/bin
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/opt/juliahub/lib

if [ -z ${HOST+x} ]; then
    HOST=0.0.0.0
fi

if [ -z ${PORT+x} ]; then
    PORT=8080
fi

julia --project=~ /opt/juliahub/bin/run.jl ${HOST} ${PORT}
