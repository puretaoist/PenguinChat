from PIL import Image
import numpy as np, sys
src,dst,row=sys.argv[1],sys.argv[2],int(sys.argv[3])
im=Image.open(src).convert("L"); a=np.asarray(im).astype(float)
H,W=a.shape; cw,ch=W//3,H//2
tiles=[]
for c in range(3):
    t=a[row*ch:(row+1)*ch, c*cw:(c+1)*cw]
    th=np.percentile(t,12)
    b=(t<th)
    img=Image.fromarray((255-b*255).astype('uint8')).resize((cw*3,ch*3),Image.NEAREST)
    tiles.append(img)
w,h=tiles[0].size
out=Image.new('L',(w*3,h),255)
for i,t in enumerate(tiles): out.paste(t,(i*w,0))
out.save(dst); print(out.size)