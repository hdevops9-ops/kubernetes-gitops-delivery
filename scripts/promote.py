"""Change only a reviewed immutable image and release version in GitOps values."""
import argparse
import re
from pathlib import Path
import yaml

def promote(path, repository, digest, version):
    if not re.fullmatch(r"sha256:[a-f0-9]{64}",digest) or digest == "sha256:"+"0"*64:
        raise ValueError("a real SHA256 image digest is required")
    if not re.fullmatch(r"[a-z0-9./_:-]+",repository): raise ValueError("invalid repository")
    if not re.fullmatch(r"[a-zA-Z0-9._-]{1,80}",version): raise ValueError("invalid release version")
    data=yaml.safe_load(Path(path).read_text())
    data['image']={'repository':repository,'digest':digest,'pullPolicy':'IfNotPresent'}
    data['release']={'version':version}
    Path(path).write_text(yaml.safe_dump(data,sort_keys=False))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('environment',choices=['dev','production']);p.add_argument('repository');p.add_argument('digest');p.add_argument('version');args=p.parse_args()
    promote(f'environments/{args.environment}/values.yaml',args.repository,args.digest,args.version)
