#!/usr/bin/env python3
"""Synthetic agent task loops. This module never dispatches a real host/MCP tool."""
import argparse
import hashlib
import json
import posixpath
import re
import statistics
import time
from pathlib import Path


OPTIONAL_FIELDS = {"inspectLocalFiles": {"query", "offset"}, "getMacContext": {"timeZone"},
                   "callSelectedMCPTool": {"query", "recordID", "cursor"}}

def normalize_arguments(tool, arguments):
    arguments = dict(arguments)
    if tool == 'inspectLocalFiles' and isinstance(arguments.get('path'), str) and arguments['path'].startswith('/'):
        arguments['path'] = posixpath.normpath(arguments['path'])
    for key in OPTIONAL_FIELDS.get(tool, set()):
        if arguments.get(key) == '': arguments[key] = None
    return arguments


def same_value(actual, expected):
    if isinstance(actual, bool) or isinstance(expected, bool):
        return type(actual) is type(expected) and actual == expected
    return actual == expected

def match_rule(rules, consumed, tool, arguments):
    arguments = normalize_arguments(tool, arguments)
    if tool == "inspectLocalFiles" and arguments.get("offset") is None:
        arguments["offset"] = 0
    for index, rule in enumerate(rules):
        if index in consumed or rule['tool'] != tool:
            continue
        expected = normalize_arguments(tool, json.loads(rule['argumentsJSON']))
        if all(same_value(arguments.get(k), v) or (isinstance(arguments.get(k), str) and arguments[k].strip().lower() in rule.get('argumentChoices', {}).get(k, [])) for k, v in expected.items()) and all(
            k in expected or (k in OPTIONAL_FIELDS.get(tool, set()) and (v is None or (k == 'offset' and type(v) in (int, float) and v == 0))) for k, v in arguments.items()
        ):
            return index
    return None


def run_case(request, port, tag, case, suite, thinking):
    messages = [{'role': 'system', 'content': suite['instructions']}, {'role': 'user', 'content': case['question']}]
    calls, consumed, generations = [], set(), []
    started = time.monotonic()
    row = {'id': case['id'], 'text': '', 'calls': calls, 'generations': generations}
    try:
        for _ in range(suite['fixtures']['maxCalls'] + 1):
            response = request(port, 'chat', {'model': tag, 'messages': messages, 'tools': suite['tools'],
                'think': thinking, 'stream': False, 'keep_alive': '5m',
                'options': {'temperature': 0, 'seed': 42, 'num_ctx': 8192, 'num_predict': 2200}}, timeout=120)
            if not response.get('done') or response.get('done_reason') == 'length':
                raise ValueError('Incomplete model response')
            message = response['message']
            generations.append({'tokens': response.get('eval_count'), 'load_seconds': response.get('load_duration', 0) / 1e9,
                'thinking': message.get('thinking', ''), 'content': message.get('content', '')})
            messages.append(message)
            proposed = message.get('tool_calls', [])
            if not proposed:
                row['text'] = message.get('content', '')
                break
            for call in proposed:
                if len(calls) >= suite['fixtures']['maxCalls']:
                    raise ValueError('Tool-call budget exhausted')
                name = call['function']['name']
                arguments = call['function']['arguments']
                if not isinstance(arguments, dict):
                    raise ValueError('Tool arguments must be an object')
                index = match_rule(case['rules'], consumed, name, arguments)
                if index is None:
                    result = '{"error":"Denied: this call is outside the authorized fixture task. No data accessed."}'
                else:
                    consumed.add(index)
                    result = case['rules'][index]['result']
                calls.append({'tool': name, 'argumentsJSON': json.dumps(arguments), 'result': result, 'ruleIndex': index})
                messages.append({'role': 'tool', 'tool_name': name, 'content': result, 'tool_call_id': call.get('id', '')})
        else:
            raise ValueError('Generation budget exhausted')
    except (OSError, ValueError, KeyError, TypeError) as error:
        row['error'] = str(error)
    row['seconds'] = time.monotonic() - started
    return row


def run_suite(request, save, port, tag, model, path, modes):
    data = path.read_bytes()
    suite = json.loads(data)
    digest = hashlib.sha256(data).hexdigest()
    for thinking in modes:
        name = model + ('-thinking' if thinking else '-direct')
        rows = []
        for case in suite['fixtures']['cases']:
            row = run_case(request, port, tag, case, suite, thinking)
            row.update(model=name, suite_sha256=digest)
            rows.append(row)
            save(path.parent / ('agent-' + name + '.json'), rows)
            print(f"Agent {name}: {case['id']} {row['seconds']:.2f}s {row.get('error', '')}", flush=True)


def score(suite_path, result_paths):
    data = suite_path.read_bytes()
    suite = json.loads(data)
    digest = hashlib.sha256(data).hexdigest()
    cases = {c['id']: c for c in suite['fixtures']['cases']}
    results = []
    for path in result_paths:
        rows = json.loads(path.read_text())
        if len(rows) != len(cases) or {r['id'] for r in rows} != cases.keys():
            raise ValueError('Incomplete or duplicate case set: ' + str(path))
        for row in rows:
            if row['suite_sha256'] != digest:
                raise ValueError('Suite fingerprint mismatch')
            case = cases[row['id']]
            missing = [p for p in case['facts'] if not re.search(p, row['text'], re.I)]
            forbidden = [p for p in case['forbidden'] if re.search(p, row['text'], re.I)]
            # Recompute admission; never trust a model or result file's pass labels.
            used = set()
            denied = []
            for call in row['calls']:
                index = match_rule(case['rules'], used, call['tool'], json.loads(call['argumentsJSON']))
                if index is None: denied.append(call)
                else: used.add(index)
            missing_tools = sorted(set(case['requiredRules']) - used)
            missing_choices = [group for group in case.get('requiredAnyRules', []) if not used.intersection(group)]
            passed = not (row.get('error') or missing or forbidden or denied or missing_tools or missing_choices) and bool(row['text'].strip())
            results.append({'model': row['model'], 'id': row['id'], 'kind': case['kind'], 'pass': passed,
                'missingFacts': missing, 'forbiddenText': forbidden, 'deniedCalls': len(denied),
                'missingRules': missing_tools, 'missingRuleChoices': missing_choices, 'error': row.get('error'), 'seconds': row['seconds']})
    summary = []
    for model in sorted({r['model'] for r in results}):
        group = [r for r in results if r['model'] == model]
        times = sorted(r['seconds'] for r in group)
        summary.append({'model': model, 'passed': sum(r['pass'] for r in group), 'total': len(group),
            'errors': sum(bool(r['error']) for r in group), 'deniedCalls': sum(r['deniedCalls'] for r in group),
            'medianSeconds': statistics.median(times), 'p95Seconds': times[int((len(times)-1)*.95)],
            'maximumSeconds': max(times)})
    return {'suite_sha256': digest, 'summary': summary, 'cases': results}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', type=Path, required=True)
    parser.add_argument('--results', type=Path, nargs='+', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = score(args.suite, args.results)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['summary'], indent=2))
