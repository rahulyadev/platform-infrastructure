#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
set +x
[[ "$#" == 2 && ( "$1" == --prepare || "$1" == --verify ) ]]
[[ "$(id -u)" == 0 && -f "$2" && ! -L "$2" ]]
if [[ "$1" == --prepare ]]; then
  [[ -f /run/lock/platform-identity-lifecycle.lock && ! -L /run/lock/platform-identity-lifecycle.lock ]]
  [[ "$(stat -c '%a:%u:%g' /run/lock/platform-identity-lifecycle.lock)" == 600:0:0 ]]
  exec 9>/run/lock/platform-identity-lifecycle.lock
  flock -w 30 9
fi
temporary="$(mktemp -d /tmp/platform-identity-host.XXXXXX)"
finish() {
  local status=$?
  trap - EXIT
  python3 - "$temporary" "$status" <<'EVIDENCE'
import hashlib,pathlib,re,sys
root=pathlib.Path(sys.argv[1])
for name in ('stdout','stderr'):
    path=root/name
    value=path.read_bytes() if path.exists() else b''
    print(f'IDENTITY_HOST_CAPTURE name={name} bytes={len(value)} lines={len(value.splitlines())} sha256={hashlib.sha256(value).hexdigest()}')
    for line in value.decode(errors='replace').splitlines():
        if re.fullmatch(r'IDENTITY_HOST_[A-Z0-9_]+=[A-Za-z0-9_:.,-]+',line):
            print(line)
print('IDENTITY_HOST_STATUS='+sys.argv[2])
EVIDENCE
  [[ "$temporary" == /tmp/platform-identity-host.* && -d "$temporary" && ! -L "$temporary" ]]
  rm -r -- "$temporary"
  [[ ! -e "$temporary" && ! -L "$temporary" ]]
  printf 'IDENTITY_HOST_CLEANUP=PASS\n'
  exit "$status"
}
trap finish EXIT
python3 - "$1" "$2" "$temporary" >"$temporary/stdout" 2>"$temporary/stderr" <<'HOST'
import base64
import dnf
import dnf.rpm
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import stat
import subprocess
import sys
from urllib.parse import urlparse

stage = 'INITIALIZE'


def failure(kind, value, traceback):
    while traceback.tb_next:
        traceback = traceback.tb_next
    print(f'IDENTITY_HOST_FAILURE={stage}:{kind.__name__.upper()}:{traceback.tb_lineno}')


sys.excepthook = failure


def digest(value):
    return hashlib.sha256(value).hexdigest()


def run(*args):
    result = subprocess.run(args, capture_output=True, check=False)
    if result.returncode:
        label = pathlib.Path(args[0]).name.upper().replace('-', '_')
        assert re.fullmatch(r'[A-Z_]+', label)
        print(f'IDENTITY_HOST_SUBCOMMAND={label}')
        print(f'IDENTITY_HOST_SUBCOMMAND_STATUS={result.returncode}')
        for name, value in (('STDOUT', result.stdout), ('STDERR', result.stderr)):
            print(f'IDENTITY_HOST_SUBCOMMAND_{name}_BYTES={len(value)}')
            print(f'IDENTITY_HOST_SUBCOMMAND_{name}_SHA256={digest(value)}')
        raise RuntimeError('host prerequisite subcommand failed')
    return result.stdout


