#!/usr/bin/env python3
"""Validate matched inputs and summarize synthetic runtime measurements."""
import argparse,json,pathlib,statistics,re
p=argparse.ArgumentParser();p.add_argument('results',type=pathlib.Path);a=p.parse_args()
expected=None;summary=[]
for arm in ['ollama-q8','direct-q8','direct-f16','ollama-f16','mlx']:
 path=a.results/(arm+'.json')
 if not path.exists():continue
 rows=json.loads(path.read_text());warm=[r for r in rows if not r['model_cold']]
 if len(warm)!=12:raise ValueError(f'{arm}: incomplete ({len(warm)} warm rows)')
 keys={(r['repeat'],r['case']):r['prompt_sha256'] for r in rows}
 if len(keys)!=13:raise ValueError('Duplicate or missing samples')
 if expected is None:expected=keys
 elif expected!=keys:raise ValueError('Prompt mismatch: '+arm)
 def passed(r):
  raw=r['raw'];ans=raw.rsplit('</think>',1)[-1] if '</think>' in raw else ''
  if r.get('finish_reason') in ('length','limit'):return False
  if r['case']=='chat':return (ans.lstrip().startswith('#') or ans.lstrip().startswith('**')) and len(re.findall(r'(?m)^\s*[-*] ',ans))==2 and 'phish' in ans.lower()
  if r['case']=='context':return 'AMBER-742' in ans and 'Mira' in ans
  if r['case']=='tool':
   calls=re.findall(r'<tool_call>(.*?)</tool_call>',ans,re.S)
   return len(calls)==1 and bool(re.fullmatch(r'\s*getMacContext\s*<arg_key>topic</arg_key>\s*<arg_value>"?battery"?</arg_value>\s*',calls[0]))
  return '73' in ans and '<tool_call>' not in ans
 cases={}
 for name in ['chat','context','tool','tool-result']:
  rs=[r for r in warm if r['case']==name]
  cases[name]={'median_seconds':statistics.median(r['seconds'] for r in rs),'range_seconds':[min(r['seconds'] for r in rs),max(r['seconds'] for r in rs)],'median_first_answer_seconds':statistics.median(r['first_answer_seconds'] for r in rs if r['first_answer_seconds'] is not None) if any(r['first_answer_seconds'] is not None for r in rs) else None,'median_output_tokens':statistics.median(r['generated_tokens'] for r in rs),'passed':sum(passed(r) for r in rs),'samples':len(rs)}
 cold=rows[0]
 row={'arm':arm,'passed':sum(passed(r) for r in warm),'samples':len(warm),'median_generation_tps':statistics.median(r['generation_tps'] for r in warm),'startup_plus_first_request_seconds':cold['startup_plus_request_seconds'],'cases':cases,'max_reported_gpu_bytes':max((r.get('peak_gpu_bytes',0) or max([m['size_vram'] for m in r.get('model_memory',{}).get('models',[])]+[0])) for r in rows),'max_process_tree_rss_bytes':max(r.get('process_tree_rss_bytes',0) for r in rows)}
 summary.append(row)
(a.results/'summary.json').write_text(json.dumps(summary,indent=2))
print('| Runtime/cache | Chat | Context | Tool proposal | Tool result | Decode tok/s | Checks |')
print('|---|---:|---:|---:|---:|---:|---:|')
for r in summary:
 print('| '+r['arm']+' | '+' | '.join(f"{r['cases'][c]['median_seconds']:.2f}s" for c in ['chat','context','tool','tool-result'])+f" | {r['median_generation_tps']:.1f} | {r['passed']}/{r['samples']} |")
