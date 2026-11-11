#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Focused receipt and identity checks without starting a native qualification."""
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest


# The runner is an executable CLI. Load its actual standalone helper definitions
# without executing argument parsing, platform checks or the full codec suite.
runner = Path(__file__).with_name('qualify-native-runtime.py')
names = {'normalise_test_identity', 'suite_identity_coverage', 'console_coverage', 'run_raw'}
definitions = [node for node in ast.parse(runner.read_text()).body
               if isinstance(node, ast.FunctionDef) and node.name in names]
assert {node.name for node in definitions} == names
helpers = dict(hashlib=hashlib, json=json, re=re, subprocess=subprocess, time=time)
exec(compile(ast.Module(body=definitions, type_ignores=[]), str(runner), 'exec'), helpers)


class NativeRuntimeReportingTests(unittest.TestCase):
    def coverage(self, discovered, executed, required=()):
        return helpers['suite_identity_coverage'](discovered, executed, {'ExampleTests'}, required)

    def test_top_level_separator_and_suite_names_match(self):
        result = self.coverage(['ExampleTests.Suite/work(_:)', 'ExampleTests.free()'],
                               ['ExampleTests.Suite/work(_:)', 'ExampleTests/free()'], ['work', 'free'])
        self.assertTrue(result['passed'])
        self.assertEqual(result['normalisedDiscovered'], result['normalisedExecuted'])

    def test_same_count_different_identity_is_rejected(self):
        result = self.coverage(['ExampleTests.Suite/first()'], ['ExampleTests.Suite/second()'])
        self.assertFalse(result['passed'])
        self.assertEqual(result['missing'], ['ExampleTests.Suite/first()'])
        self.assertEqual(result['unexpected'], ['ExampleTests.Suite/second()'])

    def test_duplicate_and_empty_discovery_are_rejected(self):
        self.assertFalse(self.coverage(['ExampleTests.free()'] * 2, ['ExampleTests/free()'] * 2)['passed'])
        self.assertFalse(self.coverage([], [])['passed'])

    def test_unknown_module_and_interleaved_diagnostic_are_rejected(self):
        with self.assertRaises(ValueError):
            self.coverage(['OtherTests.Suite/work()'], ['ExampleTests.Suite/work()'])
        self.assertFalse(self.coverage(['ExampleTests.Suite/wo' + 'warning: diagnostic'],
                                       ['ExampleTests.Suite/work()'])['passed'])

    def test_required_test_is_an_exact_method_name(self):
        self.assertFalse(self.coverage(['ExampleTests.Suite/notwork()'],
                                       ['ExampleTests.Suite/notwork()'], ['work'])['passed'])

    def test_execution_progress_may_be_on_either_stream(self):
        summary = '✔ Test run with 2 tests in 1 suite passed after 0.123 seconds.\n'
        for stdout, stderr in [(summary, ''), ('', summary)]:
            self.assertTrue(helpers['console_coverage'](stdout, stderr, 2)['passed'])

    def test_execution_stderr_failure_and_summary_disagreement_reject(self):
        summary = '✔ Test run with 2 tests in 1 suite passed after 0.123 seconds.\n'
        for stdout, stderr, count in [(summary, '✘ Test work() failed.\n', 2),
                                      (summary, 'ERROR: AddressSanitizer: bad access\n', 2),
                                      (summary, 'ERROR: LeakSanitizer: leak\n', 2),
                                      (summary, 'WARNING: ThreadSanitizer: data race\n', 2),
                                      (summary, summary, 2), (summary, '', 3), ('', '', 2)]:
            self.assertFalse(helpers['console_coverage'](stdout, stderr, count)['passed'])

    def test_non_utf8_streams_and_nonzero_exit_are_preserved_before_decode(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            argv = [sys.executable, '-c', "import sys;sys.stdout.buffer.write(b'out\\xff');sys.stderr.buffer.write(b'err\\xfe');sys.exit(7)"]
            result, record = helpers['run_raw'](argv, output, 'probe', output, None)
            self.assertEqual(result.returncode, 7)
            self.assertEqual(json.loads((output/'probe-process.json').read_text()), record)
            self.assertEqual(record['exitCode'], 7)
            for stream, expected in [('stdout', b'out\xff'), ('stderr', b'err\xfe')]:
                self.assertEqual((output/record[stream]).read_bytes(), expected)
                self.assertEqual(record[stream+'SHA256'], hashlib.sha256(expected).hexdigest())
            with self.assertRaises(UnicodeDecodeError):
                (output/'probe.stdout.log').read_text(encoding='utf-8')
            self.assertEqual((output/'probe.log').read_bytes(), b'out\xfferr\xfe')


if __name__ == '__main__':
    unittest.main()
