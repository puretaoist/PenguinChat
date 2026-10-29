from PIL import Image
im=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/c1.png").convert("RGB")
im.resize((im.width*2,im.height*2),Image.LANCZOS).save(r"C:/Users/Administrator/penguis/qqclient/tmp/c1x2.png")
print(im.size)