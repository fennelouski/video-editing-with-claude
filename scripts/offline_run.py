"""Run a local GUI stage with Python network connections disabled.

Model setup is a separate explicit step. A missing cached model stops a cut instead
of downloading one implicitly. This also covers torchaudio's URL loader, which does
not honor Hugging Face's offline environment variables.
"""
from __future__ import annotations

import runpy
import socket
import sys


def disable_network() -> None:
    original_connect = socket.socket.connect
    original_connect_ex = socket.socket.connect_ex

    def connect(self, address):
        if self.family in (socket.AF_INET, socket.AF_INET6):
            raise OSError("Clauto is offline. Install the required model in the selected NAS cache before running a cut.")
        return original_connect(self, address)

    def connect_ex(self, address):
        if self.family in (socket.AF_INET, socket.AF_INET6):
            raise OSError("Clauto is offline. Install the required model in the selected NAS cache before running a cut.")
        return original_connect_ex(self, address)

    socket.socket.connect = connect
    socket.socket.connect_ex = connect_ex


def main() -> None:
    disable_network()
    script = sys.argv[1]
    sys.argv = sys.argv[1:]
    runpy.run_path(script, run_name="__main__")


if __name__ == "__main__":
    main()
