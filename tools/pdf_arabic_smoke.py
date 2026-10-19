from pathlib import Path
import shutil
import subprocess
import tempfile
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from fontTools.ttLib import TTFont as FTFont

ROOT = Path(__file__).resolve().parents[1]
fonts = [ROOT/'assets/fonts/NotoNaskhArabic-Regular.ttf', ROOT/'assets/fonts/NotoNaskhArabic-Bold.ttf']
for f in fonts:
    font = FTFont(f)
    cmap = set()
    for t in font['cmap'].tables:
        cmap |= set(t.cmap)
    assert any(0x0600 <= cp <= 0x06FF for cp in cmap), f'لا توجد محارف عربية في {f.name}'

out = ROOT/'tools/artifacts/pdf_arabic_smoke.pdf'
txt = ROOT/'tools/artifacts/pdf_arabic_smoke.txt'
out.parent.mkdir(exist_ok=True)
pdfmetrics.registerFont(TTFont('SaqiaArabic', str(fonts[0])))
pdfmetrics.registerFont(TTFont('SaqiaArabicBold', str(fonts[1])))
c = canvas.Canvas(str(out), pagesize=(842, 595))
c.setFont('SaqiaArabicBold', 18)
c.drawString(700, 540, 'تقرير ساقية')
c.setFont('SaqiaArabic', 12)
c.drawString(700, 510, 'نوع المنظومة: شمسي')
c.drawString(700, 485, 'المبلغ: ١٢٣٤٥ ريال')
c.save()

pdftotext = shutil.which('pdftotext')
assert pdftotext, 'pdftotext غير مثبت'
subprocess.run([pdftotext, '-enc', 'UTF-8', str(out), str(txt)], check=True)
content = txt.read_text(encoding='utf-8')
assert any('\u0600' <= ch <= '\u06ff' for ch in content) and '١٢٣٤٥' in content
assert '####' not in content
print('PDF ARABIC FONT SMOKE: PASS')
print('Embedded fonts contain Arabic glyphs and extracted PDF text contains Arabic content.')
print(out)
