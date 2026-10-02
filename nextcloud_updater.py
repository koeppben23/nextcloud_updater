#!/usr/bin/env python3
"""Consistent Nextcloud backups and explicit, same-major Docker updates (Linux)."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid


def run(args, *, input=None, stdout=None, check=True):
    # Never include command arguments or stderr in exceptions: compose/DB may contain secrets.
    result = subprocess.run(args, input=input, stdout=stdout or subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode}); inspect service logs')
    return result


def atomic_json(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.chmod(0o600)
    os.replace(tmp, path)


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:\.\d+)?', value):
        raise ValueError('Expected a numeric stable Nextcloud version')
    return tuple(map(int, value.split('.')[:3]))


def validate_update(current, target):
    old, new = version(current), version(target)
    if new < old:
        raise ValueError('Downgrades are not supported')
    if new[0] != old[0]:
        raise ValueError('Major upgrades require a separately reviewed migration')


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def valid_dump(path):
    if path.stat().st_size < 1024:
        raise RuntimeError('Database dump is unexpectedly small')
    with path.open('rb') as stream:
        if not any(line.startswith(b'CREATE TABLE ') for line in stream):
            raise RuntimeError('Database dump contains no CREATE TABLE statements')


class Updater:
    def __init__(self, config):
        self.c = config
        self.compose = Path(config['compose_file']).resolve()
        self.data = Path(config['nextcloud_root']).resolve()
        self.backups = Path(config['backup_dir']).resolve()
        self.state = Path(config['state_dir']).resolve()
        self.app = config.get('app_service', 'app')
        self.db = config.get('db_service', 'db')
        self.workers = config.get('worker_services', ['cron'])
        self.dbname = config.get('database', 'nextcloud')
        if not re.fullmatch(r'[A-Za-z0-9_]+', self.dbname):
            raise ValueError('Invalid database name')
        if not 1 <= int(config.get('keep_backups', 4)) <= 52:
            raise ValueError('keep_backups must be between 1 and 52')
        if self.backups == self.data or self.data in self.backups.parents:
            raise ValueError('Backup destination must be outside Nextcloud data')
        self.dc = ['docker', 'compose', '-f', str(self.compose)]
        # Rendered compose may contain credentials; retain in memory, never log it.
        self.services = json.loads(run(self.dc + ['--profile', '*', 'config', '--format', 'json']).stdout)['services']
        for name in [self.app, self.db, *self.workers]:
            if name not in self.services:
                raise ValueError(f'Missing compose service: {name}')

    def preflight(self):
        mount = Path(self.c['required_mount']).resolve()
        if not os.path.ismount(mount):
            raise RuntimeError('Required USB disk is not mounted')
        expected = self.c.get('disk_uuid')
        actual = run(['findmnt', '-n', '-o', 'UUID', '--target', str(mount)]).stdout.decode().strip()
        if expected and actual != expected:
            raise RuntimeError('Unexpected disk UUID')
        if mount not in self.data.parents or mount not in self.backups.parents:
            raise RuntimeError('Data and backup paths must be on the configured disk')
        if not self.compose.is_file() or not (self.data / 'config/config.php').is_file():
            raise RuntimeError('Missing compose or Nextcloud configuration')

    def container(self, service):
        cid = run(self.dc + ['ps', '-q', service]).stdout.decode().strip()
        if not cid:
            raise RuntimeError(f'Service {service} is not running')
        return cid

    def occ(self, *args):
        return run(self.dc + ['exec', '-T', '-u', 'www-data', self.app, 'php', 'occ', *args])

    def status(self):
        return json.loads(self.occ('status', '--output=json').stdout)

    def image_id(self, service):
        return run(['docker', 'inspect', '-f', '{{.Image}}', self.container(service)]).stdout.decode().strip()

    def running(self):
        return run(self.dc + ['ps', '--services', '--status', 'running']).stdout.decode().splitlines()

    @contextmanager
    def paused(self, for_update=False):
        initial = self.status()
        if initial.get('needsDbUpgrade'):
            raise RuntimeError('Finish/recover the existing upgrade before running this tool')
        workers = [s for s in self.workers if s in self.running()]
        changed_maintenance = not initial.get('maintenance', False)
        failed = True
        try:
            if changed_maintenance:
                self.occ('maintenance:mode', '--on')
            if workers:
                run(self.dc + ['stop', '-t', '60', *workers])
            run(self.dc + ['stop', '-t', '60', self.app])
            yield initial
            failed = False
        finally:
            if failed and for_update:
                # The official entrypoint may have changed maintenance itself.
                # Stop serving even if PHP is too broken to set the flag.
                run(self.dc + ['exec', '-T', '-u', 'www-data', self.app, 'php', 'occ',
                               'maintenance:mode', '--on'], check=False)
                run(self.dc + ['stop', '-t', '60', self.app, *workers])
                print('Update failed: app and workers stay stopped. Restore the verified backup or diagnose before resuming.', flush=True)
            else:
                run(self.dc + ['start', self.app])
                self.wait_ready()
                if changed_maintenance:
                    self.occ('maintenance:mode', '--off')
                if workers:
                    run(self.dc + ['start', *workers])

    def wait_ready(self):
        # Apache starts only after the official image entrypoint has finished its upgrade.
        code = ('$c=stream_context_create(["http"=>["ignore_errors"=>true,"timeout"=>2]]);'
                '$s=@file_get_contents("http://127.0.0.1/status.php",false,$c);'
                '$j=json_decode($s?:"",true);'
                'exit(($j["installed"]??false)&&!($j["needsDbUpgrade"]??true)?0:1);')
        end = time.monotonic() + int(self.c.get('startup_timeout', 600))
        while time.monotonic() < end:
            if run(self.dc + ['exec', '-T', self.app, 'php', '-r', code], check=False).returncode == 0:
                return
            time.sleep(3)
        raise RuntimeError('Nextcloud did not become ready before timeout')

    def restore_test(self, dump, image):
        name = 'nextcloud-backup-test-' + uuid.uuid4().hex[:12]
        try:
            run(['docker', 'run', '-d', '--name', name, '--network', 'none',
                 '--tmpfs', '/var/lib/mysql:rw,size=1g',
                 '-e', 'MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1', image])
            deadline = time.monotonic() + 120
            while True:
                result = run(['docker', 'exec', name, 'mariadb-admin', '-u', 'root', 'ping'], check=False)
                if result.returncode == 0:
                    # The entrypoint's bootstrap server must also have exited.
                    ready = run(['docker', 'exec', name, 'healthcheck.sh', '--connect', '--innodb_initialized'], check=False)
                    if ready.returncode == 0:
                        break
                if time.monotonic() > deadline:
                    raise RuntimeError('Isolated database restore test failed to start')
                time.sleep(2)
            run(['docker', 'exec', name, 'mariadb', '-u', 'root', '-e', f'CREATE DATABASE `{self.dbname}`'])
            with dump.open('rb') as stream:
                result = subprocess.run(['docker', 'exec', '-i', name, 'mariadb', '-u', 'root', self.dbname],
                                        stdin=stream, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError('Database backup could not be restored to the isolated test database')
            sql = f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{self.dbname}'"
            count = int(run(['docker', 'exec', name, 'mariadb', '-u', 'root', '-Nse', sql]).stdout)
            if count < 1:
                raise RuntimeError('Restored database has no tables')
            return count
        finally:
            run(['docker', 'rm', '-f', name], check=False)

    def backup(self, status, images):
        self.backups.mkdir(parents=True, exist_ok=True, mode=0o700)
        size = int(run(['du', '-sb', str(self.data)]).stdout.split()[0])
        if shutil.disk_usage(self.backups).free < size * 1.1 + 1024**3:
            raise RuntimeError('Not enough space for a new full backup; existing backups were not removed')
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
        partial = self.backups / ('.partial-' + stamp)
        partial.mkdir(mode=0o700)
        dump = partial / 'database.sql'
        # Resolve credentials inside the DB container; never expose passwords in argv/logs.
        script = ('set -eu; export MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"; '
                  'test -n "$MYSQL_PWD"; '
                  'dump=$(command -v mariadb-dump || command -v mysqldump); '
                  'exec "$dump" -u root --single-transaction --quick --routines --events --triggers --hex-blob "$1"')
        print('Writing consistent database and full Nextcloud backup...', flush=True)
        with dump.open('wb') as stream:
            run(self.dc + ['exec', '-T', self.db, 'sh', '-c', script, 'backup', self.dbname], stdout=stream)
        valid_dump(dump)
        with (partial / 'nextcloud.tar').open('wb') as stream:
            run(['tar', '--acls', '--xattrs', '--numeric-owner', '-cf', '-', '-C', str(self.data), '.'], stdout=stream)
        files = [self.compose.name]
        for extra in self.c.get('deployment_files', ['.env', 'Caddyfile']):
            path = Path(extra)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('deployment_files must be relative to the compose directory')
            if not (self.compose.parent / path).is_file():
                raise RuntimeError(f'Missing deployment file: {extra}')
            files.append(extra)
        run(['tar', '-cf', str(partial / 'deployment.tar'), '-C', str(self.compose.parent), *files])
        print('Verifying archives and restoring SQL into an isolated test database...', flush=True)
        for name in ['nextcloud.tar', 'deployment.tar']:
            with open(os.devnull, 'wb') as null:
                run(['tar', '-tf', str(partial / name)], stdout=null)
        tables = self.restore_test(dump, images[self.db])
        sums = {name: sha256(partial / name) for name in ['database.sql', 'nextcloud.tar', 'deployment.tar']}
        manifest = dict(format=1, complete=True, created_utc=stamp, version=status['versionstring'],
                        images=images, restored_tables=tables, sha256=sums,
                        source=str(self.data), same_disk=True)
        atomic_json(partial / 'manifest.json', manifest)
        # Flush contents before publishing the completion marker by rename.
        run(['sync', '-f', str(partial)])
        final = self.backups / ('backup-' + stamp)
        partial.rename(final)
        run(['sync', '-f', str(self.backups)])
        print('Verified full backup: ' + str(final), flush=True)
        return str(final)

    def prune(self):
        owned = []
        for path in self.backups.glob('backup-*'):
            if path.is_symlink() or not re.fullmatch(r'backup-\d{8}T\d{6}Z-[0-9a-f]{8}', path.name):
                continue
            try:
                manifest = json.loads((path / 'manifest.json').read_text())
                if manifest.get('format') == 1 and manifest.get('complete') is True and manifest.get('source') == str(self.data):
                    owned.append(path)
            except (OSError, ValueError):
                continue
        for old in sorted(owned, reverse=True)[int(self.c.get('keep_backups', 4)):]:
            shutil.rmtree(old)

    def check_updates(self):
        status = self.status()
        current = status['versionstring']
        major = version(current)[0]
        result = []
        # A moving same-major tag detects patches even when deployment is version-pinned.
        for service in [self.app, self.db, *self.c.get('check_services', ['redis', 'proxy'])]:
            if service not in self.services:
                continue
            target = f'nextcloud:{major}-apache' if service == self.app else self.services[service]['image']
            old = self.image_id(service)
            try:
                run(['timeout', str(self.c.get('pull_timeout', 1800)), 'docker', 'pull', target])
                new = run(['docker', 'image', 'inspect', '-f', '{{.Id}}', target]).stdout.decode().strip()
                record = dict(service=service, target=target, update_available=old != new)
                if service == self.app:
                    candidate = self.image_version(target)
                    validate_update(current, candidate)
                    record.update(current_version=current, available_version=candidate)
                result.append(record)
            except Exception as exc:
                result.append(dict(service=service, target=target, error=str(exc)))
        atomic_json(self.state / 'updates.json', dict(checked_at=datetime.now(timezone.utc).isoformat(), services=result))
        print(json.dumps(result, indent=2), flush=True)
        if any('error' in item for item in result):
            raise RuntimeError('Some update checks failed; see updates.json')
        return result

    @staticmethod
    def image_version(image):
        code = 'include "/usr/src/nextcloud/version.php"; echo $OC_VersionString;'
        return run(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'php', image, '-r', code]).stdout.decode().strip()

    def update(self, target):
        import yaml  # Debian package python3-yaml; only needed for explicit updates.
        if not re.fullmatch(r'nextcloud:\d+\.\d+\.\d+-apache', target):
            raise ValueError('Use an explicit stable image, e.g. nextcloud:35.0.2-apache')
        run(['timeout', str(self.c.get('pull_timeout', 1800)), 'docker', 'pull', target])
        current = self.status()['versionstring']
        validate_update(current, self.image_version(target))
        new_id = run(['docker', 'image', 'inspect', '-f', '{{.Id}}', target]).stdout.decode().strip()
        if self.image_id(self.app) == new_id:
            print('Requested image already running')
            return
        document = yaml.safe_load(self.compose.read_text())
        old_image = document['services'][self.app]['image']
        for service in [self.app, *self.workers]:
            if document['services'][service].get('image') != old_image:
                raise ValueError('App and worker images must match before update')
            document['services'][service]['image'] = target
        images = {s: self.image_id(s) for s in [self.app, self.db]}
        with self.paused(for_update=True) as status:
            saved = self.backup(status, images)
            # Preserve .env substitutions and other services; never use rendered secrets here.
            tmp = self.compose.with_suffix('.tmp')
            tmp.write_text(yaml.safe_dump(document, sort_keys=False))
            tmp.chmod(self.compose.stat().st_mode & 0o777)
            os.replace(tmp, self.compose)
            run(self.dc + ['up', '-d', '--no-deps', self.app])
            self.wait_ready()
            if self.status()['versionstring'] != self.image_version(target):
                raise RuntimeError('Unexpected installed version after update')
            # Recreate workers with matching code but leave them stopped until maintenance ends.
            if self.workers:
                run(self.dc + ['up', '--no-start', '--no-deps', *self.workers])
        self.prune()
        print('Update successful; restore point: ' + saved)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default='/etc/nextcloud-updater.json')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--weekly', action='store_true', help='Full backup, then check updates; never install')
    group.add_argument('--backup-only', action='store_true')
    group.add_argument('--check', action='store_true')
    group.add_argument('--update', action='store_true', help='Explicit same-major update after full backup')
    parser.add_argument('--target-image')
    parser.add_argument('--dry-run', action='store_true', help='Read-only preflight; no pulls, backups or changes')
    args = parser.parse_args()
    updater = Updater(json.loads(Path(args.config).read_text()))
    updater.preflight()
    if args.dry_run:
        print(json.dumps(dict(mode='weekly' if args.weekly else 'update' if args.update else 'backup' if args.backup_only else 'check',
                              status=updater.status(), backup_dir=str(updater.backups),
                              keep_backups=updater.c.get('keep_backups', 4), target=args.target_image), indent=2))
        return 0
    updater.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (updater.state / 'run.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another maintenance run is active')
        report = dict(started_at=datetime.now(timezone.utc).isoformat(), success=False)
        errors = []
        try:
            if args.update:
                if not args.target_image:
                    raise ValueError('--update requires --target-image')
                updater.update(args.target_image)
            elif args.weekly or args.backup_only:
                try:
                    images = {s: updater.image_id(s) for s in [updater.app, updater.db]}
                    with updater.paused() as status:
                        report['backup'] = updater.backup(status, images)
                    updater.prune()
                except Exception as exc:
                    errors.append(str(exc))
            if not args.update and not args.backup_only:
                try:
                    report['updates'] = updater.check_updates()
                except Exception as exc:
                    errors.append(str(exc))
            if errors:
                raise RuntimeError('; '.join(errors))
            report['success'] = True
            return 0
        except Exception as exc:
            if str(exc) not in errors:
                errors.append(str(exc))
            raise
        finally:
            report['finished_at'] = datetime.now(timezone.utc).isoformat()
            report['errors'] = errors
            atomic_json(updater.state / 'last-run.json', report)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
