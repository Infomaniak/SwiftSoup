#!/usr/bin/env python3
"""Compare complete release clients using balanced fresh processes; no third-party dependencies."""
import argparse, hashlib, json, math, os, pathlib, random, statistics, subprocess, sys, time

CASES = ['single','first-8','first-256','first-2048','last-256','last-2048','first-mixed','fallback','parse-endpoints','parse-control']
T95 = {2:12.706204736,3:4.302652730,4:3.182446305,5:2.776445105,6:2.570581836,7:2.446911851,8:2.364624252,9:2.306004135,10:2.262157163,11:2.228138852,12:2.200985160,13:2.178812830,14:2.160368656,15:2.144786688,16:2.131449546}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for k in ['baseline-client','candidate-client','baseline-library','candidate-library','output']: ap.add_argument('--'+k,required=True)
    ap.add_argument('--blocks',type=int,choices=range(2,17),default=8)
    ap.add_argument('--ms',type=float,default=160)
    ap.add_argument('--cpu',type=int)
    ap.add_argument('--aa',action='store_true')
    ap.add_argument('--cases',default=','.join(CASES))
    args=ap.parse_args()
    if args.ms < 40: ap.error('--ms must be at least 40')
    names=args.cases.split(',')
    if not names or any(n not in CASES for n in names): ap.error('unknown/empty case set')
    if args.cpu is not None and hasattr(os,'sched_setaffinity'): os.sched_setaffinity(0,{args.cpu})
    root=pathlib.Path(args.output); root.mkdir(parents=True,exist_ok=False)
    binaries={'A':str(pathlib.Path(args.baseline_client).resolve()),'B':str(pathlib.Path(args.candidate_client).resolve())}
    libraries={'A':str(pathlib.Path(args.baseline_library).resolve()),'B':str(pathlib.Path(args.candidate_library).resolve())}
    if args.aa: binaries['B']=binaries['A']; libraries['B']=libraries['A']
    def run(side, case, iterations=None):
        env=os.environ.copy(); env['DYLD_LIBRARY_PATH' if sys.platform=='darwin' else 'LD_LIBRARY_PATH']=libraries[side]
        cmd=[binaries[side],case]+([] if iterations is None else [str(iterations)])
        proc=subprocess.run(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120,check=True)
        if proc.stderr: (root/'stderr.log').open('ab').write(proc.stderr)
        if iterations is None: return proc.stdout
        row=json.loads(proc.stdout)
        if row['case']!=case or row['iterations']!=iterations or row['checksum']!=row['expected']*iterations or row['ns']<=0: raise RuntimeError('invalid timing/consumption record')
        return row
    for side in ['A','B']: (root/f'outputs-{side}.json').write_bytes(run(side,'--verify'))
    assert (root/'outputs-A.json').read_bytes()==(root/'outputs-B.json').read_bytes(), 'Output differs'
    manifest={'args':vars(args),'binaries':binaries,'libraries':libraries,'python':sys.version,'platform':sys.platform,'timestamp':time.time(),'cpu_affinity':sorted(os.sched_getaffinity(0)) if hasattr(os,'sched_getaffinity') else None,'sha256':{k:hashlib.sha256(pathlib.Path(v).read_bytes()).hexdigest() for k,v in binaries.items()},'output_sha256':hashlib.sha256((root/'outputs-A.json').read_bytes()).hexdigest()}
    (root/'manifest.json').write_text(json.dumps(manifest,indent=2))
    counts={}; calibration=[]; expected={}
    for case in names:
        for side in ['A','B']:
            n=1
            while True:
                row=run(side,case,n); calibration.append(dict(row,side=side)); expected[(side,case)]=row['expected']
                if row['ns']>=30_000_000 or n>=20_000_000: break
                n=min(20_000_000,n*max(2,min(8,math.ceil(30_000_000/row['ns']))))
            n=max(1,min(20_000_000,round(n*args.ms*1_000_000/row['ns'])))
            row=run(side,case,n); calibration.append(dict(row,side=side,validation=True))
            if row['ns'] < args.ms*600_000 and n<20_000_000:
                n=min(20_000_000,math.ceil(n*args.ms*1_000_000/row['ns']))
                calibration.append(dict(run(side,case,n),side=side,validation=True))
            counts[(side,case)]=n
        assert expected[('A',case)]==expected[('B',case)], 'Checksum expectation differs'
    (root/'calibration.json').write_text(json.dumps(calibration,indent=2))
    rng=random.Random(36936); records=[]
    with (root/'raw.jsonl').open('w') as out:
        for block in range(args.blocks):
            shuffled=names.copy(); rng.shuffle(shuffled)
            order='ABBA' if block%2==0 else 'BAAB'
            for case in shuffled:
                for slot,side in enumerate(order):
                    row=dict(run(side,case,counts[(side,case)]),side=side,block=block,slot=slot)
                    assert row['expected']==expected[(side,case)]
                    records.append(row); out.write(json.dumps(row)+'\n'); out.flush()
            print(f'completed block {block+1}/{args.blocks}',flush=True)
    summary=[]
    for case in names:
        data=[r for r in records if r['case']==case]
        logs={side:[math.log(r['ns']/r['iterations']/1e6) for r in data if r['side']==side] for side in ['A','B']}
        differences=[]
        for block in range(args.blocks):
            byside={side:[math.log(r['ns']/r['iterations']) for r in data if r['side']==side and r['block']==block] for side in ['A','B']}
            assert len(byside['A'])==len(byside['B'])==2
            differences.append(statistics.mean(byside['B'])-statistics.mean(byside['A']))
        mean=statistics.mean(differences); margin=T95[args.blocks]*statistics.stdev(differences)/math.sqrt(args.blocks)
        row={'case':case,'baseline_ms':math.exp(statistics.mean(logs['A'])),'candidate_ms':math.exp(statistics.mean(logs['B'])),'less_time_percent':100*(1-math.exp(mean)),'ci95_less_time_percent':[100*(1-math.exp(mean+margin)),100*(1-math.exp(mean-margin))],'batch_ms_range':[min(r['ns']/1e6 for r in data),max(r['ns']/1e6 for r in data)],'blocks':args.blocks}
        summary.append(row)
        print(json.dumps(row),flush=True)
    (root/'summary.json').write_text(json.dumps(summary,indent=2))

if __name__=='__main__': main()
