#!/usr/bin/env python3
"""Fresh-process release comparisons with full output verification and balanced order.

Requires Python 3, NumPy and SciPy. Uses already-built dynamic libraries and identical
public client source separately compiled against each matching library. Never build or profile concurrently with timed runs.
"""
import argparse, hashlib, json, math, os, platform, random, subprocess, time
from pathlib import Path

WORKLOADS = {
    "classification": ["ascii-letters", "ascii-mixed", "unicode-mixed", "start-tags", "word-short", "tag-name", "word-unicode", "selector-parse", "selector-tags", "selector-unicode", "parse-control"]
}


def validate_sample(sample, workload, iterations, expected=None):
    """Reject inconsistent records before using their timing denominator."""
    if not isinstance(sample, dict) or set(sample) != {"workload", "iterations", "elapsed_ns", "expected", "checksum"}:
        raise ValueError("Unexpected sample schema")
    if sample['workload'] != workload:
        raise ValueError("Workload mismatch")
    for key in ('iterations', 'elapsed_ns', 'expected', 'checksum'):
        if type(sample[key]) is not int:
            raise ValueError(f"{key} must be an integer")
    if sample['iterations'] != iterations or iterations <= 0:
        raise ValueError("Iteration count mismatch")
    if sample['elapsed_ns'] <= 0:
        raise ValueError("Elapsed duration must be positive")
    if expected is not None and sample['expected'] != expected:
        raise ValueError("Expected value changed")
    if sample['checksum'] != sample['expected'] * iterations:
        raise ValueError("Checksum mismatch")
    return sample


def validate_outputs(first, second):
    if first != second:
        raise ValueError("Full observable outputs differ; refusing to benchmark")
    observed = json.loads(first)
    if not isinstance(observed, list) or not observed or any(not isinstance(x, dict) or not x for x in observed):
        raise ValueError("Verification output must be a nonempty array of nonempty records")
    return observed


