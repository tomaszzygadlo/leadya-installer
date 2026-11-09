"""Run a pinned Python helper privately; change Windows creation flags only."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import traceback

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
    exit_code = 0
    with Path(request['log']).open('x', encoding='utf-8') as private:
        previous_stdout, previous_stderr = sys.stdout, sys.stderr
        try:
            sys.stdout = sys.stderr = private
            sys.argv = [request['script'], *request['arguments']]
            # Match direct script execution, including the canonical gate's sibling imports.
            sys.path.insert(0, str(Path(request['script']).resolve().parent))
            runpy.run_path(request['script'], run_name='__main__')
        except SystemExit as stopped:
            exit_code = stopped.code if isinstance(stopped.code, int) else 0 if stopped.code is None else 1
            if stopped.code is not None and not isinstance(stopped.code, int):
                print(str(stopped.code), file=private)
        except BaseException:
            traceback.print_exc(file=private)
            exit_code = 1
        finally:
            sys.stdout, sys.stderr = previous_stdout, previous_stderr
    raise SystemExit(exit_code)
