#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Select an installed SDK compatible with this machine's compiler/linker.
game_sdk="${GAME_ASSISTANT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
if [ ! -d "$game_sdk" ]; then
    game_sdk="$(xcrun --show-sdk-path)"
fi
clang++ -std=c++17 -O3 -DNDEBUG -isysroot "$game_sdk" Solver.cpp -o Solver.next
swiftc -O -sdk "$game_sdk" -parse-as-library GameAssistant.swift Planner.swift GameRun.swift Session.swift -o GameAssistant.next
mv Solver.next Solver
mv GameAssistant.next GameAssistant
