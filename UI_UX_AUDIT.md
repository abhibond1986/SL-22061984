# SAIL Safety Lens — UI/UX Audit

**Date:** 2026-09-09 · **Version audited:** 1.0.98+98 · **Scope:** the whole Flutter UI (`lib/screens`, `lib/widgets`, `lib/main.dart` theme) as shipped to both Android and the web build.

---

## 1. Method and scope

Every screen file and shared widget was read in full and assessed against six lenses: visual hierarchy, the design-token system, contrast and legibility for the actual use context, responsive behaviour on desktop browsers, interaction affordance, and accessibility. Findings were cross-checked against the repo's own `tools/audit_contrast.py` and against grep-based counts so the numbers below are measured, not impressions.

The use context matters and drives most of the priorities. This app is operated at arm's length, on a plant floor, in poor light, by gloved hands, by a workforce skewing 45+ — and simultaneously by safety officers on 1600px desktop browsers. Those are two very different design targets, and right now the app is designed for neither: it is a dense phone layout with badge-sized type, stretched across a desktop viewport.

Out of scope: the standalone `admin/` and `analytics_dashboard.html` pages, PDF export layout, and copywriting/localisation quality.

---

## 2. Executive summary

The app is functionally deep and the token system underneath it is unusually well thought out — `SL`, `SLText`, the `*Text` foreground getters, `BottomNavGap`, and a purpose-built contrast auditor all exist and all encode real, hard-won lessons. **The problem is not the design system. The problem is that almost nothing uses it.**

`SLText` is referenced in exactly 2 of 24 screen files. `BottomNavGap` is used in 9 places out of roughly 20 that need it. There are 318 sites where a fill-only status token is assigned to `color:` or `foregroundColor:`, and the repo's own auditor catches only 2 of them because its regex is single-line. The result is a codebase where the guardrails are real but unenforced, so every screen has quietly drifted into its own private dialect: 31 distinct font sizes, 21 distinct corner radii, three competing severity-colour maps, and two competing "primary" brand colours.

Eight systemic issues account for the great majority of the "it doesn't look polished" feeling:

1. **A sub-11px type tier exists and is used heavily** — 188 hard failures below 10px plus 272 warnings at 10px, concentrated in exactly the elements that carry safety meaning (severity pills, confidence badges, hazard-table cells, nav labels, chart tick labels). This is the single largest legibility and credibility problem.
2. **Fill-only colour tokens are used as foreground text and icons at scale** — 318 sites. Measured, `AppColors.amber` as text on white is 2.15:1 and `green` is 2.54:1, against a 4.5:1 AA floor. Safety-critical information is rendered in colours that are close to unreadable.
3. **`SL.textOn()` fails open, not safe** (`lib/main.dart:198`). Its final line is `return fill;`, so any colour it does not recognise — including every hardcoded hex in the analytics screens — passes straight through unchanged. The one function designed to be the safety net is the mechanism by which the net is bypassed.
4. **There is no responsive layer at all.** Across 24 screens there are 8 `MediaQuery` references, 2 `LayoutBuilder`s, and 8 `ConstrainedBox`es. On a 1920px browser the login form is a single 1870px-wide strip and analytics renders 80px labels beside 1400px bars. The web app currently reads as a phone screenshot that has been dragged wider.
5. **Tap feedback is largely absent** — 103 `GestureDetector`s versus 25 `InkWell`s. With gloves and a 250ms tab transition, a user genuinely cannot tell whether a tap registered, which produces double-submits and mistrust.
6. **No single primary action per screen.** The two most important screens end in a row of five (AI Scan) and three (Near Miss) equally-weighted filled buttons at 11px. The one mandatory action, Save, has no more visual weight than "Share".
7. **The long AI waits are opaque and un-escapable.** No flow in the app can be cancelled, progress type is the smallest in the app on a dimmed photo, and failures surface raw exception strings and model slugs to shop-floor users.
8. **Accessibility is effectively absent** — 2 `Semantics` widgets, 2 `Tooltip`s, 0 `autofillHints`, and status conveyed by hue alone in dozens of places. This is both an inclusion problem and, for a government-sector deployment, a procurement risk.

Underneath these sit three pieces of dead or unreachable code that should simply be deleted, because each is an invitation to reintroduce fixed bugs.

---

## 3. Objective baseline

Measured on 2026-09-09 across `lib/`:

| Metric | Value | Healthy target |
|---|---|---|
| `tools/audit_contrast.py` type-floor failures (<10px) | **188** | 0 |
| … warnings (10px) | **272** | 0 |
| Distinct `fontSize:` literals | **31** (1 → 32, incl. 6.5, 6.8, 7.5, 9.5, 10.5, 11.5, 12.5, 13.5, 14.5) | 7–8 |
| Total hardcoded `fontSize:` declarations | **1267** | near 0 (tokens) |
| `SLText.*` usages | **68**, in **2 files only** | all screens |
| Distinct `circular()` radii | **21** (1 → 999) | 4 + pill |
| `color:`/`foregroundColor:` = fill-only status token | **318** | 0 |
| `GestureDetector` : `InkWell` | **103 : 25** | inverted |
| `Semantics(` | **2** | every icon-only control |
| `MediaQuery` / `LayoutBuilder` / `ConstrainedBox` | **8 / 2 / 8** | per-screen |
| `BackdropFilter` | **26** (several over opaque children) | minimal on web |
| `autofillHints` | **0** | login + profile |
| `SnackBarAction` (i.e. retry affordances) | **0** | every failure toast |
| `tabularFigures` | **2** | every numeric column |
| `PopScope`/`WillPopScope` (unsaved-work guards) | **2** | forms + long flows |

