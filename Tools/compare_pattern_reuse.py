#!/usr/bin/env python3
"""Balanced fresh-process Pattern A/B and same-binary A/A; no dependencies.

Compile baseline/candidate shipping libraries identically and compile the
identical Swift client source separately against each module. Pattern layout
          changes without library evolution, so swapping libraries under one old client
          is invalid. Compilation and correctness suites must
finish before this driver starts. Unused Pattern construction is reported
with fixed iterations: its very short baseline is not a precision benchmark.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import statistics
import subprocess

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline-library', type=pathlib.Path, required=True)
    p.add_argument('--candidate-library', type=pathlib.Path, required=True)
    p.add_argument('--baseline-client', type=pathlib.Path, required=True)
    p.add_argument('--candidate-client', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    loader = 'DYLD_LIBRARY_PATH' if platform.system() == 'Darwin' else 'LD_LIBRARY_PATH'
    libraries = {'A': a.baseline_library.resolve(), 'B': a.candidate_library.resolve()}
    clients = {'A': a.baseline_client.resolve(), 'B': a.candidate_client.resolve()}
    records = []
    def run(role, workload, count, stage, pair, logical_role=None):
        env = dict(os.environ)
        env[loader] = str(libraries[role])
        result = json.loads(subprocess.check_output([str(clients[role]), '--workload', workload, '--iterations', str(count)], env=env, text=True))
        if result['iterations'] != count or result['elapsed_ns'] <= 0:
            raise RuntimeError('Invalid timing record')
        result.update(role=role, logical_role=logical_role or role, stage=stage, pair=pair)
        records.append(result)
        with (a.output / 'raw.jsonl').open('a') as out:
            out.write(json.dumps(result, sort_keys=True) + '\n')
        return result
    summary = {}
    for workload in ['reused', 'validated', 'fresh', 'parse', 'unused']:
        ca = run('A', workload, 2, 'calibration', -1)
        cb = run('B', workload, 2, 'calibration', -1)
        if ca['checksum'] != cb['checksum']:
            raise RuntimeError('Output mismatch during calibration')
        count = 8 if workload == 'unused' else max(2, min(4096, int(150000000 / min(ca['ns_per_op'], cb['ns_per_op']))))
        summary[workload] = {}
        for stage, pairs in [('aa', 8), ('ab', 12)]:
            ratios = []
            for pair in range(pairs):
                roles = ['A', 'B'] if pair % 2 == 0 else ['B', 'A']
                observed = {}
                for role in roles:
                    observed[role] = run('A' if stage == 'aa' else role, workload, count, stage, pair, logical_role=role)
                if observed['A']['checksum'] != observed['B']['checksum']:
                    raise RuntimeError('Output mismatch')
                ratios.append(observed['B']['ns_per_op'] / observed['A']['ns_per_op'] - 1)
            summary[workload][stage] = {'pairs': pairs, 'median_percent_change': 100 * statistics.median(ratios),
                                       'faster_pairs': sum(r < 0 for r in ratios), 'paired_changes': ratios}
    identities = {'platform': platform.platform(), 'client_sha256': {role: hashlib.sha256(client.read_bytes()).hexdigest() for role, client in clients.items()}}
    for role, directory in libraries.items():
        identities[role] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.glob('libSwiftSoup.*')}
    (a.output / 'summary.json').write_text(json.dumps({'identities': identities, 'results': summary}, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
if __name__ == '__main__':
    main()
