import tempfile
import unittest
from pathlib import Path
import yaml
from promote import promote

class PromotionTests(unittest.TestCase):
    def test_preserves_unrelated_values(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'values.yaml';p.write_text('replicaCount: 3\nimage: {}\nrelease: {}\n')
            promote(p,'ghcr.io/owner/api','sha256:'+'a'*64,'sha-123')
            obj=yaml.safe_load(p.read_text());self.assertEqual(obj['replicaCount'],3);self.assertEqual(obj['release']['version'],'sha-123')
    def test_rejects_tag_or_unpromoted_digest(self):
        for digest in ['latest','sha256:'+'0'*64]:
            with self.assertRaises(ValueError):promote('unused','ghcr.io/owner/api',digest,'v1')
if __name__=='__main__':unittest.main()
