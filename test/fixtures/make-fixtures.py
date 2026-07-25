#!/usr/bin/env python3
"""Writes the spreadsheet fixtures the `using ... as xlsx/ods` tests read.

Both formats are a zip of XML, so the fixtures are built directly rather than
through a spreadsheet library. They deliberately include the awkward parts a
real file has: shared and rich-text strings, sparse rows that skip a column,
dates stored as day counts behind a builtin *and* a custom number format,
booleans, a formula's cached result, an empty sheet, and the huge trailing
repeat counts an ods uses to pad a table out to the sheet's full size.

Run from the repo root:  python3 test/fixtures/make-fixtures.py
"""
import datetime
import pathlib
import zipfile

HERE = pathlib.Path(__file__).parent

# xlsx counts days from this date; serial 1 is 1900-01-01.
XLSX_EPOCH = datetime.date(1899, 12, 30)


def serial(day: datetime.date) -> int:
    return (day - XLSX_EPOCH).days


JOINED_ADA = datetime.date(2026, 7, 25)
JOINED_LINUS = datetime.date(2026, 3, 2)

# --- xlsx ------------------------------------------------------------------

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>"""

ROOT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"""

# Sheet order here is the workbook order the reader must preserve, and the
# r:id values are deliberately not in file-name order so the relationships
# really have to be followed.
WORKBOOK = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="People" sheetId="1" r:id="rId2"/>
<sheet name="Blank" sheetId="2" r:id="rId1"/>
</sheets>
</workbook>"""

WORKBOOK_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>"""

# Index 4 is rich text: one logical string split across styled runs.
SHARED_STRINGS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="6" uniqueCount="6">
<si><t>name</t></si>
<si><t>joined</t></si>
<si><t>score</t></si>
<si><t>Ada</t></si>
<si><r><rPr><b/></rPr><t>O</t></r><r><t>&apos;Brien</t></r></si>
<si><t>note</t></si>
</sst>"""

# Cell format 1 is the builtin date format 14; cell format 2 is a custom one, so
# both routes into date detection are covered. Format 0 is General.
STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="2">
<numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/>
<numFmt numFmtId="165" formatCode="&quot;on &quot;yyyy\\-mm\\-dd hh:mm:ss"/>
</numFmts>
<cellXfs count="4">
<xf numFmtId="0"/>
<xf numFmtId="14"/>
<xf numFmtId="164"/>
<xf numFmtId="165"/>
</cellXfs>
</styleSheet>"""

SHEET1 = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="E1" t="s"><v>5</v></c></row>
<row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2" s="1"><v>{serial(JOINED_ADA)}</v></c><c r="C2"><v>91.5</v></c><c r="D2" t="b"><v>1</v></c><c r="E2" t="inlineStr"><is><t>inline note</t></is></c></row>
<row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" s="2"><v>{serial(JOINED_LINUS)}</v></c><c r="C3"><v>88</v></c><c r="E3" t="str"><f>CONCAT("cached")</f><v>cached result</v></c></row>
<row r="4"><c r="A4" t="s"><v>3</v></c><c r="B4" s="3"><v>{serial(JOINED_ADA)}.5</v></c></row>
</sheetData>
</worksheet>"""

SHEET2 = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData/>
</worksheet>"""

# --- ods -------------------------------------------------------------------

ODS_MIMETYPE = "application/vnd.oasis.opendocument.spreadsheet"

ODS_MANIFEST = """<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
<manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
</manifest:manifest>"""

# The 16381-cell and 1048573-row repeats are how an ods pads a table out to the
# sheet's full size; the reader has to see through them rather than expand them.
ODS_CONTENT = """<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
 xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
 office:version="1.2">
<office:body><office:spreadsheet>
<table:table table:name="People">
<table:table-column table:number-columns-repeated="3"/>
<table:table-row>
<table:table-cell office:value-type="string"><text:p>name</text:p></table:table-cell>
<table:table-cell office:value-type="string"><text:p>joined</text:p></table:table-cell>
<table:table-cell office:value-type="string"><text:p>score</text:p></table:table-cell>
<table:table-cell table:number-columns-repeated="16381"/>
</table:table-row>
<table:table-row>
<table:table-cell office:value-type="string"><text:p>Ada</text:p></table:table-cell>
<table:table-cell office:value-type="date" office:date-value="2026-07-25"><text:p>25/07/2026</text:p></table:table-cell>
<table:table-cell office:value-type="float" office:value="91.5"><text:p>91.5</text:p></table:table-cell>
</table:table-row>
<table:table-row>
<table:table-cell office:value-type="string"><text:p>O&apos;Brien</text:p></table:table-cell>
<table:table-cell office:value-type="date" office:date-value="2026-03-02T14:30:00"><text:p>02/03/2026 14:30</text:p></table:table-cell>
<table:table-cell office:value-type="boolean" office:boolean-value="true"><text:p>TRUE</text:p></table:table-cell>
</table:table-row>
<table:table-row table:number-rows-repeated="1048573">
<table:table-cell table:number-columns-repeated="16384"/>
</table:table-row>
</table:table>
<table:table table:name="Repeats">
<table:table-row>
<table:table-cell office:value-type="string" table:number-columns-repeated="3"><text:p>x</text:p></table:table-cell>
<table:table-cell office:value-type="time" office:time-value="PT14H30M05S"><text:p>14:30:05</text:p></table:table-cell>
</table:table-row>
</table:table>
</office:spreadsheet></office:body>
</office:document-content>"""


