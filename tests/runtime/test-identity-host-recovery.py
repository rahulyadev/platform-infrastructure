#!/usr/bin/env python3
"""Execute the real prerequisite and restoration logic with isolated synthetic state."""

import argparse
import base64
import binascii
import copy
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parents[2]
CONFIGURE = (ROOT / 'deploy/ssm/configure-identity-runtime.sh.tftpl').read_text()
PREPARE = (ROOT / 'deploy/ssm/prepare-identity-host.sh').read_text()
MANIFEST = json.loads((ROOT / 'config/runtime/identity-host-packages.json').read_text())


def host_namespace(source=None):
    if source is None:
        source = PREPARE.split("<<'HOST'\n", 1)[1].rsplit('\nHOST', 1)[0]
    dnf = types.ModuleType('dnf')
    rpm = types.ModuleType('dnf.rpm')
    dnf.rpm = rpm
    namespace = {'__name__': 'host_fixture'}
    original_hook = sys.excepthook
    with patch.dict(sys.modules, {'dnf': dnf, 'dnf.rpm': rpm}):
        exec(compile(source, 'actual-host-preparation', 'exec'), namespace)
    sys.excepthook = original_hook
    return namespace


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.ns = host_namespace()
        self.rows = ['baseline-a 0:1-1.aarch64', 'baseline-b 1:2-3.noarch']
        self.manifest = copy.deepcopy(MANIFEST)
        self.manifest['inventory_count'] = len(self.rows)
        self.manifest['inventory_sha256'] = hashlib.sha256(('\n'.join(self.rows)+'\n').encode()).hexdigest()
        self.installed = [f"{p['name']} {p['epoch']}:{p['version']}-{p['release']}.{p['arch']}" for p in self.manifest['packages']]

    def test_install_partial_exact_and_idempotent_states(self):
        check = self.ns['package_state']
        self.assertEqual(len(check(self.rows, self.manifest)), 6)
        self.assertEqual(len(check(sorted(self.rows+self.installed[:2]), self.manifest)), 4)
        self.assertEqual(check(sorted(self.rows+self.installed), self.manifest), [])
        self.ns['install_missing'](self.manifest, [], None)

    def test_unrelated_upgrade_removal_and_extra_package_fail_independently(self):
        for rows in (self.rows[1:], self.rows+['extra 0:1-1.aarch64'], ['baseline-a 0:2-1.aarch64',self.rows[1]]):
            with self.subTest(rows=rows), self.assertRaises(AssertionError):
                self.ns['package_state'](rows, self.manifest)

    def test_wrong_version_arch_and_epoch_fail_independently(self):
        for row in (self.installed[0].replace('aarch64','x86_64'), self.installed[0].replace('0:','1:'), self.installed[0].replace('2.50.1','2.50.2')):
            with self.subTest(row=row), self.assertRaises(AssertionError):
                self.ns['package_state'](sorted(self.rows+[row]), self.manifest)

    def test_repository_and_signature_pins(self):
        self.assertEqual(MANIFEST['signing_fingerprint'], 'B21C50FA44A99720EAA72F7FE951904AD832C631')
        for package in MANIFEST['packages']:
            self.assertTrue(self.ns['official'](MANIFEST['repository_sources'][0]))
            self.assertEqual(package['signing_key_ids'], ['d832c631'])
            self.assertEqual(len(base64.b64decode(package['checksum_sha256'],validate=True)),32)
        parsed=urlsplit(MANIFEST['repository_sources'][0])
        userinfo=chr(64).join(('fixture-user:fixture-password',parsed.netloc))
        credential_url=urlunsplit(parsed._replace(netloc=userinfo))
        for url in ('http://al2023-repos-ap-south-1-de612dc2.s3.dualstack.ap-south-1.amazonaws.com/x', 'https://evil.example/x', credential_url):
            self.assertFalse(self.ns['official'](url))

    def test_security_and_ordering_contract(self):
        self.assertLess(CONFIGURE.index('configure_stage=HOST_PREREQUISITES'), CONFIGURE.index('configure_stage=SECRET_FETCH'))
        self.assertLess(CONFIGURE.index('transaction_started=true'), CONFIGURE.index('  register_directory "$directory" "$mode"'))
        for fixed in ('base.resolve(allow_erasing=False)', 'not list(base.transaction.remove_set)', 'item.action == dnf.transaction.PKG_INSTALL', 'base.package_signature_check(package)[0] == 0', "digest(run('rpm', '-qp', '--scripts'", 'assert data_inventory() == before'):
            self.assertIn(fixed, PREPARE)
        for forbidden in ('setenforce', 'setsebool', 'semodule', 'restorecon', 'dnf update', 'distro-sync', 'history undo', 'rpm --rebuilddb', 'iptables -F', 'docker system prune'):
            self.assertNotIn(forbidden, PREPARE)

    def test_checksum_decode_rejects_corrupt_short_and_noncanonical_inputs(self):
        decode=self.ns['decode_rpm_checksum']
        for package in MANIFEST['packages']:
            self.assertEqual(len(decode(package)),32)
        for value in ('INVALID!', '', base64.b64encode(b'x'*31).decode(), MANIFEST['packages'][0]['checksum_sha256']+'='):
            with self.subTest(value=value), self.assertRaises((AssertionError,binascii.Error)):
                decode({'checksum_sha256':value})

    def test_selinux_enabled_permissive_not_disabled_or_enforcing(self):
        ns = self.ns
        class FakePath:
            def __init__(self, value): self.value = str(value)
            def read_bytes(self): return b'SELINUX=permissive\nSELINUXTYPE=targeted\n'
            def read_text(self):
                return {'/proc/cmdline':'selinux=1', '/sys/fs/selinux/enforce':'0', '/sys/fs/cgroup/cgroup.controllers':'cpu io memory pids', '/proc/mounts':'cgroup2 /sys/fs/cgroup cgroup2 rw 0 0\n'}[self.value]
        manifest = copy.deepcopy(MANIFEST)
        manifest['selinux_config_sha256'] = hashlib.sha256(FakePath('').read_bytes()).hexdigest()
        ns['pathlib'] = types.SimpleNamespace(Path=FakePath)
        ns['exact'] = lambda *args: None
        ns['platform'] = types.SimpleNamespace(machine=lambda:'aarch64', release=lambda:manifest['kernel'])
        ns['dnf'].rpm.detect_releasever = lambda root:manifest['release']
        def command(mode, *args):
            if args[0]=='getenforce': return mode.encode()
            if args[0]=='findmnt': return b'/\n'
            if args[0]=='xfs_info':
                assert args[1]=='/'
                return b'ftype=1'
            if args[0]=='modinfo': return b'(builtin)'
            if args[0]=='systemctl': return b'active'
            return b''
        ns['run'] = lambda *args:command('Permissive',*args)
        ns['baseline'](manifest)
        for mode in ('Enforcing','Disabled',''):
            ns['run'] = lambda *args:command(mode,*args)
            with self.subTest(mode=mode), self.assertRaises(AssertionError): ns['baseline'](manifest)


