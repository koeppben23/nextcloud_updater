import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('updater', Path(__file__).resolve().parents[1] / 'nextcloud_updater.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class RecoveryTests(unittest.TestCase):
    def updater(self, maintenance=False):
        u = object.__new__(m.Updater)
        u.app, u.workers, u.dc = 'app', ['cron'], ['docker', 'compose']
        u.status = lambda: {'maintenance': maintenance, 'needsDbUpgrade': False}
        u.running = lambda: ['app', 'db', 'cron']
        u.occ = lambda *args: self.events.append(('occ', *args))
        u.wait_ready = lambda: self.events.append(('ready',))
        return u

    def setUp(self):
        self.events = []
        self.p = patch.object(m, 'run', side_effect=lambda cmd, **kwargs: self.events.append(tuple(cmd)))
        self.p.start()
        self.addCleanup(self.p.stop)

    def test_backup_failure_restores_availability(self):
        with self.assertRaisesRegex(RuntimeError, 'disk error'):
            with self.updater().paused():
                self.events.append(('backup',))
                raise RuntimeError('disk error')
        self.assertLess(self.events.index(('occ', 'maintenance:mode', '--on')), self.events.index(('backup',)))
        self.assertIn(('docker', 'compose', 'stop', '-t', '60', 'cron'), self.events)
        self.assertIn(('docker', 'compose', 'stop', '-t', '60', 'app'), self.events)
        self.assertLess(self.events.index(('ready',)), self.events.index(('occ', 'maintenance:mode', '--off')))
        self.assertEqual(self.events[-1], ('docker', 'compose', 'start', 'cron'))

    def test_preexisting_maintenance_is_preserved(self):
        with self.updater(maintenance=True).paused():
            pass
        self.assertNotIn(('occ', 'maintenance:mode', '--off'), self.events)

    def test_upgrade_failure_never_reopens_site(self):
        with self.assertRaises(RuntimeError):
            with self.updater().paused(for_update=True):
                raise RuntimeError('upgrade failed')
        self.assertNotIn(('occ', 'maintenance:mode', '--off'), self.events)
        self.assertNotIn(('docker', 'compose', 'start', 'cron'), self.events)
        self.assertNotIn(('docker', 'compose', 'start', 'app'), self.events)

    def test_already_broken_upgrade_aborts_before_mutation(self):
        u = self.updater()
        u.status = lambda: {'needsDbUpgrade': True}
        with self.assertRaises(RuntimeError):
            with u.paused():
                self.fail('must not start backup')
        self.assertEqual(self.events, [])


class ValidationTests(unittest.TestCase):
    def test_version_rules(self):
        m.validate_update('35.0.1', '35.0.2')
        for target in ['34.0.9', '36.0.0', '35.0.0', '35.1.0beta1']:
            with self.assertRaises(ValueError):
                m.validate_update('35.0.1', target)

    def test_failed_dump_is_not_a_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'database.sql'
            for text in ['OCI runtime exec failed: mysqldump not found', 'error\n' * 1000]:
                p.write_text(text)
                with self.assertRaises(RuntimeError):
                    m.valid_dump(p)
            p.write_text('-- comment\n' * 200 + 'CREATE TABLE `oc_users` (id INT);\n')
            m.valid_dump(p)

    def test_retention_preserves_partial_unknown_and_foreign_backups(self):
        with tempfile.TemporaryDirectory() as tmp:
            u = object.__new__(m.Updater)
            u.backups, u.data, u.c = Path(tmp), Path('/data'), {'keep_backups': 1}
            def make(name, **overrides):
                p = u.backups / name
                p.mkdir()
                (p / 'manifest.json').write_text(json.dumps(dict(format=1, complete=True, source='/data', **overrides)))
                return p
            old = make('backup-20260101T030000Z-12345678')
            new = make('backup-20260108T030000Z-12345678')
            unknown = make('backup-my-original')
            partial = make('.partial-20260115T030000Z-12345678')
            foreign = u.backups / 'backup-20251201T030000Z-12345678'
            foreign.mkdir()
            (foreign / 'manifest.json').write_text('{"format":1,"complete":true,"source":"/elsewhere"}')
            u.prune()
            self.assertFalse(old.exists())
            for p in [new, unknown, partial, foreign]:
                self.assertTrue(p.exists())

    def test_nested_backup_directory_rejected(self):
        config = dict(compose_file='/tmp/compose.yaml', nextcloud_root='/tmp/cloud', backup_dir='/tmp/cloud/backup', state_dir='/tmp/state')
        with self.assertRaisesRegex(ValueError, 'outside'):
            m.Updater(config)

    def test_dump_restore_failure_always_removes_test_container(self):
        u = object.__new__(m.Updater)
        u.dbname = 'nextcloud'
        calls = []
        def fail(cmd, **kwargs):
            calls.append(cmd)
            if cmd[1] == 'run':
                raise RuntimeError('cannot start')
        with patch.object(m, 'run', side_effect=fail):
            with self.assertRaises(RuntimeError):
                u.restore_test(Path('/unused'), 'image')
        self.assertEqual(calls[-1][:3], ['docker', 'rm', '-f'])


class WorkflowTests(unittest.TestCase):
    def test_weekly_backs_up_even_when_no_updates_exist(self):
        from contextlib import contextmanager
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / 'state'
            cfg = Path(tmp) / 'config.json'
            cfg.write_text('{}')
            events = []
            class Fake:
                app, db = 'app', 'db'
                def __init__(self, config): self.state = state
                def preflight(self): pass
                def image_id(self, service): return service
                @contextmanager
                def paused(self):
                    events.append('pause');yield {};events.append('resume')
                def backup(self, status, images): events.append('backup');return '/saved'
                def prune(self): events.append('prune')
                def check_updates(self): events.append('check');return []
            with patch.object(m, 'Updater', Fake), patch.object(m.sys, 'argv', ['tool', '--config', str(cfg), '--weekly']):
                self.assertEqual(m.main(), 0)
            self.assertEqual(events, ['pause', 'backup', 'resume', 'prune', 'check'])
            self.assertTrue(json.loads((state/'last-run.json').read_text())['success'])

    def test_failed_backup_does_not_prune_and_still_checks(self):
        from contextlib import contextmanager
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / 'state'
            cfg = Path(tmp) / 'config.json';cfg.write_text('{}')
            events = []
            class Fake:
                app, db = 'app', 'db'
                def __init__(self, config): self.state = state
                def preflight(self): pass
                def image_id(self, service): return service
                @contextmanager
                def paused(self): yield {}
                def backup(self, status, images): raise RuntimeError('dump failed')
                def prune(self): events.append('prune')
                def check_updates(self): events.append('check');return []
            with patch.object(m, 'Updater', Fake), patch.object(m.sys, 'argv', ['tool', '--config', str(cfg), '--weekly']):
                with self.assertRaisesRegex(RuntimeError, 'dump failed'):
                    m.main()
            self.assertEqual(events, ['check'])
            self.assertFalse(json.loads((state/'last-run.json').read_text())['success'])

    def test_update_preserves_env_references_and_updates_workers(self):
        import yaml
        from contextlib import contextmanager
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            u = object.__new__(m.Updater)
            u.compose = Path(tmp)/'compose.yaml'
            u.compose.write_text('services:\n  app:\n    image: nextcloud:35.0.1-apache\n    environment:\n      MYSQL_PASSWORD: ${DB_PASSWORD}\n  cron:\n    image: nextcloud:35.0.1-apache\n  db:\n    image: mariadb:11.4\n')
            u.app,u.db,u.workers,u.dc,u.c='app','db',['cron'],['docker','compose'],{}
            events=[]
            u.status=lambda:{'versionstring':'35.0.1' if not events else '35.0.2'}
            u.image_id=lambda s:'old'
            u.image_version=lambda i:'35.0.2'
            @contextmanager
            def paused(**kwargs): yield {'versionstring':'35.0.1'}
            u.paused=paused
            def backup(*args):
                self.assertIn('35.0.1',u.compose.read_text())
                events.append('backup');return '/saved'
            u.backup=backup
            u.wait_ready=lambda:None
            u.prune=lambda:None
            calls=[]
            def run(cmd,**kwargs):
                calls.append(cmd);return SimpleNamespace(stdout=b'new\n',returncode=0)
            with patch.object(m,'run',side_effect=run): u.update('nextcloud:35.0.2-apache')
            data=yaml.safe_load(u.compose.read_text())['services']
            self.assertEqual(data['app']['image'],data['cron']['image'])
            self.assertEqual(data['app']['environment']['MYSQL_PASSWORD'],'${DB_PASSWORD}')
            self.assertEqual(data['db']['image'],'mariadb:11.4')
            self.assertIn(['docker','compose','up','--no-start','--no-deps','cron'],calls)


if __name__ == '__main__':
    unittest.main()
