#!/usr/bin/env bash
#
# Drives the generated bash completion scripts the way bash itself drives them.
#
#   tests/complete.sh            source every script and check COMPREPLY
#
# The example binaries must already be built (tests/run.sh builds them). Each
# check sets COMP_WORDS and COMP_CWORD, calls the completion function the script
# defines and compares COMPREPLY joined with single spaces to what is expected.
# compopt is shadowed by a stub that records its arguments, since the real
# builtin refuses to run outside a completion readline is driving.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

todo="$root/examples/todo/target/dusk-out/todo"
flags="$root/examples/flags/target/dusk-out/flags"

for bin in "$todo" "$flags"; do
    if [ ! -x "$bin" ]; then
        echo "complete.sh: missing binary $bin" >&2
        exit 1
    fi
done

# The bash builtin is not available outside a real completion, so record the calls instead
compopt_calls=""
compopt() {
    compopt_calls="$compopt_calls[$*]"
    return 0
}

# Source both generated scripts, which is what a user does from their rc file
source <("$todo" completion bash)
source <("$flags" completion bash)

pass=0
fail=0

# Runs one completion function over the words and compares the reply to what is expected
check() {
    local label="$1" fn="$2" want="$3"
    shift 3

    COMP_WORDS=("$@")
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    COMP_LINE="${COMP_WORDS[*]}"
    COMP_POINT=${#COMP_LINE}
    COMPREPLY=()
    compopt_calls=""

    "$fn"

    local got="${COMPREPLY[*]+${COMPREPLY[*]}}"
    if [ "$got" = "$want" ]; then
        echo "PASS complete $label"
        pass=$(( pass + 1 ))
    else
        echo "FAIL complete $label"
        echo "    expected: $want"
        echo "    actual:   $got"
        fail=$(( fail + 1 ))
    fi
}

# Checks that the last run asked compopt for the given option
checkopt() {
    local label="$1" want="$2"
    if [[ "$compopt_calls" == *"$want"* ]]; then
        echo "PASS complete $label"
        pass=$(( pass + 1 ))
    else
        echo "FAIL complete $label"
        echo "    expected compopt $want among $compopt_calls"
        fail=$(( fail + 1 ))
    fi
}

# A prefix of a command name narrows the children down to the one that starts with it
check "todo con" _todo_completions "config" "$todo" "con"

# A nested command completes its own children
check "todo config s" _todo_completions "set" "$todo" "config" "s"

# Two dashes ask for the long spellings of every flag the command takes
check "todo list --" _todo_completions "--all --help --verbose" "$todo" "list" "--"

# The flags of a command with no positional typed yet are its children
check "todo empty" _todo_completions "add completion config done help list ls" "$todo" ""

# A choice flag offers its alternatives as the value of the flag before the cursor
check "flags --emit" _flags_completions "llvm obj" "$flags" "--emit" ""

# The same through the shorthand
check "flags -e" _flags_completions "llvm obj" "$flags" "-e" ""

# A registered completion func offers the values it knows
check "flags --tag" _flags_completions "alpha beta gamma" "$flags" "--tag" ""

# bash splits "--emit=" into two words, which the script glues back together, and
# the reply drops the "--emit=" again since readline replaces the word after the "="
check "flags --emit=" _flags_completions "llvm obj" "$flags" "--emit" "="

# The candidate list came with the no file completion bit, so file names are off
checkopt "no file comp" "[+o default]"

# The same through the shorthand, whose value the last letter of the token names
check "flags -e=" _flags_completions "llvm obj" "$flags" "-e" "="

# A "--" ends the flags, so a dash after it offers no flag name at all
check "todo -- -" _todo_completions "" "$todo" "--" "-"

# A value flag nothing is known about leaves file completion alone
check "flags --rate" _flags_completions "" "$flags" "--rate" ""
checkopt "default file comp" "[-o default]"

echo "complete.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
