// ═══════════════════════════════════════════════════════════════════════════
//  TabularReader — read the quarterly SAIL employee list into rows of text.
//
//  WHY THIS EXISTS AS ITS OWN FILE
//  The bulk import has two hard jobs: getting 10,000 rows out of a spreadsheet,
//  and deciding what to do with them. They fail for completely different
//  reasons — a mis-parsed column is a file problem, a wrong password policy is a
//  design problem — so they are kept apart. This half only reads. It never
//  touches app_users, never decides anything, and never writes.
//
//  WHAT IT READS
//    .xlsx / .xlsm  — parsed here, in the app, with no new dependency (the
//                     `archive` package is already used for .docx import).
//    .csv / .tsv    — parsed here, quote-aware.
//    .xls           — CANNOT be parsed here. See _xlsGuidance below; this is the
//                     format the real SAIL export actually arrives in, so the
//                     message it produces matters more than the code around it.
//
//  EVERY CELL COMES BACK AS A STRING, on purpose. Downstream this data becomes
//  text columns in Postgres, and the two fields where a "helpful" numeric type
//  would do real damage are MOBILE_NO (a leading zero or a country code must
//  survive, and 9.87e9 is not a phone number) and SAIL_PNO (which becomes the
//  username, so "0123" and "123" must never be confused). Dates are the one
//  exception: they are converted from Excel's day-serial to ISO yyyy-MM-dd,
//  because a `date` column will not accept "45678".
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'doc_ocr_service.dart';

/// A problem worth showing the admin verbatim. Every message in this file is
/// written for a plant administrator, not a developer: it says what is wrong
/// with the file and what to do about it.
class TabularException implements Exception {
  const TabularException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One parsed sheet: the header row, and every data row below it.
class TabularSheet {
  const TabularSheet({
    required this.sheetName,
    required this.headers,
    required this.rows,
    this.headerRowNumber = 1,
    this.blankRowsSkipped = 0,
    this.notes = const <String>[],
  });

  /// Sheet name as it appears in Excel, for the preview screen.
  final String sheetName;

  /// Headers exactly as written in the file, in column order — used for
  /// display and for telling the admin which column was not recognised.
  final List<String> headers;

  /// Data rows, each keyed by the NORMALISED header
  /// ([normaliseKey]: upper-case, non-alphanumerics collapsed to `_`).
  ///
  /// Keyed rather than positional because the quarterly export is regenerated
  /// by hand: a column inserted in the middle would silently shift every field
  /// by one and load mobile numbers into the email column.
  final List<Map<String, String>> rows;

  /// 1-based row number the headers were found on. Usually 1, but exports
  /// sometimes carry a title row above the table.
  final int headerRowNumber;

  final int blankRowsSkipped;

  /// Things the admin should know but that are not errors, e.g. a duplicated
  /// header. Shown in the import preview.
  final List<String> notes;

  int get rowCount => rows.length;

  /// `NAME`, `Sail P.No`, `RETIRE_DT ` and `sail p no` all normalise to the
  /// same key, so a column renamed between quarters still maps.
  static String normaliseKey(String header) {
    final k = header.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_');
    return k.replaceAll(RegExp(r'^_+|_+$'), '');
  }
}

class TabularReader {
  TabularReader._();

  /// Extensions to offer in FilePicker. `xls` is included deliberately even
  /// though it cannot be parsed: filtering it out would leave an admin holding
  /// the real SAIL file staring at a picker that refuses to show it, with no
  /// explanation. Far better to accept it and then explain.
  static const List<String> pickerExtensions = <String>[
    'xlsx',
    'xlsm',
    'csv',
    'tsv',
    'xls',
  ];

  /// 10,086 rows of the January 2026 file is ~1.6 MB as .xlsx. 25 MB is roomy
  /// enough for several years of headcount growth and still small enough that a
  /// mis-picked video file fails immediately instead of hanging the browser tab.
  static const int maxBytes = 25 * 1024 * 1024;

  /// Guard against a runaway file rather than freezing the tab. Well above any
  /// plausible SAIL headcount.
  static const int maxRows = 200000;

