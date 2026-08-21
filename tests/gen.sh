#!/usr/bin/env bash
#
# nova-cli end to end generator test.
#
#   tests/gen.sh              build nova-cli, then scaffold, wire, and build a real app
#   tests/gen.sh --no-build   reuse target/dusk-out/nova-cli as it stands
#   tests/gen.sh --keep       leave the sandbox behind for inspection
#
# tests/run.sh replays golden output for the library, this drives the generator the way a
# user does, it inits a project, adds commands to it including the collision prone name c
# and the dashed name my-cmd, refuses the things that must be refused, then compiles the
# generated application and runs it.
#
# The first scenario is the dusk 1.14 one and it is the whole point of the file, a git
# repository is made out of the working tree, nova-cli init writes a package.dawn that
# requires it, dawn get fetches it into dawn_modules/, and the generated project builds with
# no symlink and no vendored copy anywhere in it. --vendor keeps the pre 1.14 shape alive
# underneath, and every scenario after the first one uses it.
#
# The sandbox lives under $NOVA_GEN_WORK when that is set, else under the scratch directory
# named below, else under mktemp -d.
#
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
novacli="$root/target/dusk-out/nova-cli"

build=1
keep=0
for arg in "$@"; do
    case "$arg" in
        --no-build) build=0 ;;
        --keep)     keep=1 ;;
        -h|--help)
            awk 'NR > 1 { if (substr($0, 1, 1) != "#") exit; sub(/^# ?/, ""); print }' "$here/gen.sh"
            exit 0
            ;;
        *)
            echo "gen.sh: unknown option $arg" >&2
            exit 2
            ;;
    esac
done

red=""; green=""; yellow=""; off=""
if [ -t 1 ]; then
    red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; off=$'\033[0m'
fi

scratch="/tmp/claude-1000/-home-austin-projects-nova-cli/5e648b54-f8d6-4616-97c4-92062f557880/scratchpad/gen-tests"
work="${NOVA_GEN_WORK:-$scratch}"
mkdir -p "$work" 2>/dev/null || work="$(mktemp -d)"
sandbox="$(mktemp -d "$work/run.XXXXXX")" || { echo "gen.sh: cannot make a sandbox" >&2; exit 1; }

cleanup() {
    if [ "$keep" -eq 1 ]; then
        echo "sandbox kept at $sandbox"
    else
        rm -rf "$sandbox"
    fi
}
trap cleanup EXIT

passes=0
failures=0

ok() {
    passes=$((passes + 1))
    printf '%sPASS%s %s\n' "$green" "$off" "$1"
}

bad() {
    failures=$((failures + 1))
    printf '%sFAIL%s %s\n' "$red" "$off" "$1"
    shift
    for line in "$@"; do
        printf '       %s\n' "$line"
    done
}

# ---------------------------------------------------------------- assertions
#
# Every step runs through attempt, which parks stdout, stderr, and the exit status in $out,
# $err, and $code for the assertions that follow.

out=""
err=""
code=0

attempt() {
    out="$("$@" 2>"$sandbox/.stderr")"
    code=$?
    err="$(cat "$sandbox/.stderr")"
}

attempt_sh() {
    out="$(eval "$1" 2>"$sandbox/.stderr")"
    code=$?
    err="$(cat "$sandbox/.stderr")"
}

want_code() {
    if [ "$code" -eq "$2" ]; then
        ok "$1 (exit $2)"
    else
        bad "$1: exit $code, want $2" "stdout: $out" "stderr: $err"
    fi
}

want_out() {
    case "$out" in
        *"$2"*) ok "$1" ;;
        *)      bad "$1: stdout has no '$2'" "stdout: $out" ;;
    esac
}

want_err() {
    case "$err" in
        *"$2"*) ok "$1" ;;
        *)      bad "$1: stderr has no '$2'" "stderr: $err" ;;
    esac
}

want_file() {
    if [ -f "$2" ]; then
        ok "$1"
    else
        bad "$1: no such file $2"
    fi
}

