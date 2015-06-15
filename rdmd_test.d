/*
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module rdmd_test;

/**
    RDMD Test-suite.

    Authors: Andrej Mitrovic

    Notes:
    Use the --compiler switch to specify a custom compiler to build RDMD and run the tests with.
    Use the --rdmd switch to specify the path to RDMD.
*/

import core.thread;
import std.algorithm;
import std.datetime;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.string;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
}
else version (Windows)
{
    enum objExt = ".obj";
    enum binExt = ".exe";
}
else
{
    static assert(0, "Unsupported operating system.");
}

string rdmdApp; // path/to/rdmd.exe (once built)
string compiler = "dmd";  // e.g. dmd/gdmd/ldmd

void main(string[] args)
{
    string rdmd = "rdmd.d";
    bool concurrencyTest;
    getopt(args,
        "compiler", &compiler,
        "rdmd", &rdmd,
        "concurrency", &concurrencyTest,
    );

    enforce(rdmd.exists, "Path to rdmd does not exist: %s".format(rdmd));

    mkdir(tempDir());
    scope (exit) rmdirRecurse(tempDir());

    rdmdApp = tempDir().buildPath("rdmd_app_") ~ binExt;
    if (rdmdApp.exists) std.file.remove(rdmdApp);

    auto res = execute([compiler, "-of" ~ rdmdApp, rdmd]);

    enforce(res.status == 0, res.output);
    enforce(rdmdApp.exists);

    runTests();
    if (concurrencyTest)
        runConcurrencyTest();
}

@property string compilerSwitch() { return "--compiler=" ~ compiler; }

