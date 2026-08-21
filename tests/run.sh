#!/usr/bin/env bash
#
# nova golden test harness.
#
#   tests/run.sh                 build every example, run every case
#   tests/run.sh <substr>        only cases whose name contains <substr>
#   tests/run.sh --update        additionally write missing expected files
#   tests/run.sh --update --force  overwrite expected files that already exist
#   tests/run.sh --no-build      skip the build step, the binaries must exist
#
# tests/unit/<name>_test.dusk with a matching .expected file is run too.
#
# A case is a directory tests/cases/<name>/ holding:
#   cmd      required, one line, "<app> <args...>" split on spaces with no quoting
#   stdout   required outside --update, the exact expected stdout
#   stderr   optional, the exact expected stderr, not compared when absent
#   code     optional, the expected exit status, 0 when absent
#
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
examples="$root/examples"
cases="$root/tests/cases"

update=0
force=0
build=1
filter=""

for arg in "$@"; do
    case "$arg" in
        --update)   update=1 ;;
        --force)    force=1 ;;
        --no-build) build=0 ;;
        -h|--help)
            awk 'NR > 1 { if (substr($0, 1, 1) != "#") exit; sub(/^# ?/, ""); print }' "$here/run.sh"
            exit 0
            ;;
        -*)
            echo "run.sh: unknown option $arg" >&2
            exit 2
            ;;
        *)          filter="$arg" ;;
    esac
done

red=""; green=""; yellow=""; off=""
if [ -t 1 ]; then
    red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; off=$'\033[0m'
fi

# ---------------------------------------------------------------- build

declare -A bin_of=()

for dir in "$examples"/*/; do
    app="$(basename "$dir")"
    src="$dir$app.dusk"
    [ -f "$src" ] || continue
    out="$dir/target/dusk-out/$app"
    if [ "$build" -eq 1 ]; then
        echo "building $app"
        # The cwd matters, dusk writes target/dusk-out/<stem> relative to it
        if ! log="$(cd "$dir" && dusk build "$app.dusk" 2>&1)"; then
            echo "${red}BUILD FAILED${off} $app"
            echo "$log" | sed 's/^/    /'
            exit 1
        fi
    fi
    if [ ! -x "$out" ]; then
        echo "${red}MISSING BINARY${off} $out" >&2
        exit 1
    fi
    bin_of["$app"]="$out"
done

if [ "${#bin_of[@]}" -eq 0 ]; then
    echo "run.sh: no examples found under $examples" >&2
    exit 1
fi

# ---------------------------------------------------------------- run

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
skipped=0
wrote=0
failed_names=()

for casedir in "$cases"/*/; do
    [ -d "$casedir" ] || continue
    name="$(basename "$casedir")"
    if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
        continue
    fi
    if [ ! -f "$casedir/cmd" ]; then
        echo "${yellow}SKIP${off} $name (no cmd file)"
        skipped=$((skipped + 1))
        continue
    fi

    IFS= read -r line < "$casedir/cmd"
    read -r -a argv <<< "$line"
    if [ "${#argv[@]}" -eq 0 ]; then
        echo "${yellow}SKIP${off} $name (empty cmd)"
        skipped=$((skipped + 1))
        continue
    fi
    app="${argv[0]}"
    args=("${argv[@]:1}")
    bin="${bin_of[$app]:-}"
    if [ -z "$bin" ]; then
        echo "${red}FAIL${off} $name: no example named '$app'"
        fail=$((fail + 1))
        failed_names+=("$name")
        continue
    fi

    "$bin" ${args[@]+"${args[@]}"} >"$tmp/out" 2>"$tmp/err"
    got_code=$?

    # --update fills in whatever the case is missing
    if [ "$update" -eq 1 ]; then
        if [ ! -f "$casedir/stdout" ] || [ "$force" -eq 1 ]; then
            cp "$tmp/out" "$casedir/stdout"; wrote=1
        fi
        if [ "$force" -eq 1 ] && [ -f "$casedir/stderr" ]; then
            cp "$tmp/err" "$casedir/stderr"; wrote=1
        elif [ ! -f "$casedir/stderr" ] && [ -s "$tmp/err" ]; then
            cp "$tmp/err" "$casedir/stderr"; wrote=1
        fi
        if [ "$got_code" -ne 0 ] && { [ ! -f "$casedir/code" ] || [ "$force" -eq 1 ]; }; then
            echo "$got_code" > "$casedir/code"; wrote=1
        elif [ "$got_code" -eq 0 ] && [ "$force" -eq 1 ] && [ -f "$casedir/code" ]; then
            rm -f "$casedir/code"; wrote=1
        fi
        if [ "$wrote" -eq 1 ]; then
            echo "${yellow}UPDATE${off} $name"
            wrote=0
        fi
    fi

    problems=""

    if [ -f "$casedir/stdout" ]; then
        if ! d="$(diff -u --label "expected stdout" "$casedir/stdout" --label "actual stdout" "$tmp/out")"; then
            problems="$problems$d"$'\n'
        fi
    else
        problems="${problems}missing expected stdout (run tests/run.sh --update)"$'\n'
    fi

    if [ -f "$casedir/stderr" ]; then
        if ! d="$(diff -u --label "expected stderr" "$casedir/stderr" --label "actual stderr" "$tmp/err")"; then
            problems="$problems$d"$'\n'
        fi
    fi

    want_code=0
    [ -f "$casedir/code" ] && want_code="$(tr -d '[:space:]' < "$casedir/code")"
    if [ "$got_code" -ne "$want_code" ]; then
        problems="${problems}exit code: expected $want_code, got $got_code"$'\n'
    fi

    if [ -z "$problems" ]; then
        echo "${green}PASS${off} $name"
        pass=$((pass + 1))
    else
        echo "${red}FAIL${off} $name    \$ $line"
        printf '%s' "$problems" | sed 's/^/    /'
        fail=$((fail + 1))
        failed_names+=("$name")
    fi
