
from PIL import Image
import numpy as np
im=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/cap2.png").convert("RGB")
a=np.asarray(im).astype(np.float32)
H,W,_=a.shape
th,tw=H//2,W//3
tiles=[]
for r in range(2):
    for c in range(3):
        t=a[r*th:(r+1)*th, c*tw:(c+1)*tw]
        lum=t.mean(axis=2)
        # 字形是深色树冠：取每块内最暗的 12%
        thr=np.percentile(lum,12)
        mask=(lum<=thr).astype(np.uint8)*255
        m=Image.fromarray(255-mask).resize((tw*2,th*2),Image.NEAREST)
        tiles.append(m)
Wt,Ht=tiles[0].size
comp=Image.new("L",(Wt*3+20,Ht*2+10),255)
for i,t in enumerate(tiles):
    comp.paste(t,((i%3)*(Wt+10),(i//3)*(Ht+10)))
comp.save(r"C:/Users/Administrator/penguis/qqclient/tmp/masks.png")
print("ok",comp.size)
