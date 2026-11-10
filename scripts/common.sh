#!/bin/bash
# Shared repository and SDK discovery; sourced by build/test scripts.
game_repo_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -n "${GAME_ASSISTANT_SDK:-}" ]]; then
  game_sdk=$GAME_ASSISTANT_SDK
else
  game_active_sdk=$(xcrun --sdk macosx --show-sdk-path)
  game_tested_sdk="$(dirname "$game_active_sdk")/MacOSX15.4.sdk"
  if [[ -d "$game_tested_sdk" ]]; then
    game_sdk=$game_tested_sdk
  else
    game_sdk=$game_active_sdk
  fi
fi
[[ -d "$game_sdk" ]] || { echo "macOS SDK not found: $game_sdk" >&2; exit 1; }
