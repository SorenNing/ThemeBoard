#!/usr/bin/env python3
import ctypes, json, pathlib, subprocess, tempfile
from PIL import Image, ImageDraw, ImageChops, ImageStat
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=pathlib.Path('/var/minis/workspace/themeboard-darkmode-checks');OUT.mkdir(parents=True,exist_ok=True)
failures=[];results=[];previews=[]
def require(ok,msg):
    if not ok:failures.append(msg)
with tempfile.TemporaryDirectory(prefix='tb-dark-edges-') as t:
    t=pathlib.Path(t);(t/'w.c').write_text('#include "TBDarkIconPixels.h"\nsize_t run(unsigned char*p,size_t w,size_t h,size_t s){return TBDarkIconProcessRGBA(p,w,h,s);}\n')
    subprocess.run(['cc','-std=c11','-O2','-shared','-fPIC','-I'+str(ROOT/'engine'),str(t/'w.c'),'-lm','-o',str(t/'p.so')],check=True)
    run=ctypes.CDLL(str(t/'p.so')).run;run.argtypes=[ctypes.POINTER(ctypes.c_ubyte),ctypes.c_size_t,ctypes.c_size_t,ctypes.c_size_t];run.restype=ctypes.c_size_t
    def transform(im):
        a=(ctypes.c_ubyte*(im.width*im.height*4)).from_buffer_copy(im.tobytes())
        n=run(a,im.width,im.height,im.width*4)
        return Image.frombytes('RGBA',im.size,bytes(a)),n
    for size in [60,180,512]:
        m=Image.new('L',(size*4,size*4),0)
        ImageDraw.Draw(m).ellipse((size,size,3*size,3*size),fill=255)
        m=m.resize((size,size),Image.Resampling.LANCZOS)
        fg=Image.new('RGBA',(size,size),(20,130,235,255));bg=Image.new('RGBA',(size,size),'white')
        im=Image.composite(fg,bg,m);out,n=transform(im)
        altered=0;edgeError=0
        expected=Image.composite(fg,Image.new('RGBA',(size,size),'black'),m)
        for y in range(size):
            for x in range(size):
                a=m.getpixel((x,y));p=im.getpixel((x,y));q=out.getpixel((x,y))
                if a==255 and p!=q:altered+=1
                if 8<a<247:edgeError=max(edgeError,max(abs(q[c]-expected.getpixel((x,y))[c]) for c in range(3)))
        require(altered==0,f'aa/{size}: opaque foreground changed ({altered})')
        require(edgeError<=32,f'aa/{size}: fringe error {edgeError}')
        results.append({'case':'antialias','size':size,'opaque_subject_changes':altered,'edge_max_error':edgeError})
        if size==180:previews.append(('antialias',im,out))
        # Thin opaque ring enclosing a white logo detail must survive segmentation.
        im=Image.new('RGBA',(size,size),'white');d=ImageDraw.Draw(im)
        d.rectangle((size//3,size//3,2*size//3,2*size//3),outline=(20,130,235,255),width=1)
        out,n=transform(im)
        detail=out.getpixel((size//2,size//2))
        require(detail==(255,255,255,255),f'thin-ring/{size}: enclosed detail changed {detail}')
        if size==180:previews.append(('thin-ring',im,out))
    # Premultiplied-alpha boundary bytes and zero-alpha pixels must stay valid.
    im=Image.new('RGBA',(180,180),(0,0,0,0));d=ImageDraw.Draw(im)
    d.rounded_rectangle((0,0,179,179),radius=40,fill='white');d.rectangle((65,65,115,115),fill=(10,140,230,255))
    out,n=transform(im)
    require(im.getchannel('A').tobytes()==out.getchannel('A').tobytes(),'rounded: alpha modified')
    require(out.getpixel((90,90))==im.getpixel((90,90)),'rounded: subject modified')
    previews.append(('rounded',im,out))
    paths=sorted((ROOT/'demo-themes').glob('*.theme/IconBundles/*@3x.png'))
    for p in paths:
        im=Image.open(p).convert('RGBA');out,n=transform(im)
        require(im.getchannel('A').tobytes()==out.getchannel('A').tobytes(),f'{p.name}: alpha modified')
        results.append({'case':str(p.relative_to(ROOT)),'size':im.size,'changed':n})
        if 'Aurora.theme' in str(p) and any(k in p.name for k in ['Preferences','AppStore','camera','mobilemail','Music','MobileSMS']):
            previews.append((p.stem,im,out))
    canvas=Image.new('RGB',(520,len(previews)*230),(225,225,225));d=ImageDraw.Draw(canvas)
    for i,(name,im,out) in enumerate(previews):
        d.text((16,i*230+5),name,fill='black')
        for j,a in enumerate([im,out]):
            a=a.resize((180,180),Image.Resampling.LANCZOS)
            b=Image.new('RGBA',a.size,(185,185,185,255));b.alpha_composite(a)
            canvas.paste(b.convert('RGB'),(16+260*j,i*230+30))
    canvas.save(OUT/'edge-and-theme-examples.jpg',quality=94)
receipt={'results':results,'failures':failures,'iOS_runtime_tested':False}
(OUT/'edge-results.json').write_text(json.dumps(receipt,indent=2))
print(json.dumps({'cases':len(results)+4,'failures':failures,'preview':str(OUT/'edge-and-theme-examples.jpg')},ensure_ascii=False))
raise SystemExit(bool(failures))
