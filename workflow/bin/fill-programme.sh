#!/usr/bin/env bash
# Fills the local programme grid with random talks, for trying things out by hand.
#
# Usage: workflow/bin/fill-programme.sh [base-url] [count]
#        base-url  default http://localhost:8080; must be local (the production grid is shared with the harness)
#        count     cells to fill, default 20, capped at the grid size (rooms R1-R3 x slots S1-S5 = 15 cells)
#
# Per cell: a fresh speaker (so no talk limit or speaker clash), a talk with a random format and level (a workshop
# only in S4, the only slot long enough), two ratings from different reviewers, ACCEPTED, then PUT into the cell.
# A cell that already has a talk is cleared first. Needs curl and jq.
set -euo pipefail

base="${1:-http://localhost:8080}"
count="${2:-20}"
base="${base%/}"

case "$base" in
    http://localhost*|http://127.0.0.1*|http://0.0.0.0*) ;;
    *) echo "refusing to write to $base: the programme is one global grid the harness uses; local only" >&2; exit 2 ;;
esac

rooms=(R1 R2 R3)
slots=(S1 S2 S3 S4 S5)
formats=(LIGHTNING_10 LIGHTNING_20 PRESENTATION)
levels=(BEGINNER INTERMEDIATE ADVANCED)
words=(Reactive Kotlin Spring Postgres Kubernetes Records Loom Virtual Threads GraalVM Testcontainers Observability
       Gradle Maven Modules Streams Patterns Security Caching Kafka)

pick() { local a=("$@"); echo "${a[RANDOM % ${#a[@]}]}"; }

# call <method> <path> [json]: prints the body, fails with the status and body on anything but 2xx
call() {
    local out status
    out=$(curl -sS -X "$1" "$base$2" -H 'Content-Type: application/json' ${3:+--data "$3"} -w $'\n%{http_code}')
    status="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if (( status < 200 || status >= 300 )); then
        echo "$1 $2 -> $status $out" >&2
        return 1
    fi
    printf '%s' "$out"
}

curl -fsS "$base/health" >/dev/null || { echo "no service on $base (workflow/bin/local.sh up)" >&2; exit 1; }

filled=0
for room in "${rooms[@]}"; do
    for slot in "${slots[@]}"; do
        (( filled < count )) || break 2

        # clear the cell if it's taken (404 = already empty)
        curl -sS -o /dev/null -X DELETE "$base/programme/$room/$slot"

        format=$(pick "${formats[@]}")
        if [[ $slot == S4 ]] && (( RANDOM % 2 )); then format=WORKSHOP; fi
        level=$(pick "${levels[@]}")
        title="$(pick "${words[@]}") $(pick "${words[@]}") in practice"
        name="Speaker $room$slot-$RANDOM"
        email="fill-$(date +%s%N)-$RANDOM@example.com"

        speaker=$(call POST /speakers "$(jq -nc --arg n "$name" --arg e "$email" '{name: $n, email: $e}')" | jq -r .id)
        talk=$(call POST /talks "$(jq -nc --arg t "$title" --arg f "$format" --arg l "$level" --argjson s "$speaker" \
            '{title: $t, format: $f, level: $l, speakerId: $s}')" | jq -r .id)
        call PUT "/talks/$talk/ratings/1" "{\"score\": $((RANDOM % 5 + 1))}" >/dev/null
        call PUT "/talks/$talk/ratings/2" "{\"score\": $((RANDOM % 5 + 1))}" >/dev/null
        call PUT "/talks/$talk/status" '{"status": "ACCEPTED"}' >/dev/null
        call PUT "/programme/$room/$slot" "{\"talkId\": $talk}" >/dev/null

        printf '%s %s  talk %-5s %-13s %-12s %s\n' "$room" "$slot" "$talk" "$format" "$level" "$title"
        filled=$((filled + 1))
    done
done

grid=$(( ${#rooms[@]} * ${#slots[@]} ))
if (( count > grid )); then
    echo "filled $filled cells: the grid only has $grid (${rooms[*]} x ${slots[*]}), asked for $count"
else
    echo "filled $filled cells"
fi