def validate_workloads(names):
    if not names or len(set(names)) != len(names):
        raise ValueError("Workloads must be nonempty and unique")
    if any(w not in WORKLOADS['classification'] for w in names):
        raise ValueError("Unknown workload")
    return names

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline-client',type=Path,required=True)
    p.add_argument('--candidate-client',type=Path,required=True)
    p.add_argument('--baseline-library',type=Path,required=True)
    p.add_argument('--candidate-library',type=Path,required=True)
    p.add_argument('--suite',choices=WORKLOADS,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--blocks',type=int,default=8)
    p.add_argument('--ms',type=int,default=250)
    p.add_argument('--cpu',type=int,default=0)
    p.add_argument('--aa',action='store_true')
    p.add_argument('--workloads',nargs='+')
    a=p.parse_args()
    if a.blocks < 2 or a.ms < 1: p.error('blocks must be >=2 and ms >=1')
    import numpy as np
    from scipy.stats import t
    names=validate_workloads(a.workloads or WORKLOADS[a.suite])
    a.output.mkdir(parents=True,exist_ok=False)
    clients={'A': a.baseline_client.resolve(), 'B': (a.baseline_client if a.aa else a.candidate_client).resolve()}
    paths={'A':a.baseline_library.resolve(),'B':(a.baseline_library if a.aa else a.candidate_library).resolve()}
    variables={k:dict(os.environ) for k in paths}
    libvar='DYLD_LIBRARY_PATH' if platform.system()=='Darwin' else 'LD_LIBRARY_PATH'
    for k,path in paths.items(): variables[k][libvar]=str(path)
    if hasattr(os,'sched_setaffinity'): os.sched_setaffinity(0,{a.cpu})
    def launch(k,args):
        result=subprocess.run([str(clients[k]),*args],env=variables[k],check=True,capture_output=True,text=True,timeout=120)
        if result.stderr: raise RuntimeError(result.stderr)
        return result.stdout
    verify={k:launch(k,['--verify']) for k in paths}
    for k,s in verify.items(): (a.output/f'outputs-{k}.json').write_text(s)
    observed=validate_outputs(verify['A'],verify['B'])
    manifest={'arguments':{k:str(v) if isinstance(v,Path) else v for k,v in vars(a).items()},'platform':platform.platform(),
              'client_sha256':{k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in clients.items()},
              'library_sha256':{k:hashlib.sha256((v/('libSwiftSoup.dylib' if platform.system()=='Darwin' else 'libSwiftSoup.so')).read_bytes()).hexdigest() for k,v in paths.items()},
              'output_sha256':hashlib.sha256(verify['A'].encode()).hexdigest(),'verification_records':len(observed),'created_unix':time.time()}
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
    calibration=[]; iterations={}; expected={}
    for w in names:
        iterations[w]={}
        for k in paths:
            # Calibrate with measured batches rather than extrapolating four
            # tiny calls. Retain every calibration attempt separately.
            count = 16
            while True:
                sample=validate_sample(json.loads(launch(k,[w,str(count)])),w,count,expected.get(w))
                expected[w]=sample['expected']
                calibration.append({'revision':k,**sample})
                (a.output/'calibration.json').write_text(json.dumps(calibration,indent=2))
                if sample['elapsed_ns'] >= max(20, a.ms / 3) * 1e6 or count >= 100_000_000:
                    break
                ratio = max(2, min(8, math.ceil(a.ms * 1e6 / max(1, sample['elapsed_ns']))))
                count = min(100_000_000, count * ratio)
            speed=sample['elapsed_ns']/sample['iterations']
            iterations[w][k]=max(1,min(100_000_000,math.ceil(a.ms*1e6/speed)))
            if w in expected and sample['expected'] != expected[w]: raise RuntimeError('Checksum mismatch')
            expected[w]=sample['expected']
    (a.output/'calibration.json').write_text(json.dumps(calibration,indent=2))
    records=[]; rng=random.Random(962409)
    with open(a.output/'raw.jsonl','w') as log:
        for block in range(a.blocks):
            workloads=names.copy(); rng.shuffle(workloads)
            for w in workloads:
                order='ABBA' if block%2==0 else 'BAAB'
                for slot,k in enumerate(order):
                    data=validate_sample(json.loads(launch(k,[w,str(iterations[w][k])])),w,iterations[w][k],expected[w])
                    record={'block':block,'slot':slot,'revision':k,**data}
                    records.append(record); log.write(json.dumps(record)+'\n'); log.flush()
            print(f'{a.suite} {"AA" if a.aa else "AB"}: completed block {block+1}/{a.blocks}',flush=True)
    summary=[]
    for w in names:
        means=[]
        for block in range(a.blocks):
            pair={}
            for k in paths:
                times=[x['elapsed_ns']/x['iterations']/1e6 for x in records if x['workload']==w and x['block']==block and x['revision']==k]
                if len(times)!=2: raise ValueError('Each block needs two observations per revision')
                pair[k]=float(np.mean(np.log(times)))
            means.append(pair)
        deltas=np.array([x['B']-x['A'] for x in means]); center=float(np.mean(deltas))
        margin=float(t.ppf(.975,len(deltas)-1)*np.std(deltas,ddof=1)/math.sqrt(len(deltas)))
        result={'workload':w,'baseline_ms':float(np.exp(np.mean([x['A'] for x in means]))),'candidate_ms':float(np.exp(np.mean([x['B'] for x in means]))),
                'less_time_pct':100*(1-math.exp(center)),'low_pct':100*(1-math.exp(center+margin)),'high_pct':100*(1-math.exp(center-margin)),
                'blocks':a.blocks,'processes_per_revision':a.blocks*2,'iterations':iterations[w], 'batch_ms_min':min(x['elapsed_ns']/1e6 for x in records if x['workload']==w), 'batch_ms_max':max(x['elapsed_ns']/1e6 for x in records if x['workload']==w)}
        summary.append(result)
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
    for x in summary: print(f"{x['workload']}: {x['less_time_pct']:.2f}% [{x['low_pct']:.2f}, {x['high_pct']:.2f}]",flush=True)

if __name__=='__main__': main()
