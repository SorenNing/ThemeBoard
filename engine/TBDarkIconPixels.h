// Ning. Local opt-in dark icon processing; premultiplied RGBA8 in/out.
#ifndef TB_DARK_ICON_PIXELS_H
#define TB_DARK_ICON_PIXELS_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct { float r, g, b; } TBDIPColor;
static float TBDIPMax(float a, float b) { return a > b ? a : b; }
static float TBDIPMin(float a, float b) { return a < b ? a : b; }
static float TBDIPDistance(TBDIPColor a, TBDIPColor b) {
    return TBDIPMax(fabsf(a.r-b.r), TBDIPMax(fabsf(a.g-b.g), fabsf(a.b-b.b)));
}
static TBDIPColor TBDIPLerp(TBDIPColor a, TBDIPColor b, float t) {
    return (TBDIPColor){a.r+(b.r-a.r)*t, a.g+(b.g-a.g)*t, a.b+(b.b-a.b)*t};
}
static TBDIPColor TBDIPRead(const uint8_t *p) {
    float a = p[3] ? 255.0f/p[3] : 0.0f;
    return (TBDIPColor){p[0]*a, p[1]*a, p[2]*a};
}
static float TBDIPMedian(float a, float b, float c) {
    return a+b+c-TBDIPMin(a,TBDIPMin(b,c))-TBDIPMax(a,TBDIPMax(b,c));
}

static TBDIPColor TBDIPDarkColor(TBDIPColor bg) {
    float hi=TBDIPMax(bg.r,TBDIPMax(bg.g,bg.b));
    float lo=TBDIPMin(bg.r,TBDIPMin(bg.g,bg.b));
    float white=TBDIPMin(1,TBDIPMax(0,(lo-220)/20))*
                TBDIPMin(1,TBDIPMax(0,(30-(hi-lo))/18));
    float lum=0.299f*bg.r+0.587f*bg.g+0.114f*bg.b;
    float factor=0.26f*(1-white);
    return (TBDIPColor){(0.92f*bg.r+0.08f*lum)*factor,
                        (0.92f*bg.g+0.08f*lum)*factor,
                        (0.92f*bg.b+0.08f*lum)*factor};
}
static float TBDIPLuminance(TBDIPColor c) {
    float channels[3]={c.r/255,c.g/255,c.b/255};
    for (int i=0;i<3;i++) {
        float v=TBDIPMin(1,TBDIPMax(0,channels[i]));
        channels[i]=v<=0.04045f ? v/12.92f : powf((v+0.055f)/1.055f,2.4f);
    }
    return 0.2126f*channels[0]+0.7152f*channels[1]+0.0722f*channels[2];
}
static float TBDIPContrast(float a, float b) {
    return (TBDIPMax(a,b)+0.05f)/(TBDIPMin(a,b)+0.05f);
}