class HostReconciliationTests(unittest.TestCase):
    def run_case(self, mutation=''):
        with tempfile.TemporaryDirectory(prefix='identity-host-reconcile-', dir='/tmp') as directory:
            root = Path(directory)
            for name, mode in (('etc/systemd/system/multi-user.target.wants', 0o755),
                               ('var/lib/platform/identity-install', 0o700),
                               ('var/lib/docker', 0o710), ('var/lib/docker/containers', 0o700),
                               ('run', 0o755), ('proc/net', 0o755), ('proc/123', 0o755)):
                path = root/name
                path.mkdir(parents=True, exist_ok=True)
                path.chmod(mode)
            data = root/'var/lib/docker/retained-metadata'
            data.write_bytes(b'synthetic preserved Docker metadata\n')
            (root/'proc/123/comm').write_text('fixture\n')
            unix = root/'proc/net/unix'
            unix.write_text('Num RefCount Protocol Flags Type St Inode Path\n')
            sockpath = root/'run/docker.sock'
            with socket.socket(socket.AF_UNIX) as sock:
                sock.bind(str(sockpath))
            sockpath.chmod(0o660)
            wants = root/'etc/systemd/system/multi-user.target.wants'
            for unit in ('docker.service', 'identity-stack.service'):
                (wants/unit).symlink_to(root/'etc/systemd/system'/unit)
            if mutation == 'process':
                (root/'proc/123/comm').write_text('containerd-shim-runc-v2\n')
            elif mutation == 'listener':
                unix.write_text(unix.read_text()+'0: 2 0 00010000 0001 01 1 '+str(sockpath)+'\n')
            elif mutation == 'data':
                (root/'var/lib/docker/containers/existing').write_text('preserve\n')
            elif mutation == 'link':
                (wants/'docker.service').unlink()
                (wants/'docker.service').symlink_to(root/'etc/systemd/system/unrelated.service')
            source = PREPARE.split("<<'HOST'\n", 1)[1].rsplit('\nHOST', 1)[0]
            # The actual functions run on real isolated paths; only absolute fixture roots,
            # expected caller ownership and PID1 systemctl state are substituted.
            for prefix in ('/etc', '/var', '/run', '/proc', '/sys'):
                source = source.replace("'"+prefix, "'"+str(root)+prefix)
            source = source.replace('(0, 0, mode)', f'({os.getuid()}, {os.getgid()}, mode)')
            source = source.replace('link.lstat().st_uid == link.lstat().st_gid == 0',
                                    f'(link.lstat().st_uid, link.lstat().st_gid) == ({os.getuid()}, {os.getgid()})')
            ns = host_namespace(source)
            states = {'docker.service': 'failed', 'identity-stack.service': 'inactive'}
            calls = []
            def command(*args):
                calls.append(args)
                self.assertEqual(args[0], 'systemctl')
                if args[1] == 'show':
                    return (states[args[2]] if args[3] == '--property=ActiveState' else 'not-found').encode()
                if args[1] == 'reset-failed':
                    states[args[2]] = 'inactive'
                    return b''
                self.assertEqual(args[1], 'daemon-reload')
                return b''
            ns['run'] = command
            if mutation:
                with self.assertRaises(AssertionError):
                    ns['reconcile']()
                self.assertTrue(sockpath.exists())
                self.assertTrue((wants/'docker.service').is_symlink())
                self.assertFalse(any(x[1] in ('reset-failed', 'daemon-reload') for x in calls))
            else:
                before = ns['data_inventory']()
                ns['reconcile']()
                self.assertFalse(sockpath.exists())
                self.assertFalse(any(wants.iterdir()))
                self.assertEqual(states, {'docker.service': 'inactive', 'identity-stack.service': 'inactive'})
                self.assertEqual(ns['data_inventory'](), before)
                ns['reconcile']()
                self.assertEqual(sum(x[1] == 'reset-failed' for x in calls), 1)
                self.assertEqual(ns['data_inventory'](), before)
            self.assertEqual(data.read_bytes(), b'synthetic preserved Docker metadata\n')

    def test_exact_stale_state_reconciles_and_reentry_preserves_data(self): self.run_case()
    def test_live_process_refused(self): self.run_case('process')
    def test_listening_socket_refused(self): self.run_case('listener')
    def test_existing_container_data_refused(self): self.run_case('data')
    def test_unrelated_enablement_target_refused(self): self.run_case('link')