  static String extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// 'xlsx' | 'delimited' | 'legacyExcel' | 'unsupported'
  static String kindOf(String fileName) {
    final ext = extensionOf(fileName);
    if (ext == 'xlsx' || ext == 'xlsm') return 'xlsx';
    if (ext == 'csv' || ext == 'tsv' || ext == 'txt') return 'delimited';
    if (ext == 'xls') return 'legacyExcel';
    return 'unsupported';
  }

  // ── Entry point ──────────────────────────────────────────────────────────

  /// Read [bytes] into a [TabularSheet], or throw [TabularException] with a
  /// message that can be shown to the admin as-is.
  static Future<TabularSheet> read({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      throw const TabularException(
          'That file is empty. Please check it opens in Excel and try again.');
    }
    if (bytes.length > maxBytes) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      throw TabularException('That file is $mb MB, which is larger than the '
          '${maxBytes ~/ (1024 * 1024)} MB limit. Are you sure this is the '
          'employee list?');
    }

    final kind = kindOf(fileName);

    // A .xls renamed to .xlsx is a common "fix" and would otherwise fail with
    // an unhelpful "not a zip archive". Trust the bytes, not the extension:
    // every .xlsx starts with the ZIP magic PK\x03\x04, every .xls with the
    // OLE2 signature D0 CF 11 E0.
    final looksOle2 = bytes.length > 8 &&
        bytes[0] == 0xD0 &&
        bytes[1] == 0xCF &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xE0;

    if (kind == 'legacyExcel' || looksOle2) {
      return _readLegacyExcel(fileName: fileName, bytes: bytes);
    }

    if (kind == 'xlsx') {
      final looksZip = bytes.length > 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04;
      if (!looksZip) {
        throw const TabularException(
            'That file is named .xlsx but is not a valid Excel workbook. Open '
            'it in Excel, choose File → Save As and pick "Excel Workbook '
            '(*.xlsx)", then upload the saved copy.');
      }
      return _readXlsx(bytes);
    }

    if (kind == 'delimited') return _readDelimited(fileName, bytes);

    throw TabularException(
        'Safety Lens cannot read "$fileName". Please upload the employee list '
        'as an Excel workbook (.xlsx) or a .csv file.');
  }

  // ── .xls : legacy Excel ──────────────────────────────────────────────────

  /// The message an admin sees when the server converter is not available.
  ///
  /// This is the most likely thing to happen in practice, so it is a named
  /// constant rather than an inline string: the SAIL export really is .xls
  /// (OLE2/BIFF8 — a binary format with no relation to .xlsx, and no
  /// maintained Dart reader), and the two-click Save As below always works and
  /// needs nothing deployed. The feature must stay usable while the converter
  /// is still on someone's to-do list.
  static const String _xlsGuidance =
      'This file is in the older Excel .xls format, which Safety Lens cannot '
      'read directly.\n\n'
      'To convert it (takes a few seconds):\n'
      '  1. Open the file in Excel.\n'
      '  2. File → Save As.\n'
      '  3. Under "Save as type" choose "Excel Workbook (*.xlsx)".\n'
      '  4. Save, then upload the new .xlsx file here.\n\n'
      'Nothing in the file changes — this only updates the format.';

