#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <appearances.dat> <world.otbm> [extra maps...]"
    exit 1
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
client_root="$(cd "$script_directory/../.." && pwd)"
build_directory="$(mktemp -d)"
appearances_file="$1"
shift

python3 -m grpc_tools.protoc -I"$client_root/src/protobuf" --python_out="$build_directory" "$client_root/src/protobuf/appearances.proto"
PYTHONPATH="$build_directory" python3 "$script_directory/export_appearances.py" "$appearances_file" "$build_directory/items.bin"
g++ -O2 -std=c++20 -o "$build_directory/otbm_to_otmm" "$script_directory/otbm_to_otmm.cpp" -lz
mkdir -p "$client_root/data/minimap"
"$build_directory/otbm_to_otmm" "$build_directory/items.bin" "$client_root/data/minimap/world.otmm" "$@"
rm -rf "$build_directory"