The gap between "188 type failures" and "2 contrast failures" is not good news about colour — it is the documented blind spot in the auditor. Its regex is single-line, so it misses `color:` on a continuation line, inside a ternary, or via a local variable, which is how 316 of the 318 sites escape. **Recommendation: make the auditor multiline-aware before trusting its colour score again.**

### 3a. Post-Phase-0 re-measurement (same day)

The auditor was made multiline-aware as part of Phase 0, so its numbers moved for two different reasons at once. They must be read separately:

| Metric | Before | After | Why it moved |
|---|---|---|---|
| Type-floor failures (<10px) | 186 | **181** | Real fixes: two dead files deleted, both nav bars' labels, the `/100` unit on the risk-score tile. |
| Fill-only token used as a foreground | 2 | **86** | **Not a regression.** The auditor now sees continuation lines and ternaries. 86 is still conservative — decoration fills are correctly excluded, and a global-background blind spot remains (documented in the tool). |
| Total reported failures | 188 | **267** | Sum of the two rows above. |
| 10px warnings | 272 | **261** | Dead-file deletion plus the label fixes. |

The honest reading: colour was never at 2 violations, it was always in the high tens, and the app now measures what it always was. Every number in this table is reproducible with `python3 tools/audit_contrast.py`.

---

## 4. Findings by theme

Severity: **P0** = fix now, affects safety-critical legibility, correctness, or every screen · **P1** = fix this cycle · **P2** = polish.

### A. Design system and token adoption

- **[P0] `lib/main.dart:198` — `SL.textOn()` returns the input colour for anything it does not recognise.** Every hardcoded hex in the analytics screens (`data_analysis_tab.dart:851/868/871` purple at 16px, `overview_tab.dart:411/430/739`, `plant_wise_tab.dart:688`) and every admin-added severity name falling to `default: Colors.blueGrey` (`data_analysis_tab.dart:516`, `overview_tab.dart:681`) silently bypasses the guard. **Fix:** fall back to `text1`, and log in debug. This one line change closes the largest hole in the system.
- **[P0] `SLText` is adopted in 2 of 24 screen files** (`sop_scan_screen.dart`, `doc_qa_screen.dart` — use these as the model). 1267 hardcoded `fontSize:` literals elsewhere. **Fix:** extend `SLText` with a full display scale (`h1` 24 / `h2` 20 / `h3` 17 / `body` 13 / `label` 12 / `badge` 11) and migrate screen by screen, starting with the ones the auditor flags most.
- **[P1] No radius, spacing, or elevation tokens exist at all.** 21 radii and ad-hoc spacers of 4/6/8/10/12/14/16/20/28 mean nothing lines up between screens. **Fix:** add `SLRadius {sm 8, md 12, lg 16, pill 999}` and `SLSpace {xs 4, sm 8, md 12, lg 16, xl 24, xxl 32}` next to `SLText`, then sweep.
- **[P1] `GlassCard` (r16, hand-rolled shadow at `glass_card.dart:41-47`) and `GlassContainer` (r12, no shadow) disagree**, so "glass" means two different elevations in the same app. **Fix:** share `sl.cardShadow` and one radius; expose an `elevation` enum instead of duplicating shadow constants.
- **[P1] Two competing primaries.** Indigo `AppColors.accent` is the documented primary, but the SPI card invents a blue brand (`overview_tab.dart:928-1010, 1239-1334` — `0xFF1E88E5`/`0xFF1565C0`, 11 uses) and `chat_tab.dart` builds the assistant identity and send button on amber (`871/879/882/904/917`). **Fix:** one primary; retire the blue and move chat to accent.
- **[P2] `26 BackdropFilter`s, several over fully opaque children** (`login_screen.dart:401-404, 437-440` wrap a gradient container and an outlined button). Pure cost, no visual effect, and `BackdropFilter` is the expensive path on Flutter web. **Fix:** delete those.

### B. Typography

- **[P0] Delete the sub-11px tier.** The repo's own floor is `SLText.minBadge = 11.0`, and it is violated 188 times. The worst offenders are precisely the safety-carrying elements: 8px risk-score suffix and severity pill (`ai_scan_tab.dart:3048, 3816-3824`), 8–9px confidence and CHECK-ON-SITE chips (`3459/3663/3703`), 8px severity badges in analytics (`plant_wise_tab.dart:998/1100`), 8px pipeline-stage labels (`overview_tab.dart:533`), 9px bbox labels and 8px badge on the annotated photo (`hazard_annotated_image.dart:344/358`), 9px nav labels (`home_screen.dart:428`), 9.5px assignment cards (`my_assignments_card.dart:211/342`), and 8px severity truncated to four characters (`incident_detail_screen.dart:872`). `admin_screen.dart` alone has 348 declarations under 13px including eight at 8px and 58 at 9px. **Fix:** clamp everything to 11 minimum, 13 for body; where 11px does not fit, the layout is wrong, not the type.
- **[P0] `home_screen.dart:417-418, 428` — 9px nav labels with `overflow: TextOverflow.visible, softWrap: false`.** At textScale ≥1.3 labels paint over their neighbours instead of ellipsising. The comment admits it breaks the repo's own floor. **Fix:** shorten "SOP Scan" → "SOP", set all labels to 11px with `overflow: ellipsis` — which becomes trivial once the bar drops to four destinations (§F).
- **[P1] 31 distinct sizes, including off-scale halves** (6.5, 6.8, 7.5, 9.5, 10.5, 11.5, 12.5, 13.5, 14.5). `admin_screen.dart` uses 17 distinct sizes; `overview_tab.dart` 11; `dashboard_tab.dart` and `home_tab.dart` 13 each. **Fix:** the 6-step scale above; forbid halves.
- **[P1] Missing `height:` on multi-line copy** — hazard descriptions and edit fields at 10.5–11px with no line-height (`ai_scan_tab.dart:915-952, 3350-3603`), legends and dense labels (`data_analysis_tab.dart:544/631/690/777`, `plant_wise_tab.dart:839/911`, `overview_tab.dart:700/757`, `admin_screen.dart:6907-6912, 9084-9086`). **Fix:** `height: 1.45` on every wrapping text style; bake it into the `SLText` body tokens so it cannot be forgotten.
- **[P1] No `FontFeature.tabularFigures()` on numeric columns** (2 uses app-wide). Every count column wobbles row to row and cannot be scanned vertically — `data_analysis_tab.dart:657/716/803`, `plant_wise_tab.dart:871/927`, `overview_tab.dart:702`, `admin_screen.dart:7885-7955`. **Fix:** a `SLText.number` token carrying the feature.
- **[P2] Letter-spacing and italic misapplied at small sizes** — `letterSpacing: 1.2` on 11px (`login_screen.dart:308-309`), 10.5px italic AI hint (`near_miss_tab.dart:3547-3551`), 11px italic (`login_screen.dart:429-430`). Both reduce legibility exactly where it is thinnest. **Fix:** cap letter-spacing at 0.4 below 13px; no italic below 13px.

