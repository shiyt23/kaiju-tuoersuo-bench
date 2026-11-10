#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
game_minutes=${1:-40}
game_mode=${2:-score}
game_output=${3:-"runs/session-$(date +%Y%m%d-%H%M%S)"}
case "$game_mode" in score|fullclear) ;; *) echo "Usage: $0 MINUTES [score|fullclear] [NEW_OUTPUT_DIRECTORY]" >&2; exit 1 ;; esac
game_seconds=$(ruby -e 'n=Integer(ARGV.fetch(0),10); abort "Minutes must be positive" unless n>0; puts n*60' "$game_minutes")
[[ ! -e "$game_output" ]] || { echo "Output already exists: $game_output" >&2; exit 1; }
if [[ ! -x ./GameAssistant || ! -x ./Solver ]]; then ./scripts/build.sh; fi
mkdir -p "$game_output"
cp "configs/$game_mode.json" "$game_output/config.json"
game_until=$(ruby -rjson -rtime -e '
  directory, seconds, mode = ARGV; started=Time.now.utc; until_time=started+Integer(seconds)
  config=JSON.parse(File.read(File.join(directory,"config.json")))
  session={started_at:started.iso8601,minimum_end_at:until_time.iso8601,
    minimum_duration_seconds:Integer(seconds),target:config.fetch("target"),
    search_budget_seconds:config.fetch("search_seconds"),mode:mode,status:"active"}
  File.write(File.join(directory,"session.json"),JSON.pretty_generate(session)+"\n")
  puts until_time.to_i' "$game_output" "$game_seconds" "$game_mode")
echo "Session output: $game_output"
/usr/bin/caffeinate -di ./GameAssistant session --until "$game_until" --output "$game_output" 2>&1 | tee "$game_output/session.log"
ruby scripts/report.rb "$game_output"
ruby -rjson -e '
  directory=ARGV.fetch(0); session_path=File.join(directory,"session.json")
  session=JSON.parse(File.read(session_path)); report=JSON.parse(File.read(File.join(directory,"report.json")))
  session["status"]=report.dig("current_state","status")
  session["finished_at"]=report["finished_at"] if report["finished_at"]
  session["actual_duration_seconds"]=report["observed_duration_seconds"]
  File.write(session_path,JSON.pretty_generate(session)+"\n")' "$game_output"
