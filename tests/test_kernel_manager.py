#!/usr/bin/env python3
"""Real APT/dpkg tests using synthetic packages in rootless, offline bwrap roots.

Never run the maintenance script against the host. The host /usr and libraries
are read-only; /etc, /var, /boot, /lib/modules and /usr/src are disposable mounts.
No privileged container, Docker daemon, real kernel, or remote host is used.
"""
import hashlib
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / 'shell/debian/kernel_manager.sh'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report',type=Path,help='Write a JSON report after successful cleanup')
ARGS=parser.parse_args()
if os.geteuid()==0:
    raise SystemExit('Run these tests as an ordinary user; root privileges are forbidden.')
BASE = Path(tempfile.mkdtemp(prefix='codex-kernel-manager-', dir='/tmp'))
HOST_STATUS = Path('/var/lib/dpkg/status')
BEFORE = hashlib.sha256(HOST_STATUS.read_bytes()).hexdigest()
RESULTS = []


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')
    if executable:
        path.chmod(0o755)


class Fixture:
    def __init__(self, name, *, platform='Debian', running='6.1.0-30-amd64', arch='amd64'):
        self.name, self.platform, self.running, self.arch = name, platform, running, arch
        self.root = BASE / name
        self.root.mkdir()
        for directory in ['etc/apt/apt.conf.d', 'etc/default', 'etc/kernel', 'boot/grub',
                          'var/lib/dpkg/info', 'var/lib/dpkg/updates', 'var/lib/dpkg/triggers',
                          'var/lib/apt/lists/partial', 'var/cache/apt/archives/partial',
                          'var/log/apt', 'modules', 'usr-src', 'bin', 'debs']:
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        write(self.root / 'var/lib/dpkg/status', '')
        write(self.root / 'etc/os-release', 'ID=debian\n')
        write(self.root / 'etc/default/grub', 'GRUB_DEFAULT=0\n')
        write(self.root / 'etc/apt/apt.conf', f'APT::Architecture "{arch}";\nDPkg::Path "/work/bin:/usr/bin:/usr/sbin:/bin:/sbin";\n')
        write(self.root / 'running', running)
        write(self.root / 'bin/uname', '#!/bin/sh\nif [ "$1" = -r ]; then cat /work/running; else printf "Linux\\n"; fi\n', True)
        write(self.root / 'bin/dpkg', '#!/bin/sh\nif [ "$1" = --print-architecture ]; then printf "'+arch+'\\n"; else exec /usr/bin/dpkg "$@"; fi\n', True)
        write(self.root / 'bin/systemd-detect-virt', '#!/bin/sh\nexit 1\n', True)
        write(self.root / 'bin/update-grub', '#!/bin/sh\nprintf "grub-refresh\\n" >>/work/actions\n', True)
        write(self.root / 'bin/proxmox-boot-tool', '#!/bin/sh\nif [ "$1" = kernel ]; then cat /work/pve-list; else printf "pve-refresh\\n" >>/work/actions; fi\n', True)
        if platform == 'Armbian':
            write(self.root / 'etc/armbian-release', 'LINUXFAMILY=sunxi64\n')
        if platform == 'PVE':
            self.package('pve-manager')

    def command(self, *command):
        args = ['bwrap', '--unshare-all', '--die-with-parent', '--new-session',
                '--uid', '0', '--gid', '0', '--cap-drop', 'ALL',
                '--ro-bind', '/usr', '/usr', '--ro-bind', '/lib/x86_64-linux-gnu', '/lib/x86_64-linux-gnu',
                '--ro-bind', '/lib64', '/lib64', '--symlink', 'usr/bin', '/bin',
                '--symlink', 'usr/sbin', '/sbin', '--proc', '/proc', '--dev', '/dev',
                '--tmpfs', '/run', '--dir', '/run/lock', '--tmpfs', '/tmp',
                '--bind', str(self.root), '/work', '--ro-bind', str(SCRIPT), '/kernel_manager.sh',
                '--setenv', 'PATH', '/work/bin:/usr/bin:/usr/sbin:/bin:/sbin',
                '--setenv', 'LC_ALL', 'C', '--setenv', 'DEBIAN_FRONTEND', 'noninteractive']
        for source, target in [('etc', '/etc'), ('var', '/var'), ('boot', '/boot'),
                               ('modules', '/lib/modules'), ('usr-src', '/usr/src')]:
            args += ['--bind', str(self.root / source), target]
        cp = subprocess.run([*args, *command], capture_output=True, text=True, encoding='utf-8', timeout=30)
        return cp

    def package(self, name, *, abi=None, kind='image', depends='', metadata='', version='1.0', package_arch=None):
        directory = self.root / 'build' / name
        control = f'Package: {name}\nVersion: {version}\nArchitecture: {package_arch or self.arch}\nMaintainer: Fixture <fixture@example.invalid>\nDescription: isolated synthetic package\n'
        if depends:
            control += 'Depends: '+depends+'\n'
        if metadata:
            control += 'Armbian-Kernel-Version-Family: '+metadata+'\n'
        write(directory / 'DEBIAN/control', control)
        write(directory / 'var/lib/kernel-fixtures' / name / 'fixture', 'synthetic, not bootable\n')
        if abi:
            if kind == 'image':
                write(directory / 'boot' / ('vmlinuz-'+abi), 'synthetic image\n')
                write(directory / 'lib/modules' / abi / 'kernel/fixture.ko', 'synthetic module\n')
                write(directory / 'DEBIAN/postinst', '#!/bin/sh\nset -e\nprintf "synthetic initrd\\n" > /boot/initrd.img-'+abi+'\nprintf "synthetic uInitrd\\n" > /boot/uInitrd-'+abi+'\n', True)
                write(directory / 'DEBIAN/postrm', '#!/bin/sh\nset -e\nrm -f /boot/initrd.img-'+abi+' /boot/uInitrd-'+abi+'\nprintf "purge '+name+'\\n" >> /work/actions\n', True)
            elif kind == 'headers':
                write(directory / 'usr/src' / ('linux-headers-'+abi) / 'fixture.h', 'synthetic header\n')
            elif kind == 'dtb':
                write(directory / 'boot' / ('dtb-'+abi) / 'fixture.dtb', 'synthetic dtb\n')
        cp = subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(directory), str(self.root/'debs'/(name+'.deb'))], capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr

    def normal(self, *, unsigned=False, headers=True):
        for revision in [28, 29, 30]:
            abi = f'6.1.0-{revision}-amd64'
            self.package('linux-image-'+abi+('-unsigned' if unsigned else ''), abi=abi)
            if headers:
                common=f'linux-headers-6.1.0-{revision}-common'
                self.package(common, abi=f'6.1.0-{revision}-common', kind='headers', package_arch='all')
                self.package('linux-headers-'+abi, abi=abi, kind='headers', depends=common)
        return self

    def install(self):
        registration = '/usr/bin/dpkg --add-architecture arm64\n' if self.arch=='arm64' else ''
        write(self.root/'setup.sh', '#!/bin/sh\nset -e\n'+registration+'/usr/bin/dpkg --force-architecture -i /work/debs/*.deb\n', True)
        cp=self.command('/bin/sh','/work/setup.sh')
        assert cp.returncode == 0, cp.stdout+cp.stderr

    def run(self, *args, execute=False, pipe=False, answer='y', mutate=''):
        if not execute:
            return self.command('/usr/bin/bash', '/kernel_manager.sh', '--dry-run', *args)
        driver='''import errno,json,os,pty,select,signal,sys,time
pid,fd=pty.fork()
if pid==0:
    os.execvp(sys.argv[1],sys.argv[1:])
out=b''; sent=False; deadline=time.monotonic()+20
while time.monotonic()<deadline:
    ready,_,_=select.select([fd],[],[],0.2)
    if ready:
        try: chunk=os.read(fd,65536)
        except OSError as e:
            if e.errno==errno.EIO: break
            raise
        if not chunk: break
        out+=chunk
        if not sent and '[y/N]'.encode() in out:
            MUTATION
            os.write(fd,ANSWER.encode()+b'\\n'); sent=True
else:
    os.kill(pid,signal.SIGKILL)
_,status=os.waitpid(pid,0)
print(out.decode('utf-8',errors='replace'),end='')
sys.exit(os.waitstatus_to_exitcode(status))
'''.replace('MUTATION',mutate or 'pass').replace('ANSWER',repr(answer))
        write(self.root/'driver.py',driver)
        command=['/usr/bin/bash','/kernel_manager.sh',*args]
        if pipe:
            command=['/usr/bin/bash','-c','cat /kernel_manager.sh | bash -s -- '+ ' '.join(args)]
        return self.command('/usr/bin/python3','/work/driver.py',*command)

    def installed(self):
        cp=self.command('/usr/bin/dpkg-query','-W','-f=${binary:Package};${db:Status-Status}\n')
        assert cp.returncode == 0, cp.stderr
        return {line.split(';')[0].split(':')[0] for line in cp.stdout.splitlines() if line.endswith(';installed')}


