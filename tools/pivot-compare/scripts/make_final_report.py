#!/usr/bin/env python3
"""
Builds the shareable final output of a pivot-compare list-mode run:

    <OUT>/Test Summary Report - <TITLE>.docx    one Word report (chapters like the team's Test Summary Report template)
    <OUT>/<TITLE> - Results.xlsx                one line per table + how to read + NEW data tested + open items
    <OUT>/<TABLE>/<TABLE> - results.xlsx        per table: Summary, KPI summary, Different values, Info columns
    <OUT>/<TABLE>/summary.txt
    <OUT>/Supporting_details/                   copy of the raw report folder (files over 5 MB and duplicate_keys.csv left out)

It only READS the report folder of the run. It writes nothing to the databases and changes nothing in the report folder.
Python standard library only (no pip install). Usage:

    python3 scripts/make_final_report.py REPORT_DIR OUT_DIR [--title "NS Pivot Comparison"] [--author "Name"]
            [--notes notes.md] [--comments comments.csv] [--fingerprint fingerprint.csv]

REPORT_DIR  the folder run.sh wrote in list mode (it holds pairs_summary.csv and one folder per table)
--notes     optional markdown file with the sections  ## Out of scope / ## Variations / ## Observations / ## Open items /
            ## Conclusion  (one "- " bullet per point). Only what a person has confirmed belongs there.
--comments  optional CSV  name,comment  (one human comment per table, added after the numbers)
--fingerprint optional CSV (any columns) shown on its own sheet: which NEW data was tested
"""
import argparse, csv, datetime, os, re, shutil, sys, zipfile
from xml.sax.saxutils import escape

csv.field_size_limit(10**9)
MAX_DIFF_ROWS = 100000      # rows of different values per table workbook
MAX_INFO_ROWS = 50000       # rows of label-column differences per table workbook
MAX_COPY_BYTES = 5 * 1024 * 1024
BAD_XML = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def x(s):
    return escape(BAD_XML.sub("", str(s)))


def fmt(n):
    return "{:,}".format(n) if isinstance(n, int) else str(n)


