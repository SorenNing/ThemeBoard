#!/usr/bin/env python3
"""Runs the production C kernel on generated layered fixtures, not a rewrite."""
import ctypes, json, pathlib, subprocess, tempfile, time
from PIL import Image, ImageDraw, ImageChops
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=pathlib.Path('/var/minis/workspace/themeboard-darkmode-checks')
OUT.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='tb-dark-pixels-') as tmp:
    tmp=pathlib.Path(tmp)
    (tmp/'wrapper.c').write_text('#include "TBDarkIconPixels.h"\nsize_t run(unsigned char*p,size_t w,size_t h,size_t s){return TBDarkIconProcessRGBA(p,w,h,s);}\n')
    subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-fPIC','-shared','-I'+str(ROOT/'engine'),str(tmp/'wrapper.c'),'-lm','-o',str(tmp/'pixels.so')],check=True)
    lib=ctypes.CDLL(str(tmp/'pixels.so'))
    run=lib.run;run.argtypes=[ctypes.POINTER(ctypes.c_ubyte),ctypes.c_size_t,ctypes.c_size_t,ctypes.c_size_t];run.restype=ctypes.c_size_t
    def transform(image):
        raw=image.tobytes(); array=(ctypes.c_ubyte*len(raw)).from_buffer_copy(raw)
        start=time.perf_counter();changed=run(array,image.width,image.height,image.width*4)
        elapsed=time.perf_counter()-start
        return Image.frombytes('RGBA',image.size,bytes(array)),int(changed),elapsed
    results=[]; failures=[]; examples=[]
    def require(value,message):
        if not value:failures.append(message)
    for name,bg,fg in [('white',(255,255,255),(14,140,235)),('blue',(30,140,240),(255,255,255)),('orange',(250,140,25),(245,245,245)),('grey',(195,195,200),(60,60,68)),('white-on-grey',(200,200,200),(255,255,255)),('black',(0,0,0),(255,170,20))]:
        for size in [32,60,180,512]:
            original=Image.new('RGBA',(size,size),bg+(255,))
            d=ImageDraw.Draw(original); rect=(size//3,size//3,2*size//3,2*size//3)
            d.rectangle(rect,fill=fg+(255,))
            after,changed,elapsed=transform(original)
            require(original.crop(rect).tobytes()==after.crop(rect).tobytes(),f'{name}/{size}: subject changed')
            require(after.getchannel('A').tobytes()==original.getchannel('A').tobytes(),f'{name}/{size}: alpha changed')
            border=after.getpixel((size//8,size//8))[:3]
            if name=='white':require(border==(0,0,0),f'{name}/{size}: white not black {border}')
            elif name=='grey':
                require(changed==0 and after.tobytes()==original.tobytes(),f'{name}/{size}: low contrast must retain artwork')
            elif name!='black':require(max(border)<max(bg)*0.4,f'{name}/{size}: bg not dark {border}')
            if size==180:examples.append((name,original,after))
            results.append(dict(name=name,size=size,changed=changed,seconds=elapsed,background=border))
    # A white region inside a coloured logo must not be globally colour-replaced.
    im=Image.new('RGBA',(180,180),'white'); d=ImageDraw.Draw(im)
    d.rectangle((45,45,135,135),fill=(30,140,240,255));d.rectangle((65,65,115,115),fill='white')
    out,changed,_=transform(im)
    require(out.getpixel((90,90))==im.getpixel((90,90)),'enclosed white foreground changed')
    examples.append(('enclosed-white',im,out))
    # Transparent irregular artwork is left alone.
    im=Image.new('RGBA',(180,180),(0,0,0,0));ImageDraw.Draw(im).ellipse((45,45,135,135),fill=(255,255,255,255))
    out,changed,_=transform(im)
    require(changed==0 and out.tobytes()==im.tobytes(),'irregular transparent image changed')
    # Simple vertical gradient with a high-contrast central logo.
    im=Image.new('RGBA',(180,180));d=ImageDraw.Draw(im)
    for y in range(180):d.line((0,y,179,y),fill=(30+y//3,115+y//4,230-y//4,255))
    d.rectangle((60,60,120,120),fill='white');out,changed,_=transform(im)
    require(out.getpixel((90,90))==(255,255,255,255),'gradient subject changed')
    require(max(out.getpixel((20,90))[:3])<90,'gradient background not dark')
    examples.append(('gradient',im,out))
    # Mirroring catches scan-order dependence in boundary-colour reconstruction.
    im=Image.new('RGBA',(180,180),'white');d=ImageDraw.Draw(im);d.ellipse((45,45,135,135),fill=(20,120,220,255))
    out,_,_=transform(im);reverse,_,_=transform(im.transpose(Image.Transpose.FLIP_LEFT_RIGHT))
    require(out.tobytes()==reverse.transpose(Image.Transpose.FLIP_LEFT_RIGHT).tobytes(),'scan-order-dependent result')
    canvas=Image.new('RGB',(440,len(examples)*230),(235,235,235));draw=ImageDraw.Draw(canvas)
    for i,(name,original,after) in enumerate(examples):
        draw.text((20,i*230+8),name,fill='black');canvas.paste(original.convert('RGB'),(20,i*230+30));canvas.paste(after.convert('RGB'),(240,i*230+30))
    canvas.save(OUT/'generated-examples.jpg',quality=94)
    receipt={'production_kernel':str(ROOT/'engine/TBDarkIconPixels.h'),'fixtures':results,'failures':failures,'native_iOS_runtime_tested':False}
    (OUT/'pixel-results.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps({'fixtures':len(results)+4,'failures':failures,'preview':str(OUT/'generated-examples.jpg')},ensure_ascii=False))
    raise SystemExit(bool(failures))