void runTests()
{
    /* Test help string output when no arguments passed. */
    auto res = execute([rdmdApp]);
    assert(res.status == 1, res.output);
    assert(res.output.canFind("Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]..."));

    /* Test --help. */
    res = execute([rdmdApp, "--help"]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]..."));

    /* Test --force. */
    string forceSrc = tempDir().buildPath("force_src_.d");
    std.file.write(forceSrc, `void main() { pragma(msg, "compile_force_src"); }`);

    res = execute([rdmdApp, compilerSwitch, forceSrc]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("compile_force_src"));

    res = execute([rdmdApp, compilerSwitch, forceSrc]);
    assert(res.status == 0, res.output);
    assert(!res.output.canFind("compile_force_src"));  // second call will not re-compile

    res = execute([rdmdApp, compilerSwitch, "--force", forceSrc]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("compile_force_src"));  // force will re-compile

    /* Test --build-only. */
    string failRuntime = tempDir().buildPath("fail_runtime_.d");
    std.file.write(failRuntime, "void main() { assert(0); }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--build-only", failRuntime]);
    assert(res.status == 0, res.output);  // only built, assert(0) not called.

    res = execute([rdmdApp, compilerSwitch, "--force", failRuntime]);
    assert(res.status == 1, res.output);  // assert(0) called, rdmd execution failed.

    string failComptime = tempDir().buildPath("fail_comptime_.d");
    std.file.write(failComptime, "void main() { static assert(0); }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--build-only", failComptime]);
    assert(res.status == 1, res.output);  // building will fail for static assert(0).

    res = execute([rdmdApp, compilerSwitch, "--force", failComptime]);
    assert(res.status == 1, res.output);  // ditto.

    /* Test --chatty. */
    string voidMain = tempDir().buildPath("void_main_.d");
    std.file.write(voidMain, "void main() { }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--chatty", voidMain]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("stat "));  // stat should be called.

    /* Test --dry-run. */
    res = execute([rdmdApp, compilerSwitch, "--force", "--dry-run", failComptime]);
    assert(res.status == 0, res.output);  // static assert(0) not called since we did not build.
    assert(res.output.canFind("mkdirRecurse "), res.output);  // --dry-run implies chatty

    res = execute([rdmdApp, compilerSwitch, "--force", "--dry-run", "--build-only", failComptime]);
    assert(res.status == 0, res.output);  // --build-only should not interfere with --dry-run

    /* Test --eval. */
    res = execute([rdmdApp, compilerSwitch, "--force", "--eval=writeln(`eval_works`);"]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("eval_works"));  // there could be a "DMD v2.xxx header in the output"

    // compiler flags
    res = execute([rdmdApp, compilerSwitch, "--force", "-debug",
        "--eval=debug {} else assert(false);"]);
    assert(res.status == 0, res.output);

    // vs program file
    res = execute([rdmdApp, compilerSwitch, "--force",
        "--eval=assert(true);", voidMain]);
    assert(res.status != 0);
    assert(res.output.canFind("Cannot have both --eval and a program file ('" ~
            voidMain ~ "')."));

    /* Test --exclude. */
    string packFolder = tempDir().buildPath("dsubpack");
    if (packFolder.exists) packFolder.rmdirRecurse();
    packFolder.mkdirRecurse();
    scope (exit) packFolder.rmdirRecurse();

    string subModObj = packFolder.buildPath("submod") ~ objExt;
    string subModSrc = packFolder.buildPath("submod.d");
    std.file.write(subModSrc, "module dsubpack.submod; void foo() { }");

    // build an object file out of the dependency
    res = execute([compiler, "-c", "-of" ~ subModObj, subModSrc]);
    assert(res.status == 0, res.output);

    string subModUser = tempDir().buildPath("subModUser_.d");
    std.file.write(subModUser, "module subModUser_; import dsubpack.submod; void main() { foo(); }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--exclude=dsubpack", subModUser]);
    assert(res.status == 1, res.output);  // building without the dependency fails

    res = execute([rdmdApp, compilerSwitch, "--force", "--exclude=dsubpack", subModObj, subModUser]);
    assert(res.status == 0, res.output);  // building with the dependency succeeds

    /* Test --extra-file. */

    string extraFileDi = tempDir().buildPath("extraFile_.di");
    std.file.write(extraFileDi, "module extraFile_; void f();");
    string extraFileD = tempDir().buildPath("extraFile_.d");
    std.file.write(extraFileD, "module extraFile_; void f() { return; }");
    string extraFileMain = tempDir().buildPath("extraFileMain_.d");
    std.file.write(extraFileMain,
            "module extraFileMain_; import extraFile_; void main() { f(); }");

    res = execute([rdmdApp, compilerSwitch, "--force", extraFileMain]);
    assert(res.status == 1, res.output); // undefined reference to f()

    res = execute([rdmdApp, compilerSwitch, "--force",
            "--extra-file=" ~ extraFileD, extraFileMain]);
    assert(res.status == 0, res.output); // now OK

    /* Test --loop. */
    {
    auto testLines = "foo\nbar\ndoo".split("\n");

    auto pipes = pipeProcess([rdmdApp, compilerSwitch, "--force", "--loop=writeln(line);"], Redirect.stdin | Redirect.stdout);
    foreach (input; testLines)
        pipes.stdin.writeln(input);
    pipes.stdin.close();

    while (!testLines.empty)
    {
        auto line = pipes.stdout.readln.strip;
        if (line.empty || line.startsWith("DMD v")) continue;  // git-head header
        assert(line == testLines.front, "Expected %s, got %s".format(testLines.front, line));
        testLines.popFront;
    }
    auto status = pipes.pid.wait();
    assert(status == 0);
    }

    // vs program file
    res = execute([rdmdApp, compilerSwitch, "--force",
        "--loop=assert(true);", voidMain]);
    assert(res.status != 0);
    assert(res.output.canFind("Cannot have both --loop and a program file ('" ~
            voidMain ~ "')."));

    /* Test --main. */
    string noMain = tempDir().buildPath("no_main_.d");
    std.file.write(noMain, "module no_main_; void foo() { }");

    // test disabled: Optlink creates a dialog box here instead of erroring.
    /+ res = execute([rdmdApp, " %s", noMain));
    assert(res.status == 1, res.output);  // main missing +/

    res = execute([rdmdApp, compilerSwitch, "--main", noMain]);
    assert(res.status == 0, res.output);  // main added

    string intMain = tempDir().buildPath("int_main_.d");
    std.file.write(intMain, "int main(string[] args) { return args.length; }");

    res = execute([rdmdApp, compilerSwitch, "--main", intMain]);
    assert(res.status == 1, res.output);  // duplicate main

    /* Test --makedepend. */

    string packRoot = packFolder.buildPath("../").buildNormalizedPath();

    string depMod = packRoot.buildPath("depMod_.d");
    std.file.write(depMod, "module depMod_; import dsubpack.submod; void main() { }");

    res = execute([rdmdApp, compilerSwitch, "-I" ~ packRoot, "--makedepend",
            "-of" ~ depMod[0..$-2], depMod]);

    import std.ascii : newline;

    // simplistic checks
    assert(res.output.canFind(depMod[0..$-2] ~ ": \\" ~ newline));
    assert(res.output.canFind(newline ~ " " ~ depMod ~ " \\" ~ newline));
    assert(res.output.canFind(newline ~ " " ~ subModSrc));
    assert(res.output.canFind(newline ~  subModSrc ~ ":" ~ newline));
    assert(!res.output.canFind("\\" ~ newline ~ newline));

    /* Test --makedepfile. */

    string depModFail = packRoot.buildPath("depModFail_.d");
    std.file.write(depModFail, "module depMod_; import dsubpack.submod; void main() { assert(0); }");

    string depMak = packRoot.buildPath("depMak_.mak");
    res = execute([rdmdApp, compilerSwitch, "--force", "--build-only",
            "-I" ~ packRoot, "--makedepfile=" ~ depMak,
            "-of" ~ depModFail[0..$-2], depModFail]);
    scope (exit) std.file.remove(depMak);

    string output = std.file.readText(depMak);

    // simplistic checks
    assert(output.canFind(depModFail[0..$-2] ~ ": \\" ~ newline));
    assert(output.canFind(newline ~ " " ~ depModFail ~ " \\" ~ newline));
    assert(output.canFind(newline ~ " " ~ subModSrc));
    assert(output.canFind(newline ~ "" ~ subModSrc ~ ":" ~ newline));
    assert(!output.canFind("\\" ~ newline ~ newline));
    assert(res.status == 0, res.output);  // only built, assert(0) not called.

    /* Test signal propagation through exit codes */

    version (Posix)
    {
        import core.sys.posix.signal;
        string crashSrc = tempDir().buildPath("crash_src_.d");
        std.file.write(crashSrc, `void main() { int *p; *p = 0; }`);
        res = execute([rdmdApp, compilerSwitch, crashSrc]);
        assert(res.status == -SIGSEGV, format("%s", res));
    }

    /* -of doesn't append .exe on Windows: https://d.puremagic.com/issues/show_bug.cgi?id=12149 */

    version (Windows)
    {
        string outPath = tempDir().buildPath("test_of_app");
        string exePath = outPath ~ ".exe";
        res = execute([rdmdApp, "--build-only", "-of" ~ outPath, voidMain]);
        enforce(exePath.exists(), exePath);
    }

    /* Current directory change should not trigger rebuild */

    res = execute([rdmdApp, compilerSwitch, forceSrc]);
    assert(res.status == 0, res.output);
    assert(!res.output.canFind("compile_force_src"));

    {
        auto cwd = getcwd();
        scope(exit) chdir(cwd);
        chdir(tempDir);

        res = execute([rdmdApp, compilerSwitch, forceSrc.baseName()]);
        assert(res.status == 0, res.output);
        assert(!res.output.canFind("compile_force_src"));
    }

    auto conflictDir = forceSrc.setExtension(".dir");
    if (exists(conflictDir))
    {
        if (isFile(conflictDir))
            remove(conflictDir);
        else
            rmdirRecurse(conflictDir);
    }
    mkdir(conflictDir);
    res = execute([rdmdApp, compilerSwitch, "-of" ~ conflictDir, forceSrc]);
    assert(res.status != 0, "-of set to a directory should fail");

    /* test absolute import path */
    immutable string rootsrc = buildPath(tempDir(), "root.d");
    std.file.write(rootsrc, "import foo;");
    immutable string imp = buildPath(tempDir(), "imp");
    mkdir(imp);
    std.file.write(buildPath(imp, "foo.d"), "int main() {return 101;}");
    assert(imp.isAbsolute);
    res = execute([rdmdApp, compilerSwitch, "-I" ~ imp, rootsrc]);
    assert(res.status == 101, res.output);

    /* test importing from above the current directory */
    {
        auto cwd = getcwd();
        scope(exit) chdir(cwd);
        chdir(tempDir);

        std.file.write("foo.d", "int main() {return 102;}");
        mkdir("dir");
        chdir("dir");
        std.file.write("root.d", "import foo;");
        res = execute([rdmdApp, compilerSwitch, "-I..", "root.d"]);
        assert(res.status == 102, res.output);
    }

    /* test same module names, different packages */
    immutable imp2 = buildPath(tempDir(), "imp2");
    mkdir(imp2);
    write(rootsrc, "
        module foo;
        import imp.foo;
        import imp2.foo;
        int main() {return 100 + imp.foo.f() + imp2.foo.f();}
    ");
    std.file.write(buildPath(imp, "foo.d"),
        "module imp.foo; int f() {return 1;}");
    std.file.write(buildPath(imp2, "foo.d"),
        "module imp2.foo; int f() {return 2;}");
    res = execute([rdmdApp, rootsrc]);
    assert(res.status == 103, res.output);

    /* test import expression */
    std.file.write(rootsrc,
        "int main()
        {
            return 100 + (import(\"bar\") ~ import(\"bar.d\")).length;
        }");
    std.file.write(buildPath(tempDir(), "bar"), "not D code");
    std.file.write(buildPath(tempDir(), "bar.d"), "not D code");
    res = execute([rdmdApp, "-J"~tempDir(), rootsrc]);
    assert(res.status == 100 + "not D code".length * 2, res.output);

    /* test incremental building */
    {
        // cd to tempDir because rdmd wouldn't find the library otherwise.
        auto cwd = getcwd();
        scope(exit) chdir(cwd);
        chdir(tempDir);

        std.file.write("root.d", "
            import circular1;
            import lib;
            pragma(lib, \"somelib\");
            int main()
            {
                return 100 + circular1.f() + lib.f();
            }");
        std.file.write("circular1.d", "
            import circular2;
            import outside;
            int f() {return circular2.f() + outside.f();}
            int g() {return 1;}");
        std.file.write("circular2.d", "
            import circular3;
            int f() {return circular3.f() + 1;}");
        std.file.write("circular3.d", "
            import circular1;
            int f() {return circular1.g() + 1;}");
        std.file.write("outside.d", "int f() {return 2;}");
        std.file.write("lib.di", "int f();");
        mkdir("somelib");
        std.file.write("somelib/lib.d", "int f() {return 3;}");

        // Build the library.
        version (Posix) enum libExt = ".a";
        else version (Windows) enum libExt = ".lib";
        else static assert(false);
        immutable libfile = buildPath(tempDir(), "libsomelib".setExtension(libExt));
        res = execute([rdmdApp, "-lib", "-of" ~ libfile, "somelib/lib.d"]);
        assert(res.status == 0, res.output);

        res = execute([rdmdApp, "-L-L.", "-ofprogram", "root.d"]);
        assert(res.status == 108, res.output);

        static string[] compiledSources(string rdmdChattyOutput)
        {
            auto mLine = rdmdChattyOutput
                .matchFirst(regex(`^spawn "[^"]+" "-c" .*"[^"]+\.d"$`, "m"));
            if (!mLine) return [];
            return mLine.hit.matchAll(`"([^"]+\.d)"`).map!(m => m[1]).array;
        }

        // Touching root.d must not trigger a rebuild of anything else.
        Thread.sleep(1.seconds); // so that the time is actually different
        std.file.write("root.d", "
            import circular1;
            import lib;
            pragma(lib, \"somelib\");
            int main()
            {
                return 100 + circular1.f() + lib.f()
                    + 1; // !
            }");
        res = execute([rdmdApp, "--chatty", "-L-L.", "root.d"]);
        assert(res.status == 109, res.output);
        assert(compiledSources(res.output) == ["root.d"]);

        /* Touching outside.d must trigger a rebuild of circular{1,2,3} (and
        root of course). */
        Thread.sleep(1.seconds); // so that the time is actually different
        std.file.write("outside.d", "int f() {return 3;}");
        res = execute([rdmdApp, "--chatty", "-L-L.", "root.d"]);
        assert(res.status == 110, res.output);
        auto compiled = compiledSources(res.output);
        assert(compiled.length == 5);
        assert(compiled.canFind("outside.d"));
        assert(compiled.canFind("circular1.d"));
        assert(compiled.canFind("circular2.d"));
        assert(compiled.canFind("circular3.d"));
        assert(compiled.canFind("root.d"));

        /* Touching lib.di or somelib/lib.d must not trigger a rebuild of the
        program. */
        Thread.sleep(1.seconds); // so that the time is actually different
        std.file.write("lib.di", "int f();");
        std.file.write("somelib/lib.d", "int f() {return 4;}");
        auto programTime = timeLastModified("program");
        res = execute([rdmdApp, "--chatty", "-L-L.", "root.d"]);
        assert(res.status == 110, res.output);
        assert(compiledSources(res.output) == []);
        assert(timeLastModified("program") == programTime);

        /* Having touched somelib/lib.d must trigger a rebuild of the library.
        The library having changed must trigger a rebuild of the program. */
        Thread.sleep(1.seconds); // so that the time is actually different
        res = execute([rdmdApp, "-lib", "-of" ~ libfile, "somelib/lib.d"]);
        assert(res.status == 0, res.output);
        res = execute([rdmdApp, "--chatty", "-L-L.", "root.d"]);
        assert(res.status == 111, res.output);
        assert(compiledSources(res.output) == ["root.d"]);
    }
}

void runConcurrencyTest()
{
    string sleep100 = tempDir().buildPath("delay_.d");
    std.file.write(sleep100, "void main() { import core.thread; Thread.sleep(100.msecs); }");
    auto argsVariants =
    [
        [rdmdApp, compilerSwitch, sleep100],
        [rdmdApp, compilerSwitch, "--force", sleep100],
    ];
    import std.parallelism, std.range, std.random;
    foreach (rnd; rndGen.parallel(1))
    {
        try
        {
            auto args = argsVariants[rnd % $];
            auto res = execute(args);
            assert(res.status == 0, res.output);
        }
        catch (Exception e)
        {
            import std.stdio;
            writeln(e);
            break;
        }
    }
}

string tempDir()
{
    return buildPath(std.file.tempDir(), "rdmd_test");
}