// Returns changed pixel count; zero means confidence/allocation insufficient.
// Input is never changed on failure. Alpha is never changed, even on success.
static size_t TBDarkIconProcessRGBA(uint8_t *rgba, size_t w, size_t h, size_t stride) {
    if (!rgba || w < 12 || h < 12 || w > 2048 || h > 2048 ||
        w*h > 1024*1024 || stride < w*4 || stride > SIZE_MAX/h) return 0;
    // Keep connectivity at the source resolution: downsampling can erase thin
    // foreground barriers and leak into protected logo details.
    size_t gw = w, gh = h, n = gw*gh;
    TBDIPColor *left = calloc(gh, sizeof(*left)), *right = calloc(gh, sizeof(*right));
    uint8_t *alpha = calloc(n,1), *candidate = calloc(n,1), *mask = calloc(n,1);
    uint8_t *valid = calloc(gh,1);
    uint32_t *queue = malloc(n*sizeof(*queue));
    uint8_t *source = NULL;
    size_t changed = 0, opaque = 0, validRows = 0, coherentRows = 0;
    if (!left || !right || !alpha || !candidate || !mask || !valid || !queue)
        goto cleanup;
    for (size_t y=0; y<gh; y++) for (size_t x=0; x<gw; x++) {
        size_t sx = (x*2+1)*w/(gw*2), sy = (y*2+1)*h/(gh*2), i = y*gw+x;
        const uint8_t *p = rgba+sy*stride+sx*4;
        alpha[i] = p[3];
        if (p[3] >= 240) opaque++;
    }
    // Transparent/irregular artwork has no reliable rectangular background.
    if (opaque*100 < n*72) goto cleanup;
    for (size_t y=0; y<gh; y++) {
        size_t lo=0, hi=gw-1;
        while (lo<gw && alpha[y*gw+lo]<240) lo++;
        while (hi>lo && alpha[y*gw+hi]<240) hi--;
        if (lo>=gw || hi-lo < gw*3/4) continue;
        size_t inset=(hi-lo)/28+1, lx=lo+inset, rx=hi-inset;
        if (lx+1>=rx || !lx || rx+1>=gw) continue;
        TBDIPColor l[3], r[3]; int ok=1;
        for (int j=-1; j<=1; j++) {
            size_t a=y*gw+lx+j, b=y*gw+rx+j;
            if (alpha[a]<240 || alpha[b]<240) { ok=0; break; }
            l[j+1]=TBDIPRead(rgba+y*stride+(lx+j)*4);
            r[j+1]=TBDIPRead(rgba+y*stride+(rx+j)*4);
        }
        if (!ok) continue;
        left[y]=(TBDIPColor){TBDIPMedian(l[0].r,l[1].r,l[2].r),
                            TBDIPMedian(l[0].g,l[1].g,l[2].g),
                            TBDIPMedian(l[0].b,l[1].b,l[2].b)};
        right[y]=(TBDIPColor){TBDIPMedian(r[0].r,r[1].r,r[2].r),
                             TBDIPMedian(r[0].g,r[1].g,r[2].g),
                             TBDIPMedian(r[0].b,r[1].b,r[2].b)};
        valid[y]=1; validRows++;
        if (TBDIPDistance(left[y],right[y])<=90) coherentRows++;
    }
    if (validRows*2<gh || coherentRows*100<validRows*85) goto cleanup;
    for (size_t y=0; y<gh; y++) if (!valid[y]) {
        size_t best=gh, distance=gh;
        for (size_t j=0; j<gh; j++) if (valid[j]) {
            size_t d=j>y ? j-y : y-j;
            if (d<distance) { best=j; distance=d; }
        }
        if (best==gh) goto cleanup;
        left[y]=left[best]; right[y]=right[best];
    }
    for (size_t y=0; y<gh; y++) for (size_t x=0; x<gw; x++) {
        size_t i=y*gw+x;
        TBDIPColor background=TBDIPLerp(left[y],right[y],(float)x/(gw-1));
        candidate[i]=(alpha[i]>=240 && TBDIPDistance(TBDIPRead(rgba+y*stride+x*4),background)<=20);
    }
    // Flood from the opaque silhouette's perimeter, rather than all white pixels.
    size_t count=0, head=0;
    for (size_t y=0; y<gh; y++) for (size_t x=0; x<gw; x++) {
        size_t i=y*gw+x;
        int edge=!x || !y || x+1==gw || y+1==gh;
        if (!edge) edge=alpha[i-1]<240 || alpha[i+1]<240 || alpha[i-gw]<240 || alpha[i+gw]<240;
        if (edge && candidate[i] && !mask[i]) { mask[i]=1; queue[count++]=i; }
    }
    while (head<count) {
        size_t i=queue[head++], x=i%gw, y=i/gw, neighbours[4], total=0;
        if (x) neighbours[total++]=i-1;
        if (x+1<gw) neighbours[total++]=i+1;
        if (y) neighbours[total++]=i-gw;
        if (y+1<gh) neighbours[total++]=i+gw;
        for (size_t k=0; k<total; k++) {
            size_t j=neighbours[k];
            if (candidate[j] && !mask[j]) { mask[j]=1; queue[count++]=j; }
        }
    }
    if (count*100<opaque*18) goto cleanup;
    // A coloured backdrop can show through closed outlines (mail, camera).
    // Admit only pixels almost identical to the inferred backdrop. Enclosed
    // neutral/white areas stay protected because they may be logo details.
    for (size_t y=0;y<h;y++) {
        for (size_t x=0;x<w;x++) {
            size_t i=y*w+x;
            if (mask[i] || !candidate[i]) continue;
            TBDIPColor bg=TBDIPLerp(left[y],right[y],(float)x/(w-1));
            float saturation=TBDIPMax(bg.r,TBDIPMax(bg.g,bg.b))-
                             TBDIPMin(bg.r,TBDIPMin(bg.g,bg.b));
            if (saturation>=45 && TBDIPDistance(TBDIPRead(rgba+y*stride+x*4),bg)<=5)
                mask[i]=1;
        }
    }
    // Dark/black foreground on a white backdrop cannot stay unchanged AND
    // remain visible on black. Prefer unchanged artwork over losing its logo.
    size_t darkSubject=0, lostSubject=0, subject=0, sxStep=w/160+1, syStep=h/160+1;
    for (size_t y=0;y<h;y+=syStep) for (size_t x=0;x<w;x+=sxStep) {
        size_t i=y*w+x;
        if (mask[i] || alpha[i]<240) continue;
        TBDIPColor bg=TBDIPLerp(left[y],right[y],(float)x/(w-1));
        TBDIPColor fg=TBDIPRead(rgba+y*stride+x*4);
        if (TBDIPDistance(fg,bg)<45) continue;
        float f=TBDIPLuminance(fg), before=TBDIPContrast(f,TBDIPLuminance(bg));
        subject++;
        if (before<2.5f) continue;
        if (f<0.035f) darkSubject++;
        if (TBDIPContrast(f,TBDIPLuminance(TBDIPDarkColor(bg)))<1.5f) lostSubject++;
    }
    if (subject && ((darkSubject>=2 && darkSubject*100>=subject*30) ||
                    (lostSubject>=2 && lostSubject*100>=subject*30))) goto cleanup;
    // Pixel modifications begin only after all confidence/contrast guards pass.
    source=malloc(h*stride);
    if (!source) goto cleanup;
    memcpy(source,rgba,h*stride);
    for (size_t y=0; y<h; y++) for (size_t x=0; x<w; x++) {
        size_t gx=x*gw/w, gy=y*gh/h;
        uint8_t *p=rgba+y*stride+x*4;
        if (!p[3]) continue;
        int near=mask[gy*gw+gx];
        // A one-grid-cell search only admits foreground boundary pixels; the
        // colour/matting checks below still decide whether they may change.
        if (!near) for (int dy=-1; dy<=1 && !near; dy++) for (int dx=-1; dx<=1; dx++) {
            long xx=(long)gx+dx, yy=(long)gy+dy;
            if (xx>=0 && yy>=0 && xx<(long)gw && yy<(long)gh && mask[yy*gw+xx]) { near=1; break; }
        }
        if (!near) continue;
        float row=(float)y*(gh-1)/(h-1);
        size_t y0=(size_t)row, y1=y0+1<gh ? y0+1 : y0;
        TBDIPColor l=TBDIPLerp(left[y0],left[y1],row-y0);
        TBDIPColor r=TBDIPLerp(right[y0],right[y1],row-y0);
        TBDIPColor bg=TBDIPLerp(l,r,(float)x/(w-1)), colour=TBDIPRead(p);
        float distance=TBDIPDistance(colour,bg), coverage=0;
        if (distance<=3 && mask[gy*gw+gx]) coverage=1;
        else {
            // Recover antialias coverage against a nearby definite foreground
            // colour. Only alter a pixel when this two-colour model fits it.
            TBDIPColor foreground=colour;
            float farthest=distance;
            for (int dy=-2; dy<=2; dy++) for (int dx=-2; dx<=2; dx++) {
                long xx=(long)x+dx, yy=(long)y+dy;
                if (xx<0 || yy<0 || xx>=(long)w || yy>=(long)h) continue;
                const uint8_t *q=source+yy*stride+xx*4;
                if (q[3]<240) continue;
                TBDIPColor c=TBDIPRead(q);
                float d=TBDIPDistance(c,bg);
                if (d>farthest) { farthest=d; foreground=c; }
            }
            if (farthest>=40 && farthest>distance+4) {
                float dr=bg.r-foreground.r, dg=bg.g-foreground.g, db=bg.b-foreground.b;
                float norm=dr*dr+dg*dg+db*db;
                float t=((colour.r-foreground.r)*dr+(colour.g-foreground.g)*dg+
                         (colour.b-foreground.b)*db)/norm;
                TBDIPColor fitted=TBDIPLerp(foreground,bg,t);
                if (t>0.02f && t<=1.02f && TBDIPDistance(fitted,colour)<=8)
                    coverage=TBDIPMin(1,t);
            } else if (mask[gy*gw+gx] && distance<=32) {
                // Small texture/gradient deviations well within a confirmed
                // backdrop; do not extend this branch into foreground pixels.
                coverage=1;
            }
        }
        if (coverage<=0) continue;
        float a=p[3]/255.0f;
        TBDIPColor dark=TBDIPDarkColor(bg);
        uint8_t before[3]={p[0],p[1],p[2]};
        float delta[3]={dark.r-bg.r,dark.g-bg.g,dark.b-bg.b};
        for (int c=0; c<3; c++) {
            float v=p[c]+coverage*delta[c]*a;
            p[c]=(uint8_t)(TBDIPMin(p[3],TBDIPMax(0,v))+0.5f);
        }
        if (memcmp(before,p,3)) changed++;
    }
cleanup:
    free(left); free(right); free(alpha); free(candidate);
    free(mask); free(valid); free(queue); free(source);
    return changed;
}
#endif
