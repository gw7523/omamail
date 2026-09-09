#!/usr/bin/env python3
"""Exercise the native-agent bridge using synthetic context and local fake tools."""
import importlib.util
import json
import os
import fcntl
import pty
import termios
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/agent-job.py'


class Bridge(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, XDG_STATE_HOME=str(self.root / 'state'), PATH=str(self.bin) + ':' + os.environ['PATH'])
        self.store = self.root / 'state/omamail/assistant'
        self.tool('omarchy-default-agent', 'print("fake")')
        self.tool('omarchy-launch-tui', 'import os,sys\nos.execvp(sys.argv[2],sys.argv[2:])')
        self.tool('omarchy-agent', '''import os,sys,time,json
from pathlib import Path
Path('argv.json').write_text(json.dumps(Path('/proc/self/cmdline').read_bytes().decode().split('\\0')))
Path('response.tmp').write_text('Suggestion: مرحبا\\n"quoted" \\\\ text')
os.chmod('response.tmp',0o600)
os.replace('response.tmp','response.txt')
time.sleep(0.4)
''')
        self.ids = []
        self.addCleanup(self.cancel_all)

    def tool(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\n' + body + '\n')
        path.chmod(0o700)

    def call(self, *args, value=None, ok=True):
        process = subprocess.run(['python3', str(SCRIPT), *args], input=json.dumps(value) if value is not None else None, text=True, capture_output=True, env=self.env, timeout=8)
        if ok:
            self.assertEqual(process.returncode, 0, process.stderr)
        else:
            self.assertNotEqual(process.returncode, 0)
        return json.loads(process.stdout) if process.stdout else process.stderr

    def new(self, **fields):
        data = dict(accountId='imap:synthetic@example.test', account='synthetic@example.test', messageId='41:INBOX', subject='Synthetic', prompt='SECRET-PROMPT rewrite', message='SECRET-MAIL مرحبا\n$(touch forbidden) `echo x` "quoted" \\')
        data.update(fields)
        job = self.call('new', value=data)
        self.ids.append(job['id'])
        return job['id']

    def wait(self, ident, states=('done','failed','cancelled')):
        for _ in range(80):
            shown = self.call('show', ident)
            if shown['job']['state'] in states:
                return shown
            time.sleep(.05)
        self.fail('Session did not settle')

    def cancel_all(self):
        for ident in self.ids:
            subprocess.run(['python3', str(SCRIPT), 'cancel', ident], env=self.env, capture_output=True)
        time.sleep(.4)

    def test_context_result_and_argv(self):
        ident = self.new()
        shown = self.wait(ident)
        self.assertEqual(shown['job']['state'], 'done')
        self.assertTrue(shown['job']['resultReady'])
        self.assertIn('مرحبا', shown['output'])
        folder = self.store / ident
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        self.assertEqual((folder / 'context.json').stat().st_mode & 0o777, 0o600)
        args = (folder / 'argv.json').read_text()
        self.assertNotIn('SECRET-', args)
        self.assertNotIn('synthetic@example', args)
        self.assertFalse((folder / 'forbidden').exists())
        self.assertFalse((folder / 'output.log').exists())
        self.assertEqual(self.call('list')[0]['id'], ident)
        child = self.call('new', value={'parent': ident, 'prompt': 'Shorter'})['id']
        self.ids.append(child)
        self.wait(child)
        context = json.loads((self.store / child / 'context.json').read_text())
        self.assertIn('previousSuggestion', context)
        self.call('forget', ident)
        self.assertFalse(folder.exists())

    def test_reject_input(self):
        for value in ({'command':'touch forbidden','prompt':'p','messageId':'1'}, {'prompt':'p'}, {'prompt':'p\x00','messageId':'1'}, {'scope':'all','prompt':'p'}, {'prompt':'x' * (1024*1024),'messageId':'1'}):
            self.call('new', value=value, ok=False)
        for ident in ('../outside','abc/../abc','x','a'*33):
            self.call('show', ident, ok=False)

    def test_result_boundary(self):
        ident = self.new()
        self.wait(ident)
        file = self.store / ident / 'response.txt'
        target = self.root / 'secret'
        target.write_text('DO NOT IMPORT')
        target.chmod(0o600)
        for kind in ('symlink','fifo','size','nul','escape','utf8','mode','hardlink'):
            file.unlink(missing_ok=True)
            if kind == 'symlink': file.symlink_to(target)
            elif kind == 'fifo': os.mkfifo(file,0o600)
            elif kind == 'hardlink': os.link(target,file)
            else:
                file.write_bytes({'size': b'x'*65537,'nul':b'a\0b','escape':b'\x1b[31m','utf8':b'\xff','mode':b'public'}[kind])
                file.chmod(0o644 if kind == 'mode' else 0o600)
            shown = self.call('show',ident)
            self.assertFalse(shown['job']['resultReady'],kind)
            self.assertEqual(shown['output'],'',kind)
        self.assertEqual(target.read_text(),'DO NOT IMPORT')

    def test_active_ready_cancel_limits(self):
        self.tool('omarchy-agent', "import os,time\nfrom pathlib import Path\nPath('child.pid').write_text(str(os.getpid()))\nPath('response.txt').write_text('Ready')\nos.chmod('response.txt',0o600)\ntime.sleep(60)\nPath('forbidden').touch()")
        ident = self.new()
        shown = self.wait(ident,('running',))
        for _ in range(40):
            shown = self.call('show',ident)
            if shown['job']['resultReady']: break
            time.sleep(.05)
        self.assertTrue(shown['job']['resultReady'])
        self.call('forget',ident,ok=False)
        for _ in range(3): self.new()
        self.call('new',value={'messageId':'1','prompt':'p'},ok=False)
        self.call('cancel',ident)
        self.assertEqual(self.wait(ident)['job']['state'],'cancelled')
        self.assertFalse((self.store / ident / 'forbidden').exists())
        child_pid = int((self.store / ident / 'child.pid').read_text())
        self.assertFalse(Path('/proc/%d' % child_pid).exists())

    def test_failed_launch_and_picker(self):
        self.tool('omarchy-launch-tui','raise SystemExit(3)')
        ident = self.new()
        self.assertEqual(self.wait(ident)['job']['state'],'failed')
        self.tool('omarchy-default-agent','print("")')
        marker = self.root / 'picker'
        self.tool('omarchy-agent',f'import sys\nfrom pathlib import Path\nPath({str(marker)!r}).write_text(repr(sys.argv[1:]))')
        error = self.call('new',value={'messageId':'1','prompt':'SECRET'},ok=False)
        self.assertIn('retry',error)
        for _ in range(20):
            if marker.exists(): break
            time.sleep(.05)
        self.assertEqual(marker.read_text(),"['--pick']")

    def test_continuation_cannot_replace_owner(self):
        ident = self.new(draft={'to':'ada@example.test','body':'Original'},draftKey='ada-draft')
        self.wait(ident)
        before = sorted(os.listdir(self.store))
        marker = self.root / 'launch'
        self.tool('omarchy-launch-tui',f"from pathlib import Path\nPath({str(marker)!r}).touch()")
        for extra in ({'accountId':'bob'}, {'draftKey':'bob-draft'}, {'draft':{'body':'Replacement'}}, {'message':'Replacement'}, {'messages':[{'messageId':'2','message':'Replacement'}]}):
            self.call('new',value=dict(parent=ident,prompt='Rewrite',**extra),ok=False)
            self.assertEqual(sorted(os.listdir(self.store)),before)
            self.assertFalse(marker.exists())

    def test_retention_refuses_forged_metadata(self):
        self.tool('omarchy-launch-tui','pass')
        ident = self.new()
        template = json.loads((self.store / ident / 'job.json').read_text())
        outside = self.root / 'outside'
        outside.mkdir()
        marker = outside / 'keep'
        marker.write_text('Keep this file')
        for number in range(31):
            folder = self.store / ('%032x' % number)
            folder.mkdir(mode=0o700)
            job = dict(template,id=folder.name,state='done',created=number)
            if number == 0:
                job['id'] = str(outside)
            file = folder / 'job.json'
            file.write_text(json.dumps(job))
            file.chmod(0o600)
        launch = self.root / 'launch'
        self.tool('omarchy-launch-tui',f"from pathlib import Path\nPath({str(launch)!r}).touch()")
        before = sorted(os.listdir(self.store))
        self.call('new',value={'messageId':'1','prompt':'p'},ok=False)
        self.assertEqual(sorted(os.listdir(self.store)),before)
        self.assertEqual(marker.read_text(),'Keep this file')
        self.assertFalse(launch.exists())
        for verb in ('show','cancel','forget','run'):
            self.call(verb,'0'*32,ok=False)
        self.assertTrue(marker.exists())

    def test_selection_limit_and_empty_result(self):
        self.call('new',value={'messages':[{'messageId':str(i),'message':'m'} for i in range(21)],'prompt':'p'},ok=False)
        self.tool('omarchy-agent','pass')
        ident = self.new()
        shown = self.wait(ident)
        self.assertEqual(shown['job']['state'],'failed')
        self.assertIn('response.txt',shown['job']['error'])
        self.assertFalse(shown['job']['resultReady'])

    def test_interactive_terminal_foreground(self):
        self.tool('omarchy-launch-tui','pass')
        self.tool('omarchy-agent', "import os,sys\nfrom pathlib import Path\nassert os.isatty(0)\nassert os.tcgetpgrp(0)==os.getpgrp()\nanswer=input()\nPath('response.txt').write_text(answer)\nos.chmod('response.txt',0o600)")
        ident = self.new()
        master, slave = pty.openpty()
        def terminal():
            os.setsid()
            fcntl.ioctl(0,termios.TIOCSCTTY,0)
        try:
            proc = subprocess.Popen(['python3',str(SCRIPT),'run',ident],env=self.env,stdin=slave,stdout=slave,stderr=slave,preexec_fn=terminal)
            os.write(master,b'Interactive answer\n')
            self.assertEqual(proc.wait(timeout=5),0)
            shown = self.call('show',ident)
            self.assertEqual(shown['job']['state'],'done')
            self.assertEqual(shown['output'],'Interactive answer')
        finally:
            os.close(master)
            os.close(slave)

    def test_deadline_and_retention(self):
        self.tool('omarchy-launch-tui', 'pass')
        self.tool('omarchy-agent', "import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(60)")
        ident = self.new()
        # Exercise the actual run loop with a short deadline, without a test
        # environment override that could weaken the production deadline.
        code = "import importlib.util; s=importlib.util.spec_from_file_location('bridge',%r); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.RUN_TIMEOUT=.2; import sys; sys.argv=['python3','run',%r]; m.main()" % (str(SCRIPT),ident)
        subprocess.run(['python3','-c',code],env=self.env,check=True,timeout=5)
        shown = self.call('show',ident)
        self.assertEqual(shown['job']['state'],'failed')
        self.assertIn('one-hour',shown['job']['error'])
        template = json.loads((self.store / ident / 'job.json').read_text())
        for number in range(31):
            other = '%032x' % number
            folder = self.store / other
            folder.mkdir(mode=0o700)
            job = dict(template,id=other,created=number)
            file = folder / 'job.json'
            file.write_text(json.dumps(job))
            file.chmod(0o600)
        self.new()
        self.assertEqual(len(self.call('list')),32)
        self.assertFalse((self.store / ('0'*32)).exists())

    def test_stale_start_and_wrong_pid(self):
        self.tool('omarchy-launch-tui','pass')
        ident = self.new()
        file = self.store / ident / 'job.json'
        job = json.loads(file.read_text())
        job['created'] = 0
        file.write_text(json.dumps(job))
        self.assertEqual(self.call('show',ident)['job']['state'],'failed')
        job.update(state='running',pid=os.getpid())
        file.write_text(json.dumps(job))
        self.call('cancel',ident)
        self.assertEqual(self.call('show',ident)['job']['state'],'failed')


if __name__ == '__main__':
    unittest.main()