### C. Colour, contrast and meaning

The measured token table from `audit_contrast.py`, for reference:

| token | on light | on dark | verdict |
|---|---|---|---|
| `accent` | 5.54 | **2.99** | light only |
| `amber` | **2.15** | 7.71 | dark only |
| `green` | **2.54** | 6.52 | dark only |
| `cyan` | **2.97** | 5.57 | dark only |
| `crit` | 4.83 | **3.43** | light only |
| `red` | **3.76** | **4.40** | fill only — fails both |
| `purple` | **3.99** | **4.15** | fill only — fails both |
| `accentGlow` | **3.98** | **4.16** | fill only — fails both |

- **[P0] 318 sites assign a fill-only token to a foreground.** Highest-visibility instances: the **selected bottom-nav icon and label** use bare `AppColors.accent` over the dark indigo nav gradient at ~2.8:1 (`home_screen.dart:407/433`, `contractor_home_screen.dart:236/250`) — the app's single most-looked-at control; the risk score at 20px in bare `_sevColor` (`ai_scan_tab.dart:3045/3048/3058`); a 32px bare-green verified icon (`ai_scan_tab.dart:3149`); the SPI headline score (`overview_tab.dart:1126/1130`, while the correct `textOn` call sits two functions away at `1085`); "Forgot Password?" in accent (`login_screen.dart:610`) and the Contractor Access button in cyan at 2.97:1 (`login_screen.dart:410/412`). **Fix:** mechanical sweep to `sl.*Text` / `sl.textOn()`, prioritised by the counts in §3.
- **[P0] White text on saturated fills.** White on `AppColors.amber` is 2.15:1 — that is the "Normalize Plant Names" admin button (`admin_screen.dart:2809-2810`), the Share gradient (`near_miss_tab.dart:4872`), and pie-slice percentage labels on amber and green slices (`data_analysis_tab.dart:531-533`, effectively invisible). White on the `#22C55E → #16A34A` download gradient is 2.30:1 (`login_screen.dart:478-494, 511`); on `Colors.green` snackbars, 2.56:1 (`login_screen.dart:246/718`). **Fix:** darken fills to `critLight`/`amberLight`/`greenLight` when they must carry white text, or draw labels outside the slice.
- **[P0] Three disagreeing severity-colour maps.** `ai_scan_tab.dart:3826-3834` maps MEDIUM → cyan and `default` → amber, while `hazard_annotated_image.dart`, `home_tab.dart:1195-1200` and `dashboard_tab.dart:1202-1210` map MEDIUM → amber. **The same hazard is cyan in the table and amber on the photo.** **Fix:** one `severityColor()` in `main.dart`; delete all four local maps. Keep the neutral default branch — a plant that renames HIGH to "SEVERE" must not get a cheerful chip.
- **[P1] Amber is overloaded six ways** — MEDIUM severity, OPEN status (`overview_tab.dart:476`, `plant_wise_tab.dart:320`, `incident_log_tab.dart:63`), NEAR_MISS type (`incident_log_tab.dart:598`), unassigned-plant warning (`plant_wise_tab.dart:421`), the 50–80% closure band (`overview_tab.dart:1177/1224`), and admin selection state. A MEDIUM near-miss that is OPEN paints three amber chips in one card, all meaning different things. **Fix:** amber belongs to severity alone; give status a desaturated ramp and type a neutral chip.
- **[P1] Severity ramp reused as a categorical palette** — `plant_wise_tab.dart:363-365` `_barColors = [crit, amber, accent, cyan, green]`, so "top hazard category #1" is red and "#5" is green, implying a severity that does not exist. Same problem in `dashboard_tab.dart:542-567`, where four filter cards differ only by fill hue. Same in `ai_scan_tab.dart:3638-3643`, where `_confColor` runs *confidence* through green/cyan/amber/red so a low-confidence LOW hazard reads red. **Fix:** a neutral categorical palette for categories; a monochrome opacity ramp or filled-dot meter for confidence.
- **[P2] `Colors.grey` used for Cancel** in six admin dialogs (`admin_screen.dart:1854, 6022, 6364, 7219, 7531, 10763`) and `dashboard_tab.dart:1291` — ~2.8:1, reads as disabled. **Fix:** `sl.text2`.
- **[P2] Two light-only pastel palettes exist outside the token system** — `hazard_annotated_image.dart` legend (`#FDECEA`/`#B3261E`, no dark variant) and `ai_scan_tab.dart:3837-3854` `_typeColor/_typeTextColor`. **Fix:** move into `SL` with dark values.