def record(fixture, cp, *, success=True, removed=(), kept=(), contains=''):
    output=cp.stdout+cp.stderr
    assert (cp.returncode==0)==success, fixture.name+'\n'+output
    assert contains in output, fixture.name+'\n'+output
    installed=fixture.installed()
    assert not set(removed)&installed, (fixture.name,removed,installed,output)
    assert set(kept)<=installed, (fixture.name,kept,installed,output)
    RESULTS.append({'case':fixture.name,'passed':True,'exit':cp.returncode})
    print('PASS '+fixture.name,flush=True)


def tests():
    f=Fixture('sandbox-boundaries')
    cp=f.command('/usr/bin/python3','-c',"import errno,os,pathlib; assert os.geteuid()==0; assert pathlib.Path('/var/lib/dpkg/status').read_bytes()==b''; assert all(n.split(':')[0].strip()=='lo' for n in pathlib.Path('/proc/net/dev').read_text().splitlines()[2:]); assert any(l.split()[4]=='/usr' and 'ro' in l.split()[5].split(',') for l in pathlib.Path('/proc/self/mountinfo').read_text().splitlines()); p='/usr/bin/true'; err=None;\ntry: open(p,'r+b').close()\nexcept OSError as e: err=e.errno\nassert err in (errno.EROFS,errno.EACCES)")
    assert cp.returncode==0,cp.stdout+cp.stderr
    RESULTS.append({'case':f.name,'passed':True,'exit':0}); print('PASS '+f.name,flush=True)
    # End-to-end cleanup with real APT, real dpkg, and the real v3 transaction hook.
    for name,kwargs,args in [('debian',{},()),('unsigned',{'unsigned':True},()),
                            ('keep-one',{},('--keep','1')),('keep-three',{},('--keep','3'))]:
        f=Fixture(name).normal(**kwargs); f.install()
        suffix='-unsigned' if kwargs.get('unsigned') else ''
        removed=['linux-image-6.1.0-28-amd64'+suffix] if name!='keep-three' else []
        if name=='keep-one': removed+=['linux-image-6.1.0-29-amd64']
        cp=f.run(*args,execute=True)
        record(f,cp,removed=removed,kept=['linux-image-6.1.0-30-amd64'+suffix])
    for name,mode in [('dry-run','dry'),('cancel','cancel'),('pipe','pipe')]:
        f=Fixture(name).normal(); f.install(); before=(f.root/'var/lib/dpkg/status').read_bytes()
        cp=f.run(execute=mode!='dry',pipe=mode=='pipe',answer='n' if mode=='cancel' else 'y')
        record(f,cp,kept=['linux-image-6.1.0-30-amd64'])
        if mode!='pipe': assert before==(f.root/'var/lib/dpkg/status').read_bytes()
    for marker in ['FINAL_SIMULATION=$(simulate)', 'purge -y -- "${CANDIDATES[@]}"']:
        f=Fixture('truncated-'+('early' if marker.startswith('FINAL') else 'late')).normal(); f.install()
        source=SCRIPT.read_text(); cut=source.index(marker)+len(marker)
        write(f.root/'truncated.sh',source[:cut]+'\n')
        cp=f.command('/usr/bin/bash','-c','cat /work/truncated.sh | bash')
        record(f,cp,success=False,kept=['linux-image-6.1.0-28-amd64'],contains='syntax error')
        assert not (f.root/'actions').exists()
    f=Fixture('metapackage-debug').normal()
    for name in ['linux-image-amd64','linux-image-6.1-amd64']:
        f.package(name,depends='linux-image-6.1.0-30-amd64')
    f.package('linux-image-6.1.0-30-amd64-dbg'); f.install()
    record(f,f.run(execute=True),removed=['linux-image-6.1.0-28-amd64'],
           kept=['linux-image-amd64','linux-image-6.1-amd64','linux-image-6.1.0-30-amd64-dbg'])
    f=Fixture('pending-reboot',running='6.1.0-28-amd64').normal(); f.install()
    record(f,f.run(),kept=['linux-image-6.1.0-28-amd64'],contains='没有可清理')
    f=Fixture('hold-image').normal(); f.install()
    assert f.command('/usr/bin/apt-mark','hold','linux-image-6.1.0-28-amd64').returncode==0
    record(f,f.run(),kept=['linux-image-6.1.0-28-amd64'],contains='包已 hold')
    f=Fixture('hold-headers').normal(); f.install()
    assert f.command('/usr/bin/apt-mark','hold','linux-headers-6.1.0-28-amd64').returncode==0
    record(f,f.run(),kept=['linux-image-6.1.0-28-amd64','linux-headers-6.1.0-28-amd64'],contains='包已 hold')
    f=Fixture('hold-common').normal(); f.install()
    assert f.command('/usr/bin/apt-mark','hold','linux-headers-6.1.0-28-common').returncode==0
    record(f,f.run(execute=True),removed=['linux-image-6.1.0-28-amd64'],kept=['linux-headers-6.1.0-28-common'])
    for flavor in ['amd64','cloud-amd64','rt-amd64','arm64-16k']:
        running='6.12.107+deb13-'+flavor
        f=Fixture('modern-'+flavor,running=running)
        for version in [105,106,107]:
            abi=f'6.12.{version}+deb13-'+flavor
            f.package('linux-image-'+abi,abi=abi)
        f.install()
        record(f,f.run(execute=True),removed=['linux-image-6.12.105+deb13-'+flavor],kept=['linux-image-'+running])
    for mode in ['default','saved','dangling-default']:
        f=Fixture('grub-'+mode).normal(); f.install()
        if mode=='default':
            write(f.root/'etc/default/grub','GRUB_DEFAULT="gnulinux-6.1.0-28-amd64-advanced-fixture"\n')
        elif mode=='saved':
            write(f.root/'etc/default/grub','GRUB_DEFAULT=saved\n')
            write(f.root/'boot/grub/grubenv','fixture saved choice')
            write(f.root/'bin/grub-editenv','#!/bin/sh\nprintf "saved_entry=gnulinux-6.1.0-28-amd64-advanced-fixture\\n"\n',True)
        else:
            write(f.root/'etc/default/grub','GRUB_DEFAULT="gnulinux-6.1.0-1-amd64-advanced-fixture"\n')
        record(f,f.run(),success=mode!='dangling-default',kept=['linux-image-6.1.0-28-amd64'],contains='没有可清理' if mode!='dangling-default' else '无法安全解析')
    f=Fixture('cross-abi-component').normal()
    directory=f.root/'build/linux-headers-6.1.0-28-amd64'
    write(directory/'lib/modules/6.1.0-30-amd64/build','cross-ABI fixture')
    subprocess.run(['dpkg-deb','--root-owner-group','--build',str(directory),str(f.root/'debs/linux-headers-6.1.0-28-amd64.deb')],check=True,capture_output=True)
    f.install()
    record(f,f.run(),success=False,kept=['linux-image-6.1.0-28-amd64'],contains='其它 ABI')
    f=Fixture('orphan-residues').normal(); f.install()
    write(f.root/'modules/6.1.0-28-amd64/unowned.ko','unowned fixture')
    write(f.root/'boot/vmlinuz-6.1.0-28-amd64.backup','unowned fixture')
    record(f,f.run(execute=True),removed=['linux-image-6.1.0-28-amd64'])
    assert (f.root/'modules/6.1.0-28-amd64/unowned.ko').exists()
    assert (f.root/'boot/vmlinuz-6.1.0-28-amd64.backup').exists()
    for name,change,message in [
        ('missing-initrd',lambda f:(f.root/'boot/initrd.img-6.1.0-30-amd64').unlink(),'initrd 缺失'),
        ('broken-boot-link',lambda f:(f.root/'boot/Image').symlink_to('missing'),'启动引用损坏'),
        ('ambiguous-grub',lambda f:write(f.root/'etc/default/grub','GRUB_DEFAULT="1>2"\n'),'无法安全解析'),
        ('unsupported-distro',lambda f:write(f.root/'etc/os-release','ID=fedora\n'),'未适配'),
        ('container',lambda f:write(f.root/'etc/container','yes'),'容器')]:
        f=Fixture(name).normal(); f.install(); change(f)
        if name=='container':
            write(f.root/'bin/systemd-detect-virt','#!/bin/sh\nprintf docker\\n\nexit 0\n',True)
        record(f,f.run(),success=False,kept=['linux-image-6.1.0-28-amd64'],contains=message)
    for name,tool,body,message in [
        ('hold-read-error','apt-mark','exit 2','无法读取 hold'),
        ('inventory-read-error','dpkg-query','exit 2','无法读取已安装'),
        ('file-list-error','dpkg-query','if [ "$1" = -L ]; then exit 2; fi\nexec /usr/bin/dpkg-query "$@"','无法读取软件包文件'),
        ('audit-error','dpkg','if [ "$1" = --audit ]; then exit 2; fi\nexec /usr/bin/dpkg "$@"','dpkg 审计失败')]:
        f=Fixture(name).normal(); f.install(); write(f.root/'bin'/tool,'#!/bin/sh\n'+body+'\n',True)
        cp=f.run(); output=cp.stdout+cp.stderr
        assert cp.returncode!=0 and message in output,(name,output)
        RESULTS.append({'case':name,'passed':True,'exit':cp.returncode}); print('PASS '+name,flush=True)
    f=Fixture('shared-common',running='6.1.0-30-cloud-amd64')
    for abi in ['6.1.0-30-amd64','6.1.0-31-amd64','6.1.0-30-cloud-amd64','6.1.0-31-cloud-amd64']:
        f.package('linux-image-'+abi,abi=abi)
        common='linux-headers-'+abi.split('-cloud')[0].removesuffix('-amd64')+'-common'
        if not (f.root/'debs'/(common+'.deb')).exists(): f.package(common,abi=common.removeprefix('linux-headers-'),kind='headers')
        f.package('linux-headers-'+abi,abi=abi,kind='headers',depends=common)
    f.install()
    record(f,f.run('--keep','1',execute=True),removed=['linux-image-6.1.0-30-amd64','linux-headers-6.1.0-30-amd64'],
           kept=['linux-headers-6.1.0-30-common','linux-headers-6.1.0-30-cloud-amd64'])
    for mode in ['automatic','manual','pinned','next-boot','bad-format','legacy-name','esp-refresh',
                 'manual-none','manual-none-pinned','manual-none-next-boot','manual-empty',
                 'none-without-section','none-in-automatic','none-in-pinned']:
        f=Fixture('pve-'+mode,platform='PVE',running='6.8.12-10-pve')
        for rev in [7,8,9,10]:
            package=f'pve-kernel-6.8.12-{rev}-pve' if mode=='legacy-name' else f'proxmox-kernel-6.8.12-{rev}-pve-signed'
            f.package(package,abi=f'6.8.12-{rev}-pve')
        # Match the real list_kernels() empty-manual-list output by default.
        selection='Manually selected kernels:\n'+('6.8.12-7-pve\n' if mode=='manual' else 'None.\n')+'\nAutomatically selected kernels:\n6.8.12-8-pve\n6.8.12-9-pve\n6.8.12-10-pve\n'
        if mode=='manual-empty': selection=selection.replace('None.\n','')
        if mode in ['pinned','manual-none-pinned']: selection+='\nPinned kernel:\n6.8.12-7-pve\n'
        if mode in ['next-boot','manual-none-next-boot']: selection+='\nKernel pinned on next-boot:\n6.8.12-7-pve\n'
        if mode=='none-without-section': selection='None.\n'+selection
        if mode=='none-in-automatic': selection=selection.replace('Automatically selected kernels:\n','Automatically selected kernels:\nNone.\n')
        if mode=='none-in-pinned': selection+='\nPinned kernel:\nNone.\n'
        if mode=='bad-format': selection+='Unknown future format:\n'
        if mode=='esp-refresh': write(f.root/'etc/kernel/proxmox-boot-uuids','fixture-uuid\n')
        write(f.root/'pve-list',selection); f.install()
        record(f,f.run(execute=True),success=mode not in ['bad-format','none-without-section','none-in-automatic','none-in-pinned'],
               removed=[('pve-kernel-6.8.12-7-pve' if mode=='legacy-name' else 'proxmox-kernel-6.8.12-7-pve-signed')] if mode in ['automatic','legacy-name','esp-refresh','manual-none','manual-empty'] else [],
               kept=['pve-kernel-6.8.12-8-pve','pve-kernel-6.8.12-10-pve'] if mode=='legacy-name' else ['proxmox-kernel-6.8.12-8-pve-signed','proxmox-kernel-6.8.12-10-pve-signed'])
        if mode in ['manual-none-pinned','manual-none-next-boot']:
            assert 'proxmox-kernel-6.8.12-7-pve-signed' in f.installed()
        if mode=='esp-refresh': assert 'pve-refresh' in (f.root/'actions').read_text()
    for mode in ['normal','metadata-conflict','fat-layout','wrong-family']:
        running='6.12.10-current-sunxi64'
        f=Fixture('armbian-'+mode,platform='Armbian',running=running,arch='arm64')
        for branch,version in [('legacy','6.1.10'),('current','6.12.10'),('edge','6.18.10')]:
            abi=version+'-'+branch+'-sunxi64'
            suffix=branch+'-sunxi64'
            f.package('linux-image-'+suffix,abi=abi,metadata='6.0.0-invalid' if mode=='metadata-conflict' and branch=='legacy' else abi)
            f.package('linux-headers-'+suffix,abi=abi,kind='headers',metadata=abi)
            f.package('linux-dtb-'+suffix,abi=abi,kind='dtb',metadata=abi)
        f.install()
        for name,target in [('Image','vmlinuz-'+running),('uInitrd','uInitrd-'+running),('dtb','dtb-'+running)]:
            (f.root/'boot'/name).symlink_to(target)
        if mode=='fat-layout':
            (f.root/'boot/Image').unlink(); write(f.root/'boot/Image','regular FAT image')
        if mode=='wrong-family': write(f.root/'etc/armbian-release','LINUXFAMILY=meson64\n')
        record(f,f.run(execute=True),success=mode=='normal',
               removed=['linux-image-legacy-sunxi64','linux-headers-legacy-sunxi64','linux-dtb-legacy-sunxi64'] if mode=='normal' else [],
               kept=['linux-image-current-sunxi64','linux-image-edge-sunxi64'])
    for name,mutation,message in [
        ('confirm-boot-change',"open('/etc/default/grub','w').write('GRUB_DEFAULT=saved\\n')",'启动配置改变'),
        ('confirm-hold-change',"os.system('/usr/bin/apt-mark hold linux-image-6.1.0-28-amd64 >/dev/null')",'状态改变')]:
        f=Fixture(name).normal(); f.install()
        record(f,f.run(execute=True,mutate=mutation),success=False,kept=['linux-image-6.1.0-28-amd64'],contains=message)
    for mode in ['extra-package','version-change','old-protocol']:
        f=Fixture('transaction-'+mode).normal(); f.package('unrelated'); f.install()
        wrapper='''#!/usr/bin/python3
import os,sys
args=sys.argv[1:]
if '-s' not in args:
    MUTATION
os.execv('/usr/bin/apt-get',['apt-get',*args])
'''
        mutations={
            'extra-package':"args.append('unrelated')",
            'version-change':"p='/var/lib/dpkg/status'; s=open(p).read(); s=s.replace('Package: linux-image-6.1.0-28-amd64\\n','Package: linux-image-6.1.0-28-amd64\\nX-Fixture: changed\\n'); chunks=s.split('\\n\\n'); chunks=[c.replace('Version: 1.0','Version: 2.0') if 'Package: linux-image-6.1.0-28-amd64\\n' in c else c for c in chunks]; open(p,'w').write('\\n\\n'.join(chunks))",
            'old-protocol':"args=[a.replace('::Version=3','::Version=2') for a in args]"}
        write(f.root/'bin/apt-get',wrapper.replace('MUTATION',mutations[mode]),True)
        record(f,f.run(execute=True),success=False,kept=['linux-image-6.1.0-28-amd64','unrelated'],contains='事务校验拒绝')


try:
    for tool in ['bwrap','dpkg-deb','shellcheck']:
        assert shutil.which(tool), 'Missing required test tool: '+tool
    tests()
    assert hashlib.sha256(HOST_STATUS.read_bytes()).hexdigest()==BEFORE, 'Host dpkg status changed'
finally:
    resolved=BASE.resolve()
    assert resolved.parent==Path('/tmp') and resolved.name.startswith('codex-kernel-manager-')
    assert not BASE.is_symlink() and not str(resolved).startswith('/mnt/')
    shutil.rmtree(resolved)
summary={'passed':len(RESULTS),'host_dpkg_unchanged':True,'temporary_directory_removed':not BASE.exists(),
         'isolation':'rootless bubblewrap; offline; host runtime read-only; disposable package/boot state',
         'script_sha256':hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),'cases':RESULTS}
if ARGS.report:
    ARGS.report.write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(summary,ensure_ascii=False,indent=2))
