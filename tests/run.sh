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
# tests/unit/<name>_test.dusk with a matching .expected file is run too, the
# recorded stdout of every "<app> completion bash" case is checked with bash -n
# (and zsh -n where a zsh case exists and zsh is installed, fish is skipped), and
# tests/complete.sh sources the generated bash scripts and drives them.
#
# A case is a directory tests/cases/<name>/ holding:
#   cmd      required, one line, "<app> <args...>" split on spaces with no quoting,
#            a bare "" standing for an empty argument the shell would have quoted.
#            The line may start with any number of VAR=value assignments before the
#            app name; they are applied to that run with env and to nothing else,
#            which is how a case exercises the environment bindings
#            ("NOVA_NAME=fromenv config show").
#   stdout   required outside --update, the exact expected stdout
#   stderr   optional, the exact expected stderr, not compared when absent
#   code     optional, the expected exit status, 0 when absent
#
# Every case runs with the repository root as its working directory, so a path
# written in a cmd line ("--config examples/config/good.json") means the same
# thing wherever run.sh itself was called from.
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
    # A bare "" stands for an empty argument, which read leaves as two quote characters
    for i in "${!argv[@]}"; do
        if [ "${argv[$i]}" = '""' ]; then
            argv[$i]=""
        fi
    done
    # Leading VAR=value tokens set the environment of this run and are not arguments
    envs=()
    while [ "${#argv[@]}" -gt 0 ] && [[ "${argv[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        envs+=("${argv[0]}")
        argv=("${argv[@]:1}")
    done
    if [ "${#argv[@]}" -eq 0 ]; then
        echo "${yellow}SKIP${off} $name (no app named)"
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

    (cd "$root" && env ${envs[@]+"${envs[@]}"} "$bin" ${args[@]+"${args[@]}"}) >"$tmp/out" 2>"$tmp/err"
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

# ---------------------------------------------------------------- shell syntax
#
# A generated completion script is a golden like any other, so the shell it is
# written for parses its recorded stdout: bash -n for a "completion bash" case,
# zsh -n for a "completion zsh" case when zsh is installed, and nothing for fish
# since a fish script is not parsed by a flag.

for casedir in "$cases"/*/; do
    [ -d "$casedir" ] || continue
    name="syntax-$(basename "$casedir")"
    if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
        continue
    fi
    [ -f "$casedir/cmd" ] || continue
    [ -f "$casedir/stdout" ] || continue

    IFS= read -r line < "$casedir/cmd"
    shell=""
    case "$line" in
        *" completion bash"*) shell="bash" ;;
        *" completion zsh"*)  shell="zsh" ;;
        *)                    continue ;;
    esac

    if ! command -v "$shell" > /dev/null 2>&1; then
        echo "${yellow}SKIP${off} $name ($shell is not installed)"
        skipped=$((skipped + 1))
        continue
    fi

    if d="$("$shell" -n "$casedir/stdout" 2>&1)"; then
        echo "${green}PASS${off} $name"
        pass=$((pass + 1))
    else
        echo "${red}FAIL${off} $name"
        printf '%s\n' "$d" | sed 's/^/    /'
        fail=$((fail + 1)); failed_names+=("$name")
    fi
done

# ---------------------------------------------------------------- completion drive
#
# tests/complete.sh sources the generated bash scripts and calls the completion
# functions with COMP_WORDS set, so the scripts are checked by running as well as
# by parsing. It needs the example binaries, which the build step above made.

if [ -z "$filter" ] || [[ "complete" == *"$filter"* ]]; then
    if out="$(bash "$here/complete.sh" 2>&1)"; then
        echo "${green}PASS${off} complete-drive"
        pass=$((pass + 1))
    else
        echo "${red}FAIL${off} complete-drive"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail + 1)); failed_names+=("complete-drive")
    fi
fi

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