class RestorationTests(unittest.TestCase):
    def run_case(self, present=False, enabled=False, active=False, failure='', cleanup_failure=False, stale_failed=False):
        with tempfile.TemporaryDirectory(prefix='identity-recovery-',dir='/tmp') as directory:
            root = Path(directory)
            work = root/'work'
            for name in ('rollback','active','docker','generation','unit-verification'):
                (work/name).mkdir(parents=True)
            (work/'secret.json').write_text('synthetic-only')
            (work/'generation'/'secret').write_text('synthetic-only')
            units = root/'etc/systemd/system'
            wants = units/'multi-user.target.wants'
            wants.mkdir(parents=True)
            data = root/'var/lib/docker'
            data.mkdir(parents=True)
            (data/'preserve').write_text('synthetic-docker-data')
            old = root/'generations/old'
            new = root/'generations/new'
            old.mkdir(parents=True);new.mkdir()
            (new/'secret').write_text('synthetic-only')
            link = root/'generation-link'
            link.symlink_to(new)
            targets = [units/'docker.service', units/'identity-stack.service']
            (root/'run').mkdir()
            (root/'proc/net').mkdir(parents=True)
            (root/'proc/net/unix').write_text('Num RefCount Protocol Flags Type St Inode Path\n')
            with socket.socket(socket.AF_UNIX) as sock:
                sock.bind(str(root/'run/docker.sock'))
            (root/'run/docker.sock').chmod(0o660)
            for target in targets:
                label = hashlib.sha256(str(target).encode()).hexdigest()
                if present:
                    (work/'rollback'/f'{label}.file').write_text('previous unit bytes\n')
                    (work/'rollback'/f'{label}.file').chmod(0o644)
                else:
                    (work/'rollback'/f'{label}.absent').touch()
                target.write_text('new unit bytes\n')
                (wants/target.name).symlink_to(target)
            source = CONFIGURE[CONFIGURE.index('atomic_link() {'):CONFIGURE.index('\ntrap fail ERR')]
            # Only OpenTofu escaping and the fixed service fixture root/expected UID differ.
            source = source.replace('$${','${').replace('/etc/systemd/system',str(units)).replace('== 0:0','== '+str(os.getuid())+':'+str(os.getgid()))
            source=source.replace("pathlib.Path('/proc')", "pathlib.Path('"+str(root/'proc')+"')").replace("'/proc/net/unix'",repr(str(root/'proc/net/unix'))).replace("'/run/docker.sock'",repr(str(root/'run/docker.sock'))).replace('(0,0,0o660)',f'({os.getuid()},{os.getgid()},0o660)')
            setup = f'''#!/bin/bash
set -Eeuo pipefail
work_root={work}
staged_generation={work/'generation'}
unit_verification_root={work/'unit-verification'}
generation={new}
active_generation={link}
previous_generation={'"'+str(old)+'"' if present else '""'}
docker_was_present={str(present).lower()}
stack_was_present={str(present).lower()}
docker_was_enabled={str(enabled).lower()}
stack_was_enabled={str(enabled).lower()}
docker_was_active={str(active).lower()}
stack_was_active={str(active).lower()}
docker_socket_was_present={str(active).lower()}
active_targets=({' '.join(str(x) for x in targets)})
created_directories=()
work_root_owned=true
transaction_started=true
transaction_committed=false
configure_stage=TRANSACTION
report_configure_failure() {{ printf 'ORIGINAL_STATUS=%s\\n' "$2"; }}
systemctl() {{
  printf '%s\\n' "$*" >>{root/'calls'}
  if [[ "$1" == '{failure or 'NO_FAILURE'}' ]]; then return 7; fi
  case "$1" in
    show)
      case "$3" in
        --property=LoadState) if [[ -f {units}/"$2" ]]; then printf loaded; else printf not-found; fi ;;
        --property=ActiveState) if [[ -f {root}/"$2.failed" ]]; then printf failed; elif [[ -f {root}/"$2.active" ]]; then printf active; else printf inactive; fi ;;
        --property=UnitFileState) if [[ -L {wants}/"$2" ]]; then printf enabled; else printf disabled; fi ;;
        *) return 9 ;;
      esac ;;
    stop) rm -f {root}/"$2.active" ;;
    start) touch {root}/"$2.active" ;;
    enable) ln -sf {units}/"$2" {wants}/"$2" ;;
    disable) [[ -f {units}/"$2" ]] || return 1; rm -f {wants}/"$2" ;;
    is-enabled) [[ -L {wants}/"$2" ]] && printf enabled ;;
    reset-failed) rm -f {root}/"$2.failed" ;;
    daemon-reload) return 0 ;;
    *) return 9 ;;
  esac
}}
'''
            if active:
                for target in targets: (root/(target.name+'.active')).touch()
            elif failure=='stop':
                (root/'docker.service.active').touch()
            if stale_failed:
                (root/'docker.service.failed').touch()
            script = root/'actual-recovery.sh'
            script.write_text(setup+source+'\ntrap fail ERR\n(exit 23)\n')
            if cleanup_failure:
                # Exact cleanup command fails independently; subsequent cleanup/readback must run.
                script.write_text(script.read_text().replace('trap fail ERR\n(exit 23)', 'find() { return 8; }\ntrap fail ERR\n(exit 23)'))
            result = subprocess.run(['bash',str(script)],capture_output=True,text=True)
            self.assertEqual(result.returncode,23)
            self.assertIn('ORIGINAL_STATUS=23',result.stdout)
            self.assertEqual((data/'preserve').read_text(),'synthetic-docker-data')
            self.assertFalse((work/'generation').exists())
            self.assertFalse((work/'active').exists())
            self.assertFalse((work/'unit-verification').exists())
            if cleanup_failure:
                self.assertIn('cleanup_status=1',result.stderr)
            else:
                self.assertFalse((work/'secret.json').exists())
                self.assertIn('cleanup_status=0',result.stderr)
            if failure:
                self.assertIn('restoration_status=1',result.stderr)
                self.assertTrue((work/'rollback').is_dir())
            else:
                self.assertIn('restoration_status=0',result.stderr)
                self.assertFalse((work/'rollback').exists())
                self.assertFalse(new.exists())
                self.assertEqual((root/'run/docker.sock').exists(),active)
                self.assertFalse((root/'docker.service.failed').exists())
                for target in targets:
                    self.assertEqual(target.exists(),present)
                    self.assertEqual((wants/target.name).is_symlink(),enabled)
                    self.assertEqual((root/(target.name+'.active')).exists(),active)
                    if present: self.assertEqual(target.read_text(),'previous unit bytes\n')
            return result

    def test_first_install_absent_units(self): self.run_case()
    def test_prior_disabled_inactive(self): self.run_case(present=True)
    def test_prior_enabled_inactive(self): self.run_case(present=True,enabled=True)
    def test_prior_healthy_preserved(self): self.run_case(present=True,enabled=True,active=True)
    def test_failed_stop_preserves_recovery_and_cleans_transient_secrets(self): self.run_case(failure='stop')
    def test_failed_reload_preserves_recovery_and_cleans_transient_secrets(self): self.run_case(failure='daemon-reload')
    def test_failed_cleanup_not_reported_as_success(self): self.run_case(cleanup_failure=True)
    def test_failed_cache_and_inactive_socket(self): self.run_case(stale_failed=True)


