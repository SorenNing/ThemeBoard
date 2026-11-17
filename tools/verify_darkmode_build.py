#!/usr/bin/env python3
"""Inspect final deb bytes; on macOS also verify the extracted signed objects."""
from pathlib import Path
import hashlib, io, json, plistlib, struct, subprocess, sys, tarfile, tempfile
ROOT=Path(__file__).resolve().parents[1]
def digest(b):return hashlib.sha256(b).hexdigest()
def ar(path):
 b=path.read_bytes();assert b[:8]==b'!<arch>\n';out={};p=8
 while p<len(b):
  header=b[p:p+60];assert header[58:60]==b'`\n'
  name=header[:16].decode().strip().rstrip('/');n=int(header[48:58]);p+=60
  out[name]=b[p:p+n];assert len(out[name])==n;p+=n+(n%2)
 assert p==len(b) and out['debian-binary']==b'2.0\n'
 return out
def tarfiles(b):
 with tarfile.open(fileobj=io.BytesIO(b),mode='r:*') as t:
  out={}
  for m in t.getmembers():
   name=m.name.removeprefix('./')
   assert not name.startswith('/') and '..' not in Path(name).parts
   if m.isfile():out[name]=t.extractfile(m).read()
  return out

def macho(b,expected):
 assert b[:4]==b'\xcf\xfa\xed\xfe','expected thin Mach-O64'
 magic,cpu,sub,kind,ncmd,size,flags,res=struct.unpack_from('<8I',b)
 assert cpu==0x100000c and sub==expected,(hex(cpu),hex(sub))
 p=32;signature=None;minos=None
 for _ in range(ncmd):
  cmd,n=struct.unpack_from('<II',b,p);assert n>=8 and p+n<=len(b)
  if cmd==0x1d:off,count=struct.unpack_from('<II',b,p+8);signature=b[off:off+count]
  if cmd==0x32:minos=struct.unpack_from('<I',b,p+12)[0]
  if cmd==0x25:minos=struct.unpack_from('<I',b,p+8)[0]
  p+=n
 assert minos and minos<=0x000f0000,(hex(minos or 0),'deployment target')
 assert signature and len(signature)>=12
 magic,length,count=struct.unpack_from('>III',signature);assert magic==0xfade0cc0 and length<=len(signature)
 entitlements={};pages=0
 for i in range(count):
  slot,offset=struct.unpack_from('>II',signature,12+8*i)
  blobmagic,blobsize=struct.unpack_from('>II',signature,offset)
  blob=signature[offset:offset+blobsize]
  if slot==5:
   assert blobmagic==0xfade7171;entitlements=plistlib.loads(blob[8:].rstrip(b'\0'))
  if slot==0:
   assert blobmagic==0xfade0c02
   hashOffset,identOffset,nSpecial,nCode,codeLimit=struct.unpack_from('>5I',blob,16)
   hashSize,hashType,platform,pageSize=struct.unpack_from('>4B',blob,36)
   assert hashType in (1,2,3) and 0<pageSize<32
   algo=hashlib.sha1 if hashType==1 else hashlib.sha256
   for j in range(nCode):
    start=j*(1<<pageSize);end=min(codeLimit,start+(1<<pageSize))
    expectedHash=blob[hashOffset+j*hashSize:hashOffset+(j+1)*hashSize]
    assert algo(b[start:end]).digest()[:hashSize]==expectedHash,('code page',j)
   pages+=nCode
 assert pages>0
 return {'cpu_subtype':hex(sub),'code_pages_verified':pages,'minimum_os':hex(minos),'entitlements':entitlements}

def main():
 dist=Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'dist'
 dest=Path(sys.argv[2]) if len(sys.argv)>2 else ROOT/'build/verification.json'
 packages=sorted(dist.glob('*.deb'));assert len(packages)==2,packages
 rows=[];payloads={};all_ownership=[]
 for path in packages:
  members=ar(path);control=tarfiles(members['control.tar.gz'])['control'].decode()
  fields=dict(line.split(': ',1) for line in control.splitlines() if ': ' in line)
  assert fields['Version']=='1.50.1' and fields['Architecture']=='iphoneos-arm64e'
  assert fields['Maintainer']==fields['Author']=='Ning'
  kind='engine' if fields['Package'].endswith('.engine') else 'app'
  files=tarfiles(members['data.tar.gz']);payloads[kind]=files
  assert all(k.startswith('var/jb/') for k in files),list(files)[:5]
  all_ownership.append(set(files))
  programs={}
  for name,b in files.items():
   if b[:4]==b'\xcf\xfa\xed\xfe':
    expected=0x80000002 if name.endswith('.dylib') else 0
    programs[name]=macho(b,expected)
  assert len(programs)==(2 if kind=='app' else 1),(kind,list(programs))
  row={'name':path.name,'bytes':path.stat().st_size,'sha256':digest(path.read_bytes()),'fields':fields,'payload_files':len(files),'machos':programs}
  if kind=='app':
   app='var/jb/Applications/ThemeBoard.app/'
   info=plistlib.loads(files[app+'Info.plist'])
   assert info['CFBundleShortVersionString']=='1.50.1' and info['CFBundleIdentifier']=='com.ning.themeboard'
   assert info['MinimumOSVersion']=='15.0'
   ent=programs[app+'ThemeBoard']['entitlements']
   for key in ['platform-application','com.apple.private.security.storage.MobileDocuments','com.apple.private.security.storage.AppDataContainers','com.apple.private.skip-library-validation']:
    assert ent.get(key) is True,key
   assert files[app+'Engine/version.txt'].strip()==b'1.50.1'
   assert b'DarkIconBackground' in files[app+'ThemeBoard']
  for name,b in files.items():
   if name.endswith('ThemeBoardEngine.dylib'):
    assert b'DarkIconBackground' in b and b'TBDarkAppearanceProbe' in b
  if sys.platform=='darwin':
   with tempfile.TemporaryDirectory(prefix='themeboard-final-') as tmp:
    with tarfile.open(fileobj=io.BytesIO(members['data.tar.gz']),mode='r:gz') as tar:tar.extractall(tmp,filter='data')
    for name in programs:
     subprocess.run(['codesign','--verify','--strict','--all-architectures',str(Path(tmp)/name)],check=True)
    if kind=='app':
     subprocess.run(['codesign','--verify','--deep','--strict','--all-architectures',str(Path(tmp)/'var/jb/Applications/ThemeBoard.app')],check=True)
   row['macos_final_package_signatures']=True
  rows.append(row)
 assert not all_ownership[0]&all_ownership[1],'app-engine file collision'
 embedded=payloads['app']['var/jb/Applications/ThemeBoard.app/Engine/ThemeBoardEngine.dylib']
 engine=payloads['engine']['var/jb/Library/MobileSubstrate/DynamicLibraries/ThemeBoardEngine.dylib']
 assert embedded==engine,'embedded engine differs'
 result={'passed':True,'version':'1.50.1','source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT).decode().strip(),'packages':rows,'embedded_engine_equal':True,'file_ownership_overlap':0,'note':'1.50-compatible var/jb layout; App arm64, engine real arm64e; no device/runtime validation'}
 dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(json.dumps(result,ensure_ascii=False,indent=2))
 print(json.dumps({'passed':True,'packages':[{k:p[k] for k in ['name','bytes','sha256']} for p in rows]},ensure_ascii=False))
if __name__=='__main__':main()
