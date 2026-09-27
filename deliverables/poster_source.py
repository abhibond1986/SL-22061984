from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A3
from reportlab.lib.colors import HexColor, white
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.utils import simpleSplit
import qrcode

F = '/tmp/fonts/'
for n in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold', 'Italic']:
    pdfmetrics.registerFont(TTFont('P-' + n, F + 'Poppins-' + n + '.ttf'))
pdfmetrics.registerFont(TTFont('P-BoldItalic', F + 'Poppins-BoldItalic.ttf'))

NAVY = HexColor('#1A1A3E')
NAVY2 = HexColor('#26265A')
INDIGO = HexColor('#4F5BD5')
INDIGO_T = HexColor('#ECEEFB')
TEAL = HexColor('#0E7490')
CYAN = HexColor('#5ED3DE')
PINK = HexColor('#F472B6')
TEXT1 = HexColor('#14142B')
TEXT2 = HexColor('#3C4257')
TEXT3 = HexColor('#5B6275')
BORDER = HexColor('#DCE1E9')
CARD = HexColor('#F5F7FA')

W, H = A3
M = 44
OUT = '/sessions/great-sweet-mayer/mnt/SL-22061984/deliverables/SafetyLens_Poster_A3.pdf'
c = canvas.Canvas(OUT, pagesize=A3)
c.setTitle('SAIL SafetyLens - features and how to use')
c.setAuthor('SAIL SafetyLens')


def para(text, x, y, width, font='P-Regular', size=11, lead=None, color=TEXT2):
    lead = lead or size * 1.5
    c.setFont(font, size)
    c.setFillColor(color)
    for line in simpleSplit(text, font, size, width):
        c.drawString(x, y, line)
        y -= lead
    return y


def rrect(x, y, w, h, r, fill, stroke=None):
    c.setFillColor(fill)
    if stroke:
        c.setStrokeColor(stroke)
        c.setLineWidth(0.8)
    c.roundRect(x, y, w, h, r, fill=1, stroke=1 if stroke else 0)


# ── Header band ───────────────────────────────────────────────────────────────
HB = 222
c.setFillColor(NAVY)
c.rect(0, H - HB, W, HB, fill=1, stroke=0)
# faint steel-plate diagonal texture, right side
c.saveState()
c.setStrokeColor(NAVY2)
c.setLineWidth(18)
for i in range(8):
    x0 = W - 260 + i * 44
    c.line(x0, H, x0 + 200, H - HB)
c.restoreState()

c.drawImage('/sessions/great-sweet-mayer/mnt/SL-22061984/assets/images/app_icon.png',
            M, H - 32 - 72, 72, 72, mask='auto')
tx = M + 96
ty = H - 82
c.setFont('P-ExtraBold', 44)
c.setFillColor(white)
c.drawString(tx, ty, 'SAIL ')
x = tx + c.stringWidth('SAIL ', 'P-ExtraBold', 44)
c.setFont('P-Bold', 44)
c.setFillColor(CYAN)
c.drawString(x, ty, 'Safety')
x += c.stringWidth('Safety', 'P-Bold', 44)
c.setFont('P-BoldItalic', 44)
c.setFillColor(PINK)
c.drawString(x, ty, ' Lens')
c.setFont('P-Medium', 14)
c.setFillColor(HexColor('#C7CBE8'))
c.drawString(tx + 2, ty - 26, 'AI safety platform for the steel industry')

intro = ('SafetyLens helps teams report near misses, analyse industrial safety '
         'observations with AI, identify PPE and unsafe-condition gaps from images, '
         'link findings to SOP/SMP controls, and track corrective actions to closure.')
para(intro, M, H - 150, W - 2 * M - 30, 'P-Medium', 15.5, 24, white)

# ── Hero: the five-step flow ─────────────────────────────────────────────────
top = H - HB - 24
c.setFont('P-Bold', 20)
c.setFillColor(TEXT1)
c.drawString(M, top - 20, 'From observation to closure')
c.setFont('P-Regular', 11.5)
c.setFillColor(TEXT3)
c.drawString(M, top - 40, 'Every report follows the same five steps, so nothing is lost between the shop floor and the review.')