want_no_path() {
    if [ -e "$2" ] || [ -L "$2" ]; then
        bad "$1: $2 exists and should not" "$(ls -ld "$2" 2>&1)"
    else
        ok "$1"
    fi
}

want_grep() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        ok "$1"
    else
        bad "$1: $2 has no '$3'"
    fi
}

want_symlink() {
    if [ -L "$2" ]; then
        ok "$1"
    else
        bad "$1: $2 is not a symlink"
    fi
}

want_dir() {
    if [ -d "$2" ]; then
        ok "$1"
    else
        bad "$1: $2 is not a directory"
    fi
}

want_no_err() {
    case "$err" in
        *"$2"*) bad "$1: stderr has '$2'" "stderr: $err" ;;
        *)      ok "$1" ;;
    esac
}

# ---------------------------------------------------------------- build the generator

if [ "$build" -eq 1 ]; then
    if (cd "$root" && dusk build nova-cli.dusk >"$sandbox/.build" 2>&1); then
        ok "build nova-cli.dusk"
    else
        bad "build nova-cli.dusk" "$(cat "$sandbox/.build")"
        printf '%s1 failed, 0 passed%s\n' "$red" "$off"
        exit 1
    fi
fi
if [ ! -x "$novacli" ]; then
    bad "no nova-cli binary at $novacli"
    exit 1
fi

cd "$sandbox" || exit 1

# ---------------------------------------------------------------- init, dawn manifest
#
# The default mode since dusk 1.14. nova-cli init writes a package.dawn requiring nova and
# runs dawn get, which needs a real git repository to fetch from, so the working tree is
# copied into one under the sandbox and served over file:// and the whole path runs with no
# network. Excluding .git keeps this from being a clone of the repository's own history, and
# the -c user options keep it from needing a configured git identity.

srcrepo="$sandbox/repo"
mkdir -p "$srcrepo"
if (cd "$root" && tar --exclude=target --exclude=dawn_modules --exclude=.git -cf - . | tar -xf - -C "$srcrepo") \
    && git -C "$srcrepo" init -q -b main \
    && git -C "$srcrepo" add -A \
    && git -C "$srcrepo" -c user.name=t -c user.email=t@t commit -qm "gen.sh fixture"; then
    ok "package the working tree as a git repository"
else
    bad "package the working tree as a git repository"
fi

attempt "$novacli" init mapp --dir mapp --source "file://$srcrepo" --ref main
want_code "init mapp (manifest mode)" 0
want_file "init writes package.dawn" "$sandbox/mapp/package.dawn"
want_grep "package.dawn names the root" "$sandbox/mapp/package.dawn" "@root mapp.dusk"
want_grep "package.dawn requires nova" "$sandbox/mapp/package.dawn" "@require nova file://$srcrepo main"
want_grep "package.dawn floors the compiler" "$sandbox/mapp/package.dawn" "@dusk 1.14"
want_file "init writes the root file" "$sandbox/mapp/mapp.dusk"
want_file "init writes cmd/root.dusk" "$sandbox/mapp/cmd/root.dusk"
want_grep ".gitignore ignores dawn_modules" "$sandbox/mapp/.gitignore" "dawn_modules/"
want_file "dawn get wrote the lock" "$sandbox/mapp/dawn.lock"
want_dir  "dawn get fetched nova" "$sandbox/mapp/dawn_modules/nova"
want_file "the checkout holds the library" "$sandbox/mapp/dawn_modules/nova/nova/command.dusk"
want_no_path "manifest mode vendors nothing" "$sandbox/mapp/nova"
want_no_path "manifest mode links nothing under cmd" "$sandbox/mapp/cmd/nova"

attempt "$novacli" add serve --dir mapp
want_code "add serve (manifest mode)" 0
attempt "$novacli" add config --dir mapp
want_code "add config (manifest mode)" 0
attempt "$novacli" add set --parent config --dir mapp
want_code "add set --parent config (manifest mode)" 0
want_grep "add set wires into the config file" "$sandbox/mapp/cmd/config_cmd.dusk" "c.addCommand(setCmd())"
want_no_path "add links nothing under cmd" "$sandbox/mapp/cmd/nova"

