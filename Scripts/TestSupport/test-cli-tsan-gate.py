#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the interpreter boundary that previously lost the NRRD environment."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('cli_tsan', Path(__file__).with_name('qualify-cli-tsan.py'))
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class InterpreterBoundaryTests(unittest.TestCase):
    def test_virtual_environment_survives_argument_normalisation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run([sys.executable, '-m', 'venv', '--without-pip', str(root/'venv')], check=True)
            interpreter = root/'venv/bin/python'
            args = argparse.Namespace(nrrd_python=interpreter, repo=root, foundation_report=None)
            DRIVER.normalise_paths(args)
            result = subprocess.run([str(args.nrrd_python), '-c',
                'import json,sys;print(json.dumps([sys.prefix,sys.base_prefix]))'],
                capture_output=True, text=True, check=True)
            prefix, base = json.loads(result.stdout)
            self.assertEqual(Path(prefix).resolve(), (root/'venv').resolve())
            self.assertNotEqual(prefix, base)
            self.assertEqual(args.nrrd_python, interpreter)


if __name__ == '__main__':
    unittest.main()
