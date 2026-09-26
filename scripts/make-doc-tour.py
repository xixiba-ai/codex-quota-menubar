#!/usr/bin/env python3
"""Assemble the native-view documentation exports (requires Pillow)."""
from pathlib import Path
import sys
from PIL import Image

source = Path(sys.argv[1])
output = Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
frames = []
for name in ('help-en', 'help-zh', 'about-en', 'about-zh'):
    with Image.open(source / f'{name}.png') as image:
        image.convert('RGB').save(output / f'{name}.png', optimize=True)
        preview = image.convert('RGB')
        preview.thumbnail((620, 660), Image.Resampling.LANCZOS)
        frame = Image.new('RGB', (660, 700), '#f4f5f7')
        frame.paste(preview, ((660 - preview.width) // 2, (700 - preview.height) // 2))
        frames.append(frame)
frames[0].save(output / 'bilingual-tour.gif', save_all=True, append_images=frames[1:],
               duration=[3500, 3500, 2500, 2500], loop=0, optimize=True, disposal=2)
