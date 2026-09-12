"""Install a built wheel in isolation and exercise it with the SDK regression suite."""

import argparse
from pathlib import Path
import subprocess
import tempfile
import venv


RUN_TESTS = """
from importlib.metadata import version
from pathlib import Path
import sys
import unittest

# Import before discovery: existing tests add src/ to sys.path, but this
# package and its submodules must resolve from the installed wheel.
import fountain

package = Path(fountain.__file__).resolve().parent
if not package.is_relative_to(Path(sys.prefix).resolve()):
    raise RuntimeError("Fountain did not load from the isolated environment")
if not (package / "py.typed").is_file():
    raise RuntimeError("The wheel omitted its py.typed marker")
if fountain.__version__ != version("fountain-agent-sdk"):
    raise RuntimeError("Installed package and SDK versions differ")
print("Testing installed SDK from " + str(package), flush=True)
suite = unittest.defaultTestLoader.discover(sys.argv[1])
if not suite.countTestCases():
    raise RuntimeError("No SDK regression tests were discovered")
result = unittest.TextTestRunner(verbosity=2).run(suite)
for name, module in list(sys.modules.items()):
    if name == "fountain" or name.startswith("fountain."):
        if not Path(module.__file__).resolve().is_relative_to(package):
            raise RuntimeError("Test imported SDK source outside the wheel: " + name)
sys.exit(0 if result.wasSuccessful() else 1)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheel", type=Path)
    args = parser.parse_args()
    wheel = args.wheel.resolve()
    sdk = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="fountain-wheel-") as directory:
        environment = Path(directory) / "venv"
        venv.EnvBuilder(with_pip=True).create(environment)
        python = environment / ("Scripts/python.exe" if (environment / "Scripts").exists() else "bin/python")
        subprocess.run([str(python), "-I", "-m", "pip", "install", "--no-index", "--no-deps",
                        "--disable-pip-version-check", str(wheel)], check=True, cwd=directory)
        subprocess.run([str(python), "-I", "-c", RUN_TESTS, str(sdk / "tests")],
                       check=True, cwd=directory)


if __name__ == "__main__":
    main()
