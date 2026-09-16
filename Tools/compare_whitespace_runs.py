#!/usr/bin/env python3
"""Independent release-library A/B or A/A runs. Requires Python 3 and SciPy."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
from scipy.stats import t


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline-library', required=True, type=Path)
    p.add_argument('--candidate-library', required=True, type=Path)
    p.add_argument('--client', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--blocks', type=int, default=12)
    p.add_argument('--ms', type=float, default=500)
    p.add_argument('--size', type=int, default=128)
    p.add_argument('--workloads', nargs='+', default=['text-japanese', 'text-mixed', 'text-short', 'text-ascii', 'text-plain', 'textnode', 'owntext', 'parse-text', 'raw'])
    p.add_argument('--aa', action='store_true')
    a = p.parse_args()
    if a.blocks < 3 or a.ms <= 0 or not 1 <= a.size <= 4096:
        p.error('Need blocks >= 3, ms > 0, and size 1...4096')
    a.output.mkdir(parents=True, exist_ok=False)
    client = str(a.client.resolve(strict=True))
    libs = {'baseline': a.baseline_library.resolve(strict=True),
            'candidate': (a.baseline_library if a.aa else a.candidate_library).resolve(strict=True)}
    affinity = None
    if hasattr(os, 'sched_getaffinity'):
        affinity = min(os.sched_getaffinity(0))
        os.sched_setaffinity(0, {affinity})
    ext = 'dylib' if sys.platform == 'darwin' else 'so'
    key = 'DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH'
    metadata = {'argv': sys.argv, 'platform': platform.platform(), 'python': sys.version,
                'affinity_cpu': affinity, 'aa': a.aa, 'client': client, 'client_sha256': digest(client),
                'libraries': {k: {'path': str(v), 'sha256': digest(v / ('libSwiftSoup.' + ext))} for k, v in libs.items()}}
    (a.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')

    def run(label, workload, iterations, verify=False):
        command = [client, '--workload', workload, '--size', str(a.size), '--iterations', str(iterations)]
        if verify:
            command.append('--verify')
        environment = os.environ.copy()
        environment[key] = str(libs[label])
        result = subprocess.run(command, env=environment, capture_output=True, timeout=180, check=True)
        parsed = json.loads(result.stdout)
        return parsed, result.stdout, command

    calibrations = []
    counts = {}
    checksums = {}
    for workload in a.workloads:
        reference = None
        sample_times = []
        for label in libs:
            value, raw, _ = run(label, workload, 1, True)
            (a.output / f'{workload}-{label}-output.json').write_bytes(raw)
            if reference is not None and raw != reference:
                raise RuntimeError(f'Full output mismatch: {workload}')
            reference = raw
            checksums[workload] = value['checksum']
            value, _, command = run(label, workload, 64)
            calibrations.append({'label': label, 'command': command, **value})
            sample_times.append(value['ns_per_op'])
        counts[workload] = max(1, math.ceil(a.ms * 1e6 / min(sample_times)))
    (a.output / 'calibration.json').write_text(json.dumps(calibrations, indent=2) + '\n')
    records = []
    rng = random.Random(20260909)
    with (a.output / 'raw.jsonl').open('w') as stream:
        for block in range(a.blocks):
            workloads = list(a.workloads)
            rng.shuffle(workloads)
            order = ['baseline', 'candidate', 'candidate', 'baseline'] if block % 2 == 0 else ['candidate', 'baseline', 'baseline', 'candidate']
            for workload in workloads:
                for slot, label in enumerate(order):
                    value, _, command = run(label, workload, counts[workload])
                    if value['checksum'] != checksums[workload] * counts[workload]:
                        raise RuntimeError(f'Timed checksum mismatch: {workload}/{label}')
                    row = {'block': block, 'slot': slot, 'label': label, 'command': command, **value}
                    records.append(row)
                    stream.write(json.dumps(row) + '\n')
                    stream.flush()
            print(f'Completed block {block + 1}/{a.blocks}', flush=True)
    summary = []
    for workload in a.workloads:
        pairs = []
        logs = {'baseline': [], 'candidate': []}
        for block in range(a.blocks):
            means = {}
            for label in libs:
                values = [math.log(r['ns_per_op']) for r in records if r['block'] == block and r['workload'] == workload and r['label'] == label]
                assert len(values) == 2
                logs[label].extend(values)
                means[label] = statistics.mean(values)
            pairs.append(means['candidate'] - means['baseline'])
        center = statistics.mean(pairs)
        half = float(t.ppf(0.975, len(pairs) - 1)) * statistics.stdev(pairs) / math.sqrt(len(pairs))
        row = {'workload': workload, 'baseline_ms': math.exp(statistics.mean(logs['baseline'])) / 1e6,
               'candidate_ms': math.exp(statistics.mean(logs['candidate'])) / 1e6,
               'less_time_percent': 100 * (1 - math.exp(center)),
               'ci95_low': 100 * (1 - math.exp(center + half)), 'ci95_high': 100 * (1 - math.exp(center - half)),
               'blocks': len(pairs), 'processes_per_revision': 2 * len(pairs)}
        summary.append(row)
    (a.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
