# nova

[img](path)

A Cobra style command line framework for dusk

# TOC

- [About](#about)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands and flags](#commands-and-flags)
- [Flag groups](#flag-groups)
- [Help output](#help-output)
- [Output and errors](#output-and-errors)
- [Env and config](#env-and-config)
- [Generator](#generator)
- [Shell completion](#shell-completion)
- [Docs](#docs)
- [Tests](#tests)
- [Status](#status)

# About

nova is a command line framework I wrote for dusk because every dusk program I started ended up hand rolling the same argument loop, the same misspelled flag error, and the same help text that never quite lined up. It works the way Cobra does in Go: you build a tree of commands, hang flags and positional argument rules and hooks off each one, and nova does the traversal, the parsing, the error messages, the help rendering and the exit codes, so a handler only ever sees a Context and returns an int32. It ships with nova-cli, a generator in the shape of cobra-cli that scaffolds a whole dawn project and adds subcommands to it, so you don't have to type the boilerplate either.

# Install

nova needs dusk 1.14 or newer, since that's where the package manifest landed. It's a dawn package and a release is a git tag, so pulling it into a project is one command.

```console
$ mkdir myapp && cd myapp
$ dawn init myapp
$ dawn add nova github.com/saembit/nova-cli v0.3.0
```

dawn add fetches the package into dawn_modules/nova, records the commit in dawn.lock, and writes the @require line into package.dawn, and after that every file in the project just writes @import nova.command and builds offline, cmd/serve_cmd.dusk included, since alias resolution is manifest wide and the compiler never touches the network. For the generator itself, clone this repository and build the binary, which lands in target/dusk-out/nova-cli.

```console
$ git clone https://github.com/saembit/nova-cli
$ cd nova-cli
$ dusk build nova-cli.dusk
```

# Quick start

examples/hello/hello.dusk is a whole one command application.

```dusk
@paradigm procedural

@import nova.command
@import nova.context
@import nova.flagset
@import nova.args
@import nova.exec

func runHello(ctx: *Context) -> int32 {
    greeting: string = "Hello, " + ctx.getStr("name") + "!"
    mut k: int64 = 0
    while k < ctx.getInt("times") {
        println(greeting)
        k = k + 1
    }
    return 0
}

func helloCmd() -> *Command {
    c: *Command = cmdNew("hello", "Print a friendly greeting")
    c.setArgs(argsAny())
    c.setRun(runHello)
    c.localFlags().addStr("name", "n", "world", "who to greet")
    c.localFlags().addInt("times", "t", 1, "how many times to greet")
    return c
}

func main(argc: int32, argv: string[]) -> int32 {
    return novaExecute(helloCmd(), argv)
}
```

dusk build writes target/dusk-out/hello relative to whatever directory you're in, so build it from its own.

```console
$ cd examples/hello
$ dusk build hello.dusk
$ ./target/dusk-out/hello -t 2 --name sam
Hello, sam!
Hello, sam!
```

# Commands and flags

cmdNew takes the use string and a short description, the name is the first word of it, and everything else is a setter on the command.

```dusk
c: *Command = cmdNew("serve", "Start the server")
c.setLong("A longer description shown by --help.")
c.setExample("  app serve --port 9000")
c.setVersion("1.2.3")            // root only, enables --version
c.setArgs(argsExact(1))          // argsAny, argsNone, argsExact, argsMin, argsMax, argsRange
c.addAlias("s")
c.setHidden(true)
c.setDeprecated("use \"serve\" instead")
c.setRun(runServe)
c.setPreRun(...)  c.setPostRun(...)
c.setPersistentPreRun(...)  c.setPersistentPostRun(...)
c.setDisableFlagParsing(true)
c.setSilenceUsage(true)
c.addCommand(child)
```

Handlers have to be named top level functions or capture free lambdas, since a lambda that captured a local couldn't escape the frame that built the tree. Flags come in seven kinds and live either on the command or on all of its descendants.

```dusk
c.localFlags().addStr("name", "n", "world", "who to greet")
c.localFlags().addBool("shout", "s", false, "shout the greeting")
c.localFlags().addInt("times", "t", 1, "how many times to greet")
c.localFlags().addFloat("rate", "r", 1.5, "rate to apply")
c.localFlags().addStrs("tag", "g", "a,b", "tags to attach")          // default is comma separated, "" for none
c.localFlags().addChoice("emit", "e", "llvm", "llvm,obj", "what to emit")
c.localFlags().markRequired("name")
c.localFlags().markHidden("internal")
c.localFlags().markDeprecated("old", "use --new")

c.persistentFlags().addBool("verbose", "v", false, "verbose output")
c.persistentFlags().addCount("loud", "l", "loudness, repeatable")
```

Persistent flags are inherited by every descendant and can be given on either side of the subcommand, so todo -v list and todo list -v are the same, and the parser accepts --name value, --name=value, -n value, -nvalue, grouped bool shorthands where -st 3 is -s -t 3, and -- to end flag parsing. A strs flag splits every value on commas with no quoting and appends across repeats, so --tag a --tag b,c is a, b, c and the first value on the line replaces the default, a count flag takes no value and adds one per occurrence, so -lll is 3 and --loud=5 sets it outright, a float parses whatever parse_float takes, and a choice flag refuses anything outside its list with invalid argument "x" for "--emit" flag: must be one of "llvm", "obj". Inside a handler the Context is the only thing you need.

```dusk
func runServe(ctx: *Context) -> int32 {
    n: int64 = ctx.nargs()
    first: string = ctx.arg(0)
    port: int64 = ctx.getInt("port")     // searches local, then inherited
    loud: bool = ctx.getBool("verbose")
    who: string = ctx.getStr("name")     // a choice flag reads through getStr too
    rate: float64 = ctx.getFloat("rate")
    tags: *Vector<string> = ctx.getStrs("tag")   // borrowed, don't free it
    level: int64 = ctx.getCount("loud")
    if ctx.changed("port") { ... }
    if n == 0 {
        return ctx.fail("nothing to serve")  // Error line plus usage hint, returns 1
    }
    println(ctx.commandPath())           // "app serve"
    return 0
}
```

novaExecute is the entry point, it walks argv past the program name, descends into subcommands, parses flags, handles -h, --help, help and --version, warns about deprecated commands and flags, checks the required flags and the positional argument rule, then runs persistentPreRun, preRun, run, postRun and persistentPostRun in that order, where the first non zero return stops the chain and becomes the exit status.

```dusk
func main(argc: int32, argv: string[]) -> int32 {
    return novaExecute(rootCmd(), argv)
}
```

Errors print two lines to stderr and exit 1.

```console
$ hello --bogus
Error: unknown flag: --bogus
Run 'hello --help' for usage.
```

# Flag groups

A command can tie some of its flags together the way Cobra does, each mark takes a comma separated list of names that have to be declared on that command already, local or persistent, and the rules are checked after the required flags and before the positional arguments.

```dusk
c.markFlagsRequiredTogether("user,pass")
c.markFlagsOneRequired("json,yaml")
c.markFlagsMutuallyExclusive("json,yaml")
```

A flag counts as set when it was given on the line, the messages are Cobra's own, and a group belongs to the command that declared it, so a child that inherits the flags doesn't inherit the rule.

```console
$ groups login --user ann
Error: if any flags in the group [user pass] are set they must all be set; missing [pass]
Run 'groups login --help' for usage.
```

# Help output

```console
$ hello --help
hello prints a friendly greeting.

The greeting is repeated --times times, and any positional arguments
are joined with spaces and used instead of --name.

Usage:
  hello [flags]

Flags:
  -h, --help          help for hello
  -n, --name string   who to greet (default "world")
  -s, --shout         shout the greeting
  -t, --times int     how many times to greet (default 1)
```

The type word after a flag is string, int, float or strings, nothing for a bool or a count, and the choices joined with | for a choice flag, and the default shows when it isn't the zero value, so (default 1.5) or (default [a,b]). Nothing is wrapped unless you ask, c.setWrapWidth(60) on the root or on one command wraps its descriptions and flag help at that column with the continuation lines indented under the description column.

# Output and errors

Everything nova prints goes through two sinks, out for help, the version line and completion scripts, err for error lines, usage hints and deprecation warnings, and both default to stdout and stderr. A command can point either one somewhere else and every descendant follows it, which is how the sinks example catches its own output in a test.

```dusk
@import nova.sink

outbuf: *StringBuilder = alloc(sb_new())
root.setOut(Sink.Buffer(outbuf))     // Sink.Stdout, Sink.Stderr, Sink.Fd(2), Sink.Func(myWriter), Sink.Buffer(sb)
root.setErr(Sink.Stderr)
```

Inside a handler ctx.print, ctx.println, ctx.eprint and ctx.eprintln write to the same sinks, and ctx.printHelp and ctx.printUsage go through whatever help and usage functions are set, c.setHelpFunc(f) and c.setUsageFunc(f) taking a (*Context) -> void that replaces the Cobra layout for that command and its descendants.

A handler can return an error instead of an exit code. Every hook has an E twin, setRunE, setPreRunE, setPostRunE, setPersistentPreRunE and setPersistentPostRunE, each taking a (*Context) -> error, setting one clears the int32 form of the same hook, and an error coming back ends the chain, prints Error: <msg> and the usage hint under the usual silence flags and exits 1.

```dusk
func runCheck(ctx: *Context) -> error {
    if ctx.arg(0) == "bad" {
        return error { message: "cannot check \"bad\"" }
    }
    return error {}
}

c.setRunE(runCheck)
```

novaExecuteE hands the error back along with the code, already reported, so main can decide what to do with it, and novaExecute is the same call with the error dropped.

```dusk
code, e := novaExecuteE(rootCmd(), argv)
if e.exists() {
    // the flag, argument, group or handler error, already printed per the silence flags
}
return code
```

# Env and config

A flag can take its value from the environment or from a JSON file when the line didn't give one, and the order is always the line, then the environment, then the file, then the default. c.setEnvPrefix("APP") on the root binds every flag under it to APP_NAME, the long name upper cased with dashes turned into underscores, fs.bindEnv("label", "LABEL") binds one flag to one variable outright, and an empty variable counts as unset since dusk can't tell the two apart.

```dusk
root.setEnvPrefix("NOVA")                 // --port reads NOVA_PORT, --db-host reads NOVA_DB_HOST
root.setConfigFile("nova-config.json")    // the default path, missing is silent
root.setConfigFlag("config")              // a string flag naming the file, then missing is an error
c.localFlags().bindEnv("label", "LABEL")
```

The file is a flat object keyed by flag name, with an optional section keyed by a command name that wins for that command, unknown keys are ignored, a string is accepted anywhere and parsed like a value on the line, a number has to be integral for an int, and an array of strings feeds a strs flag.

```json
{ "verbose": true, "serve": { "port": 9000, "tags": ["a", "b"] } }
```

A wrong shape is Error: config <path>: invalid value for "--port": expected an integer, bad JSON is Error: config <path>: <reason>, and the check runs right after parsing, before the required flags, so an env or config value satisfies a required flag and counts inside a flag group while ctx.changed stays true only for the line. ctx.source("port") says where a value came from and flagSourceWord turns it into default, config, env or flag.

```console
$ NOVA_NAME=fromenv config show --config examples/config/good.json --port=1234
name=fromenv (env)
port=1234 (flag)
rate=2.5 (config)
label=none (default)
```

# Generator

nova-cli init scaffolds a dawn project and nova-cli add writes a subcommand into it and wires it into its parent.

```console
$ nova-cli init myapp --dir myapp
$ cd myapp
$ nova-cli add serve
$ nova-cli add config
$ nova-cli add set --parent config
$ dawn run config set a b
```

init writes package.dawn holding @package, @version, @dusk 1.14, @root and the @require line for nova, the root program <name>.dusk calling novaExecute(rootCmd(), argv), cmd/root.dusk holding rootCmd() with one persistent --verbose flag, and a .gitignore for target/ and dawn_modules/, then runs dawn get in the new directory to write dawn.lock and dawn_modules/nova. Existing files are never overwritten, and a dawn get that fails, no dawn on PATH, no network, a bad ref, etc. is only a warning line on stderr and exit 0, since every generated file is already correct and the fetch is one command away. Its flags:

```text
--dir, -d       directory to scaffold into (default .)
--source, -s    repository to require nova from (default github.com/saembit/nova-cli)
--ref, -r       tag, branch or commit to pin it at (default v plus the library version)
--no-fetch      write the manifest, skip dawn get
--vendor        copy the library into <dir>/nova and link cmd/nova, no @require line
--link          the same, symlinking the library instead of copying it
--license, -l   mit, apache2, bsd3 or none, writes LICENSE with this year and the holder
--author, -a    the holder, defaults to git config user.name, then "the author"
--docs          wire nova's hidden docs command into the root
```

add takes --parent, -p (default root), --dir, -d and --flags, -f, and writes cmd/<name>_cmd.dusk exporting <name>Cmd(), then inserts the @import line and the c.addCommand(<name>Cmd()) call into the parent's constructor just before its return c. The flags spec is a comma separated list of name[/s]:kind[=default] where the kind is bool, string, int, float, strs, count or choice[a|b|c], so --flags "port/p:int=8080,host:string=localhost,tag:strs=a|b,emit:choice[llvm|obj]=llvm" declares four flags and the generated handler reads each one back and prints it, a bad spec is refused with exit 2 and invalid flag spec "x": <why> before anything is written. Names have to match [A-Za-z][A-Za-z0-9_-]* and anything else is refused, which is what keeps a quote or a backslash out of the generated string literals, and adding a command to itself is refused too. If the anchors aren't in the parent file the command file is still written, the two lines you have to paste are printed as warnings, and add exits 2 so a script notices. One thing to watch is that the first segment of every @import becomes a global qualifier in dusk, so a module named c or ctx would break every c.addCommand and ctx.getBool in the program, which is why the generator suffixes every module with _cmd.

# Shell completion

Any root command with subcommands gets a builtin completion command beside help, and the script it prints is dynamic the way Cobra's is, meaning it calls back into your program through a hidden __complete command every time the shell wants candidates, so nothing is baked in and the script never goes stale. bash, zsh and fish are supported, anything else is an error, --no-descriptions drops the descriptions, and root.setDisableCompletionCmd(true) suppresses the builtin along with the hidden commands, as does adding a completion child of your own.

```console
$ source <(todo completion bash)
$ todo completion zsh > "${fpath[1]}/_todo"
$ todo completion fish > ~/.config/fish/completions/todo.fish
```

Out of the box the shell gets subcommands and aliases with their short descriptions, validArgs, every flag the command can take with its help text, and the list of a choice flag, and two hooks cover the rest, c.setValidArgsFunc(f) for positionals and c.registerFlagCompletionFunc("tag", f) for one flag's value, both taking a (*Context, string) -> (*Vector<string>, int64) that gets the words parsed so far and the word being completed and gives back candidates, name plus a tab plus a description if you want one, and a directive which is compDefault, compNoFileComp, compNoSpace or compError added together. nova frees the vector, the strings inside are yours.

```dusk
func completeDoneIds(ctx: *Context, toComplete: string) -> (*Vector<string>, int64) {
    out: *Vector<string> = alloc(vec_new())
    vec_push(out, "1\tbuy milk")
    vec_push(out, "2\twrite nova")
    return (out, compNoFileComp())
}

c.setValidArgsFunc(completeDoneIds)
```

You can ask the program yourself, which is what the goldens do, the last line is the directive.

```console
$ todo __complete ""
add	Add a todo item
config	Manage configuration
done	Mark a todo item done
list	List todo items
:4
```

# Docs

nova/doc.dusk renders a command as markdown in the shape Cobra's doc package uses, the path as a heading, the short and long descriptions, the use line, the examples, the flag blocks exactly as help prints them and a SEE ALSO list linking the parent and the children, docWriteTree(root, dir) writes one page per visible command named after its path with spaces as underscores, and docCommandNew() is a hidden docs [dir] command you can add to a root so the program documents itself.

```dusk
@import nova.doc

c.addCommand(docCommandNew())
```

```console
$ myapp docs site/
$ ls site/
myapp.md  myapp_serve.md  myapp_config.md  myapp_config_set.md
```

# Tests

tests/run.sh builds every example and replays every case under tests/cases/, where a case is a directory holding cmd with the app name and its arguments, optionally led by VAR=value assignments for the environment, the exact expected stdout, an optional stderr and an optional code, and failures print a unified diff. It also runs bash -n over every recorded completion script, zsh -n when zsh is around, and tests/complete.sh, which sources the generated bash script and drives it with COMP_WORDS set to prove the candidates come back through the real program. tests/gen.sh is the generator's own end to end test, it packages the working tree into a git repository inside a sandbox, has init require it over file://, then builds and runs the fetched project with dawn run, dawn build and dusk build, checks every refusal and the unwired warning fallback, and covers --vendor after that.

```console
$ tests/run.sh                    # everything
$ tests/run.sh todo-config        # only cases whose name contains this
$ tests/run.sh --update           # record expected files that are missing
$ tests/gen.sh                    # build nova-cli, then the whole scenario
$ tests/gen.sh --no-build --keep  # reuse the binary, leave the sandbox behind
```

# Status

There's a fair amount that isn't done. The command tree lives for the whole process and novaFreeTree in nova/freetree.dusk frees it at the end of main if you want it gone, a novaExecute call itself gives back every block it took so a long running program can run the tree as often as it likes, it frees every command, their vectors, groups and both flag sets along with the strings a strs or choice flag split for itself, but not the strings you handed in since those are your literals or argv, the library needs dusk 1.14 or newer since it leans on the package manifest as well as @paradigm oop plus procedural, self referencing vectors, function typed struct fields, etc. and dawn has no version ranges, so a reference is one tag, branch or commit and a diamond in the dependency graph is something you pin yourself. init --vendor and init --link still write the pre 1.14 shape for a tree that has to build with no dawn at all, they find the library through NOVA_HOME or by walking up from the running binary. The examples in this repository are the odd ones out, they use symlinks to reach nova because they sit inside the nova-cli package itself and a package can't require itself. Completion covers bash, zsh and fish and only the bash script is exercised by a test since the other two shells aren't on my machine, error messages follow Cobra 1.x but print the help hint instead of a full usage dump, and library misuse such as a duplicate flag, a duplicate command name, a getter for a flag that doesn't exist, etc. aborts with fatal: nova: <msg> on stderr rather than handing you an error to deal with.

It may not be perfect but it's better than nothing.
