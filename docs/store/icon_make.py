import sys
from PIL import Image, ImageDraw
S=4; W=1024*S
def R(x): return int(round(x*S))
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
img=Image.new("RGB",(W,W)); d=ImageDraw.Draw(img)
for y in range(W): d.line([(0,y),(W,y)],fill=lerp((22,38,120),(46,120,255),y/W))
WHITE=(248,250,255)
def scene(w,h,rad):
    """the same picture on both screens: sky gradient, sun, two hills"""
    im=Image.new("RGB",(w,h)); g=ImageDraw.Draw(im)
    for y in range(h): g.line([(0,y),(w,y)],fill=lerp((255,183,94),(255,111,145),y/h))
    sr=int(h*0.16); sx,sy=int(w*0.68),int(h*0.36)
    g.ellipse([sx-sr,sy-sr,sx+sr,sy+sr],fill=(255,240,180))
    g.polygon([(int(-w*0.1),h),(int(w*0.32),int(h*0.48)),(int(w*0.78),h)],fill=(92,70,170))
    g.polygon([(int(w*0.35),h),(int(w*0.72),int(h*0.58)),(int(w*1.15),h)],fill=(60,48,130))
    m=Image.new("L",(w,h),0); ImageDraw.Draw(m).rounded_rectangle([0,0,w-1,h-1],radius=rad,fill=255)
    return im,m
# TV (upper right): dark screen showing the phone's portrait picture in the middle, as the app does
tx0,ty0,tx1,ty1=230,200,890,600; b=30
d.rounded_rectangle([R(tx0),R(ty0),R(tx1),R(ty1)],radius=R(56),fill=WHITE)
d.rounded_rectangle([R(tx0+b),R(ty0+b),R(tx1-b),R(ty1-b)],radius=R(30),fill=(16,20,44))
sh=(ty1-ty0-2*b); swid=int(sh*(270-2*18)/(500-2*18))
scx=(tx0+tx1)//2+70
im,m=scene(R(swid),R(sh),R(8)); img.paste(im,(R(scx-swid//2),R(ty0+b)),m)
d.rounded_rectangle([R(525),R(ty1-6),R(595),R(668)],radius=R(6),fill=WHITE)
d.rounded_rectangle([R(435),R(652),R(685),R(692)],radius=R(20),fill=WHITE)
# phone (lower left), with a soft shadow ring in background colour to separate it
px0,py0,px1,py1=140,400,400,880; pb=18
d.rounded_rectangle([R(px0-16),R(py0-16),R(px1+16),R(py1+16)],radius=R(70),fill=lerp((22,38,120),(46,120,255),(py0+py1)/2/1024))
d.rounded_rectangle([R(px0),R(py0),R(px1),R(py1)],radius=R(56),fill=WHITE)
im,m=scene(R(px1-px0-2*pb),R(py1-py0-2*pb),R(40)); img.paste(im,(R(px0+pb),R(py0+pb)),m)
# dynamic-island style pill
d.rounded_rectangle([R(232),R(py0+32),R(308),R(py0+56)],radius=R(12),fill=(30,30,40))
img.resize((1024,1024),Image.LANCZOS).save(sys.argv[1])