> **Process note, learned the hard way:** the auditor scores tokens against the two *global* backgrounds, never a local card fill. When a card fill changes, hand-measure every foreground sitting on it — including widgets the diff did not touch. Prefer near-white fills for small badges in light mode over a wash of their own colour.

### D. Responsive behaviour and the web build

- **[P0] There is no responsive layer.** No width-based logic exists in any of the eight core task screens or the four analytics tabs; the only `MediaQuery` in analytics-adjacent code is `chat_tab.dart:716` (keyboard insets) and the app's only breakpoint is `admin_screen.dart:707` pinning the admin drawer at 900px. Consequences: `login_screen.dart:284-551` has no `ConstrainedBox`, so the login card fills a 1920px browser edge to edge; `data_analysis_tab.dart:236` renders 80px labels beside 1400px bars; `incident_log_tab.dart:368` gives full-bleed cards a 52px thumbnail; the hazard table (`ai_scan_tab.dart:3350-3603`) is a fixed 3-column `Row` at 10.5px that neither widens usefully nor reflows narrow. **Fix, in order:** (1) `ConstrainedBox(maxWidth: 440)` on login and other single-column entry screens — `force_password_change_screen.dart:132-133` already does this correctly, copy it; (2) `Center(child: ConstrainedBox(maxWidth: 720))` on task screens and `1100` on analytics/admin; (3) a `LayoutBuilder` in the shell switching to a `NavigationRail` above ~900px; (4) 2–3 column grids for dashboard and hazard cards above 900px.
- **[P1] `contractor_home_screen.dart:73/83` — nested `Scaffold`s with contradictory layout contracts.** The outer sets `extendBody: true` but owns no `bottomNavigationBar`, so the flag is inert; the inner owns the nav bar *without* `extendBody`. Contractor content is inset while employee content scrolls behind. **Fix:** one Scaffold with `extendBody: true`, background via a `Container` in `body`.
- **[P1] Fixed multi-column stat rows with no `Wrap`** — `data_analysis_tab.dart:426-436, 848-854`, `plant_wise_tab.dart:687-702, 755-779`, `overview_tab.dart:409-434`, `login_screen.dart:465-521`. At textScale 1.3 on a 320px device these overflow; `plant_wise_tab.dart:755` divides width by `stages.length`, so a six-stage admin ladder leaves ~50px for an 18px numeral. **Fix:** `Wrap` with a min tile width.
- **[P1] `reports_tab.dart:92-96` — four fixed non-scrollable tabs at 13.5px.** Hindi labels or raised textScale clip. **Fix:** `isScrollable: true`.

### E. Interaction, touch targets and feedback

- **[P0] 103 `GestureDetector`s give no ripple.** This includes every analytics drill-through (`overview_tab.dart:440/514/691/829/916`, `plant_wise_tab.dart:533/707/763`, `incident_log_tab.dart:340/482/506/533/557/615`, `data_analysis_tab.dart:375/399`, 21 in `admin_screen.dart`), the nav bar itself (`home_screen.dart:380-385`, `contractor_home_screen.dart:216-217`), `home_tab.dart:960-992` action cards, and the chat send button (`chat_tab.dart:874`). With gloves and a 250ms `AnimatedSwitcher`, the user has no confirmation a tap landed. **Fix:** `InkWell`/`InkResponse` inside `Material`. `incident_log_tab.dart:814` shows the right pattern.
- **[P0] Sub-48px targets on primary controls.** The **mic button is 36×36** (`near_miss_tab.dart:3698-3720`) despite voice being the primary gloved input. `IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints())` collapses to ~20–24px at `ai_scan_tab.dart:1007-1017, 1872-1873`, `dashboard_tab.dart:1153/1515/1590`, `near_miss_tab.dart:4499`, `admin_screen.dart:6462-6475, 6562-6600`. The theme toggle is a `GestureDetector` around 11px text ≈15px tall (`login_screen.dart:540-547`); "Forgot Password?" ≈16px tall in the corner (`604-614`); filter chips ~26px (`incident_log_tab.dart:487/512/536/560`); "Clear" ~17px (`data_analysis_tab.dart:375-388`); clear-date ~15px nested *inside* its row's own tap area (`incident_detail_screen.dart:1173-1178`). **Fix:** `constraints: BoxConstraints(minWidth: 48, minHeight: 48)` — grow the hit area via padding, not visual size.
- **[P1] `BottomNavGap` missing wherever it matters most.** Used in 9 places; needed in roughly 20. Missing at `ai_scan_tab.dart:2640` (hardcoded 80 — and the action buttons are the clipped row), `near_miss_tab.dart:4788` (hardcoded 100), `incident_log_tab.dart:369` (hardcoded 80), `dashboard_tab.dart:359/1164/1535/1595`, `sop_scan_screen.dart:1239/1463/1666`, `doc_qa_screen.dart:487/747/849`. **Fix:** `BottomNavGap()` / `BottomNavGap.padding(context)`; also hoist the `60` literal duplicated at `bottom_nav_gap.dart:35`, `home_screen.dart:368`, `contractor_home_screen.dart:210` into one `static const barHeight`.
- **[P2] Gesture-only affordances with no visual hint** — bounding boxes on the annotated photo are tappable with no indicator (`hazard_annotated_image.dart`); the SPI card toggles expansion with no chevron and nests a help `GestureDetector` inside its own tap area (`overview_tab.dart:916-917, 991-1003`). **Fix:** add an expand glyph / chevron; never nest tap targets.
- **[P2] Emoji as meaning-carrying icons** — 🏆 ⚠️ ⚖️ 🔧 📝 📭 at `overview_tab.dart:1022/1033`, `incident_detail_screen.dart:791-798, 884/903, 1302-1305`, `dashboard_tab.dart:1159-1163`. Unlocalisable, announced literally by screen readers, and rendered differently on Android versus browser. **Fix:** Material icons.