steps = [('Capture / Upload', 'Photo, location and details from the site'),
         ('AI-assisted Review', 'Likely hazards, PPE gaps and controls suggested'),
         ('Supervisor Validation', 'A person confirms, edits or rejects each finding'),
         ('Action Assignment', 'Owner and target date within the plant'),
         ('Closure & Analytics', 'Closed out and counted in plant trends')]
fy = top - 86
cw = (W - 2 * M) / 5
c.setStrokeColor(INDIGO)
c.setLineWidth(3)
c.line(M + cw / 2, fy, M + cw * 4.5, fy)
for i, (t, d) in enumerate(steps):
    cx = M + cw * i + cw / 2
    c.setFillColor(white)
    c.circle(cx, fy, 25, fill=1, stroke=0)
    c.setFillColor(INDIGO)
    c.circle(cx, fy, 21, fill=1, stroke=0)
    c.setFillColor(white)
    c.setFont('P-Bold', 18)
    c.drawCentredString(cx, fy - 6.5, str(i + 1))
    c.setFont('P-SemiBold', 12.5)
    c.setFillColor(TEXT1)
    c.drawCentredString(cx, fy - 48, t)
    yy = fy - 66
    c.setFont('P-Regular', 10)
    c.setFillColor(TEXT3)
    for ln in simpleSplit(d, 'P-Regular', 10, cw - 22):
        c.drawCentredString(cx, yy, ln)
        yy -= 14

# ── Features grid ────────────────────────────────────────────────────────────
gtop = fy - 100
c.setStrokeColor(BORDER)
c.setLineWidth(1)
c.line(M, gtop + 8, W - M, gtop + 8)
c.setFont('P-Bold', 20)
c.setFillColor(TEXT1)
c.drawString(M, gtop - 14, 'What you can do')

features = [
    ('AI Scan', 'AI Scan tab',
     'Photograph a work area. AI flags likely hazards and PPE gaps, rates each on '
     'the 5×5 risk matrix, and shows its confidence and citation checks. '
     'Export the result as a PDF report.'),
    ('Near Miss reporting', 'Near Miss tab',
     'Describe what happened in English, Hindi or romanised Hindi. It is sorted '
     'into near miss, unsafe act or unsafe condition for the right follow-up.'),
    ('SOP / SMP library', 'SOP tab',
     'Scan your plant’s SOPs and SMPs once. Findings are then linked to the '
     'exact clause and control measure that applies.'),
    ('Ask AI and Ask a Document', 'Ask AI tab',
     'Ask a safety question and get an answer drawn from your own plant '
     'documents, with the source quoted so you can check it.'),
    ('Investigations and actions', 'Case details, Home',
     'Move each case through the status stages, assign an owner in the same plant, '
     'set target dates and see overdue items first in My assignments.'),
    ('Reports and analytics', 'Reports tab',
     'Dashboards by plant, severity and week, top hazards and days since LTI. '
     'Export to CSV or PDF for review meetings.'),
]
gap = 16
colw = (W - 2 * M - 2 * gap) / 3
ch = 134
y0 = gtop - 34
for i, (t, where, d) in enumerate(features):
    col, row = i % 3, i // 3
    x = M + col * (colw + gap)
    y = y0 - row * (ch + gap) - ch
    rrect(x, y, colw, ch, 12, CARD, BORDER)
    c.setFillColor(INDIGO)
    c.roundRect(x, y + 14, 4, ch - 28, 2, fill=1, stroke=0)
    c.setFont('P-SemiBold', 14)
    c.setFillColor(TEXT1)
    c.drawString(x + 18, y + ch - 28, t)
    c.setFont('P-Medium', 9.5)
    c.setFillColor(TEAL)
    c.drawString(x + 18, y + ch - 44, where)
    para(d, x + 18, y + ch - 66, colw - 34, 'P-Regular', 10.2, 15, TEXT2)

