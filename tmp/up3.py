from PIL import Image
im=Image.open(r"C:/Users/Administrator/penguis/qqclient/tmp/cap3.png")
im.resize((im.width*2,im.height*2),Image.LANCZOS).save(r"C:/Users/Administrator/penguis/qqclient/tmp/cap3x2.png")
print(im.size)