### F. Information architecture and hierarchy

- **[P0] No primary action on the two most important screens.** `ai_scan_tab.dart:3254-3324` puts five filled `ElevatedButton`s in one Row (Review/Save/PDF/Share/New) at 11px with 4px padding — ~60px each on a phone. `near_miss_tab.dart:4864-4890` does the same with three equal-weight gradient buttons. **Fix:** one full-width filled **Save**; demote the rest to text buttons or a `PopupMenuButton`, and enable Share/PDF only after save.
- **[P1] Six bottom-nav destinations** (`home_screen.dart:323-334`), above Material's 3–5 guidance. At 320px each slot is 53px for a 22px icon plus a 9px label, and "AI Scan / SOP Scan / Reports" is not a clean taxonomy. **Fix:** four primary tabs (Home, Scan, Near Miss, Reports); move Ask AI and SOP Scan behind a Home entry point or an overflow. This also dissolves the 9px-label compromise.
- **[P1] Duplicate presentations of the same data class** — `home_tab.dart:591-659` hero stat columns versus `719-769` `_statTile`, at very different visual weights with no stated rank. **Fix:** one stat treatment; reserve the hero row for the two KPIs leadership actually tracks.
- **[P1] Charts without scales.** Every "bar chart" in analytics is a hand-rolled `Stack` + `FractionallySizedBox` normalised to `maxVal` with no axis and no gridline (`data_analysis_tab.dart:610-810`, `plant_wise_tab.dart:849-930`, `overview_tab.dart:549-612`), so a set of 3/2/1 renders pixel-identical to 300/200/100. Worse, `fraction.clamp(0.03, 1.0)` (`data_analysis_tab.dart:644/703/790`, `plant_wise_tab.dart:864/919`) gives a **visible bar to a zero value**, and `overview_tab.dart:577`'s `(v/max)*80 + 4` baseline offset distorts every bar non-linearly while `582` hides the label when the value is 0, so a zero month reads as missing data. **Fix:** use `fl_chart`'s `BarChart` with `titlesData`/`gridData`; clamp only the top; render 0 as an empty track with the numeral.
- **[P1] Charts that look interactive but are not** — `PieChart` with no `pieTouchData` at `data_analysis_tab.dart:490-494, 569-592`, `overview_tab.dart:648-652`, `plant_wise_tab.dart:818-826`, sitting directly beneath KPI cards that *are* tappable. Two donuts are built with `title: ''`, so they carry no on-chart labels at all and are pure decoration beside their own legend. **Fix:** wire slice touch to the existing `_showIncidentsSheet`; label slices ≥8%.
- **[P2] Silent truncation** — `.take(8)` at `data_analysis_tab.dart:672, 733-743`, top-5 at `plant_wise_tab.dart:790`, `.take(50)/(60)/(20)` at `admin_screen.dart:8229/10178/6889`, `.take(8)` twice on bulk-import errors (`bulk_user_import_screen.dart:616-635`). No "+N more", no "showing top 8 of 23". Users conclude the tail does not exist. **Fix:** always state the total.
- **[P2] Section titles stranded above nothing** — empty data returns `const SizedBox()` while `build()` has already emitted the heading (`data_analysis_tab.dart:470/556/612/671`, `overview_tab.dart:620`, `plant_wise_tab.dart:791/887`). `_departmentBarChart` (`745-758`) does it correctly. **Fix:** hoist the empty check to the title, or render a uniform "No data" card.
- **[P2] No sort control on any hand-rolled table** (`data_analysis_tab.dart:624`, `plant_wise_tab.dart:905`, `admin_screen.dart:1452-1506, 7885`); order is hardcoded descending by count. **Fix:** tap-to-sort headers.

### G. Long-running AI flows

- **[P0] Nothing in the app can be cancelled** — `analysis_progress.dart` (entire widget), `ai_scan_tab.dart:2785-2818`, `near_miss_tab.dart:3163`, `sop_scan_screen.dart:1465-1510`, `doc_qa_screen.dart:697-735`, `bulk_user_import_screen.dart:781-804`. A 40s-per-page SOP read can only be escaped by killing the tab, losing everything. **Fix:** a Stop button that cancels the `ScanJob` and keeps partial results.
- **[P0] Raw technical errors reach shop-floor users.** `job.errorMessage` and `_offline_reason` spliced into snackbars (`ai_scan_tab.dart:271, 295-299`), service reason/hint strings (`2882-2890`), `PDF export failed: $e` (`near_miss_tab.dart:2359/2374/2607`), and a mid-import failure flattened to one string with no count of rows already created (`bulk_user_import_screen.dart:249-263`). Model slugs and exception text are shown to reporters. **Fix:** map to a fixed set of plain-language messages ("Couldn't reach the analyser — saved offline, will retry"); log the technical string via `AppLogger`.
- **[P1] The screen users stare at for 22s+ has the smallest type in the app** — `analysis_progress.dart` renders a 13px title, 11px caption and 10px elapsed counter in white on a 0.55-dimmed photo. **Fix:** 16/13/12, and move the phase line above the photo onto an opaque surface.
- **[P1] Zero `SnackBarAction`s app-wide.** A failed analysis offers no Retry (`ai_scan_tab.dart:2611-2620`). **Fix:** `SnackBarAction(label: 'Retry')` on every recoverable failure.
- **[P2] `ai_scan_tab.dart:2785-2818` — fixed `height: 210` analysing frame** crops tall portrait photos, which is most plant-floor captures. **Fix:** `AspectRatio(4/3)` with `BoxFit.contain`.
- **[P2] `ai_scan_tab.dart:795-819` — `_logAnalysisError` hardcodes `appVersion: '1.0.98'` and uses `print()`.** Already stale relative to `pubspec.yaml`. **Fix:** read the real version; route through `AppLogger`.

