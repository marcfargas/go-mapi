"""Actual service stdin and MCP process lifetime checks; CUA tools are a local double."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).parent
MCP = r'''
import json, os, sys
for line in sys.stdin:
    msg=json.loads(line)
    if 'id' not in msg: continue
    if msg['method']=='initialize': result={'serverInfo':{'name':'process-fixture','pid':os.getpid()}}
    elif msg['method']=='tools/list': result={'tools':[{'name':name,'inputSchema':{'type':'object'}} for name in ('list_windows','get_window_state','click','launch_app')]}
    elif msg['method']=='tools/call' and msg['params']['name']=='launch_app': result={'structuredContent':{'pid':os.getpid(),'running':True}}
    else: result={'content':[]}
    print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':result}),flush=True)
'''
SERVICE = r'''
import sys
sys.path.insert(0,sys.argv[1])
import hosted_cua_prompt as module
RealMcp=module.Mcp
module.Mcp=lambda binary,session,env,evidence: RealMcp([sys.executable,sys.argv[2]],session,env,evidence)
raise SystemExit(module.main(sys.argv[3:]))
'''

class ActualServiceProcessTests(unittest.TestCase):
    def run_case(self, mode):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/'private').mkdir(); (root/'rdpilot-mcp.exe').touch(); (root/'rdpilot-mcp').touch()
            (root/'import.ps1').write_text('synthetic source fixture; never executed')
            (root/'mcp.py').write_text(MCP); (root/'service.py').write_text(SERVICE)
            args=[sys.executable,str(root/'service.py'),str(HERE.resolve()),str(root/'mcp.py'),
                  '--service','--bin-dir',str(root),'--runtime-root',str(root/'private'),
                  '--expected-name','Ticket569-Root-Prompt-'+('a'*32),'--run-id','a'*32,
                  '--job-start-counter','100','--counter-frequency','1000','--source-sha','b'*40,'--thumbprint','C'*40,'--expected-sid','S-1-5-21-1-2-3-1001',
                  '--expected-session-id','1','--supervisor-pipe','Ticket569-'+('a'*32)+'-helper',
                  '--certificate-path',str(root/'cert'),'--import-script',str(root/'import.ps1'),
                  '--observer-script',str(root/'observer.ps1'),'--observer-attached',str(root/'attached'),
                  '--observer-exit',str(root/'exit'),'--observer-failure',str(root/'failure'),
                  '--import-result',str(root/'result'),'--evidence',str(root/'evidence.json')]
            proc=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                # communicate with a separate reader so an implementation hang has a bound.
                import concurrent.futures
                pool=concurrent.futures.ThreadPoolExecutor(max_workers=1)
                future=pool.submit(proc.stdout.readline)
                ready=json.loads(future.result(timeout=8));pool.shutdown(wait=False)
                self.assertEqual(ready['op'],'ready')
                mcp_pid=ready['nativeMcp']['serverInfo']['pid']
                if mode in ('launch','repeated-launch'):
                    proc.stdin.write('{"op":"launch"}\n');proc.stdin.flush()
                    pool=concurrent.futures.ThreadPoolExecutor(max_workers=1)
                    launch=json.loads(pool.submit(proc.stdout.readline).result(timeout=8));pool.shutdown(wait=False)
                    self.assertEqual(launch['op'],'importer-launched');self.assertEqual(launch['receipt']['pid'],mcp_pid)
                    if mode=='repeated-launch':
                        proc.stdin.write('{"op":"launch"}\n');proc.stdin.flush()
                    else:
                        proc.stdin.write('{"op":"status"}\n{"op":"stop"}\n');proc.stdin.flush()
                elif mode=='stop':
                    proc.stdin.write('{"op":"status"}\n{"op":"stop"}\n');proc.stdin.flush()
                elif mode=='eof':
                    proc.stdin.close();proc.stdin=None
                else:
                    # Kill the actual advertised MCP participant while service stdin stays open.
                    if os.name=='nt': subprocess.run(['taskkill','/PID',str(mcp_pid),'/F'],check=True,capture_output=True)
                    else:
                        import signal
                        os.kill(mcp_pid,signal.SIGKILL)
                if mode=='death':
                    # Do not close service stdin through communicate: it must notice MCP death itself.
                    proc.wait(timeout=8)
                output,error=proc.communicate(timeout=8)
                if mode in ('stop','launch'):
                    self.assertEqual(proc.returncode,0,error)
                    messages=[json.loads(line) for line in output.splitlines()]
                    self.assertTrue(messages[0]['mcpAlive']);self.assertEqual(messages[-1]['op'],'stopped')
                else:
                    self.assertNotEqual(proc.returncode,0)
                    evidence=json.loads((root/'evidence.json').read_text());self.assertEqual(evidence['status'],'harness-defect');self.assertIn('session-owner',evidence['fault'])
                if os.name!='nt':
                    with self.assertRaises(ProcessLookupError): os.kill(mcp_pid,0)
            finally:
                if proc.poll() is None: proc.kill()
                proc.communicate(timeout=8)
    def test_actual_service_emits_pinned_launch_receipt_before_run(self): self.run_case('launch')
    def test_actual_service_rejects_repeated_importer_launch(self): self.run_case('repeated-launch')
    def test_explicit_stop_exits_service_and_actual_mcp(self): self.run_case('stop')
    def test_real_stdin_eof_is_failure_and_stops_actual_mcp(self): self.run_case('eof')
    def test_actual_mcp_death_is_detected_without_another_command(self): self.run_case('death')

if __name__=='__main__': unittest.main()
