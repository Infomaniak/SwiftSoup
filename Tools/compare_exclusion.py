#!/usr/bin/env python3
"""Fresh-process release comparisons with full output verification and balanced order.

Requires Python 3, NumPy and SciPy. Uses already-built dynamic libraries and one
unchanged public client. Never build or profile concurrently with timed runs.
"""
import argparse, hashlib, json, math, os, platform, random, subprocess, time
from pathlib import Path
import numpy as np
from scipy.stats import t

WORKLOADS = {
    'exclusion': ['not-8', 'not-128', 'not-512', 'not-2048', 'not-8192',
                  'sparse-control', 'descendant-control', 'parse-not', 'parse-control'],
}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--client',type=Path,required=True)
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
    a.output.mkdir(parents=True,exist_ok=False)
    client=a.client.resolve()
    paths={'A':a.baseline_library.resolve(),'B':(a.baseline_library if a.aa else a.candidate_library).resolve()}
    variables={k:dict(os.environ) for k in paths}
    libvar='DYLD_LIBRARY_PATH' if platform.system()=='Darwin' else 'LD_LIBRARY_PATH'
    for k,path in paths.items(): variables[k][libvar]=str(path)
    if hasattr(os,'sched_setaffinity'): os.sched_setaffinity(0,{a.cpu})
    def launch(k,args):
        result=subprocess.run([str(client),*args],env=variables[k],check=True,capture_output=True,text=True)
        if result.stderr: raise RuntimeError(result.stderr)
        return result.stdout
    verify={k:launch(k,['--verify']) for k in paths}
    for k,s in verify.items(): (a.output/f'outputs-{k}.json').write_text(s)
    if verify['A'] != verify['B']: raise RuntimeError('Full observable outputs differ; refusing to benchmark')
    observed=json.loads(verify['A'])
    if not observed: raise RuntimeError('Empty verification output')
    manifest={'arguments':{k:str(v) if isinstance(v,Path) else v for k,v in vars(a).items()},'platform':platform.platform(),
              'client_sha256':hashlib.sha256(client.read_bytes()).hexdigest(),
              'library_sha256':{k:hashlib.sha256((v/('libSwiftSoup.dylib' if platform.system()=='Darwin' else 'libSwiftSoup.so')).read_bytes()).hexdigest() for k,v in paths.items()},
              'output_sha256':hashlib.sha256(verify['A'].encode()).hexdigest(),'verification_records':len(observed),'created_unix':time.time()}
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
    names=a.workloads or WORKLOADS[a.suite]
    if any(w not in WORKLOADS[a.suite] for w in names): raise ValueError('Unknown workload')
    calibration=[]; iterations={}; expected={}
    for w in names:
        speeds=[]
        for k in paths:
            sample=json.loads(launch(k,[w,'4']))
            calibration.append({'revision':k,**sample})
            speeds.append(sample['elapsed_ns']/sample['iterations'])
            if w in expected and sample['expected'] != expected[w]: raise RuntimeError('Checksum mismatch')
            expected[w]=sample['expected']
        iterations[w]=max(4,min(2_000_000,math.ceil(a.ms*1e6/min(speeds))))
    (a.output/'calibration.json').write_text(json.dumps(calibration,indent=2))
    records=[]; rng=random.Random(962409)
    with open(a.output/'raw.jsonl','w') as log:
        for block in range(a.blocks):
            workloads=names.copy(); rng.shuffle(workloads)
            for w in workloads:
                order='ABBA' if block%2==0 else 'BAAB'
                for slot,k in enumerate(order):
                    data=json.loads(launch(k,[w,str(iterations[w])]))
                    if data['expected'] != expected[w] or data['checksum'] != expected[w]*iterations[w]: raise RuntimeError('Timed checksum changed')
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
                assert len(times)==2
                pair[k]=float(np.mean(np.log(times)))
            means.append(pair)
        deltas=np.array([x['B']-x['A'] for x in means]); center=float(np.mean(deltas))
        margin=float(t.ppf(.975,len(deltas)-1)*np.std(deltas,ddof=1)/math.sqrt(len(deltas)))
        result={'workload':w,'baseline_ms':float(np.exp(np.mean([x['A'] for x in means]))),'candidate_ms':float(np.exp(np.mean([x['B'] for x in means]))),
                'less_time_pct':100*(1-math.exp(center)),'low_pct':100*(1-math.exp(center+margin)),'high_pct':100*(1-math.exp(center-margin)),
                'blocks':a.blocks,'processes_per_revision':a.blocks*2,'iterations':iterations[w]}
        summary.append(result)
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
    for x in summary: print(f"{x['workload']}: {x['less_time_pct']:.2f}% [{x['low_pct']:.2f}, {x['high_pct']:.2f}]",flush=True)

if __name__=='__main__': main()