def exact(path, kind, mode):
    path = pathlib.Path(path)
    info = path.lstat()
    assert stat.S_IFMT(info.st_mode) == kind
    assert (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (0, 0, mode)
    assert not path.is_symlink()


def inventory():
    value = run('rpm', '-qa', '--qf', '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n')
    return sorted(value.decode().splitlines())


def package_state(rows, manifest):
    expected = {p['name']: f"{p['name']} {p['epoch']}:{p['version']}-{p['release']}.{p['arch']}" for p in manifest['packages']}
    selected = [row for row in rows if row.split(' ', 1)[0] in expected]
    assert all(row == expected[row.split(' ', 1)[0]] for row in selected)
    original = [row for row in rows if row.split(' ', 1)[0] not in expected]
    assert len(original) == manifest['inventory_count']
    assert digest(('\n'.join(original) + '\n').encode()) == manifest['inventory_sha256']
    return sorted(set(expected) - {row.split(' ', 1)[0] for row in selected})


def baseline(manifest):
    assert platform.machine() == manifest['arch'] == 'aarch64'
    assert platform.release() == manifest['kernel']
    assert dnf.rpm.detect_releasever('/') == manifest['release'] == '2023.12.20260817'
    assert run('getenforce').strip() == b'Permissive'
    config = pathlib.Path('/etc/selinux/config')
    exact(config, stat.S_IFREG, 0o644)
    assert digest(config.read_bytes()) == manifest['selinux_config_sha256']
    assert b'SELINUX=permissive' in config.read_bytes().splitlines()
    assert b'SELINUXTYPE=targeted' in config.read_bytes().splitlines()
    assert 'selinux=1' in pathlib.Path('/proc/cmdline').read_text().split()
    assert pathlib.Path('/sys/fs/selinux/enforce').read_text().strip() == '0'
    controllers = set(pathlib.Path('/sys/fs/cgroup/cgroup.controllers').read_text().split())
    assert {'cpu', 'io', 'memory', 'pids'} <= controllers
    mounts = pathlib.Path('/proc/mounts').read_text().splitlines()
    assert any(x.split()[1:3] == ['/sys/fs/cgroup', 'cgroup2'] and 'rw' in x.split()[3].split(',') for x in mounts)
    mount = run('findmnt', '--noheadings', '--output', 'TARGET', '--target', '/var/lib/docker').decode().strip()
    assert mount.startswith('/') and '\n' not in mount
    assert b'ftype=1' in run('xfs_info', mount)
    for name in manifest['required_modules']:
        path = run('modinfo', '-F', 'filename', name).decode().strip()
        assert path == '(builtin)' or path.startswith('/lib/modules/' + manifest['kernel'] + '/kernel/')
    assert run('systemctl', 'is-active', 'nginx.service').strip() == b'active'
    run('nginx', '-t')
    print('IDENTITY_HOST_SELINUX_BASELINE=PRESERVED_PERMISSIVE')
    print('IDENTITY_HOST_SELINUX_ENFORCEMENT=NOT_ACTIVE')


def no_workload():
    names = {'dockerd', 'containerd', 'containerd-shim', 'containerd-shim-runc-v2', 'docker-proxy'}
    for path in pathlib.Path('/proc').glob('[0-9]*/comm'):
        try:
            name = path.read_text().strip()
        except FileNotFoundError:
            continue
        assert name not in names and not name.startswith('containerd-shim')
    for line in pathlib.Path('/proc/net/unix').read_text().splitlines()[1:]:
        fields = line.split()
        assert not (len(fields) == 8 and fields[7] in ('/run/docker.sock', '/var/run/docker.sock') and fields[3] == '00010000')
    for unit in ('docker.service', 'identity-stack.service'):
        assert run('systemctl', 'show', unit, '--property=ActiveState', '--value').strip() in (b'inactive', b'failed')
    assert not pathlib.Path('/etc/platform/identity').exists()
    assert not pathlib.Path('/etc/platform/identity').is_symlink()
    staging = pathlib.Path('/var/lib/platform/identity-install')
    exact(staging, stat.S_IFDIR, 0o700)
    assert not list(staging.iterdir())


def data_inventory():
    root = pathlib.Path('/var/lib/docker')
    exact(root, stat.S_IFDIR, 0o710)
    assert not list((root / 'containers').iterdir())
    rows = []
    for path in [root] + sorted(root.rglob('*')):
        info = path.lstat()
        rows.append((str(path.relative_to(root)), info.st_mode, info.st_uid, info.st_gid, info.st_size, info.st_mtime_ns))
    return digest(json.dumps(rows, separators=(',', ':')).encode())


def official(url):
    parsed = urlparse(url)
    return (parsed.scheme == 'https' and not parsed.username and not parsed.password
            and parsed.hostname == 'al2023-repos-ap-south-1-de612dc2.s3.dualstack.ap-south-1.amazonaws.com')


def decode_rpm_checksum(expected):
    checksum = base64.b64decode(expected['checksum_sha256'], validate=True)
    assert len(checksum) == 32 and base64.b64encode(checksum).decode() == expected['checksum_sha256']
    return checksum


def install_missing(manifest, missing, temporary):
    if not missing:
        print('IDENTITY_HOST_PACKAGE_WRITES=0')
        return
    with dnf.Base() as base:
        base.conf.read()
        base.conf.substitutions.update_from_etc('/', varsdir=base.conf.varsdir)
        base.conf.substitutions['releasever'] = manifest['release']
        for name in ('cache', 'logs'):
            (temporary / name).mkdir(mode=0o700)
        base.conf.cachedir = str(temporary / 'cache')
        # Keep normal durable DNF history/reason accounting for an actual installation.
        assert base.conf.persistdir == '/var/lib/dnf'
        base.conf.logdir = str(temporary / 'logs')
        base.conf.install_weak_deps = False
        base.conf.gpgcheck = True
        base.conf.sslverify = True
        base.read_all_repos()
        for repo in base.repos.values():
            if repo.id != 'amazonlinux':
                repo.disable()
        repos = list(base.repos.iter_enabled())
        assert len(repos) == 1 and repos[0].id == 'amazonlinux'
        repo = repos[0]
        assert repo.gpgcheck and repo.sslverify
        sources = [x for x in list(repo.baseurl) + [repo.mirrorlist, repo.metalink] if x]
        assert sources == manifest['repository_sources'] and all(official(x) for x in sources)
        assert list(repo.gpgkey) == ['file://' + x['path'] for x in manifest['keys']]
        for key in manifest['keys']:
            exact(key['path'], stat.S_IFREG, 0o644)
            assert digest(pathlib.Path(key['path']).read_bytes()) == key['sha256']
        base.fill_sack(load_system_repo=True)
        selected = {p['name']: p for p in manifest['packages']}
        for name in missing:
            base.install(selected[name]['nevra'], strict=True)
        base.resolve(allow_erasing=False)
        assert not list(base.transaction.remove_set)
        packages = sorted(base.transaction.install_set, key=lambda p: p.name)
        assert sorted(p.name for p in packages) == missing
        assert all(item.action == dnf.transaction.PKG_INSTALL for item in base.transaction)
        base.download_packages(packages)
        for package in packages:
            expected = selected[package.name]
            assert package.reponame == 'amazonlinux'
            assert (int(package.epoch), package.version, package.release, package.arch) == (expected['epoch'], expected['version'], expected['release'], expected['arch'])
            path = pathlib.Path(package.localPkg())
            data = path.read_bytes()
            checksum = decode_rpm_checksum(expected)
            assert len(data) == expected['bytes'] and hashlib.sha256(data).digest() == checksum
            assert package.chksum[0] == 2 and hashlib.sha256(data).digest() == package.chksum[1]
            assert official(package.remote_location())
            assert base.package_signature_check(package)[0] == 0
            signature = run('rpm', '-Kv', str(path)).decode()
            assert sorted(set(re.findall(r'key ID ([0-9a-f]+): OK', signature))) == expected['signing_key_ids']
            assert 'NOT OK' not in signature and 'NOKEY' not in signature
            assert digest(run('rpm', '-qp', '--scripts', str(path))) == expected['scriptlets_sha256']
            assert digest(run('rpm', '-qp', '--triggers', str(path))) == expected['triggers_sha256']
        assert package_state(inventory(), manifest) == missing
        no_workload()
        print('IDENTITY_HOST_TRANSACTION=INSTALL_ONLY')
        base.do_transaction()
        assert not package_state(inventory(), manifest)
        print('IDENTITY_HOST_PACKAGE_WRITES=' + str(len(missing)))


def reconcile():
    no_workload()
    before = data_inventory()
    for unit in ('docker.service', 'identity-stack.service'):
        target = pathlib.Path('/etc/systemd/system') / unit
        assert not target.exists() and not target.is_symlink()
        link = pathlib.Path('/etc/systemd/system/multi-user.target.wants') / unit
        if link.is_symlink():
            assert link.lstat().st_uid == link.lstat().st_gid == 0
            assert os.readlink(link) == str(target)
            link.unlink()
        else:
            assert not link.exists()
        if run('systemctl', 'show', unit, '--property=ActiveState', '--value').strip() == b'failed':
            run('systemctl', 'reset-failed', unit)
    socket = pathlib.Path('/run/docker.sock')
    if socket.exists():
        exact(socket, stat.S_IFSOCK, 0o660)
        socket.unlink()
    pid = pathlib.Path('/run/docker.pid')
    assert not pid.exists() and not pid.is_symlink()
    run('systemctl', 'daemon-reload')
    for unit in ('docker.service', 'identity-stack.service'):
        assert run('systemctl', 'show', unit, '--property=LoadState', '--value').strip() == b'not-found'
        assert run('systemctl', 'show', unit, '--property=ActiveState', '--value').strip() == b'inactive'
        link = pathlib.Path('/etc/systemd/system/multi-user.target.wants') / unit
        assert not link.exists() and not link.is_symlink()
    assert not socket.exists() and not socket.is_symlink()
    no_workload()
    assert data_inventory() == before
    print('IDENTITY_HOST_RECONCILIATION=PASS')


def verify_commands(manifest):
    for name in manifest['required_commands']:
        path = shutil.which(name)
        assert path and os.access(path, os.X_OK)
    for name in ('iptables', 'ip6tables'):
        assert pathlib.Path(shutil.which(name)).resolve() == pathlib.Path('/usr/sbin/xtables-legacy-multi')
        assert run(name, '--version').strip() == (name + ' v1.8.8 (legacy)').encode()
    for name in ('iptables', 'ip6tables', 'git', 'nginx', 'openssl'):
        output = run('ldd', shutil.which(name))
        assert b'not found' not in output
    exact('/opt/platform/certbot-5.7.0/bin/certbot', stat.S_IFREG, 0o755)
    print('IDENTITY_HOST_PREREQUISITES=PASS')


def main():
    global stage
    mode, manifest_path, temporary_path = sys.argv[1:]
    assert mode in ('--prepare', '--verify')
    manifest = json.loads(pathlib.Path(manifest_path).read_text())
    assert manifest['schema_version'] == 1 and manifest['install_only'] is True
    assert len(manifest['packages']) == 6
    stage = 'BASELINE'
    baseline(manifest)
    missing = package_state(inventory(), manifest)
    if mode == '--prepare':
        stage = 'NO_WORKLOAD'
        no_workload()
        before = data_inventory()
        stage = 'PACKAGES'
        install_missing(manifest, missing, pathlib.Path(temporary_path))
        assert data_inventory() == before
        stage = 'RECONCILIATION'
        reconcile()
    else:
        assert not missing
    stage = 'VERIFY'
    assert not package_state(inventory(), manifest)
    verify_commands(manifest)
    baseline(manifest)
    print('IDENTITY_HOST_RESULT=PASS')


if __name__ == '__main__':
    main()
HOST
