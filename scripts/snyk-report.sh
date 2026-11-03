#!/usr/bin/env bash
# Runs Snyk Open Source and Snyk Code over the project and writes JSON and HTML reports to
# snyk-reports/<yyyy-mm-dd_hhmm>/, for the AppExchange security review (docs/security-review.md, "Snyk").
# Needs `npx snyk auth` once. archive/ and snyk-reports/ are excluded by .snyk.
# A finding makes snyk exit non-zero; the reports are still written, so this script carries on and only fails
# when a scan couldn't run at all (exit 2 or more).
set -u
cd "$(dirname "$0")/.."

out="snyk-reports/$(date +%Y-%m-%d_%H%M)"
mkdir -p "$out"

run() {
    local name=$1
    shift
    npx --yes snyk "$@" --json-file-output="$out/$name.json" > "$out/$name.txt" 2>&1
    local status=$?
    if [ "$status" -ge 2 ]; then
        echo "Snyk $name couldn't run (exit $status): see $out/$name.txt" >&2
        exit "$status"
    fi
    if ! npx --yes snyk-to-html -i "$out/$name.json" -o "$out/Replayr-Snyk-$name.html" > /dev/null || [ ! -s "$out/Replayr-Snyk-$name.html" ]; then
        echo "No HTML report for $name: see $out/$name.json" >&2
    fi
}

run open-source test
run code code test
grep -hE "Total issues|Open issues|no vulnerable paths" "$out"/*.txt
echo "Reports: $out"
