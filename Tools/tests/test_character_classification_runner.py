"""Run with python3 -m unittest discover -s Tools/tests (no SciPy needed)."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("classification_runner", Path(__file__).resolve().parents[1] / "compare_character_classification.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SampleValidationTests(unittest.TestCase):
    def sample(self, **changes):
        value = {"workload": "word-short", "iterations": 16, "elapsed_ns": 123456,
                 "expected": 7, "checksum": 112}
        value.update(changes)
        return value

    def test_valid_record_is_not_rewritten(self):
        sample = self.sample()
        self.assertIs(runner.validate_sample(sample, 'word-short', 16, 7), sample)

    def test_wrong_iteration_count_is_rejected_even_with_plausible_checksum(self):
        with self.assertRaisesRegex(ValueError, 'Iteration'):
            runner.validate_sample(self.sample(iterations=1), 'word-short', 16, 7)

    def test_zero_checksum_cannot_hide_wrong_iteration_count(self):
        with self.assertRaisesRegex(ValueError, 'Iteration'):
            runner.validate_sample(self.sample(iterations=1, expected=0, checksum=0), 'word-short', 16, 0)
        runner.validate_sample(self.sample(expected=0, checksum=0), 'word-short', 16, 0)

    def test_workload_must_match_the_requested_operation(self):
        with self.assertRaisesRegex(ValueError, 'Workload'):
            runner.validate_sample(self.sample(workload='parse-control'), 'word-short', 16)

    def test_calibration_checks_the_checksum_too(self):
        with self.assertRaisesRegex(ValueError, 'Checksum'):
            runner.validate_sample(self.sample(checksum=111), 'word-short', 16)

    def test_expected_value_cannot_drift(self):
        with self.assertRaisesRegex(ValueError, 'Expected'):
            runner.validate_sample(self.sample(expected=8, checksum=128), 'word-short', 16, 7)

    def test_duration_must_be_positive(self):
        for duration in (0, -1):
            with self.subTest(duration=duration), self.assertRaises(ValueError):
                runner.validate_sample(self.sample(elapsed_ns=duration), 'word-short', 16)

    def test_counts_must_be_integers_not_coercible_values(self):
        for key in ('iterations', 'elapsed_ns', 'expected', 'checksum'):
            for value in (True, False, 16.0, '16', None, float('nan'), float('inf')):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    runner.validate_sample(self.sample(**{key: value}), 'word-short', 16)

    def test_schema_rejects_missing_extra_and_nonobject_values(self):
        incomplete = self.sample()
        incomplete.pop('checksum')
        for sample in (None, [], incomplete, self.sample(extra=1)):
            with self.subTest(sample=sample), self.assertRaises(ValueError):
                runner.validate_sample(sample, 'word-short', 16)

    def test_verifier_requires_complete_nonempty_record_array(self):
        for value in (None, False, 1, 'nonempty', {}, {'x': 1}, [], [{}], [1]):
            text = json.dumps(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                runner.validate_outputs(text, text)
        text = '[{"input":"a","word":"a"}]\n'
        self.assertEqual(runner.validate_outputs(text, text), json.loads(text))

    def test_verifier_uses_exact_bytes_not_just_json_equality(self):
        with self.assertRaises(ValueError):
            runner.validate_outputs('[{"a":1}]', '[{"a": 1}]')

    def test_workloads_are_known_nonempty_and_unique(self):
        for names in ([], ['unknown'], ['word-short', 'word-short']):
            with self.subTest(names=names), self.assertRaises(ValueError):
                runner.validate_workloads(names)
        names = ['word-short', 'parse-control']
        self.assertIs(runner.validate_workloads(names), names)


if __name__ == '__main__':
    unittest.main()
