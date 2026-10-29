from PIL import Image
im=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/c2.png").convert("RGB")
W,H=im.size
cw,ch=W//3,H//2
for r in range(2):
  for c in range(3):
    t=im.crop((c*cw,r*ch,(c+1)*cw,(r+1)*ch)).resize((cw*3,ch*3),Image.LANCZOS)
    t.save(r"C:/Users/Administrator/penguis/qqclient/tmp/t%d%d.png"%(r+1,c+1))
im2=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/t21.png")
im3=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/t22.png")
im4=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/t23.png")
w,h=im2.size
strip=Image.new("RGB",(w*3,h))
strip.paste(im2,(0,0));strip.paste(im3,(w,0));strip.paste(im4,(w*2,0))
strip.save(r"C:/Users/Administrator/penguis/qqclient/tmp/bottom.png")
print(strip.size)