#!/usr/bin/env python3
"""notice.py XML_DIR OUT: collect every Wayland protocol definition's
<copyright> block into one notice file.

A Linux build carries bindings generated from these definitions, and each
asks that its notice go with copies of it; baldr.notices() embeds the file
this writes (baldr/notices.odin), and every_wayland_protocols_notice_is_passed_on
fails if a definition is missing from it. gen.sh runs this after copying the
XML files, so a protocol added or bumped there is in the notice too.
"""
import glob
import os
import re
import sys
import textwrap

xml_dir, out_path = sys.argv[1], sys.argv[2]
out = [
    'Wayland protocol definitions',
    '============================',
    '',
    "Baldr's Wayland backend speaks these protocols through bindings generated",
    'from their definitions (platform/wayland/wl/xml/, by tools/wl_scanner). A',
    'Linux build carries those bindings, and each definition asks that its notice',
    'go with copies of it. Here they are, as each file states them.',
    '',
]
for f in sorted(glob.glob(os.path.join(xml_dir, '*.xml'))):
    s = open(f, encoding='utf-8').read()
    m = re.search(r'<copyright>(.*?)</copyright>', s, re.S)
    if not m:
        sys.exit(f'{f}: no <copyright> block, so no notice to carry: check its licence by hand')
    body = textwrap.dedent(m.group(1).strip('\n')).strip()
    for a, b in (('&lt;', '<'), ('&gt;', '>'), ('&quot;', '"'), ('&#169;', '©'), ('&amp;', '&')):
        body = body.replace(a, b)
    out += ['-' * 72, os.path.basename(f), '-' * 72, '', body, '']
open(out_path, 'w', encoding='utf-8').write('\n'.join(out))
