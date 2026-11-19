#!/usr/bin/env bash
#
# nova argv fuzz run.
#
#   tests/fuzz.sh              run the fixed seed against the strict and flags examples
#   tests/fuzz.sh <count>      run <count> vectors per example instead of the default 1500
#
# A deterministic generator, a linear congruential one with a fixed seed so every run
# replays the same vectors, builds argv vectors of 0 to 20 words out of a token pool
# holding the commands and flags of each example plus hostile tokens, a lone "-", "--",
# "--=", "-=x", an empty word, bytes that are not UTF-8, numbers past the int64 range,
# inf, nan, hex, words longer than the strict example's 256 byte limit and one past the
# default 65536 byte limit, etc. Every vector runs once under timeout, and the run fails
# when a process dies by a signal, runs past the time bound, exits with anything but 0
# or 1, or writes "fatal:" to stderr, which is how a nova abort and a dusk heap fault
# both start. The example binaries have to exist, tests/run.sh builds them first and
# runs this under the name fuzz.
#
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

count="${1:-1500}"
bound=5

# The seed every run starts from
seed=20261119
state=$seed

# Steps the generator and leaves a number from 0 to 2^31 - 1 in rnd
next() {
    state=$(( (state * 1103515245 + 12345) % 2147483648 ))
    rnd=$(( state / 65536 ))
}

# Tokens both trees get, the hostile ones first
long300="$(printf 'x%.0s' $(seq 1 300))"
long70k="$(head -c 70000 /dev/zero | tr '\0' 'y')"
shared=(
    "-" "--" "--=" "--=x" "-=x" "-=" "=" "---x" "" " " "a b" $'a\tb' $'\n'
    $'\xff\xfe' $'\xc3' $'-\xc3' $'--\xff' $'\xc3(' "-h" "--help" "--help=maybe"
    "help" "completion" "bash" "zsh" "fish" "elvish" "__complete" "__completeNoDesc"
    "0x10" "1e999" "inf" "nan" "-9223372036854775809" "99999999999999999999" "+5" "-5"
    "$long300" "$long70k" "--version" "-v" "x" "y"
)

# Tokens of the strict example
strict_pool=(
    "show" "nest" "deeper" "deepest" "big" "getter" "refuse"
    "-n" "-p" "-r" "-t" "-l" "-m" "--name" "--port" "--rate" "--tag" "--loud" "--mode"
    "--name=x" "--port=1" "--port=+-1" "--port=" "--rate=1e400" "--rate=nan" "--rate=.5"
    "--tag=a,b,c,d,e" "-lllll" "-lnbob" "-nl" "-ln" "--loud=9223372036854775807"
    "--mode=bad" "safe" "fast" "-mfast" "-p=8" "-t,,,,"
)

# Tokens of the flags example
flags_pool=(
    "echo" "-r" "-t" "-x" "-e" "-v" "-vvv" "--rate" "--tag" "--exclude" "--emit"
    "--verbose" "--verbose=3" "--verbose=99999999999999999999" "--rate=1e-400"
    "--rate=0x1p3" "--emit=x" "llvm" "obj" "-e=obj" "-vr" "-rv" "-tx" "--no-descriptions"
    "--tag=a,a,a,a,a" "-v=-1"
)

fails=0
runs=0
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# Runs count vectors against one binary drawn from the shared pool and one tree pool
fuzz_tree() {
    local bin="$1"
    shift
    local pool=("${shared[@]}" "$@")
    local n=${#pool[@]}
    local k
    for ((k = 0; k < count; k++)); do
        # The vector length, mostly short with the odd one past the strict argument limit
        next
        local len=$(( rnd % 11 ))
        if (( rnd % 50 == 0 )); then
            len=20
        fi

        # The words
        local argv=()
        local j
        for ((j = 0; j < len; j++)); do
            next
            argv+=("${pool[$(( rnd % n ))]}")
        done

        # Run it under the time bound
        (cd "$root" && timeout "$bound" "$bin" ${argv[@]+"${argv[@]}"}) > /dev/null 2> "$err"
        local code=$?
        runs=$((runs + 1))

        # Anything but 0 or 1 is a signal, the time bound or a code nova never gives
        local why=""
        if (( code == 124 )); then
            why="ran past ${bound}s"
        elif (( code >= 128 )); then
            why="died by signal $(( code - 128 ))"
        elif (( code != 0 && code != 1 )); then
            why="exit $code"
        elif grep -q "^fatal:" "$err"; then
            why="wrote fatal: to stderr"
        fi
        if [ -n "$why" ]; then
            fails=$((fails + 1))
            printf 'FAIL %s: %s, argv:' "$(basename "$bin")" "$why"
            printf ' %q' ${argv[@]+"${argv[@]}"} | cut -c1-400
            echo
        fi
    done
}

strict_bin="$root/examples/strict/target/dusk-out/strict"
flags_bin="$root/examples/flags/target/dusk-out/flags"
for b in "$strict_bin" "$flags_bin"; do
    if [ ! -x "$b" ]; then
        echo "fuzz.sh: missing $b, run tests/run.sh first" >&2
        exit 1
    fi
done

fuzz_tree "$strict_bin" "${strict_pool[@]}"
fuzz_tree "$flags_bin" "${flags_pool[@]}"

echo "fuzz: seed $seed, $runs runs, $fails failed"
if (( fails > 0 )); then
    exit 1
fi
exit 0
