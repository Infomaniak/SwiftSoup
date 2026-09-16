#!/usr/bin/env python3
"""Run identical public clients against two shipping SwiftSoup libraries.

Produces raw fresh-process ABBA/BAAB records and a provenance manifest. Run
--aa as a separate control. No sample or outlier is removed. See the companion
Benchmarks reports for compilation commands and interpretation limits.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-library', type=Path, required=True)
    parser.add_argument('--candidate-library', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    parser.add_argument('--workloads', nargs='+', required=True)
    parser.add_argument('--output', type=Path, required=True, help='New output prefix')
    parser.add_argument('--blocks', type=int, default=12)
    parser.add_argument('--ms', type=float, default=500)
    parser.add_argument('--size', type=int, default=128)
    parser.add_argument('--aa', action='store_true', help='Use the baseline for BOTH labels')
    args = parser.parse_args()
    if args.blocks < 2 or not 0 < args.ms <= 60000 or args.size < 1:
        parser.error('Require blocks >= 2, 0 < ms <= 60000, size >= 1')
    client = args.client.resolve(strict=True)
    libraries = {'A': args.baseline_library.resolve(strict=True),
                 'B': args.candidate_library.resolve(strict=True)}
    extension = '.dylib' if platform.system() == 'Darwin' else '.so'
    files = {k: v / ('libSwiftSoup' + extension) for k, v in libraries.items()}
    raw_path = Path(str(args.output) + '.jsonl')
    meta_path = Path(str(args.output) + '-metadata.json')
    if raw_path.exists() or meta_path.exists():
        parser.error('Refusing to overwrite an existing run')
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    allowed = sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else []
    cpu = allowed[0] if allowed else None
    if cpu is not None:
        os.sched_setaffinity(0, {cpu})
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('SWIFTSOUP_', 'SWIFT_DETERMINISTIC'))
                   and k not in ('LD_PRELOAD', 'DYLD_INSERT_LIBRARIES', 'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH')}
    loader_variable = 'DYLD_LIBRARY_PATH' if extension == '.dylib' else 'LD_LIBRARY_PATH'

    def run(label: str, workload: str, iterations: int, verify: bool = False):
        actual = 'A' if args.aa else label
        child = dict(environment, **{loader_variable: str(libraries[actual])})
        command = [str(client), '--workload', workload, '--iterations', str(iterations),
                   '--size', str(args.size), '--warmups', '3']
        if verify:
            command.append('--verify')
        started = time.time()
        result = subprocess.run(command, env=child, capture_output=True, text=True, timeout=180)
        if result.returncode or result.stderr:
            raise RuntimeError({'command': command, 'status': result.returncode,
                                'stdout': result.stdout, 'stderr': result.stderr})
        if verify:
            return result.stdout
        sample = json.loads(result.stdout)
        if sample['iterations'] != iterations or sample['nanoseconds'] <= 0:
            raise RuntimeError('Invalid sample: ' + result.stdout)
        sample.update(label=label, actual_label=actual, command=command,
                      library=str(files[actual]), timestamp=started)
        return sample

    metadata = {'platform': platform.platform(), 'cpu': cpu, 'allowed_cpus': allowed,
                'aa': args.aa, 'blocks': args.blocks, 'target_ms': args.ms, 'size': args.size,
                'client_sha256': sha256(client),
                'libraries': {k: {'path': str(v), 'sha256': sha256(v)} for k, v in files.items()},
                'verification_sha256': {}, 'calibration': {}}
    for workload in args.workloads:
        observed_a = run('A', workload, 1, True)
        observed_b = run('B', workload, 1, True)
        if observed_a != observed_b:
            raise RuntimeError('Complete public output mismatch: ' + workload)
        metadata['verification_sha256'][workload] = hashlib.sha256(observed_a.encode()).hexdigest()
        calibration = [run(label, workload, 20) for label in ['A', 'B']]
        fastest = min(s['nanoseconds'] / s['iterations'] for s in calibration)
        iterations = max(1, min(2000000, round(args.ms * 1e6 / fastest)))
        metadata['calibration'][workload] = {'samples': calibration, 'iterations': iterations}
    with meta_path.open('x') as stream:
        json.dump(metadata, stream, indent=2)
    with raw_path.open('x') as stream:
        for workload in args.workloads:
            iterations = metadata['calibration'][workload]['iterations']
            for block in range(args.blocks):
                order = ['A', 'B', 'B', 'A'] if block % 2 == 0 else ['B', 'A', 'A', 'B']
                samples = []
                for position, label in enumerate(order):
                    sample = run(label, workload, iterations)
                    sample.update(block=block, position=position)
                    samples.append(sample)
                    stream.write(json.dumps(sample) + '\n')
                    stream.flush()
                if len({s['checksum'] for s in samples}) != 1:
                    raise RuntimeError('Timed checksum mismatch: ' + workload)
            print('Completed', workload, flush=True)


if __name__ == '__main__':
    main()
