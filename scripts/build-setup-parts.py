"""Splits all migrations into numbered parts small enough to paste into the Supabase SQL Editor
one at a time (comments removed, each part in its own transaction, cut between statements).
Usage: python3 scripts/build-setup-parts.py   → supabase/setup/parts/partN.sql"""
import glob, os, re

out = 'supabase/setup/parts'
os.makedirs(out, exist_ok=True)
for f in glob.glob(f'{out}/part*.sql'):
    os.remove(f)
lines = []
for f in sorted(glob.glob('supabase/migrations/*.sql')):
    for line in open(f):
        if re.match(r'^\s*--', line) or not line.strip():
            continue
        lines.append(line.rstrip() + '\n')
chunks, cur, size, in_body = [], [], 0, False
for line in lines:
    cur.append(line); size += len(line)
    if line.count('$$') % 2 == 1:
        in_body = not in_body
    if not in_body and line.rstrip().endswith(';') and size > 26000:
        chunks.append(cur); cur, size = [], 0
if cur:
    chunks.append(cur)
assert not in_body
for i, c in enumerate(chunks, 1):
    with open(f'{out}/part{i}.sql', 'w') as fh:
        fh.write(f'-- BizPilot setup PART {i} of {len(chunks)}. Run parts in order.\nbegin;\n' + ''.join(c) + 'commit;\n')
print(f'{len(chunks)} parts written to {out}')
