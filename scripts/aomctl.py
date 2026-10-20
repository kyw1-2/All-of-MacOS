#!/usr/bin/env python3
"""Local AOM CLI. Named UI commands use aom://; JSON API uses scoped MCP."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from urllib.parse import urlencode


def rpc(name, arguments):
    token = os.environ.get("AOM_MCP_TOKEN")
    if not token:
        raise ValueError("Set AOM_MCP_TOKEN from a connected client with Automation enabled in AOM settings.")
    endpoint = Path.home() / "Library/Application Support/AllOfMacOS/mcp.sock"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(15)
        client.connect(str(endpoint))
        with client.makefile("rwb") as stream:
            def exchange(message):
                stream.write(json.dumps(message, ensure_ascii=False).encode() + b"\n")
                stream.flush()
                line = stream.readline(4_194_305)
                if not line or len(line) > 4_194_304:
                    raise ValueError("Missing or oversized response from AOM.")
                return json.loads(line)
            if exchange({"aom_mcp_auth": token}).get("aom_mcp_auth") != "ok":
                raise ValueError("AOM rejected this client token.")
            response = exchange({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                 "params": {"name": "automation_" + name, "arguments": arguments}})
            result = response.get("result", {})
            if result.get("isError") or "error" in response:
                message = "; ".join(item.get("text", "") for item in result.get("content", []))
                raise ValueError(message or "AOM rejected the request.")
            return result.get("structuredContent", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("run-trigger", "show-menu"):
        commands.add_parser(command).add_argument("name")
    for command in ("edit-menus", "hide-menus", "clipboard", "catalog", "list-triggers", "list-menus"):
        commands.add_parser(command)
    save = commands.add_parser("save-trigger", help="Native JSON {name, actions, enabled}; disabled by default")
    save.add_argument("file", type=Path)
    commands.add_parser("save-menu", help="Native FloatingMenuDefinition JSON").add_argument("file", type=Path)
    args = parser.parse_args()
    if args.command in ("run-trigger", "show-menu", "edit-menus", "hide-menus", "clipboard"):
        host = {"run-trigger": "trigger", "clipboard": "open-clipboard"}.get(args.command, args.command)
        query = "?" + urlencode({"name": args.name}) if hasattr(args, "name") else ""
        subprocess.run(["/usr/bin/open", "-g", "aom://" + host + query], check=True)
        print("Request sent to All of MacOS.")
        return
    if args.command in ("catalog", "list-triggers", "list-menus"):
        tool, arguments = args.command.replace("-", "_"), {}
    else:
        if args.file.stat().st_size > 1_000_000:
            raise ValueError("JSON file exceeds 1 MB.")
        value = json.loads(args.file.read_text())
        tool = "save_named_trigger" if args.command == "save-trigger" else "save_menu"
        arguments = value if args.command == "save-trigger" else {"menu": value}
    print(json.dumps(rpc(tool, arguments), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"aomctl: {error}", file=sys.stderr)
        sys.exit(1)
