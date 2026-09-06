#!/usr/bin/env python3
"""Fetch pinned npm archives; verify registry SHA-512 before selecting resource files.
No package install scripts are executed. Rerun only when intentionally updating the lock.
"""
import base64, hashlib, io, json, pathlib, re, tarfile, urllib.request
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
        wanted = (name == 'katex' and (relative in ['dist/katex.min.css','dist/katex.min.js'] or (relative.startswith('dist/fonts/') and relative.endswith('.woff2')))
                  or name == 'marked' and relative == 'lib/marked.umd.js'
                  or name == 'dompurify' and relative == 'dist/purify.min.js'
                  or relative.lower().startswith('license'))
        if not wanted: continue
        target = output / name / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        content = archive.extractfile(member).read()
        # 应用的 WebKit 使用 WOFF2；保留全部字形和字重，只去掉同字体的旧格式回退。
        # 同步裁剪 CSS，避免引用未打包的文件。
        if name == 'katex' and relative == 'dist/katex.min.css':
            content = re.sub(rb',url\(fonts/[^)]+\.(?:woff|ttf)\) format\("(?:woff|truetype)"\)', b'', content)
        target.write_bytes(content)
    if name == 'katex':
        # 更新已有资源目录时也清理上一次导入留下的重复格式。
        for font in (output/name/'dist/fonts').iterdir():
            if font.suffix in ['.woff', '.ttf']: font.unlink()
    print(name, pin['version'], 'verified and vendored')