attempt_sh "cd $(printf %q "$sandbox/mapp") && dawn run serve"
want_code "dawn run serve" 0
want_out  "dawn run reaches the added command" "serve called"

attempt_sh "cd $(printf %q "$sandbox/mapp") && dusk build mapp.dusk && ./target/dusk-out/mapp config set a b"
want_code "dusk build mapp.dusk, then a nested command" 0
want_out  "the built binary runs the nested command" "set called"

# --no-fetch writes the same project and leaves the fetching to the user, so nothing is
# warned about and nothing lands under dawn_modules until dawn get runs.

attempt "$novacli" init nofetch --dir nofetch --source "file://$srcrepo" --ref main --no-fetch
want_code "init --no-fetch" 0
want_no_err "init --no-fetch warns about nothing" "warning"
want_file "init --no-fetch still writes package.dawn" "$sandbox/nofetch/package.dawn"
want_no_path "init --no-fetch fetches nothing" "$sandbox/nofetch/dawn_modules"
want_no_path "init --no-fetch locks nothing" "$sandbox/nofetch/dawn.lock"

attempt_sh "cd $(printf %q "$sandbox/nofetch") && dawn get && dawn build"
want_code "dawn get then dawn build after --no-fetch" 0
want_dir  "dawn get fetched nova into the --no-fetch project" "$sandbox/nofetch/dawn_modules/nova"

# ---------------------------------------------------------------- init, vendored

attempt "$novacli" init myapp --dir myapp --vendor
want_code "init myapp" 0
want_out  "init reports the root file" "created  myapp/myapp.dusk"
want_file "init writes the root file" "$sandbox/myapp/myapp.dusk"
want_file "init writes cmd/root.dusk" "$sandbox/myapp/cmd/root.dusk"
want_file "init vendors the library" "$sandbox/myapp/nova/command.dusk"
want_symlink "init links cmd/nova" "$sandbox/myapp/cmd/nova"
want_file "init writes .gitignore" "$sandbox/myapp/.gitignore"

# ---------------------------------------------------------------- add

attempt "$novacli" add serve --dir myapp
want_code "add serve" 0
want_file "add serve writes cmd/serve_cmd.dusk" "$sandbox/myapp/cmd/serve_cmd.dusk"
want_grep "add serve wires the import" "$sandbox/myapp/cmd/root.dusk" "@import serve_cmd"
want_grep "add serve wires addCommand" "$sandbox/myapp/cmd/root.dusk" "c.addCommand(serveCmd())"

attempt "$novacli" add serve --dir myapp
want_code "add serve again is a no-op" 0
if [ "$(grep -cF 'c.addCommand(serveCmd())' "$sandbox/myapp/cmd/root.dusk")" = "1" ]; then
    ok "add serve again does not duplicate the wiring"
else
    bad "add serve again duplicated the wiring"
fi

attempt "$novacli" add config --dir myapp
want_code "add config" 0
want_file "add config writes cmd/config_cmd.dusk" "$sandbox/myapp/cmd/config_cmd.dusk"

attempt "$novacli" add set --parent config --dir myapp
want_code "add set --parent config" 0
want_file "add set writes cmd/set_cmd.dusk" "$sandbox/myapp/cmd/set_cmd.dusk"
want_grep "add set wires into the config file" "$sandbox/myapp/cmd/config_cmd.dusk" "c.addCommand(setCmd())"
want_grep "add set imports set_cmd" "$sandbox/myapp/cmd/config_cmd.dusk" "@import set_cmd"

attempt "$novacli" add c --dir myapp
want_code "add c (a name that would shadow every receiver)" 0
want_file "add c writes cmd/c_cmd.dusk" "$sandbox/myapp/cmd/c_cmd.dusk"
want_grep "add c imports c_cmd, not c" "$sandbox/myapp/cmd/root.dusk" "@import c_cmd"
want_no_path "add c writes no cmd/c.dusk" "$sandbox/myapp/cmd/c.dusk"