done

# ---------------------------------------------------------------- unit tests
#
# tests/unit/<name>_test.dusk is a dusk root program whose combined stdout and stderr must
# equal tests/unit/<name>_test.expected. It reaches the library through the tests/unit/nova
# symlink and is filtered by the same substring the cases are.

for src in "$root"/tests/unit/*_test.dusk; do
    [ -f "$src" ] || continue
    name="unit-$(basename "$src" .dusk)"
    if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
        continue
    fi
    expected="${src%.dusk}.expected"
    got="$(cd "$root/tests/unit" && dusk run "$(basename "$src")" 2>&1)"
    if [ ! -f "$expected" ]; then
        if [ "$update" -eq 1 ]; then
            printf '%s\n' "$got" > "$expected"
            echo "${yellow}UPDATE${off} $name"
        else
            echo "${red}FAIL${off} $name: missing $expected"
            fail=$((fail + 1)); failed_names+=("$name"); continue
        fi
    fi
    if d="$(printf '%s\n' "$got" | diff -u --label "expected" "$expected" --label "actual" -)"; then
        echo "${green}PASS${off} $name"
        pass=$((pass + 1))
    else
        if [ "$update" -eq 1 ] && [ "$force" -eq 1 ]; then
            printf '%s\n' "$got" > "$expected"
            echo "${yellow}UPDATE${off} $name"
            pass=$((pass + 1))
        else
            echo "${red}FAIL${off} $name"
            printf '%s\n' "$d" | sed 's/^/    /'
            fail=$((fail + 1)); failed_names+=("$name")
        fi
    fi
done
rm -rf "$root/tests/unit/target"

echo
if [ -n "$filter" ] && [ $((pass + fail + skipped)) -eq 0 ]; then
    echo "${yellow}no case name contains '$filter'${off}"
fi
echo "$pass passed, $fail failed, $skipped skipped"
if [ "$fail" -gt 0 ]; then
    printf 'failed: %s\n' "${failed_names[*]}"
    exit 1
fi
exit 0
