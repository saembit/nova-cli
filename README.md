# nova

[img](path)

A Cobra style command line framework for dusk

# TOC

- [About](#about)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands and flags](#commands-and-flags)
- [Help output](#help-output)
- [Generator](#generator)
- [Shell completion](#shell-completion)
- [Tests](#tests)
- [Status](#status)

# About

nova is a command line framework I wrote for dusk because every dusk program I started ended up hand rolling the same argument loop, the same misspelled flag error, and the same help text that never quite lined up. It works the way Cobra does in Go: you build a tree of commands, hang flags and positional argument rules and hooks off each one, and nova does the traversal, the parsing, the error messages, the help rendering and the exit codes, so a handler only ever sees a Context and returns an int32. It ships with nova-cli, a generator in the shape of cobra-cli that scaffolds a whole dawn project and adds subcommands to it, so you don't have to type the boilerplate either.

# Install

nova needs dusk 1.14 or newer, since that's where the package manifest landed. It's a dawn package and a release is a git tag, so pulling it into a project is one command.

```console
$ mkdir myapp && cd myapp
$ dawn init myapp
$ dawn add nova github.com/saembit/nova-cli v0.1.1
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

Handlers have to be named top level functions or capture free lambdas, since a lambda that captured a local couldn't escape the frame that built the tree. Flags come in three kinds and live either on the command or on all of its descendants.

```dusk
c.localFlags().addStr("name", "n", "world", "who to greet")
c.localFlags().addBool("shout", "s", false, "shout the greeting")
c.localFlags().addInt("times", "t", 1, "how many times to greet")
c.localFlags().markRequired("name")
c.localFlags().markHidden("internal")
c.localFlags().markDeprecated("old", "use --new")

c.persistentFlags().addBool("verbose", "v", false, "verbose output")
```

Persistent flags are inherited by every descendant and can be given on either side of the subcommand, so todo -v list and todo list -v are the same, and the parser accepts --name value, --name=value, -n value, -nvalue, grouped bool shorthands where -st 3 is -s -t 3, and -- to end flag parsing. Inside a handler the Context is the only thing you need.

```dusk
func runServe(ctx: *Context) -> int32 {
    n: int64 = ctx.nargs()
    first: string = ctx.arg(0)
    port: int64 = ctx.getInt("port")     // searches local, then inherited
    loud: bool = ctx.getBool("verbose")
    who: string = ctx.getStr("name")
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
```

add takes --parent, -p (default root) and --dir, -d, and writes cmd/<name>_cmd.dusk exporting <name>Cmd(), then inserts the @import line and the c.addCommand(<name>Cmd()) call into the parent's constructor just before its return c. Names have to match [A-Za-z][A-Za-z0-9_-]* and anything else is refused, which is what keeps a quote or a backslash out of the generated string literals, and adding a command to itself is refused too. If the anchors aren't in the parent file the command file is still written, the two lines you have to paste are printed as warnings, and add exits 2 so a script notices. One thing to watch is that the first segment of every @import becomes a global qualifier in dusk, so a module named c or ctx would break every c.addCommand and ctx.getBool in the program, which is why the generator suffixes every module with _cmd.

# Shell completion

Any root command with subcommands gets a builtin completion command beside help, and the script it prints is static, meaning nova walks the tree at generation time and bakes it in as shell case statements, so completing a word never runs your program and the script has to be regenerated when the commands or flags change. Only bash and zsh are supported, anything else is an error, and root.setDisableCompletionCmd(true) suppresses the builtin, as does adding a completion child of your own.

```console
$ source <(todo completion bash)
$ todo completion zsh > "${fpath[1]}/_todo"
```

# Tests

tests/run.sh builds every example and replays every case under tests/cases/, where a case is a directory holding cmd with the app name and its arguments, the exact expected stdout, an optional stderr and an optional code, and failures print a unified diff. tests/gen.sh is the generator's own end to end test, it packages the working tree into a git repository inside a sandbox, has init require it over file://, then builds and runs the fetched project with dawn run, dawn build and dusk build, checks every refusal and the unwired warning fallback, and covers --vendor after that.

```console
$ tests/run.sh                    # everything
$ tests/run.sh todo-config        # only cases whose name contains this
$ tests/run.sh --update           # record expected files that are missing
$ tests/gen.sh                    # build nova-cli, then the whole scenario
$ tests/gen.sh --no-build --keep  # reuse the binary, leave the sandbox behind
```

# Status

There's a fair amount that isn't done. The command tree lives for the whole process and novaFreeTree in nova/freetree.dusk frees it at the end of main if you want it gone, it frees every command, their vectors and both flag sets but not the strings since those are your literals or argv, the library needs dusk 1.14 or newer since it leans on the package manifest as well as @paradigm oop plus procedural, self referencing vectors, function typed struct fields, etc. and dawn has no version ranges, so a reference is one tag, branch or commit and a diamond in the dependency graph is something you pin yourself. init --vendor and init --link still write the pre 1.14 shape for a tree that has to build with no dawn at all, they find the library through NOVA_HOME or by walking up from the running binary. The examples in this repository are the odd ones out, they use symlinks to reach nova because they sit inside the nova-cli package itself and a package can't require itself. Completion is static and covers bash and zsh only, error messages follow Cobra 1.x but print the help hint instead of a full usage dump, and library misuse such as a duplicate flag, a duplicate command name, a getter for a flag that doesn't exist, etc. aborts with fatal: nova: <msg> on stderr rather than handing you an error to deal with.

It may not be perfect but it's better than nothing.
