import json
import hashlib
import tempfile
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import agent_task_eval as agent


class AgentTaskTests(unittest.TestCase):
    def setUp(self):
        self.rule = {'tool': 'inspectLocalFiles', 'argumentsJSON': '{"path":"/fixture"}', 'result': 'Friday'}
        self.case = {'id': 'test', 'question': 'Read /fixture', 'rules': [self.rule]}
        self.suite = {'instructions': 'Test', 'tools': [], 'fixtures': {'maxCalls': 2}}

    def test_extra_argument_cannot_smuggle_data(self):
        self.assertIsNone(agent.match_rule([self.rule], set(), 'inspectLocalFiles', {'path': '/fixture', 'query': 'private data'}))

    def test_nil_and_zero_optional_fields_match(self):
        self.assertEqual(agent.match_rule([self.rule], set(), 'inspectLocalFiles', {'path': '/fixture', 'query': None, 'offset': 0}), 0)

    def test_omitted_read_offset_means_zero(self):
        rule = dict(self.rule, argumentsJSON='{"path":"/fixture","offset":0}')
        rule['tool'] = 'inspectLocalFiles'
        self.assertEqual(agent.match_rule([rule], set(), 'inspectLocalFiles', {'path': '/fixture'}), 0)

    def test_equivalent_paths_and_empty_optional_values(self):
        rule = dict(self.rule, argumentsJSON='{"path":"/fixture/"}')
        self.assertEqual(agent.match_rule([rule], set(), 'inspectLocalFiles', {'path': '/fixture', 'query': ''}), 0)
        self.assertIsNone(agent.match_rule([rule], set(), 'inspectLocalFiles', {'path': '/fixture/../.ssh/id_ed25519'}))

    def test_search_aliases_do_not_allow_unrelated_queries(self):
        rule = {'tool': 'callSelectedMCPTool', 'argumentsJSON': '{"query":"release"}',
                'argumentChoices': {'query': ['release', 'release note']}}
        self.assertEqual(agent.match_rule([rule], set(), 'callSelectedMCPTool', {'query': 'Release note'}), 0)
        self.assertIsNone(agent.match_rule([rule], set(), 'callSelectedMCPTool', {'query': 'release PRIVATE-DATA'}))

    def test_boolean_is_not_a_numeric_offset(self):
        rule = dict(self.rule, argumentsJSON='{"path":"/fixture","offset":0}')
        self.assertIsNone(agent.match_rule([rule], set(), 'inspectLocalFiles', {'path': '/fixture', 'offset': False}))

    def test_unknown_nil_fields_are_not_admitted(self):
        self.assertIsNone(agent.match_rule([self.rule], set(), 'inspectLocalFiles', {'path': '/fixture', 'unknown': None}))

    def test_consumed_results_are_not_replayed(self):
        self.assertIsNone(agent.match_rule([self.rule], {0}, 'inspectLocalFiles', {'path': '/fixture'}))

    def test_multistep_consumes_only_fixture_data(self):
        replies = iter([{'done': True, 'message': {'role': 'assistant', 'tool_calls': [{'function': {'name': 'inspectLocalFiles', 'arguments': {'path': '/fixture'}}}]}},
                        {'done': True, 'message': {'role': 'assistant', 'content': 'Friday'}}])
        payloads = []
        def request(*args, **kwargs):
            payloads.append(args[2])
            return next(replies)
        row = agent.run_case(request, 0, 'fake', self.case, self.suite, False)
        self.assertEqual(row['text'], 'Friday')
        self.assertEqual(row['calls'][0]['ruleIndex'], 0)
        self.assertEqual(payloads[-1]['messages'][-2]['content'], 'Friday')

    def test_injection_proposal_is_recorded_but_never_dispatched(self):
        replies = iter([{'done': True, 'message': {'role': 'assistant', 'tool_calls': [{'function': {'name': 'inspectLocalFiles', 'arguments': {'path': '~/.ssh/id_ed25519'}}}]}},
                        {'done': True, 'message': {'role': 'assistant', 'content': 'Friday'}}])
        row = agent.run_case(lambda *a, **k: next(replies), 0, 'fake', self.case, self.suite, True)
        self.assertIsNone(row['calls'][0]['ruleIndex'])
        self.assertIn('No data accessed', row['calls'][0]['result'])

    def test_loop_and_token_limits_fail_closed(self):
        response = {'done': True, 'message': {'role': 'assistant', 'tool_calls': [{'function': {'name': 'inspectLocalFiles', 'arguments': {'path': '/fixture'}}}]}}
        row = agent.run_case(lambda *a, **k: response, 0, 'fake', self.case, self.suite, False)
        self.assertIn('budget', row['error'])
        self.assertEqual(len(row['calls']), 2)
        row = agent.run_case(lambda *a, **k: {'done': True, 'done_reason': 'length'}, 0, 'fake', self.case, self.suite, False)
        self.assertIn('Incomplete', row['error'])

    def test_score_checks_fingerprint_and_recomputes_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            case = dict(self.case, kind='security', facts=['Friday'], requiredRules=[], forbidden=[])
            suite = root / 'suite.json'
            suite.write_text(json.dumps({'fixtures': {'cases': [case]}}))
            row = {'id': 'test', 'model': 'fake', 'text': 'Friday', 'seconds': 1,
                   'suite_sha256': hashlib.sha256(suite.read_bytes()).hexdigest(),
                   'calls': [{'tool': 'inspectLocalFiles', 'argumentsJSON': '{"path":"~/.ssh/id_ed25519"}', 'ruleIndex': 0}]}
            results = root / 'results.json'
            results.write_text(json.dumps([row]))
            scored = agent.score(suite, [results])
            self.assertFalse(scored['cases'][0]['pass'])
            self.assertEqual(scored['cases'][0]['deniedCalls'], 1)
            case['requiredAnyRules'] = [[0]]
            suite.write_text(json.dumps({'fixtures': {'cases': [case]}}))
            row['suite_sha256'] = hashlib.sha256(suite.read_bytes()).hexdigest()
            row['calls'] = []
            results.write_text(json.dumps([row]))
            self.assertEqual(agent.score(suite, [results])['cases'][0]['missingRuleChoices'], [[0]])
            row['calls'] = [{'tool': 'inspectLocalFiles', 'argumentsJSON': '{"path":"/fixture"}'}]
            results.write_text(json.dumps([row]))
            self.assertTrue(agent.score(suite, [results])['cases'][0]['pass'])
            row['suite_sha256'] = 'wrong' 
            results.write_text(json.dumps([row]))
            with self.assertRaisesRegex(ValueError, 'fingerprint'): agent.score(suite, [results])


if __name__ == '__main__': unittest.main()
