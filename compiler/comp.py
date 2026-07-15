from http.server import BaseHTTPRequestHandler, HTTPServer
import sys
import re
import os
import argparse

pattern = re.compile(r"--\s*@import\((.*?)\)")
parser = argparse.ArgumentParser()

parser.add_argument("src_root", help="Source root directory (e.g. ./src)")
parser.add_argument("main_file", help="Entry Lua file")
parser.add_argument(
    "-i",
    action="append",
    default=[],
    help="Allowed external file or directory (can be used multiple times)"
)

args = parser.parse_args()

SRC_ROOT = os.path.abspath(args.src_root)
main_file = os.path.abspath(args.main_file)
PROJECT_ROOT = os.path.dirname(SRC_ROOT)

ALLOWED_EXTERNAL = set(os.path.abspath(p) for p in args.i)

if not main_file.startswith(SRC_ROOT + os.sep):
    raise Exception("Main file must be inside src root")

if not os.path.exists(SRC_ROOT):
    raise Exception("SRC root does not exist")


def is_allowed_external(path):
    for allowed in ALLOWED_EXTERNAL:
        # allow exact file
        if path == allowed:
            return True
        # allow directory prefix
        if os.path.isdir(allowed) and path.startswith(allowed + os.sep):
            return True
    return False


def resolve_path(path, current_dir):
    resolved = os.path.abspath(
        os.path.normpath(os.path.join(current_dir, path))
    )

    # inside src → always allowed
    if resolved.startswith(SRC_ROOT + os.sep):
        return resolved

    # external allowlist
    if is_allowed_external(resolved):
        return resolved

    raise Exception(f"Import outside src not allowed: {path}")

def expand_file(path, expanded=None, stack=None):
    if expanded is None:
        expanded = set()
    if stack is None:
        stack = set()

    full_path = os.path.abspath(path)

    if full_path in stack:
        raise Exception(f"Circular import detected: {full_path}")

    if full_path in expanded:
        return ""

    stack.add(full_path)

    output = []

    with open(full_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    file_dir = os.path.dirname(full_path)

    # handle imports
    for line in lines:
        match = pattern.search(line)
        if match:
            import_path = match.group(1).strip()
            resolved = resolve_path(import_path, file_dir)

            imported = expand_file(resolved, expanded, stack).rstrip("\n")

            if imported.strip():
                output.append(imported)

                rel_path = os.path.relpath(resolved, PROJECT_ROOT).replace("\\", "/")
                output.append(f"\n\n--[[ <{rel_path}> ]]--\n")

    # keep non-import lines
    for line in lines:
        if not pattern.search(line):
            output.append(line)

    expanded.add(full_path)
    stack.remove(full_path)

    return "".join(output)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            content = expand_file(main_file)

            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()

            self.wfile.write(content.encode("utf-8"))

        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode("utf-8"))


server = HTTPServer(("", 8070), Handler)

print("Server running on http://localhost:8070")

try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nStopping server...")
    server.shutdown()
finally:
    server.server_close()