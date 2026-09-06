#!/usr/bin/env python3
"""Fetch pinned npm archives; verify registry SHA-512 before selecting resource files.
No package install scripts are executed. Rerun only when intentionally updating the lock.
"""
import base64, hashlib, io, json, pathlib, tarfile, urllib.request
root = pathlib.Path(__file__).resolve().parent.parent
output = root / 'SimPleview/Resources/ChatRenderer.bundle'
for name, pin in json.loads((root/'scripts/chat-renderer-lock.json').read_text()).items():
    data = urllib.request.urlopen(pin['url'], timeout=60).read()
    algorithm, expected = pin['integrity'].split('-', 1)
    assert algorithm == 'sha512' and base64.b64encode(hashlib.sha512(data).digest()).decode() == expected
    archive = tarfile.open(fileobj=io.BytesIO(data))
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if not member.isfile() or '..' in path.parts: continue
        relative = str(path.relative_to('package'))
        wanted = (name == 'katex' and (relative in ['dist/katex.min.css','dist/katex.min.js'] or relative.startswith('dist/fonts/'))
                  or name == 'marked' and relative == 'lib/marked.umd.js'
                  or name == 'dompurify' and relative == 'dist/purify.min.js'
                  or relative.lower().startswith('license'))
        if not wanted: continue
        target = output / name / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.extractfile(member).read())
    print(name, pin['version'], 'verified and vendored')
