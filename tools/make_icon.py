"""生成 1024x1024 App 图标：深蓝渐变 + 白色耳机。"""
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

S = 1024
OUT = "AudiobookPlayer/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

top = np.array([24, 32, 44], dtype=np.float64)
bottom = np.array([52, 74, 102], dtype=np.float64)

# 垂直渐变
rows = np.linspace(0, 1, S)[:, None]
grad = top[None, :] * (1 - rows) + bottom[None, :] * rows
grad = np.repeat(grad[:, None, :], S, axis=1)
img = Image.fromarray(grad.astype(np.uint8), "RGB")

# 左上柔光
glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse((-260, -320, 760, 560), fill=90)
glow = glow.filter(ImageFilter.GaussianBlur(150))
img = Image.composite(Image.new("RGB", (S, S), (96, 140, 190)), img, glow)

d = ImageDraw.Draw(img)

WHITE = (255, 255, 255)
# 头带
d.arc((250, 250, 774, 780), start=180, end=360, fill=WHITE, width=54)
# 左右耳罩（顶部上移，盖住头带接缝）
d.rounded_rectangle((204, 470, 300, 754), radius=48, fill=WHITE)
d.rounded_rectangle((724, 470, 820, 754), radius=48, fill=WHITE)
# 耳罩上的内嵌细节（用背景色挖一个圆角缺口，避免整块死白）
d.rounded_rectangle((232, 528, 272, 664), radius=20, fill=(60, 84, 114))
d.rounded_rectangle((752, 528, 792, 664), radius=20, fill=(60, 84, 114))

img = img.convert("RGB")
img.save(OUT, "PNG")
print("saved", OUT, img.size, img.mode)
