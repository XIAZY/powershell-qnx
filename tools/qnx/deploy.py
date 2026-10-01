#!/usr/bin/env python3
# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.

"""Assemble a .NET install tree for QNX 6.5 x86 and write a program's props file.

    deploy.py --out DIR --framework FX --native DIR... --host QNXHOST PROGRAM.dll...

Layout (relocatable; qnxhost expands $ROOT to the props file's directory,
and the props file lives in the tree's root):

    DIR/shared/   the linux-x86 managed framework, unmodified, and the
                  native libraries built for QNX (libcoreclr.so,
                  libSystem.Native.so, libSystem.IO.Compression.Native.so)
    DIR/<name>/   each program's files
    DIR/bin/qnxhost
    DIR/<name>.props

The props file holds what the dotnet host would give the runtime: the
trusted assemblies (framework plus program), the native library search
path, the base directory, RUNTIME_IDENTIFIER=linux-x86 (the managed
libraries are the Linux ones), and the configProperties of the program's
runtimeconfig.json.
"""
import argparse
import glob
import json
import os
import shutil

QNX_NATIVE = ("libcoreclr.so", "libSystem.Native.so", "libSystem.IO.Compression.Native.so")

# The RIDs whose runtimes/<rid>/lib assemblies apply, most specific first, as
# the dotnet host would pick them for linux-x86.
RID_FALLBACKS = ("linux-x86", "linux", "unix")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--framework", required=True, help="directory of the linux-x86 managed framework")
    ap.add_argument("--native", nargs="+", required=True, help="QNX-built native libraries")
    ap.add_argument("--host", required=True, help="qnxhost built for QNX")
    ap.add_argument("--tree", action="store_true",
                    help="copy each program's whole directory (modules, resources, and ref/, the reference "
                         "assemblies Add-Type compiles against), not only its assemblies; runtimes/ is left out")
    ap.add_argument("--setenv", action="append", default=[], metavar="NAME=VALUE",
                    help="environment variable qnxhost sets before starting the runtime")
    ap.add_argument("--defaultenv", action="append", default=[], metavar="NAME=VALUE",
                    help="environment variable qnxhost sets only if it is not set")
    ap.add_argument("programs", nargs="+", help="the programs' main assemblies")
    args = ap.parse_args()

    shared = os.path.join(args.out, "shared")
    os.makedirs(shared, exist_ok=True)
    for dll in sorted(glob.glob(os.path.join(args.framework, "*.dll"))):
        shutil.copy2(dll, shared)
    natives = {os.path.basename(p): p for p in args.native}
    missing = [n for n in QNX_NATIVE if n not in natives]
    if missing:
        ap.error(f"missing QNX native libraries: {missing}")
    for name, path in natives.items():
        shutil.copy2(path, shared)
    os.makedirs(os.path.join(args.out, "bin"), exist_ok=True)
    shutil.copy2(args.host, os.path.join(args.out, "bin", "qnxhost"))

    framework = sorted(os.path.basename(p) for p in glob.glob(os.path.join(shared, "*.dll")))
    for program in args.programs:
        name = os.path.splitext(os.path.basename(program))[0]
        appdir = os.path.join(args.out, name)
        os.makedirs(appdir, exist_ok=True)
        srcdir = os.path.dirname(os.path.abspath(program))
        if args.tree:
            shutil.copytree(srcdir, appdir, dirs_exist_ok=True, symlinks=True,
                            ignore=lambda d, names: [n for n in names
                                                     if d == srcdir and n == "runtimes"])
        for dll in glob.glob(os.path.join(srcdir, "*.dll")):
            shutil.copy2(dll, appdir)
        # RID-specific assemblies replace the portable ones, the most specific last.
        for rid in reversed(RID_FALLBACKS):
            for dll in sorted(glob.glob(os.path.join(srcdir, "runtimes", rid, "lib", "*", "*.dll"))):
                shutil.copy2(dll, appdir)
        own = sorted(os.path.basename(p) for p in glob.glob(os.path.join(appdir, "*.dll")))
        # The program's own executable (the dotnet apphost, a Linux binary in
        # the portable releases) becomes a script that starts it through
        # qnxhost: programs start themselves by that path, as PowerShell does
        # for Start-Job and other child PowerShell processes ($PSHOME/pwsh).
        launcher = os.path.join(appdir, name)
        if os.path.exists(launcher):
            os.remove(launcher)
            with open(launcher, "w") as f:
                f.write("#!/bin/sh\n"
                        "# Written by deploy.py: runs this program on QNX through bin/qnxhost.\n"
                        'here=$(cd "$(dirname "$0")" && pwd)\n'
                        f'exec "$here/../bin/qnxhost" "$here/../{name}.props" "$@"\n')
            os.chmod(launcher, 0o755)

        config = {}
        rc = os.path.join(srcdir, name + ".runtimeconfig.json")
        if os.path.exists(rc):
            config = json.load(open(rc)).get("runtimeOptions", {}).get("configProperties", {})
        tpa = [f"$ROOT/shared/{d}" for d in framework] + [f"$ROOT/{name}/{d}" for d in own]
        props = [
            f"APP=$ROOT/{name}/{name}.dll",
            "RUNTIME=$ROOT/shared/libcoreclr.so",
            "TRUSTED_PLATFORM_ASSEMBLIES=" + ":".join(tpa),
            f"NATIVE_DLL_SEARCH_DIRECTORIES=$ROOT/{name}/:$ROOT/shared/",
            f"APP_CONTEXT_BASE_DIRECTORY=$ROOT/{name}/",
            "RUNTIME_IDENTIFIER=linux-x86",
            "System.Globalization.Invariant=true",
            # Culture names (en-US, de-DE) are accepted and behave like the
            # invariant culture, instead of throwing: QNX has no ICU data, and
            # Get-Help -UICulture, Update-Help and scripts that name a culture
            # need them to exist.
            "System.Globalization.PredefinedCulturesOnly=false",
        ]
        props += [f"SETENV={e}" for e in args.setenv] + [f"DEFAULTENV={e}" for e in args.defaultenv]
        for key, value in config.items():
            if key in ("System.Globalization.Invariant", "System.Globalization.PredefinedCulturesOnly"):
                continue
            props.append(f"{key}={str(value).lower() if isinstance(value, bool) else value}")
        with open(os.path.join(args.out, name + ".props"), "w") as f:
            f.write("# Written by deploy.py; read by bin/qnxhost.\n")
            f.write("\n".join(props) + "\n")
        print(f"{name}: {len(tpa)} trusted assemblies, {len(config)} runtimeconfig properties")


if __name__ == "__main__":
    main()