### H. Forms and data entry

- **[P0] `near_miss_tab.dart:3505-3559` — Step 2 is seven consecutive dropdowns** (plant, dept, other-dept, location, WSA-13 category, observation type, severity). Each needs a precise tap inside a scrolling popup, with gloves. **Fix:** render the 3–5 option fields (observation type, severity) as horizontal `ChoiceChip` rows at 48px; keep dropdowns only for genuinely long lists.
- **[P0] A half-filled report can be lost silently.** No `PopScope`/`WillPopScope` and no draft persistence in `near_miss_tab.dart`; switching tabs disposes the State, taking the photo with it. **Fix:** `PopScope` confirm plus autosave a draft to `LocalDB` on every `onChanged`.
- **[P0] `login_screen.dart:943-977` — no `Form`/`TextFormField`, no `autofillHints` (0 app-wide), no `FocusNode` chain.** Browser and Android password managers cannot fill or save credentials — real daily friction for a web-first app. The 7-field register form sets no `textInputAction`, so there is no next-field traversal. **Fix:** `AutofillGroup` + `AutofillHints.username`/`password`; `TextInputAction.next` throughout.
- **[P1] Validation lands late and in the wrong place.** `login_screen.dart:338-355` collapses all errors into one banner *above* the submit button, so on the register form the failing field can be 400px off-screen with no error styling. `near_miss_tab.dart:2380-2440` validates only at submit, after a GPS call, telling the reporter about five missing fields at the very end. (Credit where due: the one-pass error collection, `_scrollToFirstError` at `2239`, and `_requiredLabel` asterisks are all good.) **Fix:** per-field `errorText`, validate `onChanged` after first blur, `Scrollable.ensureVisible` on the first invalid field.
- **[P1] `near_miss_tab.dart:4562` — every field defaults to `TextInputType.text`** with no `textCapitalization`. **Fix:** `sentences` capitalisation; correct keyboard types for numeric and email fields.
- **[P2] `near_miss_tab.dart:3569-3695` — description is 3 lines, corrective action 2**, so dictated text scrolls invisibly in a 2-line box. **Fix:** `minLines: 3, maxLines: 8`. No `autofocus` anywhere in the form either.
- **[P2] Loading states drop context** — `login_screen.dart:382-393` and `force_password_change_screen.dart:223-229` swap the label for a bare spinner. "Signing in…" is cheap and reassuring. The surrounding card also stays fully interactive while `_loading`.
- **[P2] `force_password_change_screen.dart:120` uses deprecated `WillPopScope`.** On newer Flutter, predictive back can bypass it — the one thing this screen exists to prevent. **Fix:** `PopScope(canPop: false, onPopInvoked:)`.

### I. Empty, loading, error and offline states

- **[P1] Loading is a bare `CircularProgressIndicator` in every list** (`dashboard_tab.dart:355/417/1423`, `near_miss_tab.dart:3824`, `ai_scan_tab.dart:3906`), so the layout jumps when data lands. **Fix:** skeleton placeholders matching the card geometry.
- **[P1] Empty states are an emoji plus one grey line and offer no way out** — `dashboard_tab.dart:1159-1163` "📭 No cases found", `1533`, `sop_scan_screen.dart:1336`, `chat_tab.dart:757`. **Fix:** each empty state gets the primary CTA that fixes it ("Scan a hazard", "Add first page").
- **[P1] Zero-row filter states don't say which filter emptied the list** and offer no Clear (`admin_screen.dart:7673-7680, 9223-9235, 10161-10174`). `incident_log_tab.dart:358-364` does this right — copy it.
- **[P1] `splash_screen.dart:40-64` — `await LocalDB.getCurrentUser()` with no try/catch.** A throw leaves the user on an infinite splash with no error affordance; the 2000ms delay is also fixed rather than tied to readiness. **Fix:** try/catch → login; navigate as soon as the future resolves.
- **[P2] `admin_screen.dart:8089-8125, 6873-6888` — `FutureBuilder`s collapse loading and error into `snap.data ?? {}`,** so a failed stats fetch renders plausible zeros. This is worse than an error. **Fix:** distinguish the three states.
- **[P2] No offline banner anywhere.** Offline surfaces only inside an error string (`ai_scan_tab.dart:295`). Pull-to-refresh exists on only 4 screens. **Fix:** a slim persistent banner when queued-offline items exist, and a refresh affordance on every data screen.
- **[P2] `contractor_home_screen.dart:140/147` — sync feedback is a snackbar with a `✓` and no failure branch**, so `BackgroundSync.syncNow()` returning 0 or throwing both read as success.

### J. Accessibility

- **[P0] 2 `Semantics` widgets and 2 `Tooltip`s app-wide.** Every icon-only control — mic, close, re-analyse, bounding-box taps, nav items — is unlabelled to TalkBack; nav items expose no selected state; `hazard_annotated_image.dart` offers no alt equivalent for the annotated photo; `login_screen.dart:938` renders labels as sibling `Text` rather than `InputDecoration.labelText`, so TalkBack announces an unlabelled edit box. **Fix:** `labelText` on all fields, `Semantics(label:, selected:, button:)` on every icon-only control and nav item, and a `semanticLabel` summarising hazard count and severity on the annotated image.
- **[P1] Status conveyed by hue alone** — 7–8px coloured dots at `overview_tab.dart:697`, `plant_wise_tab.dart:834`, `admin_screen.dart:4125/5263`; pipeline rings at `incident_detail_screen.dart:623-670`; severity pill at `ai_scan_tab.dart:3816-3824`; pass/fail tint at `dashboard_tab.dart:761-767`. `dashboard_tab.dart:594-608` does it right with 🟠/🟢 prefixes. **Fix:** always pair colour with text or shape.
- **[P1] textScale overflow risk wherever fixed heights meet text** — `ai_scan_tab.dart:2785` (`height: 210`), `3254-3324` (five buttons in a Row), `hazard_annotated_image.dart` `_legendHeight = 22`, `reports_tab.dart:92`, `login_screen.dart:465-521`. **Fix:** min-height instead of height, `Wrap` for button rows, and clamp textScale to ~1.3 rather than ignoring it.

