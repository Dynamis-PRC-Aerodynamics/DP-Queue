#!/usr/bin/env python3
"""Builds a small copy of the half-car personal case, for testing the dpq queue.

The copy keeps the structure and the geometry of the template and only edits
initialConditions: lower refinement levels, fewer iterations, np. With --break
it also plants one defect, to check that the queue catches it.
"""

import argparse
import os
import re
import shutil
import sys

SKIP_DIRS = {".git", "Mesh", "allProcessors", "allProcessors_mesh", "postProcessing",
             "log_mesh", "log_solve", "dynamicCode", "VTK", "polyMesh", "triSurface",
             "extendedFeatureEdgeMesh", "triSurface_0deg"}
RESULT_DIR = re.compile(r"^(processor\d+|\d+(\.\d+)?)$")
INTERNAL_ZONES = ("Porous_", "Fan_")


def copy_template(template, dest):
    for root, dirs, files in os.walk(template):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not RESULT_DIR.match(d)]
        target = os.path.join(dest, os.path.relpath(root, template))
        os.makedirs(target, exist_ok=True)
        for name in files:
            if ".bak" in name:
                continue
            with open(os.path.join(root, name), "rb") as src:
                data = src.read().replace(b"\r\n", b"\n")
            path = os.path.join(target, name)
            with open(path, "wb") as dst:
                dst.write(data)
            if name.startswith("run"):
                os.chmod(path, 0o755)


def link_geometry(geometry, dest):
    """Hard links when possible, copies otherwise. Never symbolic links: the
    pre-processor copies triSurface_0deg with `cp -a` and rewrites the files in
    place, so a symbolic link would make it overwrite the geometry it points to."""
    target = os.path.join(dest, "constant", "triSurface_0deg")
    os.makedirs(target, exist_ok=True)
    names = sorted(n for n in os.listdir(geometry) if n.endswith(".obj"))
    if not names:
        sys.exit(f"no .obj files in {geometry}")
    for name in names:
        src = os.path.realpath(os.path.join(geometry, name))
        try:
            os.link(src, os.path.join(target, name))
        except OSError:
            shutil.copyfile(src, os.path.join(target, name))
    return len(names)


def lower(value, by):
    return max(int(value) - by, 1) if int(value) > 1 else int(value)


def edit_initial_conditions(path, args):
    with open(path) as f:
        lines = f.read().split("\n")

    out = []
    for line in lines:
        key = line.split()[0] if line.split() else ""
        by = args.zone_coarsen if key.startswith(INTERNAL_ZONES) else args.coarsen

        if key == "np":
            line = re.sub(r"\d+", str(args.np), line, count=1)
        elif key == "iterations":
            line = re.sub(r"\d+", str(args.iterations), line, count=1)
        elif key == "writeStep":
            line = re.sub(r"\d+", str(args.iterations), line, count=1)
        elif key == "turbModel" and args.broken == "solver":
            line = "turbModel            dpqTestNotAModel;"
        elif key.endswith("_RefLvl"):
            line = re.sub(r"\((\d+)\s+(\d+)\)",
                          lambda m: f"({lower(m.group(1), by)} {lower(m.group(2), by)})", line, count=1)
        elif (key.endswith(("_feature", "_regionLvl")) or re.fullmatch(r"ref1\w*|lvl\d+", key)):
            line = re.sub(r"^(\s*\S+\s+)(\d+)", lambda m: m.group(1) + str(lower(m.group(2), by)), line)
        elif key.endswith("_nLayers") and not args.keep_layers:
            line = re.sub(r"^(\s*\S+\s+)(\d+)", lambda m: m.group(1) + "0", line)
        out.append(line)

    with open(path, "w") as f:
        f.write("\n".join(out))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("template", help="case folder to copy the structure from")
    p.add_argument("geometry", help="folder with the .obj files for constant/triSurface_0deg")
    p.add_argument("dest", help="case folder to create")
    p.add_argument("--np", type=int, default=4)
    p.add_argument("--iterations", type=int, default=30)
    p.add_argument("--coarsen", type=int, default=3, help="levels taken off every refinement level")
    p.add_argument("--zone-coarsen", type=int, default=1, help="same, for porous and fan zones")
    p.add_argument("--keep-layers", action="store_true", help="do not set the layers to zero")
    p.add_argument("--break", dest="broken", choices=["snappy", "solver", "np"],
                   help="plant a defect: snappy = syntax error in snappyHexMeshDict, "
                        "solver = unknown turbulence model, np = more cores than any machine has")
    args = p.parse_args()

    if os.path.exists(args.dest):
        sys.exit(f"{args.dest} already exists")
    if not os.path.isfile(os.path.join(args.template, "initialConditions")):
        sys.exit(f"{args.template} is not a case folder: initialConditions missing")
    if args.broken == "np":
        args.np = 999

    copy_template(args.template, args.dest)
    count = link_geometry(args.geometry, args.dest)
    edit_initial_conditions(os.path.join(args.dest, "initialConditions"), args)

    if args.broken == "snappy":
        with open(os.path.join(args.dest, "system", "snappyHexMeshDict"), "a") as f:
            f.write("\ndpqTestSyntaxError {\n")

    print(f"created {args.dest}: {count} obj, np {args.np}, {args.iterations} iterations"
          + (f", defect: {args.broken}" if args.broken else ""))


if __name__ == "__main__":
    main()