attempt "$novacli" add my-cmd --dir myapp
want_code "add my-cmd" 0
want_file "add my-cmd writes cmd/my_cmd_cmd.dusk" "$sandbox/myapp/cmd/my_cmd_cmd.dusk"
want_grep "add my-cmd keeps the dashed command name" "$sandbox/myapp/cmd/my_cmd_cmd.dusk" 'cmdNew("my-cmd"'

# ---------------------------------------------------------------- refusals

attempt "$novacli" init myapp --dir myapp --vendor
want_code "init re-run with the same name" 0
want_out  "init re-run skips the root file" "exists, skipping"

attempt "$novacli" init other --dir myapp --vendor
want_code "init re-run with a different name is refused" 1
want_err  "init re-run names the existing root" "already holds an application root (myapp.dusk); nothing created for other"
want_no_path "init re-run writes no second root" "$sandbox/myapp/other.dusk"

attempt "$novacli" add root --dir myapp
want_code "add root is refused" 1
want_err  "add root explains itself" "Error: cannot add a command to itself"
want_no_path "add root writes nothing" "$sandbox/myapp/cmd/root_cmd.dusk"

attempt "$novacli" add config --parent config --dir myapp
want_code "add config --parent config is refused" 1
want_err  "add config --parent config explains itself" "Error: cannot add a command to itself"

attempt "$novacli" add 'bad"name' --dir myapp
want_code "add with a quote in the name is refused" 1
want_err  "add with a quote names the bad name" 'Error: invalid command name "bad"name"'
attempt "$novacli" add '9lives' --dir myapp
want_code "add with a leading digit is refused" 1
attempt "$novacli" add 'two words' --dir myapp
want_code "add with whitespace is refused" 1

# ---------------------------------------------------------------- wiring fallback

mkdir -p "$sandbox/warnapp/cmd"
cat > "$sandbox/warnapp/cmd/root.dusk" <<'EOF'
@paradigm procedural

@import nova.command

export func notTheAnchor() -> *Command {
    c: *Command = cmdNew("warnapp", "no anchor here")
    return c
}
EOF
attempt "$novacli" add serve --dir warnapp
want_code "add into a parent with no anchors exits 2" 2
want_err  "the fallback warns on stderr" "warning:"
want_err  "the fallback names the two lines" "add '@import serve_cmd' and 'c.addCommand(serveCmd())'"
want_file "the fallback still writes the file" "$sandbox/warnapp/cmd/serve_cmd.dusk"

# ---------------------------------------------------------------- anchor, helpers first
#
# examples/todo/cmd/config.dusk declares two private Cmd() -> *Command helpers before the
# exported one. Anchoring on the first of those lines would splice the child into
# configSetCmd instead, which is finding 2.

attempt "$novacli" init anchorapp --dir anchorapp --vendor
want_code "init anchorapp" 0
attempt "$novacli" add config --dir anchorapp
want_code "add config to anchorapp" 0
cp "$root/examples/todo/cmd/config.dusk" "$sandbox/anchorapp/cmd/config_cmd.dusk"
attempt "$novacli" add show --parent config --dir anchorapp
want_code "add show into a hand written parent" 0
want_grep "add show wires into the parent" "$sandbox/anchorapp/cmd/config_cmd.dusk" "c.addCommand(showCmd())"
anchor_line="$(grep -n 'export func configCmd() -> \*Command' "$sandbox/anchorapp/cmd/config_cmd.dusk" | head -1 | cut -d: -f1)"
child_line="$(grep -n 'c.addCommand(showCmd())' "$sandbox/anchorapp/cmd/config_cmd.dusk" | head -1 | cut -d: -f1)"
if [ -n "$anchor_line" ] && [ -n "$child_line" ] && [ "$child_line" -gt "$anchor_line" ]; then
    ok "add show lands inside configCmd, not inside the first helper"
else
    bad "add show landed at line ${child_line:-?}, anchor is at line ${anchor_line:-?}"
fi

# ---------------------------------------------------------------- build and run the app

