#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$game_repo_root"
echo "Using macOS SDK: $game_sdk"
clang++ -std=c++17 -O3 -DNDEBUG -isysroot "$game_sdk" src/Solver.cpp -o Solver.next
swiftc -O -sdk "$game_sdk" -parse-as-library \
  src/GameAssistant.swift src/Planner.swift src/GameRun.swift \
  src/Session.swift src/BoardVerification.swift -o GameAssistant.next
mv Solver.next Solver
mv GameAssistant.next GameAssistant
echo "Built ./Solver and ./GameAssistant"