# ── How to use it ────────────────────────────────────────────────────────────
htop = y0 - 2 * (ch + gap) - 10
c.setStrokeColor(BORDER)
c.line(M, htop + 12, W - M, htop + 12)
c.setFont('P-Bold', 20)
c.setFillColor(TEXT1)
c.drawString(M, htop - 18, 'How to use it')

how = [
    ('Open the app', 'Go to safetylens.in in any browser, or install the Android app from the login screen.'),
    ('Sign in', 'Use your P.no and password. On first sign-in you may be asked to set a new password.'),
    ('Report', 'Tap AI Scan for a photo, or Near Miss to describe an event. Add location and details.'),
    ('Check the AI', 'Accept, edit or delete each suggested finding. You decide what is filed.'),
    ('Submit', 'Your supervisor validates the report and assigns corrective action.'),
    ('Follow up', 'Track your cases on Home and in My assignments until they are closed.'),
]
hw = (W - 2 * M - 24) / 2
rows_y = [htop - 52]
for i, (t, d) in enumerate(how):
    col, row = i // 3, i % 3
    bx = M + col * (hw + 24)
    ly = htop - 48 - row * 54
    c.setFillColor(INDIGO_T)
    c.circle(bx + 14, ly + 4, 14, fill=1, stroke=0)
    c.setFillColor(INDIGO)
    c.setFont('P-Bold', 13)
    c.drawCentredString(bx + 14, ly - 0.5, str(i + 1))
    c.setFont('P-SemiBold', 12.5)
    c.setFillColor(TEXT1)
    c.drawString(bx + 40, ly + 1, t)
    para(d, bx + 40, ly - 16, hw - 44, 'P-Regular', 10.5, 15, TEXT2)

btop = htop - 48 - 3 * 54 + 2
bw = (W - 2 * M - 2 * gap) / 3
bh = 106
boxes = [
    ('Contractor on site?',
     'Tap Contractor Access on the login screen. No account is needed to run an '
     'AI Scan or report a near miss.', INDIGO_T, TEXT1, TEXT2),
    ('For supervisors and managers',
     'Validate reports, assign actions within your plant, track overdue items '
     'and spot repeat hazards in Reports.', INDIGO_T, TEXT1, TEXT2),
    ('AI advises. People decide.',
     'Each AI finding is a suggestion with a confidence level. You review it '
     'before filing, and a person always makes the final call.',
     NAVY, white, HexColor('#D5D8F0')),
]
for i, (t, body, fill, tcol, bcol) in enumerate(boxes):
    x = M + i * (bw + gap)
    rrect(x, btop - bh, bw, bh, 12, fill)
    c.setFont('P-SemiBold', 13)
    c.setFillColor(tcol)
    c.drawString(x + 18, btop - 28, t)
    para(body, x + 18, btop - 50, bw - 36, 'P-Regular', 10.5, 15, bcol)
ly = by = btop - bh

# ── Footer ───────────────────────────────────────────────────────────────────
FB = 84
c.setFillColor(NAVY)
c.rect(0, 0, W, FB, fill=1, stroke=0)
qr = qrcode.QRCode(border=1, box_size=10)
qr.add_data('https://safetylens.in')
qr.make(fit=True)
img = qr.make_image(fill_color='#1A1A3E', back_color='white')
img.save('/tmp/qr.png')
c.drawImage('/tmp/qr.png', W - M - 64, 10, 64, 64)
c.setFont('P-Bold', 22)
c.setFillColor(white)
c.drawString(M, 46, 'safetylens.in')
c.setFont('P-Regular', 11)
c.setFillColor(HexColor('#C7CBE8'))
c.drawString(M, 25, 'Web and Android  |  English and Hindi  |  Light and dark mode')
c.setFont('P-SemiBold', 15)
c.setFillColor(CYAN)
c.drawRightString(W - M - 80, 46, 'Safety starts with me')
c.setFont('P-Regular', 10)
c.setFillColor(HexColor('#C7CBE8'))
c.drawRightString(W - M - 80, 27, 'Scan to open SafetyLens')

c.showPage()
c.save()
print('ok', ly, by)
