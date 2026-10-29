from PIL import Image
im=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/d1.png").convert("RGB")
im.resize((im.width*2,im.height*2),Image.LANCZOS).save(r"C:/Users/Administrator/penguis/qqclient/tmp/d1x2.png")