### K. Admin destructive actions

- **[P0] `admin_screen.dart:2799-2813` — "Normalize Plant Names" rewrites the `plant` field of every incident in the database with no confirmation dialog at all.** Also unconfirmed: SPI/score reset (`3899-3918, 6654-6661`), delete department (`6337-6340`), delete list item (`6717-6720`). **Fix:** confirmation naming the affected row count.
- **[P1] No undo anywhere in the app.** Delete-all-incidents (`2914-2978`), restore-overwrites-everything (`7452-7537`), clear KB (`8752-8774`), clear audit (`2109-2135`) are confirmed and counted — good — but irreversible. **Fix:** require typing DELETE for the destructive tier; auto-backup before restore.
- **[P1] `incident_detail_screen.dart:1388-1409` — "Close Case" is irreversible on a single unconfirmed tap** (`555` removes the action bar permanently). `336-451` — PDF/share never set `_saving` and the button at `545` is never disabled, so a multi-second export is re-tappable. **Fix:** confirm; disable during work.
- **[P1] `bulk_user_import_screen.dart` — progress bar with no cancel, no partial-success reporting, no resume, per-row problems truncated twice at 8.** **Fix:** report rows created before failure; offer retry-failed-only.
- **[P2] `admin_screen.dart:5519` toasts a plaintext password.** **Fix:** never; show a copy-to-clipboard affordance instead.

### L. Dead and unreachable code

Verified by grep — each of these has no reference outside itself:

- **[P0] `lib/screens/settings_screen.dart` (617 lines) is unreachable** — never imported, `SettingsScreen` never constructed. It also prints default `admin`/`admin` credentials as `SelectableText` (`150-154`) and shows a six-step Apps Script developer runbook to plant users (`514-526`) referring to "the field above" that no longer exists, alongside dead `_urlCtrl`/`_saveUrl`/`_testConnection` members. **Fix:** delete it — then note the real gap it was masking: **there is no theme switch anywhere in the app** despite a complete dark/light system, and language is an unlabelled AppBar widget. Add a reachable Settings with a System/Light/Dark segmented control and a labelled "Language · English" row.
- **[P0] `lib/screens/home_screen_modern.dart` (196 lines) + `lib/widgets/modern_bottom_nav.dart` (836 lines) are dead.** The former declares a *second* `class HomeScreen`, hard-codes `i < 5`, lacks the SOP tab, the `_visibleTabs` clamp and the unsaved-scan guard, and its header comment says "Copy this over home_screen.dart" — an invitation to reintroduce every bug listed above. `modern_bottom_nav.dart:532` also contributes a 9px type failure to the audit. **Fix:** delete both.
- **[P2] Nav bar duplicated** — `_NavItem` + `_bottomNav` at `home_screen.dart:319-453` and `contractor_home_screen.dart:174-267`, already drifted (10px vs 9px labels, 14 vs 10 pill padding). **Fix:** one `SlBottomNav(items, visible, current, onTap)`; move labels and icons into `app_tabs.dart` beside the indices.
- **[P2] `home_screen.dart:224` — `UniversalAppBar.onHome` is a static callback reassigned inside `build()`.** With two shells live this is a cross-shell hazard. **Fix:** pass it down, or key it per shell.

---

## 5. Prioritised roadmap

### Phase 0 — quick wins (mechanical, low risk, high visible payoff)

These are safe, mostly single-line, and together they change how the app *feels* more than any redesign would.

1. `SL.textOn()` fails safe — return `text1`, not `fill` (`main.dart:198`). One line, closes the biggest hole.
2. Delete `home_screen_modern.dart`, `modern_bottom_nav.dart`, `settings_screen.dart`. Removes 1649 lines, one duplicate `HomeScreen`, one 9px type failure, and a leaked default credential.
3. Fix the selected nav state: `sl.accentText` for icon and label, labels to 11px with `overflow: ellipsis`, `InkResponse` for feedback. The most-looked-at control in the app, currently failing contrast, the size floor, and tap feedback simultaneously.
4. `ConstrainedBox(maxWidth: 440)` on login and splash; `maxWidth: 720` on task screens; `1100` on analytics. Four wrappers, and the web app stops looking like a stretched phone.
5. `BottomNavGap` at the ~11 sites listed in §E, plus hoist the `60` literal into one constant.
6. White-on-saturated-fill sweep: the Normalize button, download gradient, green snackbars, Share gradient, pie labels.
7. Add `SLRadius` and `SLSpace` tokens (definition only, no sweep yet) so new code has somewhere correct to go.
8. `constraints: BoxConstraints(minWidth: 48, minHeight: 48)` on the mic button and the zero-constraint `IconButton`s.
9. `autofillHints` + `textInputAction` on login and register.
10. Make `tools/audit_contrast.py` multiline-aware so the colour score becomes trustworthy.

#### Phase 0 — what shipped on 2026-09-09

All ten were applied. Notes where the implementation differs from the item as written above:

