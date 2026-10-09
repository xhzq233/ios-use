#!/usr/bin/env python3
"""Generate typed interposers from the installed SDK, not an application's imports."""
import re
import sys
from pathlib import Path

sdk, output = map(Path, sys.argv[1:])
headers = sdk / 'System/Library/Frameworks/OpenGLES.framework/Headers'
pattern = r'GL_API\s+(.+?)\s+(?:GL_APIENTRY\s+)?(gl[A-Z]\w+)\s*\(([^;]*?)\)\s+OPENGLES_'
functions = {}
for header in ('ES3/gl.h', 'ES3/glext.h', 'ES2/glext.h'):
    for result, name, parameters in re.findall(pattern, (headers / header).read_text()):
        functions.setdefault(name, (result, parameters))
# These extensions have the same call ABI as their ES 3 core equivalents.
aliases = {name: name.removesuffix('APPLE') for name in (
    'glClientWaitSyncAPPLE', 'glDeleteSyncAPPLE', 'glFenceSyncAPPLE',
    'glGetSyncivAPPLE', 'glWaitSyncAPPLE', 'glIsSyncAPPLE',
    'glGetInteger64vAPPLE', 'glRenderbufferStorageMultisampleAPPLE')}
manual = {'glResolveMultisampleFramebufferAPPLE', 'glTexImage2D', 'glDeleteRenderbuffers'}
lines = ['// Generated from SDK declarations by generate_gles_forwarders.py.']
for name, (result, parameters) in sorted(functions.items()):
    if name in manual:
        continue
    arguments = [] if parameters.strip() == 'void' else [
        re.search(r'(\w+)\s*(?:\[.*?\])?$', p.strip()).group(1)
        for p in parameters.split(',')]
    lines += [f'static {result} (*angle_{name})({parameters});',
              f'static {result} forward_{name}({parameters}) {{',
              f'    if (!angle_{name}) missingFunction("{name}");',
              f'    return angle_{name}({", ".join(arguments)});', '}',
              f'INTERPOSE(forward_{name}, {name});']
lines += ['static void loadGLFunctions(void) {']
for name in sorted(functions.keys() - manual):
    symbol = aliases.get(name, name)[2:]
    lines += [f'    angle_{name} = dlsym(angleLibrary, "GL_{symbol}");']
lines += ['}']
output.write_text('\n'.join(lines) + '\n')
print(f'GLES forwarders: {len(functions) - len(manual)} SDK entry points')
