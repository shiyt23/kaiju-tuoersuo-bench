#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$game_repo_root"
./scripts/build.sh
mkdir -p build
for test_name in check_full_clear check_beam; do
  clang++ -std=c++17 -O2 -isysroot "$game_sdk" "tests/$test_name.cpp" -o "build/$test_name"
  "build/$test_name"
done
./GameAssistant selftest
./GameAssistant test-scenes
./GameAssistant test-appearance