def write_zip(path, members, first_stored=None):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        # An ods keeps `mimetype` first and uncompressed, as the spec requires.
        if first_stored:
            name, data = first_stored
            info = zipfile.ZipInfo(name)
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, data)
        for name, data in members.items():
            archive.writestr(name, data)


# --- the shipped example's data ---------------------------------------------
# A plain two-sheet workbook, with none of the fixtures' awkwardness, so the
# example reads as the feature rather than as a test of it.
EXAMPLE = pathlib.Path("code-examples/12 - Files and Spreadsheets")

EXAMPLE_SHARED = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="8" uniqueCount="8">
<si><t>item</t></si><si><t>restocked</t></si><si><t>pence</t></si>
<si><t>Beeswax</t></si><si><t>Smoker fuel</t></si><si><t>Hive tool</t></si>
<si><t>site</t></si><si><t>Apiary</t></si>
</sst>"""

EXAMPLE_STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs>
</styleSheet>"""

EXAMPLE_WORKBOOK = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="Stock" sheetId="1" r:id="rId1"/>
<sheet name="Sites" sheetId="2" r:id="rId2"/>
</sheets>
</workbook>"""

EXAMPLE_WORKBOOK_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
</Relationships>"""

RESTOCKED = [
    datetime.date(2026, 7, 2),
    datetime.date(2026, 6, 18),
    datetime.date(2026, 7, 21),
]

EXAMPLE_SHEET1 = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>
<row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2" s="1"><v>{serial(RESTOCKED[0])}</v></c><c r="C2"><v>450</v></c></row>
<row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" s="1"><v>{serial(RESTOCKED[1])}</v></c><c r="C3"><v>1225</v></c></row>
<row r="4"><c r="A4" t="s"><v>5</v></c><c r="B4" s="1"><v>{serial(RESTOCKED[2])}</v></c><c r="C4"><v>899</v></c></row>
</sheetData>
</worksheet>"""

EXAMPLE_SHEET2 = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="s"><v>6</v></c></row>
<row r="2"><c r="A2" t="s"><v>7</v></c></row>
</sheetData>
</worksheet>"""

EXAMPLE_ODS = """<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
 xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
 office:version="1.2">
<office:body><office:spreadsheet>
<table:table table:name="Stock">
<table:table-row>
<table:table-cell office:value-type="string"><text:p>item</text:p></table:table-cell>
<table:table-cell office:value-type="string"><text:p>restocked</text:p></table:table-cell>
<table:table-cell office:value-type="string"><text:p>pence</text:p></table:table-cell>
</table:table-row>
<table:table-row>
<table:table-cell office:value-type="string"><text:p>Beeswax</text:p></table:table-cell>
<table:table-cell office:value-type="date" office:date-value="2026-07-02"><text:p>02/07/2026</text:p></table:table-cell>
<table:table-cell office:value-type="float" office:value="450"><text:p>450</text:p></table:table-cell>
</table:table-row>
<table:table-row>
<table:table-cell office:value-type="string"><text:p>Smoker fuel</text:p></table:table-cell>
<table:table-cell office:value-type="date" office:date-value="2026-06-18"><text:p>18/06/2026</text:p></table:table-cell>
<table:table-cell office:value-type="float" office:value="1225"><text:p>1225</text:p></table:table-cell>
</table:table-row>
</table:table>
</office:spreadsheet></office:body>
</office:document-content>"""


def write_example(root: pathlib.Path):
    if not root.exists():
        print("skipping example data:", root, "does not exist")
        return
    write_zip(
        root / "stock.xlsx",
        {
            "[Content_Types].xml": CONTENT_TYPES,
            "_rels/.rels": ROOT_RELS,
            "xl/workbook.xml": EXAMPLE_WORKBOOK,
            "xl/_rels/workbook.xml.rels": EXAMPLE_WORKBOOK_RELS,
            "xl/sharedStrings.xml": EXAMPLE_SHARED,
            "xl/styles.xml": EXAMPLE_STYLES,
            "xl/worksheets/sheet1.xml": EXAMPLE_SHEET1,
            "xl/worksheets/sheet2.xml": EXAMPLE_SHEET2,
        },
    )
    write_zip(
        root / "stock.ods",
        {
            "META-INF/manifest.xml": ODS_MANIFEST,
            "content.xml": EXAMPLE_ODS,
        },
        first_stored=("mimetype", ODS_MIMETYPE),
    )
    print("wrote stock.xlsx and stock.ods into", root)


def main():
    write_zip(
        HERE / "book.xlsx",
        {
            "[Content_Types].xml": CONTENT_TYPES,
            "_rels/.rels": ROOT_RELS,
            "xl/workbook.xml": WORKBOOK,
            "xl/_rels/workbook.xml.rels": WORKBOOK_RELS,
            "xl/sharedStrings.xml": SHARED_STRINGS,
            "xl/styles.xml": STYLES,
            "xl/worksheets/sheet1.xml": SHEET1,
            "xl/worksheets/sheet2.xml": SHEET2,
        },
    )
    write_zip(
        HERE / "book.ods",
        {
            "META-INF/manifest.xml": ODS_MANIFEST,
            "content.xml": ODS_CONTENT,
        },
        first_stored=("mimetype", ODS_MIMETYPE),
    )
    write_example(pathlib.Path.cwd() / EXAMPLE)
    print("wrote book.xlsx and book.ods")
    print("  Ada joined serial:", serial(JOINED_ADA), "->", JOINED_ADA)
    print("  Linus joined serial:", serial(JOINED_LINUS), "->", JOINED_LINUS)


if __name__ == "__main__":
    main()