def wrapper_test(filename):
    wrapper = Path(filename).read_text()
    with tempfile.TemporaryDirectory(prefix='identity-wrapper-fixture-',dir='/tmp') as directory:
        root=Path(directory);active=root/'active';active.mkdir()
        payload=base64.b64encode(gzip.compress(b'fixture bytes\n',mtime=0)).decode()
        env=dict(os.environ,PLATFORM_IDENTITY_COMPRESSED_PAYLOAD_TEST_ROOT=str(active),PLATFORM_IDENTITY_COMPRESSED_PAYLOAD=payload)
        before=set(Path('/tmp').glob('platform-identity-document.*'))
        success=subprocess.run(['bash',filename,'--compressed-payload-fixture'],env=env,capture_output=True)
        assert success.returncode==0 and (active/'result').read_bytes()==b'fixture bytes\n'
        assert set(Path('/tmp').glob('platform-identity-document.*'))==before
        broken=re.sub(r"printf '%s' '[A-Za-z0-9+/=]+' \| base64 --decode", "printf '%s' 'INVALID' | base64 --decode",wrapper,count=1)
        assert broken!=wrapper
        corrupt=root/'corrupt.sh';corrupt.write_text(broken)
        failure=subprocess.run(['bash',str(corrupt)],capture_output=True)
        assert failure.returncode!=0 and b'IDENTITY_DOCUMENT_CLEANUP=PASS' in failure.stdout
        assert set(Path('/tmp').glob('platform-identity-document.*'))==before
        print('Document wrapper round-trip execution and decoder failure cleanup passed.')


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--wrapper')
    args=parser.parse_args()
    if args.wrapper:
        wrapper_test(args.wrapper)
    else:
        unittest.main(argv=[sys.argv[0]])
