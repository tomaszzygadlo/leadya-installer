"""Run a pinned Python helper privately; change Windows creation flags only."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys

if __name__ == '__main__':
    request = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
    original = subprocess.Popen

    class HiddenProcess(original):
        def __init__(self, args, *positional, **keywords):
            if os.name == 'nt':
                keywords['creationflags'] = keywords.get('creationflags', 0) | subprocess.CREATE_NO_WINDOW
                if isinstance(args, (list, tuple)) and Path(str(args[0])).name.lower() in ('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh'):
                    args = [args[0], '-WindowStyle', 'Hidden', *args[1:]]
            super().__init__(args, *positional, **keywords)

    subprocess.Popen = HiddenProcess
    with Path(request['log']).open('x', encoding='utf-8') as private:
        sys.stdout = sys.stderr = private
        sys.argv = [request['script'], *request['arguments']]
        runpy.run_path(request['script'], run_name='__main__')
