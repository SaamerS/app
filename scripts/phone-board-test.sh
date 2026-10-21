#!/bin/bash
# Plays a Mac's board against the iPhone app in a Simulator, on throwaway data: a quick trip to the background keeps the
# link, an agent's question rings on the iPhone, its card opens from the notification, and the answer reaches the Mac.
# Build first: Binders (Debug, -derivedDataPath build-dev) and BindersPhone for testing (-derivedDataPath build-phone-sim).
# Usage: scripts/phone-board-test.sh <simulator UDID>
set -uo pipefail
UDID=${1:?usage: $0 <simulator UDID>}
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
mkdir "$WORK/data" "$WORK/signals"
mkfifo "$WORK/in"
failures=0
check() { if [[ $1 == 0 ]]; then echo "PASS: $2"; else echo "FAIL: $2"; failures=$((failures + 1)); fi; }

# The Mac: fictional data in an empty folder, on spare ports, taking commands on its input.
BINDERS_DATA_DIR="$WORK/data" build-dev/Build/Products/Debug/Binders.app/Contents/MacOS/Binders --selftest-link-serve \
  < "$WORK/in" > "$WORK/mac.log" 2>&1 &
mac=$!
exec 3> "$WORK/in"
say() { echo "$1" >&3; sleep 2; }
for _ in $(seq 120); do grep -q PAIR_URL "$WORK/mac.log" && break; sleep 0.5; done
pair=$(grep -m1 PAIR_URL "$WORK/mac.log" | sed 's/^PAIR_URL: //')
if [[ -z $pair ]]; then
  echo "FAIL: the Mac didn't start"; cat "$WORK/mac.log"; exit 1
fi

TEST_RUNNER_BINDERS_PAIR_URL="$pair" TEST_RUNNER_BINDERS_SIGNALS="$WORK/signals" xcodebuild test-without-building \
  -scheme BindersPhone -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build-phone-sim \
  -clonedSourcePackagesDirPath build-dev/SourcePackages -only-testing:BindersPhoneUITests/BoardTests > "$WORK/test.log" 2>&1 &
test=$!
waitFor() {
  for _ in $(seq 180); do
    [[ -e "$WORK/signals/$1" ]] && return 0
    kill -0 $test 2>/dev/null || return 1
    sleep 1
  done
  return 1
}
hellos() { say hellos; grep HELLOS "$WORK/mac.log" | tail -1; }

waitFor connected; check $? "the iPhone pairs and connects"
before=$(hellos)
waitFor ready; check $? "the iPhone comes back from the background"
after=$(hellos)
[[ -n $before && $before == "$after" ]]; check $? "a moment in the background keeps the link ($before, then $after)"
say "ask Fix the import|Which staging database should the 50k import test use?"
grep -q "ASKED: [0-9A-F-]\{36\}" "$WORK/mac.log"; check $? "an agent asks on the Mac"
waitFor answered; check $? "the question rings on the iPhone, opens its card and is answered there"
say "card Fix the import"
card=$(grep CARD: "$WORK/mac.log" | tail -1)
[[ $card == *"column=in_progress assignee=Claude Code · harbor-web lease=30 last=answer:You:Use the second one"* ]]
check $? "the Mac has the answer, and the agent a fresh 30 minutes: $card"
waitFor away; check $? "Binders goes to the background"
say "ask Draft the changelog|Should the post mention annual plans?"
waitFor replied; check $? "the second question rings with Binders in the background, and is answered in the notification"
sleep 4
say "card Draft the changelog"
card=$(grep CARD: "$WORK/mac.log" | tail -1)
[[ $card == *"column=in_progress assignee=Claude Code · harbor-web lease=30 last=answer:You:Yes, in one line"* ]]
check $? "the notification's answer reaches the Mac: $card"

wait $test; check $? "the iPhone's test passes"
say quit
wait $mac 2>/dev/null
grep -E "(Test Case|error:|failed|XCTAssert)" "$WORK/test.log" | head -20
echo "Logs and screenshots: $WORK"
[[ $failures == 0 ]] && echo "PHONE_BOARD_OK" || echo "PHONE_BOARD_FAILED: $failures"
[[ $failures == 0 ]]