if (cd "$sandbox/myapp" && dusk build myapp.dusk >"$sandbox/.appbuild" 2>&1); then
    ok "dusk build myapp.dusk"
else
    bad "dusk build myapp.dusk" "$(cat "$sandbox/.appbuild")"
fi
app="$sandbox/myapp/target/dusk-out/myapp"

if [ -x "$app" ]; then
    attempt "$app" config set a b
    want_code "myapp config set a b" 0
    want_out  "myapp config set a b runs the nested command" "set called"

    attempt "$app" c
    want_code "myapp c" 0
    want_out  "myapp c runs" "c called"

    attempt "$app" my-cmd
    want_code "myapp my-cmd" 0
    want_out  "myapp my-cmd runs" "my-cmd called"

    attempt "$app" --help
    want_code "myapp --help" 0
    want_out  "myapp --help lists serve" "serve"
    want_out  "myapp --help lists config" "config"
    want_out  "myapp --help lists c" "c "
    want_out  "myapp --help lists my-cmd" "my-cmd"
else
    bad "myapp binary was never produced"
fi

if (cd "$sandbox/anchorapp" && dusk build anchorapp.dusk >"$sandbox/.anchorbuild" 2>&1); then
    ok "dusk build anchorapp.dusk"
    attempt "$sandbox/anchorapp/target/dusk-out/anchorapp" config show
    want_code "anchorapp config show" 0
    want_out  "anchorapp config show runs the added child" "show called"
    attempt "$sandbox/anchorapp/target/dusk-out/anchorapp" config set k v
    want_code "anchorapp config set k v" 0
    want_out  "anchorapp keeps the hand written children" "set k = v"
else
    bad "dusk build anchorapp.dusk" "$(cat "$sandbox/.anchorbuild")"
fi

# ---------------------------------------------------------------- --link

attempt_sh "NOVA_HOME=$(printf %q "$root") $(printf %q "$novacli") init linkapp --dir linkapp --link"
want_code "init --link with a good NOVA_HOME" 0
want_symlink "--link links nova/" "$sandbox/linkapp/nova"
if [ "$(readlink "$sandbox/linkapp/nova")" = "$root/nova" ]; then
    ok "--link links to an absolute NOVA_HOME/nova"
else
    bad "--link linked to '$(readlink "$sandbox/linkapp/nova")', want '$root/nova'"
fi
if (cd "$sandbox/linkapp" && dusk build linkapp.dusk >"$sandbox/.linkbuild" 2>&1); then
    ok "dusk build linkapp.dusk through the symlink"
else
    bad "dusk build linkapp.dusk" "$(cat "$sandbox/.linkbuild")"
fi

# ---------------------------------------------------------------- library discovery
#
# No NOVA_HOME, argv[0] with no directory in it, and a cwd nowhere near the repository, so
# only /proc can say where the binary lives, which is finding 8.

mkdir -p "$sandbox/onpath"
ln -sf "$novacli" "$sandbox/onpath/nova-cli"
attempt_sh "env -u NOVA_HOME PATH=$(printf %q "$sandbox/onpath"):\$PATH nova-cli init probe --dir probe --vendor"
want_code "init with no NOVA_HOME finds the library through /proc" 0
want_file "init vendored the library it found through /proc" "$sandbox/probe/nova/command.dusk"

attempt_sh "NOVA_HOME=/nonexistent $(printf %q "$novacli") init z --dir z --link"
want_code "init --link with a bad NOVA_HOME fails" 1
want_err  "the bad NOVA_HOME is reported" "no such directory: /nonexistent/nova"
want_err  "the failure hints at NOVA_HOME" "set NOVA_HOME"
want_no_path "no dangling link is left behind" "$sandbox/z/nova"

# ---------------------------------------------------------------- tally

total=$((passes + failures))
if [ "$failures" -eq 0 ]; then
    printf '%sall %d checks passed%s\n' "$green" "$total" "$off"
    exit 0
fi
printf '%s%d of %d checks failed%s\n' "$red" "$failures" "$total" "$off"
exit 1
