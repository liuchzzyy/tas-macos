#!/usr/bin/env python3
"""Run real tas processes against an isolated vault and local Telegram HTTP fixture.

    swift build --product tas
    python3 scripts/test-history-cli.py --binary .build/debug/tas

Only Python's standard library is required. Never reads or writes ~/.tas.
"""
import argparse
import email.parser
import email.policy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class TelegramFixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, result=None, status=200):
        data = json.dumps({"ok": status == 200, "result": result or {},
                           "description": "fixture file missing" if status != 200 else ""}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        method = self.path.rsplit("/", 1)[-1]
        if method == "getMe":
            return self.reply({"id": 1, "is_bot": True, "username": "test_bot"})
        if method == "getChat":
            return self.reply({"id": 1, "type": "private"})
        if method == "sendDocument":
            mime = email.parser.BytesParser(policy=email.policy.default).parsebytes(
                b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
            document = next(p.get_payload(decode=True) for p in mime.iter_parts()
                            if p.get_param("name", header="content-disposition") == "document")
            self.server.counter += 1
            identifier = str(self.server.counter)
            self.server.documents[identifier] = document
            return self.reply({"message_id": int(identifier), "document": {"file_id": identifier}})
        parameters = json.loads(body)
        if method == "getFile":
            identifier = parameters["file_id"]
            if identifier not in self.server.documents:
                return self.reply(status=404)
            return self.reply({"file_path": "documents/" + identifier,
                               "file_size": len(self.server.documents[identifier])})
        if method == "deleteMessage":
            self.server.documents.pop(str(parameters["message_id"]), None)
            return self.reply({})
        self.reply(status=404)

    def do_GET(self):
        data = self.server.documents.get(self.path.rsplit("/", 1)[-1])
        if data is None:
            return self.reply(status=404)
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class CLIHistoryTests(unittest.TestCase):
    binary = None

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tas-cli-history-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vault = self.root / "vault"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), TelegramFixture)
        self.server.documents = {}
        self.server.counter = 0
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        # Explicitly discard inherited TAS credentials and routing settings.
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith("TAS_")}
        self.environment.update(TAS_PASSWORD="Fixture-Only-Password1!", TAS_BOT_TOKEN="123:fixture",
                                TAS_CHAT_ID="1", TAS_DATA_DIR=str(self.vault),
                                TAS_TMP_DIR=str(self.root / "staging"), HOME=str(self.root),
                                TMPDIR=str(self.root))
        self.run_cli("init", "--endpoint", "http://127.0.0.1:" + str(self.server.server_port))
        self.source = self.root / "source.txt"
        self.source.write_bytes(b"first revision\n")

    def run_cli(self, *args, succeeds=True):
        process = subprocess.run([str(self.binary), *map(str, args), "--data-dir", str(self.vault)],
                                 env=self.environment, cwd=self.root, capture_output=True,
                                 text=True, timeout=90)
        if succeeds:
            self.assertEqual(process.returncode, 0, f"{args}: {process.stderr}")
        else:
            self.assertNotEqual(process.returncode, 0, f"{args}: unexpectedly succeeded: {process.stdout}")
        return process

    def json_cli(self, *args):
        return json.loads(self.run_cli(*args, "--json").stdout)

    def test_new_version_alias_message_and_historical_pull(self):
        self.run_cli("push", self.source, "--name", "docs/report.txt", "--message", "initial")
        identifier = self.json_cli("list")[0]["id"]
        self.source.write_bytes(b"second revision\n")
        self.run_cli("push", self.source, "--name", "docs/report.txt", "--new-version", "--message", "edited")
        self.source.write_bytes(b"third revision\n")
        self.run_cli("push", self.source, "--name", "docs/report.txt", "--replace", "--new-version", "--message", "both aliases")
        files = self.json_cli("list")
        self.assertEqual(files[0]["id"], identifier)
        self.assertEqual(files[0]["versionNumber"], 3)
        versions = sorted(self.json_cli("history", identifier), key=lambda item: item["number"])
        self.assertEqual([v["message"] for v in versions], ["initial", "edited", "both aliases"])
        output = self.root / "old.txt"
        self.run_cli("pull", "docs/report.txt", "--version", "1", "--output", output)
        self.assertEqual(output.read_bytes(), b"first revision\n")
        self.run_cli("pull", identifier, "--output", output)
        self.assertEqual(output.read_bytes(), b"third revision\n")
        self.run_cli("push", self.source, "--name", "docs/report.txt", "--new-version")
        self.assertEqual(len(self.json_cli("history", identifier)), 3)

    def test_restore_delete_resume_and_manifest_roundtrip(self):
        self.run_cli("push", self.source, "--name", "report.txt")
        self.source.write_bytes(b"new content")
        self.run_cli("push", self.source, "--name", "report.txt", "--replace")
        self.run_cli("restore", "report.txt", "--version", "1", "--message", "recovered")
        current = self.json_cli("list")[0]
        self.assertEqual(current["versionNumber"], 3)
        self.assertTrue(current["syncPaused"])
        self.run_cli("sync", "resume", "report.txt")
        self.assertFalse(self.json_cli("list")[0]["syncPaused"])
        self.run_cli("delete", "report.txt", "--hard", "--yes", succeeds=False)
        self.run_cli("delete", "report.txt")
        self.assertEqual(self.json_cli("list"), [])
        self.assertTrue(self.json_cli("list", "--deleted")[0]["deleted"])
        self.assertEqual(len(self.json_cli("history", "report.txt")), 3)
        self.run_cli("index", "rebuild")
        self.assertEqual(len(self.json_cli("history", "report.txt")), 3)
        self.run_cli("verify", "--all-versions", "--deep")
        stats = self.json_cli("status")
        self.assertEqual(stats["files"], 0)
        self.assertEqual(stats["deletedFiles"], 1)
        self.assertEqual(stats["versions"], 3)
        self.run_cli("delete", "report.txt", "--hard", succeeds=False)
        self.assertEqual(len(self.json_cli("history", "report.txt")), 3)
        self.run_cli("delete", "report.txt", "--hard", "--yes")
        self.assertEqual(self.json_cli("list", "--deleted"), [])
        self.assertEqual(self.json_cli("status")["versions"], 0)

    def test_reject_invalid_options_without_changes(self):
        self.run_cli("push", self.source, "--name", "123")
        self.assertEqual(len(self.json_cli("history", "./123")), 1)
        for invalid in ("0", "-1", "abc", "1.2", "999999999999999999999999"):
            self.run_cli("pull", "./123", "--version", invalid, succeeds=False)
            self.run_cli("restore", "./123", "--version", invalid, succeeds=False)
        self.run_cli("restore", "./123", succeeds=False)
        self.run_cli("push", self.source, "--name", "123", "--unknown", succeeds=False)
        self.assertEqual(len(self.json_cli("history", "./123")), 1)

    def test_history_by_path_and_id(self):
        self.run_cli("push", self.source, "--name", "docs/report.txt")
        files = self.json_cli("list")
        versions = self.json_cli("history", "docs/report.txt")
        self.assertEqual(len(versions), 1)
        self.assertEqual(versions[0]["number"], 1)
        self.assertTrue(versions[0]["isCurrent"])
        self.assertEqual(versions, self.json_cli("history", files[0]["id"]))
        self.assertIn("1", self.run_cli("history", "docs/report.txt").stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(".build/debug/tas"))
    options, remaining = parser.parse_known_args()
    CLIHistoryTests.binary = options.binary.resolve(strict=True)
    unittest.main(argv=[__file__, *remaining], verbosity=2)