  /// Hand a .xls to the conversion endpoint on the Python service, falling back
  /// to [_xlsGuidance] whenever that is not possible.
  ///
  /// Shares [DocOcrService]'s address and token deliberately: it is the same
  /// deployment, and a second copy of the configuration would drift and leave
  /// an admin who has set up OCR wondering why the roster still will not load.
  static Future<TabularSheet> _readLegacyExcel({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final base = await DocOcrService.getServiceUrl();
    if (base.isEmpty) throw const TabularException(_xlsGuidance);

    final token = await DocOcrService.getServiceToken();
    http.Response resp;
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$base/tabular'))
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: fileName.isEmpty ? 'upload.xls' : fileName));
      if (token.isNotEmpty) req.fields['token'] = token;
      final streamed =
          await req.send().timeout(const Duration(seconds: 120));
      // Second timeout because the one on send() only bounds the response
      // HEADERS — a stalled body would otherwise spin forever with no error.
      resp = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw TabularException('$_xlsGuidance\n\n'
          '(The conversion service could not be reached: $e)');
    }

    if (resp.statusCode == 404 || resp.statusCode == 405) {
      // An older deployment of the OCR service that predates /tabular. Say so,
      // because "404" on its own would send an admin hunting for a wrong URL.
      throw const TabularException('$_xlsGuidance\n\n'
          '(The conversion service is running but does not support .xls files '
          'yet — it needs updating to a newer version.)');
    }
    if (resp.body.trimLeft().startsWith('<')) {
      throw const TabularException('$_xlsGuidance\n\n'
          '(The conversion service returned a web page instead of data — it '
          'may be starting up. Waiting a minute and retrying may work.)');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      throw const TabularException('$_xlsGuidance\n\n'
          '(The conversion service sent a reply that could not be understood.)');
    }
    if (resp.statusCode != 200 || data['ok'] != true) {
      final detail =
          (data['detail'] ?? data['error'] ?? 'HTTP ${resp.statusCode}')
              .toString();
      throw TabularException('$_xlsGuidance\n\n'
          '(The conversion service could not read the file: $detail)');
    }

    return _fromServiceJson(data);
  }

  /// Contract for `POST /tabular`, implemented by ocr_service:
  ///   { "ok": true,
  ///     "sheetName": "Sheet1",
  ///     "headers": ["NAME", "SAIL_PNO", ...],
  ///     "rows": [ {"NAME": "...", "SAIL_PNO": "..."} , ... ] }
  ///
  /// The service is responsible for the two conversions this side cannot check:
  /// dates as ISO yyyy-MM-dd, and mobile numbers as text. Everything is
  /// re-stringified here anyway, so a stray number in the JSON cannot become a
  /// type error at the database.
  static TabularSheet _fromServiceJson(Map<String, dynamic> data) {
    final headers = ((data['headers'] as List?) ?? const [])
        .map((h) => h?.toString().trim() ?? '')
        .toList();
    final rawRows = (data['rows'] as List?) ?? const [];
    final rows = <Map<String, String>>[];
    for (final r in rawRows) {
      if (r is! Map) continue;
      final row = <String, String>{};
      r.forEach((k, v) {
        final key = TabularSheet.normaliseKey(k.toString());
        if (key.isEmpty) return;
        row[key] = _asCellText(v);
      });
      if (row.values.any((v) => v.isNotEmpty)) rows.add(row);
    }
    if (rows.isEmpty) {
      throw const TabularException(
          'The converted file contained no data rows. Please check the file '
          'opens correctly in Excel.');
    }
    return TabularSheet(
      sheetName: (data['sheetName'] ?? 'Sheet1').toString(),
      headers: headers,
      rows: rows,
      notes: const ['Converted from .xls by the Safety Lens service.'],
    );
  }

  static String _asCellText(dynamic v) {
    if (v == null) return '';
    if (v is String) return v.trim();
    if (v is int) return v.toString();
    if (v is double) {
      // Whole numbers must not come back as "12345.0" — that value may be a
      // P.no, and "12345.0" would become a username nobody can type.
      if (v == v.roundToDouble() && v.abs() < 1e15) {
        return v.toInt().toString();
      }
      return v.toString();
    }
    if (v is bool) return v ? 'TRUE' : 'FALSE';
    return v.toString().trim();
  }

  // ── .csv / .tsv ──────────────────────────────────────────────────────────

  static TabularSheet _readDelimited(String fileName, Uint8List bytes) {
    // allowMalformed: an HR export saved from Windows may carry a stray
    // non-UTF8 byte in one name. Losing that one character is acceptable;
    // losing the whole roster to a FormatException is not.
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      // Excel writes a UTF-8 BOM. Left in place it becomes part of the first
      // header, so "NAME" would not match and column one would vanish.
      text = text.substring(1);
    }

    final ext = extensionOf(fileName);
    // Sniff rather than trust the extension: files named .csv are routinely
    // tab- or semicolon-separated depending on the machine's locale.
    final firstLine = text.split(RegExp(r'\r?\n')).first;
    String delim;
    if (ext == 'tsv') {
      delim = '\t';
    } else {
      final counts = <String, int>{
        ',': firstLine.split(',').length,
        '\t': firstLine.split('\t').length,
        ';': firstLine.split(';').length,
      };
      delim = ',';
      var best = 0;
      counts.forEach((d, n) {
        if (n > best) {
          best = n;
          delim = d;
        }
      });
    }

    final grid = _parseDelimited(text, delim);
    if (grid.isEmpty) {
      throw const TabularException('That file contains no rows.');
    }
    return _gridToSheet(grid, sheetName: fileName);
  }

  /// RFC 4180 parse: quoted fields may contain the delimiter, newlines, and
  /// doubled quotes. Written out rather than split-on-delimiter because a
  /// designation like "Manager, Operations" is entirely normal in this data and
  /// a naive split shifts every following column on that row only — the worst
  /// kind of bug, because 9,999 rows look perfect.
  static List<List<String>> _parseDelimited(String text, String delim) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    final d = delim.codeUnitAt(0);

    void endField() {
      row.add(field.toString());
      field.clear();
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inQuotes) {
        if (c == 0x22) {
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x22) {
            field.writeCharCode(0x22);
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.writeCharCode(c);
        }
      } else if (c == 0x22 && field.isEmpty) {
        inQuotes = true;
      } else if (c == d) {
        endField();
      } else if (c == 0x0A) {
        endRow();
      } else if (c == 0x0D) {
        // Swallow CR; the LF that follows ends the row. A lone CR (old Mac
        // exports) ends it here instead.
        if (i + 1 >= text.length || text.codeUnitAt(i + 1) != 0x0A) endRow();
      } else {
        field.writeCharCode(c);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) endRow();
    return rows;
  }

  // ── .xlsx ────────────────────────────────────────────────────────────────

  static TabularSheet _readXlsx(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw TabularException(
          'That Excel file could not be opened — it may be damaged or password '
          'protected. Try opening it in Excel and saving a fresh copy. ($e)');
    }

    String? entry(String name) {
      for (final f in archive.files) {
        if (f.isFile && f.name == name) {
          return utf8.decode(List<int>.from(f.content as List<int>),
              allowMalformed: true);
        }
      }
      return null;
    }

    // Worksheet. sheet1.xml is what Excel writes; the loop is the fallback for
    // workbooks whose first sheet is stored under another name.
    var sheetXml = entry('xl/worksheets/sheet1.xml');
    if (sheetXml == null) {
      final candidates = archive.files
          .where((f) =>
              f.isFile &&
              f.name.startsWith('xl/worksheets/') &&
              f.name.endsWith('.xml'))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (candidates.isNotEmpty) {
        sheetXml = utf8.decode(List<int>.from(candidates.first.content as List<int>),
            allowMalformed: true);
      }
    }
    if (sheetXml == null) {
      throw const TabularException(
          'That Excel file contains no worksheets that Safety Lens can read.');
    }

    var sheetName = 'Sheet1';
    final wb = entry('xl/workbook.xml');
    if (wb != null) {
      final m = RegExp(r'<sheet\b[^>]*\bname="([^"]*)"').firstMatch(wb);
      if (m != null) sheetName = _unescapeXml(m.group(1)!);
    }

    final shared = _sharedStrings(entry('xl/sharedStrings.xml'));
    final dateStyles = _dateStyleIndexes(entry('xl/styles.xml'));

    final grid = _sheetGrid(sheetXml, shared, dateStyles);
    if (grid.isEmpty) {
      throw const TabularException(
          'That worksheet is empty. Please check you uploaded the right file.');
    }
    return _gridToSheet(grid, sheetName: sheetName);
  }

  /// Shared string table, in index order.
  ///
  /// A `<si>` may hold several `<r>` runs when part of the text is formatted
  /// differently, so all `<t>` inside one `<si>` are joined — taking only the
  /// first would truncate any name that happens to be part-bold.
  ///
  /// Absent entirely in workbooks written by openpyxl, which uses inline
  /// strings instead; an empty table is normal, not an error.
  static List<String> _sharedStrings(String? xml) {
    if (xml == null) return const <String>[];
    final out = <String>[];
    final si = RegExp(r'<si\b[^>]*>([\s\S]*?)</si>|<si\b[^>]*/>');
    final t = RegExp(r'<t\b[^>]*>([\s\S]*?)</t>');
    for (final m in si.allMatches(xml)) {
      final inner = m.group(1);
      if (inner == null) {
        out.add('');
        continue;
      }
      final sb = StringBuffer();
      for (final tm in t.allMatches(inner)) {
        sb.write(_unescapeXml(tm.group(1) ?? ''));
      }
      out.add(sb.toString());
    }
    return out;
  }

  /// Which `s="N"` style indexes format their number as a date.
  ///
  /// This is the only way to tell a date from a number in .xlsx: a cell holding
  /// 12/01/1968 stores `<v>24838</v>` and nothing else. Without this,
  /// DOB and RETIRE_DT arrive as five-digit integers and Postgres rejects the
  /// whole batch.
  static Set<int> _dateStyleIndexes(String? xml) {
    final dateXfs = <int>{};
    if (xml == null) return dateXfs;

    // Built-in formats reserved for dates and times by the OOXML spec. They
    // carry no formatCode in the file, so they can only be recognised by id.
    const builtinDateIds = <int>{
      14, 15, 16, 17, 18, 19, 20, 21, 22,
      27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
      45, 46, 47,
      50, 51, 52, 53, 54, 55, 56, 57, 58,
    };

    final customIsDate = <int, bool>{};
    for (final m
        in RegExp(r'<numFmt\b[^>]*/>').allMatches(xml)) {
      final tag = m.group(0)!;
      final id = int.tryParse(
          RegExp(r'numFmtId="(\d+)"').firstMatch(tag)?.group(1) ?? '');
      final code =
          RegExp(r'formatCode="([^"]*)"').firstMatch(tag)?.group(1) ?? '';
      if (id == null) continue;
      customIsDate[id] = _formatCodeIsDate(_unescapeXml(code));
    }

    // cellXfs ONLY. styles.xml also contains cellStyleXfs, with its own <xf>
    // elements in a different numbering; mixing them shifts every style index
    // and would mark arbitrary columns as dates.
    final cellXfs =
        RegExp(r'<cellXfs\b[^>]*>([\s\S]*?)</cellXfs>').firstMatch(xml);
    if (cellXfs == null) return dateXfs;

    var index = 0;
    for (final m
        in RegExp(r'<xf\b[^>]*?(?:/>|>[\s\S]*?</xf>)').allMatches(cellXfs.group(1)!)) {
      final id = int.tryParse(
          RegExp(r'numFmtId="(\d+)"').firstMatch(m.group(0)!)?.group(1) ?? '');
      if (id != null &&
          (builtinDateIds.contains(id) || customIsDate[id] == true)) {
        dateXfs.add(index);
      }
      index++;
    }
    return dateXfs;
  }

  /// True for codes like `dd/mm/yyyy` or `d-mmm-yy`, false for `0.00`, `#,##0`
  /// and `General`.
  ///
  /// Quoted literals and `[Red]`-style conditions are stripped first: a
  /// currency format such as `"Dhs"#,##0` would otherwise look like a date
  /// because of the `s` and `D`.
  static bool _formatCodeIsDate(String code) {
    final stripped = code
        .replaceAll(RegExp(r'"[^"]*"'), '')
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'\\.'), '');
    if (stripped.isEmpty) return false;
    final lower = stripped.toLowerCase();
    // `m` alone is ambiguous (minutes), so it only counts alongside y or d.
    if (lower.contains('y') || lower.contains('d')) return true;
    return lower.contains('m') && lower.contains(':');
  }

  /// Sheet XML → a dense grid of strings, empty cells included.
  static List<List<String>> _sheetGrid(
    String xml,
    List<String> shared,
    Set<int> dateStyles,
  ) {
    final rows = <List<String>>[];
    final rowRe = RegExp(r'<row\b([^>]*?)(?:/>|>([\s\S]*?)</row>)');
    final cellRe = RegExp(r'<c\b([^>]*?)(?:/>|>([\s\S]*?)</c>)');
    final vRe = RegExp(r'<v\b[^>]*>([\s\S]*?)</v>');
    final tRe = RegExp(r'<t\b[^>]*>([\s\S]*?)</t>');

    for (final rm in rowRe.allMatches(xml)) {
      if (rows.length >= maxRows) break;
      final inner = rm.group(2);
      final cells = <int, String>{};
      var widest = -1;

      if (inner != null) {
        var fallbackCol = 0;
        for (final cm in cellRe.allMatches(inner)) {
          final attrs = cm.group(1) ?? '';
          final body = cm.group(2);

          // Column from the cell reference, NOT from position. Excel omits
          // empty cells entirely, so a row where EMAIL is blank has one fewer
          // <c> and positional reading would load MOBILE_NO into EMAIL for
          // exactly those rows — 202 of them in the January 2026 file.
          final ref = RegExp(r'\br="([A-Za-z]+)').firstMatch(attrs)?.group(1);
          final col = ref != null ? _colIndex(ref) : fallbackCol;
          fallbackCol = col + 1;

          final type =
              RegExp(r'\bt="([^"]*)"').firstMatch(attrs)?.group(1) ?? 'n';
          final style = int.tryParse(
              RegExp(r'\bs="(\d+)"').firstMatch(attrs)?.group(1) ?? '');

          var text = '';
          if (body != null && body.isNotEmpty) {
            if (type == 'inlineStr') {
              final sb = StringBuffer();
              for (final tm in tRe.allMatches(body)) {
                sb.write(_unescapeXml(tm.group(1) ?? ''));
              }
              text = sb.toString();
            } else {
              final raw = _unescapeXml(vRe.firstMatch(body)?.group(1) ?? '');
              if (type == 's') {
                final i = int.tryParse(raw);
                text = (i != null && i >= 0 && i < shared.length)
                    ? shared[i]
                    : '';
              } else if (type == 'b') {
                text = raw == '1' ? 'TRUE' : 'FALSE';
              } else if (type == 'str' || type == 'e') {
                text = raw;
              } else {
                final n = double.tryParse(raw);
                if (n != null && style != null && dateStyles.contains(style)) {
                  text = _excelSerialToIsoDate(n);
                } else if (n != null) {
                  text = _numberToText(n);
                } else {
                  text = raw;
                }
              }
            }
          }

          text = text.trim();
          if (text.isNotEmpty) {
            cells[col] = text;
            if (col > widest) widest = col;
          }
        }
      }

      final list = List<String>.filled(widest + 1, '');
      cells.forEach((i, v) {
        if (i >= 0 && i <= widest) list[i] = v;
      });
      rows.add(list);
    }
    return rows;
  }

  /// "A" → 0, "Z" → 25, "AA" → 26. Returns -1 if there are no letters.
  static int _colIndex(String letters) {
    var n = 0;
    for (var i = 0; i < letters.length; i++) {
      final c = letters.codeUnitAt(i);
      if (c >= 65 && c <= 90) {
        n = n * 26 + (c - 64);
      } else if (c >= 97 && c <= 122) {
        n = n * 26 + (c - 96);
      } else {
        break;
      }
    }
    return n - 1;
  }

  /// Excel day-serial → `yyyy-MM-dd`.
  ///
  /// The epoch is 1899-12-30, not 1899-12-31, because Excel treats 1900 as a
  /// leap year for Lotus compatibility and therefore counts one day that never
  /// existed. That is correct for every serial from 61 (1900-03-01) upward,
  /// which covers every date of birth and retirement date in this data. Below
  /// 61 the workbook itself is ambiguous, so those are returned as text rather
  /// than guessed at.
  static String _excelSerialToIsoDate(double serial) {
    if (serial < 61) return _numberToText(serial);
    final dt = DateTime.utc(1899, 12, 30).add(Duration(days: serial.floor()));
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$mm-$dd';
  }

  /// A number as the file's author would have typed it.
  ///
  /// Whole values lose the ".0" — a P.no read as "12345.0" becomes a username
  /// nobody can type, and a mobile as "9.876543211e9" is not a phone number.
  static String _numberToText(double n) {
    if (n == n.roundToDouble() && n.abs() < 1e15) return n.toInt().toString();
    var s = n.toString();
    if (s.contains('e') || s.contains('E')) {
      s = n.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
  }

  // ── Grid → sheet ─────────────────────────────────────────────────────────

  static TabularSheet _gridToSheet(
    List<List<String>> grid, {
    required String sheetName,
  }) {
    final headerIndex = _findHeaderRow(grid);
    if (headerIndex < 0) {
      throw const TabularException(
          'No header row could be found in that file. The first row should '
          'contain the column names (NAME, SAIL_PNO, DESIG, and so on).');
    }

    final notes = <String>[];
    final rawHeaders = grid[headerIndex];
    final headers = <String>[];
    final keys = <String>[];
    final seen = <String, int>{};

    for (var i = 0; i < rawHeaders.length; i++) {
      final raw = rawHeaders[i].trim();
      headers.add(raw);
      var key = TabularSheet.normaliseKey(raw);
      if (key.isEmpty) {
        // Unnamed column. Keyed by position so it is still reachable, and
        // reported so the admin can see it was not simply dropped.
        key = 'COLUMN_${i + 1}';
      }
      final prior = seen[key];
      if (prior != null) {
        // Two columns with the same name: the second would otherwise overwrite
        // the first and one field would silently hold the wrong data.
        final unique = '${key}_${prior + 1}';
        notes.add('Column ${i + 1} repeats the heading "$raw" — it has been '
            'read as "$unique" and will not be imported unless mapped.');
        seen[key] = prior + 1;
        key = unique;
      } else {
        seen[key] = 1;
      }
      keys.add(key);
    }

    final rows = <Map<String, String>>[];
    var blank = 0;
    for (var r = headerIndex + 1; r < grid.length; r++) {
      final cells = grid[r];
      final row = <String, String>{};
      var any = false;
      for (var c = 0; c < keys.length; c++) {
        final v = c < cells.length ? cells[c].trim() : '';
        row[keys[c]] = v;
        if (v.isNotEmpty) any = true;
      }
      // Trailing empty rows are extremely common in hand-edited exports, and
      // importing them would create accounts with no username.
      if (!any) {
        blank++;
        continue;
      }
      rows.add(row);
    }

    if (rows.isEmpty) {
      throw const TabularException(
          'That file has column headings but no employee rows below them.');
    }

    return TabularSheet(
      sheetName: sheetName,
      headers: headers,
      rows: rows,
      headerRowNumber: headerIndex + 1,
      blankRowsSkipped: blank,
      notes: notes,
    );
  }

  /// Locate the header row within the first few rows.
  ///
  /// Not simply row 1: exports regularly carry a title ("SAIL EMPLOYEE LIST AS
  /// ON 01-JAN-2026") or a blank row above the table, and treating that as the
  /// headers makes every column unrecognised — which reads to the admin as "the
  /// app cannot open my file" rather than "the app looked in the wrong place".
  ///
  /// A header row is taken to be the first with at least two non-empty cells of
  /// which most are not numbers.
  static int _findHeaderRow(List<List<String>> grid) {
    final limit = grid.length < 20 ? grid.length : 20;
    for (var i = 0; i < limit; i++) {
      final filled = grid[i].where((c) => c.trim().isNotEmpty).toList();
      if (filled.length < 2) continue;
      final numeric =
          filled.where((c) => double.tryParse(c.replaceAll(',', '')) != null).length;
      if (numeric * 2 <= filled.length) return i;
    }
    // Nothing convincing. If there is anything at all, fall back to the first
    // non-empty row: a wrong guess produces a mapping screen the admin can see
    // and correct, whereas giving up produces nothing to work with.
    for (var i = 0; i < grid.length; i++) {
      if (grid[i].any((c) => c.trim().isNotEmpty)) return i;
    }
    return -1;
  }

  static String _unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      // &amp; LAST, or "&amp;lt;" would decode to "<" instead of "&lt;".
      .replaceAll('&amp;', '&');
}