1. **Done.** `SL.textOn()` now returns `text1` for an unrecognised fill and trips a debug `assert` naming the colour. Verified safe by enumerating all 84 call sites — every one passes a status colour, none passes `Colors.white`, so the fail-safe cannot invert a foreground.
2. **Done**, via `git rm` (history preserves them): `settings_screen.dart` (617 lines, incl. the leaked default `admin`/`admin`), `home_screen_modern.dart` (196, the duplicate `HomeScreen`), `modern_bottom_nav.dart` (836). Zero residual references.
3. **Done in both shells**, kept in lockstep. `sl.accentText`, `InkResponse` with a ripple, `Semantics(label/selected/button)`, and `SLText.minBadge` (11px) labels with `ellipsis`. **This overrides an earlier explicit request for 9px labels** — the same code comment that recorded the 9px request also sanctioned the fix ("shorten this one label to 'SOP' and put all six back"), so `SOP Scan` is now `SOP` and all six labels are 11px. Flagged here because it reverses a stated preference.
4. **Partly done.** `SLLayout` tokens defined (`form 440`, `content 720`, `wide 1100`, `railBreak 900`) and applied to login. The task-screen and analytics wrappers are deferred to Phase 1 — they interact with each tab's own scroll padding and are not the single-line change this phase is for.
5. **Done** for the real cases: `BottomNavGap.barHeight` is now the single source of the `60`, and the measured gap replaced literals in `ai_scan_tab`, `near_miss_tab`, `dashboard_tab`, and `sop_scan_screen`'s `_listPadding`. Four sites from the original list were *not* changed and should not be: the `120`/`100` paddings in `ai_scan_tab` are inside modal bottom sheets, and `doc_qa_screen` is a pushed route — neither sits under the nav bar.
6. **Done.** Download-button gradient `#22C55E→#16A34A` became `#15803D→#166534` (white text 2.28:1 → 5.02:1) with its glow updated to match; both green snackbars became `AppColors.greenLight` (2.5:1 → 5.48:1); the admin Normalize Plant Names button became `AppColors.amberLight` (**2.15:1 → 5.02:1**, the worst pair in the app, on a button that rewrites every incident's plant field); both Share gradients became `#B45309→#C2410C` (2.15/2.80 → 5.02/5.18); the Save gradient became `#15803D→#047857`. Pie labels deferred — they are drawn in a painter and need a layout change, not a colour swap.
7. **Done.** `SLRadius`, `SLSpace` (incl. `tapTarget = 48`), and `SLLayout` added to `main.dart`. Definitions only, as scoped.
8. **Done.** The Near Miss mic button keeps its 36px painted circle inside a 48px `HitTestBehavior.opaque` target, gains a `Semantics` label, and its live-state glyph moved from `Colors.red` (~3.9:1) to `sl.redText`. The five zero-constraint `IconButton`s in `ai_scan_tab` and `dashboard_tab` went to 48×48. Admin's dense rows were raised to 40 (edit/delete) and 44 (score steppers) rather than 48, because those live in a draggable list — and their `AppColors.red`/`green` glyphs became `sl.redText`/`sl.greenText`.
9. **Done.** `autofillHints` on all eight login and register fields (`username`/`password`, and `newUsername`/`newPassword` on register so a manager offers to generate rather than fill), plus an `AutofillGroup` around the form — without the group the platform never offers "save this password?".
10. **Done**, and it changed the score: see §3a. The tool now finds the nearest enclosing `TextStyle(`/`Icon(` vs `BoxDecoration(`/`Container(` marker within a 260-char lookback instead of requiring it on the same physical line.

Not attempted in Phase 0, still open: the plaintext-password toast at `admin_screen.dart:5519`, and the pie-slice labels.

### Phase 1 — this cycle

Type-floor sweep to 11px minimum (188 failures → 0) and `SLText` adoption across the top-5 offending screens · one shared `severityColor()` and a `sl.*Text` sweep of the 318 foreground sites · `GestureDetector` → `InkWell` sweep · one primary action on AI Scan and Near Miss · nav from six to four destinations · near-miss draft autosave and `PopScope` · plain-language error mapping plus `SnackBarAction(Retry)` · Stop button on every AI flow · real `BarChart`s with axes, and remove the `clamp(0.03)` zero-bar lie · confirmations on the four unconfirmed destructive admin actions · a reachable Settings screen with the theme and language controls.

### Phase 2 — polish and platform

`NavigationRail` and multi-column layouts above 900px · skeleton loaders · `Semantics` pass · tabular figures on numeric columns · retire the second blue brand and the amber overload · radius and spacing token sweep · offline banner · undo/backup for the destructive admin tier.

---

## 6. On visual direction

The app does not need a new look; it needs the look it already declares to be applied consistently. The token file describes a coherent industrial system — graphite steel dark base, cool neutral light base, steel-indigo primary, safety-amber reserved for MEDIUM, Inter throughout. That is a good, defensible direction for a SAIL product. What undermines it is not the palette but the entropy: 31 type sizes, 21 radii, a second blue brand, amber meaning six things, and a badge tier so small it reads as unfinished rather than dense.

Three principles worth adopting explicitly, because most findings above reduce to one of them:

**One meaning, one colour.** Amber is severity. Status, category, and confidence each get their own neutral or desaturated ramp. A card should never show three amber chips meaning three different things.

**Nothing below 11px, ever.** If 11px does not fit, the layout is wrong — reflow, truncate with a "+N more", or move content to a second line. Density achieved by shrinking type is not density, it is unreadability, and on a plant floor that is a safety property rather than a cosmetic one.

**One primary action per screen, and it is always the one that saves the user's work.** Everything else is a text button.

---

## 7. Verification

No SDK is available here, so Dart changes are verified by the baseline-diff method (see the `reference_dart_verification` note): capture `dart analyze` output before and after and compare, rather than reading absolute counts. For colour work, run `python3 tools/audit_contrast.py` before and after — but remember its two blind spots: the single-line regex (so grep separately for `color:` on continuation lines and inside ternaries) and the fact that it scores against the two global backgrounds only, never a local card fill. **When a card fill changes, hand-measure every foreground sitting on it, including widgets the diff did not touch.**
