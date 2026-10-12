"""The qualification harness must reject tampered artifacts and truncated output."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('qualification', Path(__file__).resolve().parents[1] / 'scripts/eval-local-models.py')
qualification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qualification)


class QualificationTests(unittest.TestCase):
    def test_glm_import_preserves_chat_and_tool_protocol(self):
        definition = qualification.model_definition(Path('/trial weights/glm.gguf'), qualification.MODELS['glm-4.7-flash'])
        self.assertIn('FROM "/trial weights/glm.gguf"\n', definition)
        self.assertIn('RENDERER glm-4.7\n', definition)
        self.assertIn('PARSER glm-4.7\n', definition)
        self.assertIn('PARAMETER repeat_penalty 1\n', definition)

    def test_rejects_runtime_cache_redirected_outside_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / 'evaluation'
            runtime = workspace / 'isolated-runtime'
            runtime.mkdir(parents=True)
            other_cache = root / 'other-cache'
            other_cache.mkdir()
            (runtime / 'models').symlink_to(other_cache, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'escapes the workspace'):
                qualification.validate_runtime_directory(workspace)

    def test_rejects_tampered_weight_with_same_length(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'model.gguf'
            expected = {'size': 4, 'sha256': hashlib.sha256(b'GGUF').hexdigest()}
            path.write_bytes(b'GGUF')
            qualification.verify(path, expected)
            path.write_bytes(b'EVIL')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                qualification.verify(path, expected)

    def test_rejects_incomplete_download(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'model.gguf'
            path.write_bytes(b'GG')
            with self.assertRaisesRegex(ValueError, 'size/type'):
                qualification.verify(path, {'size': 4, 'sha256': 'unused'})

    def test_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / 'original'
            original.write_bytes(b'GGUF')
            link = Path(directory) / 'model.gguf'
            link.symlink_to(original)
            with self.assertRaisesRegex(ValueError, 'size/type'):
                qualification.verify(link, {'size': 4, 'sha256': hashlib.sha256(b'GGUF').hexdigest()})

    def test_rejects_output_cut_at_token_limit(self):
        with patch.object(qualification, 'request', return_value={'done': True, 'done_reason': 'length'}):
            with self.assertRaisesRegex(ValueError, 'Incomplete'):
                qualification.infer(12345, 'test', [])

    def test_rejects_redirect_to_remote_inference(self):
        with self.assertRaisesRegex(ValueError, 'must not redirect'):
            qualification.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.com')


if __name__ == '__main__':
    unittest.main()