# ============================================================================================================
# reading the run
# ============================================================================================================
def read_csv_rows(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        return list(csv.reader(f))


def read_env(path):
    out = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip("'\"")
    return out


def num(detail, key):
    m = re.search(re.escape(key) + r"=(\d+)", detail)
    return int(m.group(1)) if m else None


def read_notes(path):
    sections, cur = {}, None
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("## "):
                    cur = line[3:].strip().lower(); sections[cur] = []
                elif cur and line.strip().startswith("- "):
                    sections[cur].append(line.strip()[2:].strip())
                elif cur and line.strip() and sections[cur]:
                    sections[cur][-1] += " " + line.strip()
    return sections


def load_run(report_dir, comments):
    ps = os.path.join(report_dir, "pairs_summary.csv")
    if not os.path.isfile(ps):
        sys.exit("pairs_summary.csv not found in %s (this builder is for list-mode runs)" % report_dir)
    rows = []
    for r in csv.DictReader(open(ps, newline="", encoding="utf-8")):
        name, res, d = r["name"], r["result"], r["detail"]
        t = dict(name=name, result=res, detail=d, level="Cell" if name.upper().startswith("CELL") else "Node")
        for k, key in (("only_old", "objects only old"), ("only_new", "only new"), ("kpi_old", "KPI columns only old"),
                       ("compared", "values compared"), ("different", "different"), ("null_old", "null_old_only"),
                       ("null_new", "null_new_only"), ("common", "common objects")):
            t[k] = num(d, key)
        # "only new" appears twice (objects, KPI columns): the first one belongs to objects, the second to KPI columns
        m = re.search(r"objects only old=(\d+) only new=(\d+), KPI columns only old=(\d+) only new=(\d+)", d)
        if m:
            t["only_old"], t["only_new"], t["kpi_old"], t["kpi_new"] = (int(m.group(i)) for i in (1, 2, 3, 4))
        else:
            t["kpi_new"] = None
        folder = os.path.join(report_dir, name)
        t["folder"] = folder
        t["env"] = read_env(os.path.join(folder, "config_used.env"))
        has = t["compared"] is not None
        if res == "IDENTICAL":
            t["status"] = "PASS"
        elif not has:
            t["status"] = res          # NOT COMPARABLE or ERROR: no numbers
        else:
            clean = all((t[k] or 0) == 0 for k in ("different", "only_old", "only_new", "null_old", "null_new", "kpi_old", "kpi_new"))
            t["status"] = "PASS" if clean else "NOT MET"
        t["equal"] = "n/a" if not has else ("Yes" if t["different"] == 0 else "No")
        t["auto"], t["top_kpis"], t["example"] = auto_comment(t)
        t["comment"] = t["auto"] + ((" " + comments[name]) if name in comments else "")
        rows.append(t)
    if not rows:
        sys.exit("pairs_summary.csv has no table lines")
    return rows


def kpi_diffs(folder):
    p = os.path.join(folder, "kpi_summary.csv")
    out = []
    if os.path.isfile(p):
        rows = read_csv_rows(p)
        if rows:
            h = rows[0]
            try:
                ik, idf = h.index("kpi"), h.index("different")
            except ValueError:
                return out
            for r in rows[1:]:
                try:
                    if int(r[idf]) > 0:
                        out.append((r[ik], int(r[idf])))
                except ValueError:
                    pass
    return sorted(out, key=lambda a: -a[1])


def diff_stream(folder):
    """Yield the header, then the rows with kind == DIFF of differences.csv. Also remember the largest abs_diff row."""
    p = os.path.join(folder, "differences.csv")
    if not os.path.isfile(p):
        return None, [], None, 0
    keep, best, best_v, total = [], None, -1.0, 0
    with open(p, newline="", encoding="utf-8", errors="replace") as f:
        rd = csv.reader(f)
        h = next(rd, None)
        if not h or "kind" not in h:
            return h, [], None, 0
        ik = h.index("kind"); ia = h.index("abs_diff") if "abs_diff" in h else None
        for r in rd:
            if len(r) <= ik or r[ik] != "DIFF":
                continue
            total += 1
            if len(keep) < MAX_DIFF_ROWS:
                keep.append(r)
            if ia is not None:
                try:
                    v = float(r[ia])
                    if v > best_v:
                        best_v, best = v, r
                except ValueError:
                    pass
    return h, keep, best, total


def auto_comment(t):
    if t["compared"] is None:
        return ("%s: no numbers (see %s.screen.txt in the run folder)." % (t["result"], t["name"]), [], None)
    parts = []
    if t["different"]:
        parts.append("%s different value%s" % (fmt(t["different"]), "" if t["different"] == 1 else "s"))
    else:
        parts.append("All %s compared values equal" % fmt(t["compared"]))
    if t["only_old"]: parts.append("%s objects only in OLD" % fmt(t["only_old"]))
    if t["only_new"]: parts.append("%s objects only in NEW" % fmt(t["only_new"]))
    if t["null_new"]: parts.append("%s values empty in NEW only" % fmt(t["null_new"]))
    if t["null_old"]: parts.append("%s values empty in OLD only" % fmt(t["null_old"]))
    if t.get("kpi_old"): parts.append("%d KPI column%s only in OLD" % (t["kpi_old"], "" if t["kpi_old"] == 1 else "s"))
    if t.get("kpi_new"): parts.append("%d KPI column%s only in NEW" % (t["kpi_new"], "" if t["kpi_new"] == 1 else "s"))
    top = kpi_diffs(t["folder"])
    if top:
        parts.append("KPIs with different values: " + ", ".join("%s (%s)" % (k, fmt(n)) for k, n in top[:4]))
    key = (t["env"].get("OLD_KEY_COLS") or "").replace(",", " + ")
    if key:
        parts.append("paired by " + key)
    return ("; ".join(parts) + ".", top, None)


# ============================================================================================================
# minimal xlsx writer (standard library)
# ============================================================================================================
def col_letter(i):
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


XLSX_STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="3"><font><sz val="10"/><name val="Calibri"/></font><font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><font><i/><sz val="10"/><name val="Calibri"/></font></fonts>
<fills count="5"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF1F3864"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF8CBAD"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFC6E0B4"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="7">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>
<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>
<xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>
<xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>
<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>
</cellXfs></styleSheet>"""
S_HDR, S_NUM, S_WRAP, S_RED, S_GRN, S_NOTE = 1, 2, 3, 4, 5, 6


def sheet_xml(rows, widths, freeze_row):
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">']
    if freeze_row:
        out.append('<sheetViews><sheetView workbookViewId="0"><pane ySplit="%d" topLeftCell="A%d" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>' % (freeze_row, freeze_row + 1))
    if widths:
        out.append("<cols>" + "".join('<col min="%d" max="%d" width="%s" customWidth="1"/>' % (i + 1, i + 1, w) for i, w in enumerate(widths)) + "</cols>")
    out.append("<sheetData>")
    for ri, row in enumerate(rows, 1):
        out.append('<row r="%d">' % ri)
        for ci, cell in enumerate(row):
            v, st = cell if isinstance(cell, tuple) else (cell, 0)
            ref = "%s%d" % (col_letter(ci), ri)
            if v is None or v == "":
                if st:
                    out.append('<c r="%s" s="%d"/>' % (ref, st))
            elif isinstance(v, bool) or not isinstance(v, (int, float)):
                out.append('<c r="%s" s="%d" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' % (ref, st, x(v)))
            else:
                out.append('<c r="%s" s="%d"><v>%s</v></c>' % (ref, st or S_NUM if isinstance(v, int) else st, v))
        out.append("</row>")
    out.append("</sheetData></worksheet>")
    return "".join(out)


def to_cell(v):
    """text that is a plain number becomes a number (so it sorts); leading-zero ids stay text"""
    if isinstance(v, str) and re.fullmatch(r"-?(0|[1-9]\d{0,14})(\.\d+)?", v):
        return float(v) if "." in v else int(v)
    return v


def table_rows(data, note=None):
    """data[0] = header. Returns (rows, freeze_row)"""
    rows = []
    if note:
        rows.append([(note, S_NOTE)]); rows.append([])
    rows.append([(h, S_HDR) for h in data[0]])
    for r in data[1:]:
        rows.append([to_cell(v) if not isinstance(v, tuple) else v for v in r])
    return rows, len(rows) - (len(data) - 1)


def write_xlsx(path, sheets):
    """sheets = list of dict(name, rows, widths, freeze)"""
    names = []
    for s in sheets:
        n = re.sub(r"[\[\]\*\?/\\:]", " ", s["name"])[:31]
        names.append(n)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' + "".join('<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' % (i + 1) for i in range(len(sheets))) + "</Types>")
        z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr("xl/workbook.xml", '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>' + "".join('<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (x(n), i + 1, i + 1) for i, n in enumerate(names)) + "</sheets></workbook>")
        z.writestr("xl/_rels/workbook.xml.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + "".join('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>' % (i + 1, i + 1) for i in range(len(sheets))) + '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>' % (len(sheets) + 1))
        z.writestr("xl/styles.xml", XLSX_STYLES)
        for i, s in enumerate(sheets):
            z.writestr("xl/worksheets/sheet%d.xml" % (i + 1), sheet_xml(s["rows"], s.get("widths"), s.get("freeze", 0)))


def simple_sheet(name, data, widths, note=None):
    rows, fr = table_rows(data, note)
    return dict(name=name, rows=rows, widths=widths, freeze=fr)


# ============================================================================================================
# minimal docx writer (standard library)
# ============================================================================================================
DOC_STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="21"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="100"/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="300" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="32"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="26"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="60"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/></w:rPr></w:style>
</w:styles>"""


class Doc:
    def __init__(self):
        self.b = []

    def p(self, text="", bold=False, size=None, center=False, color=None, indent=None):
        ppr = ""
        if center: ppr += '<w:jc w:val="center"/>'
        if indent: ppr += '<w:ind w:left="%d" w:hanging="260"/>' % indent
        rpr = ("<w:b/>" if bold else "") + ('<w:color w:val="%s"/>' % color if color else "") + ('<w:sz w:val="%d"/>' % (size * 2) if size else "")
        runs = []
        for i, line in enumerate(str(text).split("\n")):
            runs.append("<w:r>%s<w:t xml:space=\"preserve\">%s</w:t></w:r>" % ("<w:rPr>%s</w:rPr>" % rpr if rpr else "", x(line)))
            if i < len(str(text).split("\n")) - 1:
                runs.append("<w:r><w:br/></w:r>")
        self.b.append("<w:p>%s%s</w:p>" % ("<w:pPr>%s</w:pPr>" % ppr if ppr else "", "".join(runs)))

    def h(self, level, text):
        self.b.append('<w:p><w:pPr><w:pStyle w:val="Heading%d"/></w:pPr><w:r><w:t xml:space="preserve">%s</w:t></w:r></w:p>' % (level, x(text)))

    def bullets(self, items):
        for it in items:
            self.p("•  " + it, indent=360)

    def table(self, headers, data, widths_cm, size=9):
        tw = [int(w * 567) for w in widths_cm]
        o = ['<w:tbl><w:tblPr><w:tblW w:w="%d" w:type="dxa"/><w:tblBorders>%s</w:tblBorders><w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="70" w:type="dxa"/><w:right w:w="70" w:type="dxa"/></w:tblCellMar></w:tblPr>' % (sum(tw), "".join('<w:%s w:val="single" w:sz="4" w:space="0" w:color="808080"/>' % s for s in ("top", "left", "bottom", "right", "insideH", "insideV")))]
        o.append("<w:tblGrid>" + "".join('<w:gridCol w:w="%d"/>' % w for w in tw) + "</w:tblGrid>")

        def cell(txt, w, fill=None, bold=False, white=False):
            shd = '<w:shd w:val="clear" w:color="auto" w:fill="%s"/>' % fill if fill else ""
            rpr = "<w:sz w:val=\"%d\"/>" % (size * 2) + ("<w:b/>" if bold else "") + ('<w:color w:val="FFFFFF"/>' if white else "")
            return '<w:tc><w:tcPr><w:tcW w:w="%d" w:type="dxa"/>%s</w:tcPr><w:p><w:pPr><w:spacing w:after="0"/></w:pPr><w:r><w:rPr>%s</w:rPr><w:t xml:space="preserve">%s</w:t></w:r></w:p></w:tc>' % (w, shd, rpr, x(txt))
        o.append('<w:tr><w:trPr><w:tblHeader/></w:trPr>' + "".join(cell(h, tw[i], "1F3864", True, True) for i, h in enumerate(headers)) + "</w:tr>")
        for row in data:
            fills = {"NOT MET": "F8CBAD", "PASS": "C6E0B4", "Not Met": "F8CBAD", "Met": "C6E0B4"}
            o.append("<w:tr>" + "".join(cell(v, tw[i], fills.get(str(v))) for i, v in enumerate(row)) + "</w:tr>")
        o.append("</w:tbl>")
        self.b.append("".join(o))
        self.p("")

    def save(self, path):
        body = "".join(self.b) + '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>'
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>')
            z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
            z.writestr("word/_rels/document.xml.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>')
            z.writestr("word/styles.xml", DOC_STYLES)
            z.writestr("word/document.xml", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>%s</w:body></w:document>' % body)


# ============================================================================================================
# building the output
# ============================================================================================================
def period_text(env):
    f, t = env.get("PERIOD_FROM", "?"), env.get("PERIOD_TO", "?")
    txt = "%s to %s (UTC, end not included)" % (f, t)
    tz = env.get("OLD_PERIOD_TZ")
    try:
        from zoneinfo import ZoneInfo
        pf = datetime.datetime.strptime(f[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        pt = datetime.datetime.strptime(t[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        z = ZoneInfo(tz)
        txt += " = %s to %s %s" % (pf.astimezone(z).strftime("%Y-%m-%d %H:%M"), pt.astimezone(z).strftime("%Y-%m-%d %H:%M"), tz)
        n = -int(-(pt - pf).total_seconds() // 900)   # a period that starts before PERIOD_TO counts (round up)
        txt += ", %d quarter-hour periods" % n
    except Exception:
        pass
    return txt


def build(report_dir, out_dir, title, author, notes_path, comments_path, fingerprint_path):
    if os.path.exists(out_dir):
        sys.exit("%s already exists; nothing was written. Remove it or choose another folder." % out_dir)
    comments = {}
    if comments_path and os.path.isfile(comments_path):
        for r in csv.DictReader(open(comments_path, newline="", encoding="utf-8")):
            comments[r["name"].strip()] = r["comment"].strip()
    rows = load_run(report_dir, comments)
    env = rows[0]["env"]
    notes = read_notes(notes_path)
    today = datetime.date.today().strftime("%d-%m-%Y")
    # when the comparison finished = when pairs_summary.csv was last written (server local time)
    run_time = datetime.datetime.fromtimestamp(os.path.getmtime(os.path.join(report_dir, "pairs_summary.csv"))).strftime("%Y-%m-%d %H:%M")
    n = len(rows)
    ok = [r for r in rows if r["compared"] is not None]
    tot = lambda k: sum(r[k] or 0 for r in rows)
    t_cmp, t_dif = tot("compared"), tot("different")
    n_pass = sum(1 for r in rows if r["status"] == "PASS")
    n_zero = sum(1 for r in ok if r["different"] == 0)
    n_nc = sum(1 for r in rows if r["status"] == "NOT COMPARABLE")
    n_err = sum(1 for r in rows if r["status"] == "ERROR")
    n_notmet = sum(1 for r in rows if r["status"] == "NOT MET")
    pct = (100.0 * (t_cmp - t_dif) / t_cmp) if t_cmp else 0.0
    period = period_text(env)
    zero_names = [r["name"] for r in ok if r["different"] == 0]
    diff_rows = sorted([r for r in ok if r["different"]], key=lambda r: -r["different"])

    os.makedirs(out_dir)
    # ---- per-table folders
    for r in rows:
        d = os.path.join(out_dir, r["name"]); os.makedirs(d)
        sums = [["Item", "Value"], ["Table", r["name"]], ["Status", (r["status"], S_GRN if r["status"] == "PASS" else S_RED)],
                ["Paired by (key columns)", (r["env"].get("OLD_KEY_COLS") or "").replace(",", " + ")],
                ["Values compared (filled on both sides)", r["compared"]], ["Values different", r["different"]],
                ["Values empty in NEW only", r["null_new"]], ["Values empty in OLD only", r["null_old"]],
                ["Objects on both sides", r["common"]], ["Objects only in OLD", r["only_old"]], ["Objects only in NEW", r["only_new"]],
                ["KPI columns only in OLD", r["kpi_old"]], ["KPI columns only in NEW", r["kpi_new"]], ["Comment", (r["comment"], S_WRAP)]]
        s1 = simple_sheet("Summary", sums, [42, 110])
        sheets = [s1]
        kp = os.path.join(r["folder"], "kpi_summary.csv")
        if os.path.isfile(kp):
            sheets.append(simple_sheet("KPI summary", read_csv_rows(kp), [14, 14, 14, 14, 16, 16, 18]))
        h, keep, best, total = diff_stream(r["folder"])
        if h:
            note = None
            if total == 0: note = "No different values in this table."
            elif total > len(keep): note = "Showing the first %s of %s different values. Full file: Supporting_details/%s/differences.csv" % (fmt(len(keep)), fmt(total), r["name"])
            sheets.append(simple_sheet("Different values", [h] + keep, [18, 55, 12, 18, 18, 18, 8], note))
            if best is not None:
                r["example"] = best
        ip = os.path.join(r["folder"], "info_differences.csv")
        if os.path.isfile(ip):
            idd = read_csv_rows(ip)
            if idd:
                note = None
                if len(idd) - 1 > MAX_INFO_ROWS:
                    note = "Showing the first %s of %s rows. Full file: Supporting_details/%s/info_differences.csv" % (fmt(MAX_INFO_ROWS), fmt(len(idd) - 1), r["name"]); idd = idd[:MAX_INFO_ROWS + 1]
                elif len(idd) == 1:
                    note = "No differences in the label columns (names, ids, LAC, SAC, TAC)."
                sheets.append(simple_sheet("Info columns (labels)", idd, [18, 55, 14, 22, 22, 10], note))
        write_xlsx(os.path.join(d, "%s - results.xlsx" % r["name"]), sheets)
        with open(os.path.join(d, "summary.txt"), "w", encoding="utf-8") as f:
            f.write("%s  (%s table)\nStatus: %s\n\nPeriod: %s\nOLD: %s.%s   NEW: %s.%s\n\n" % (r["name"], r["level"].lower(), r["status"], period, r["env"].get("OLD_SCHEMA", "?"), r["env"].get("OLD_TABLE", "?"), r["env"].get("NEW_SCHEMA", "?"), r["env"].get("NEW_TABLE", "?")))
            for lab, k in (("Values compared", "compared"), ("Values different", "different"), ("Empty in NEW only", "null_new"), ("Empty in OLD only", "null_old"), ("Objects on both sides", "common"), ("Objects only in OLD", "only_old"), ("Objects only in NEW", "only_new")):
                f.write("%-26s%s\n" % (lab + ":", fmt(r[k]) if r[k] is not None else "n/a"))
            f.write("\nComment: %s\n" % r["comment"])
            if r["example"]:
                f.write("Largest difference: %s\n" % " | ".join(r["example"]))
            f.write("\nSame pattern in every table folder: this file and one results workbook.\nRaw files: ../Supporting_details\n")

    # ---- overall workbook
    hdr = ["Table", "Level", "Status", "All paired values equal?", "Values compared", "Values different", "Empty in NEW only", "Empty in OLD only", "Objects only in OLD", "Objects only in NEW", "Comment"]
    res = [[(h, S_HDR) for h in hdr]]
    for r in rows:
        res.append([r["name"], r["level"], (r["status"], S_GRN if r["status"] == "PASS" else S_RED), r["equal"]] + [r[k] for k in ("compared", "different", "null_new", "null_old", "only_old", "only_new")] + [(r["comment"], S_WRAP)])
    res.append(["TOTAL (%d tables)" % n, "", "%d PASS / %d NOT MET%s" % (n_pass, n_notmet, (" / %d other" % (n_nc + n_err)) if (n_nc + n_err) else ""), "%d of %d tables" % (n_zero, n), t_cmp, t_dif, tot("null_new"), tot("null_old"), tot("only_old"), tot("only_new"), "%.2f%% of compared values are equal" % pct])
    ov = [dict(name="Results", rows=res, widths=[20, 8, 14, 14, 16, 14, 16, 16, 16, 16, 110], freeze=1)]
    ov.append(simple_sheet("How to read", [["Term", "Meaning"],
        ["Status PASS", "0 different values AND nothing found on one side only AND no value empty on one side AND no KPI column on one side only."],
        ["Status NOT MET", "At least one of the above is not zero. The comment says which."],
        ["All paired values equal?", "Yes = every value filled on both sides is equal within the tolerance. It does not cover objects or values found on one side only."],
        ["Values compared", "Values filled on both sides, for objects found on both sides."],
        ["Empty in NEW only / OLD only", "The object is on both sides; one side has a number and the other is empty."],
        ["Objects only in OLD / NEW", "An object (cell or node and period) found in one table but not the other."],
        ["Tolerance", "absolute %s, relative %s (equal when abs(old-new) <= abs + rel*abs(old))" % (env.get("TOLERANCE_ABS", "?"), env.get("TOLERANCE_REL", "?"))],
        ["Period", period],
        ["Data as of", "Comparison finished %s (server time). Data that arrives later or a change in the NEW calculator can change the result." % run_time]], [30, 130]))
    if fingerprint_path and os.path.isfile(fingerprint_path):
        fp = read_csv_rows(fingerprint_path)
        if fp:
            ov.append(simple_sheet("NEW data tested", fp, [40] + [20] * (len(fp[0]) - 1), "State of the NEW tables in the tested window at the time of the run. If the NEW data changes, the comparison has to be run again."))
    oi = [["#", "Open item", "Status"]]
    for i, t in enumerate(notes.get("open items", []), 1):
        oi.append([i, t, ""])
    if len(oi) == 1: oi.append([1, "None recorded in the notes file for this run.", ""])
    ov.append(simple_sheet("Open items", oi, [5, 140, 20]))
    write_xlsx(os.path.join(out_dir, "%s - Results.xlsx" % title), ov)

    # ---- Word report
    D = Doc()
    D.p(title + "\nOLD (Java) calculator vs NEW KPI calculator", bold=True, size=20, center=True, color="1F3864")
    D.p("Test Summary Report (TSR)", bold=True, size=16, center=True)
    D.p("Version: Draft\nDate: %s\nComparison finished: %s (server time)\nAuthor: %s\nThis is a comparison report, not a production sign-off." % (today, run_time, author or "(not set)"))
    D.table(["Role", "Name", "Department", "Signature / email", "Date of approval"], [["Approver", "", "", "", ""], ["Reviewer", "", "", "", ""]], [3, 4, 3.5, 4, 3])
    D.h(1, "1. Executive Summary")
    D.h(2, "1.1 Test Phase Summary")
    D.p("This report records the comparison of the pivot tables written by the NEW KPI calculator with the pivot tables written by the OLD (Java) calculator, for %d tables (%d cell tables, %d node tables). The aim is to show that the NEW calculator produces the same KPI values as the OLD one." % (n, sum(1 for r in rows if r["level"] == "Cell"), sum(1 for r in rows if r["level"] == "Node")))
    D.bullets(["Period tested: " + period + ".",
               "Approach: the OLD and NEW pivot tables are read (read-only), rows are paired by the key columns of each table, every KPI value is compared, and the differences are recorded.",
               "Tolerance: absolute %s, relative %s." % (env.get("TOLERANCE_ABS", "?"), env.get("TOLERANCE_REL", "?")),
               "Tool: pivot-compare (DuckDB CLI + bash); this report is built from its report folder."])
    D.h(2, "1.2 Test Environment & Code Base")
    D.table(["Item", "Detail"], [["OLD side", "%s: schema %s (period column %s, %s)" % (env.get("OLD_SOURCE", "?"), env.get("OLD_SCHEMA", "?"), env.get("OLD_PERIOD_COL", "?"), env.get("OLD_PERIOD_TZ", "?"))],
                                  ["NEW side", "%s: schema %s (period column %s, %s)" % (env.get("NEW_SOURCE", "?"), env.get("NEW_SCHEMA", "?"), env.get("NEW_PERIOD_COL", "?"), env.get("NEW_PERIOD_TZ", "?"))],
                                  ["Test stub", "No"], ["Report built", today]], [4, 13])
    D.h(2, "1.3 Test Data Setup")
    D.p("All statements in this report describe the OLD and NEW data as they were when the comparison finished (%s). The NEW calculator is still under test: data that arrives later, or a change of its logic, can change the result, and a value that is missing in NEW now may be present after a later run." % run_time)
    if fingerprint_path and os.path.isfile(fingerprint_path):
        D.p("The NEW tables may change while they are being tested. The results workbook has a sheet 'NEW data tested' (row count, periods and last update of each NEW table in the tested window) that shows which NEW data was compared. If that data changes, the comparison has to be run again.")
    else:
        D.p("The NEW tables may change while they are being tested. No fingerprint of the NEW data (row count, periods and last update per table) was recorded for this run, so this report does not prove that the NEW data stayed the same. If the NEW data changes, the comparison has to be run again.")
    D.h(2, "1.4 Compliance to Exit Criteria")
    met = "Met" if n_pass == n else "Not Met"
    D.table(["No.", "Exit criterion", "Compliance", "Comments"], [["1", "All NEW pivot values equal the OLD values for the tested period, for all %d tables" % n, met,
        "%d of %d tables have all paired values equal. %s values compared, %s different (%.2f%% equal). %d tables are PASS, %d NOT MET%s." % (n_zero, n, fmt(t_cmp), fmt(t_dif), pct, n_pass, n_notmet, (", %d could not be compared or failed" % (n_nc + n_err)) if (n_nc + n_err) else "")]], [1.2, 6, 2.3, 7.5])
    D.h(2, "1.5 Conclusion & Recommendations")
    c = ["%d tables compared; %s of %s values equal (%.2f%%)." % (n, fmt(t_cmp - t_dif), fmt(t_cmp), pct)]
    if zero_names: c.append("%d tables have 0 different values among the values that paired: %s." % (len(zero_names), ", ".join(zero_names)))
    if diff_rows: c.append("%d tables have different values: %s." % (len(diff_rows), ", ".join("%s %s" % (r["name"], fmt(r["different"])) for r in diff_rows)))
    c += notes.get("conclusion", [])
    D.bullets(c)
    D.h(1, "2. Test Scope Summary")
    D.h(2, "2.1 In Scope")
    D.bullets(["%d tables: %s." % (n, ", ".join(r["name"] for r in rows)), "All KPI columns that exist on both sides, for the period above."])
    D.h(2, "2.2 Out of Scope")
    D.bullets(notes.get("out of scope", ["None recorded for this run."]))
    D.h(2, "2.3 Variations in Test Approach/Scope")
    D.bullets(notes.get("variations", ["None recorded for this run."]))
    D.h(1, "3. Test Results")
    D.h(2, "3.1 Test Execution Summary")
    D.p("%d tables compared: %d PASS, %d NOT MET%s. Values compared %s, different %s, empty in NEW only %s, empty in OLD only %s, objects only in OLD %s, objects only in NEW %s." % (n, n_pass, n_notmet, (", %d NOT COMPARABLE, %d ERROR" % (n_nc, n_err)) if (n_nc + n_err) else "", fmt(t_cmp), fmt(t_dif), fmt(tot("null_new")), fmt(tot("null_old")), fmt(tot("only_old")), fmt(tot("only_new"))))
    D.h(2, "3.2 Test Cases Executed (one line per table)")
    D.table(["Table", "Status", "Values compared", "Different", "Empty NEW only", "Empty OLD only", "Only OLD", "Only NEW"],
            [[r["name"], r["status"]] + [fmt(r[k]) if r[k] is not None else "n/a" for k in ("compared", "different", "null_new", "null_old", "only_old", "only_new")] for r in rows], [3.1, 2, 2.8, 1.8, 2.1, 2.1, 1.8, 1.8], size=8)
    D.h(2, "3.3 Outstanding Test Cases")
    D.h(3, "3.3.1 Failed (different values)")
    if diff_rows:
        D.table(["Table", "Different", "Comment"], [[r["name"], fmt(r["different"]), r["comment"]] for r in diff_rows], [3, 2, 12], size=8)
    else:
        D.p("No table has different values.")
    D.h(3, "3.3.2 Not run / not comparable / error")
    nr = [r for r in rows if r["status"] in ("NOT COMPARABLE", "ERROR")]
    if nr:
        D.table(["Table", "Result", "Detail"], [[r["name"], r["result"], r["detail"]] for r in nr], [3, 3, 11], size=8)
    else:
        D.p("None.")
    D.h(2, "3.4 Defect Summary")
    D.p("No defects are raised by this report. Each difference has to be analysed to decide whether it is a NEW calculator issue, an OLD calculator issue, a data issue or a difference in setup.")
    D.h(1, "4. Open Issues & Risks")
    D.h(2, "4.1 Issues and open items")
    D.bullets(notes.get("open items", ["None recorded for this run."]))
    D.h(1, "5. Observations / Findings")
    D.bullets(notes.get("observations", ["None recorded for this run."]))
    D.h(1, "6. Detailed Test Execution Stats")
    D.p("Per-table detail (summary, KPI-level counts, every different value, label-column differences) is in the folder of each table next to this report. The raw files of the run are in Supporting_details.")
    D.h(1, "Appendix 1. Acronyms")
    D.table(["Term", "Meaning"], [["OLD / NEW", "OLD (Java) KPI calculator / NEW KPI calculator"], ["KPI", "Key Performance Indicator"], ["CM", "Configuration Management data (cell and site attributes)"], ["UTC", "Coordinated Universal Time"], ["TSR", "Test Summary Report"]], [4, 13])
    D.save(os.path.join(out_dir, "Test Summary Report - %s.docx" % title))

    # ---- supporting details: copy of the run folder, big files left out
    sup = os.path.join(out_dir, "Supporting_details")
    skipped = []
    for root, dirs, files in os.walk(report_dir):
        rel = os.path.relpath(root, report_dir)
        os.makedirs(os.path.join(sup, rel), exist_ok=True)
        for fn in files:
            src = os.path.join(root, fn)
            if fn == "duplicate_keys.csv" or os.path.getsize(src) > MAX_COPY_BYTES:
                skipped.append(os.path.join(rel, fn) if rel != "." else fn); continue
            shutil.copy2(src, os.path.join(sup, rel, fn))
    for extra in (notes_path, comments_path, fingerprint_path):
        if extra and os.path.isfile(extra):
            shutil.copy2(extra, os.path.join(sup, os.path.basename(extra)))
    with open(os.path.join(sup, "NOT_COPIED.txt"), "w", encoding="utf-8") as f:
        f.write("Left out of this copy (duplicate_keys.csv and files over 5 MB). They stay in the run's report folder:\n")
        f.write("\n".join(skipped) + "\n" if skipped else "(nothing)\n")
    # one zip next to the folder, so the person only has to download one file
    zp = out_dir.rstrip("/\\") + ".zip"
    if os.path.exists(zp):
        print("zip not written: %s already exists" % zp)
    else:
        with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
            base = os.path.dirname(os.path.abspath(out_dir))
            for root, dirs, files in os.walk(out_dir):
                for fn in files:
                    full = os.path.join(root, fn)
                    z.write(full, os.path.relpath(full, base))
        print("zip written: " + zp)
    print("final output written to: " + out_dir)
    print("  %d tables: %d PASS, %d NOT MET, %d other; %s values compared, %s different" % (n, n_pass, n_notmet, n_nc + n_err, fmt(t_cmp), fmt(t_dif)))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report_dir"); ap.add_argument("out_dir")
    ap.add_argument("--title", default="NS Pivot Comparison"); ap.add_argument("--author", default="")
    ap.add_argument("--notes"); ap.add_argument("--comments"); ap.add_argument("--fingerprint")
    a = ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9 _\-]+", a.title):
        sys.exit("--title may only hold letters, digits, space, _ and -")
    build(a.report_dir, a.out_dir, a.title, a.author, a.notes, a.comments, a.fingerprint)
