"""Generate the monochrome serrated paper strip for receipt and tax coupons."""

from pathlib import Path

from PIL import Image, ImageDraw


DESTINATION = Path(__file__).resolve().parent / "assets"
DESTINATION.mkdir(exist_ok=True)

for scale in (1, 2, 3):
    width, height = 375 * scale, 144 * scale
    tooth = 15 * scale
    depth = 9 * scale
    points = [(0, depth)]
    for x in range(0, width, tooth):
        points.extend([(x + tooth // 2, 0), (min(x + tooth, width), depth)])
    points.append((width, height - depth))
    for x in range(width, 0, -tooth):
        points.extend([(x - tooth // 2, height), (max(x - tooth, 0), height - depth)])
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.polygon(points, fill=(255, 255, 255, 255))
    draw.line(points[: 1 + width // tooth * 2], fill=(190, 190, 190, 255), width=scale)
    draw.line(points[-(1 + width // tooth * 2) :], fill=(190, 190, 190, 255), width=scale)
    suffix = "" if scale == 1 else f"@{scale}x"
    image.save(DESTINATION / f"strip{suffix}.png")
