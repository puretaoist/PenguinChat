
from PIL import Image
im=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/shot3.png")
# grid approx
x0,x1=340,630; y0,y1=78,285
w=(x1-x0)/3; h=(y1-y0)/2
tiles=[]
for r in range(2):
    for c in range(3):
        box=(int(x0+c*w),int(y0+r*h),int(x0+(c+1)*w),int(y0+(r+1)*h))
        tiles.append(im.crop(box).resize((int(w*5),int(h*5)),Image.LANCZOS))
W,H=tiles[0].size
comp=Image.new("RGB",(W*3+20,H*2+10),(255,255,255))
for i,t in enumerate(tiles):
    comp.paste(t,((i%3)*(W+10),(i//3)*(H+10)))
comp.save(r"C:/Users/Administrator/penguis/qqclient/tmp/grid5x.png")
print(comp.size)
