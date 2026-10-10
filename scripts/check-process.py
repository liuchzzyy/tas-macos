"""Build-time smoke check with a bounded timeout and macOS stack diagnostics."""
import subprocess
import sys

process = subprocess.Popen(sys.argv[1:])
try:
    sys.exit(process.wait(timeout=30))
except subprocess.TimeoutExpired:
    print("Packaged process timed out; collecting stack trace", flush=True)
    subprocess.run(["/usr/bin/sample", str(process.pid), "2", "-file", "/dev/stdout"], timeout=15, check=False)
    process.kill()
    process.wait()
    sys.exit(1)
