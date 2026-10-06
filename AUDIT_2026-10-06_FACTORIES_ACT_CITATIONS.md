# Pre-deployment audit: Factories Act 1948 citations in AI hazard scans

Date: 2026-10-06  ·  Status: committed locally, **not yet pushed / not deployed**
Requested by: owner, "in most of the case regulation is mentioned as FA1948 S21 or S32 … please check once with respect to the Factories Act 1948", then "before deployment make a comprehensive audit of whatever changes you are suggesting".

## 1. Scope of this deployment

Everything already deployed earlier today (copyright footer, voice input, Safari/iPhone login) is on `origin/main` (tag v1.0.286) and is **not** part of this push. This push contains only the files below.

| File | Change | Risk |
|---|---|---|
| `lib/services/regulation_catalog.dart` | 14 Factories Act sections added (12 → 25 FA sections in total); S32, S41C and S40 meanings corrected; 4 new groups | Medium: changes what the AI may cite |
| `lib/services/gemini_vision.dart` | HARD RULES now include a subject→section guide; stockpile guidance re-cited; `kHazardPromptRev` 2 → 3 | Medium: changes the prompt and invalidates cached answers |
| `lib/screens/near_miss_tab.dart` | Tubing preset `S39` → `S7A(2)(a)`; empty-regulation fallback "Refer Factories Act S35-41" → "FA 1948 S7A (general duties of occupier)" | Low |
| `lib/screens/chat_tab.dart` | Safety-chat knowledge line: "S21–S39, S111A" → the correct range, including S7A, S11–S17, S41B–H, S111 and S111A | Low (text only) |
| `lib/services/local_ai.dart` | Offline answer: wrong "S39: Defective equipment" line replaced by S7A, S11/13/14/17, S24, S40, S41C and S111 | Low (text only) |
| `lib/services/.fuse_hidden0000000400000001` | Deleted. It was a stale 1,731-line copy of an old gemini_vision.dart that had been committed by accident. It is not a `.dart` file, so nothing imports it | None |
| `tools/regulation_catalog_test.dart`, `tools/pdf_regulation_column_test.dart` | New tests | None |

There are no database, Supabase, schema, auth or storage changes, and no new packages.

## 2. Root cause

The scan prompt tells the model to "CITE ONLY FROM" the regulation table, and that table is generated from `RegulationCatalog`. The table contained only these Factories Act sections: S21, S22, S28, S29, S31, S32, S33, S35, S36, S37, S38 and S41C. A finding about dust, heat, lighting, housekeeping, storage of coils or stockpiles, manual handling, plant roads, LOTO/permits, a damaged structure, or a worker's own unsafe act had **no correct section available**. The model then picked the nearest one, almost always S21 (machinery) or S32 (floors/access). The fault was in the table, not the model.

## 3. Legal check, section by section (Factories Act 1948 as amended 1987)

Each entry's title and sub-clauses were checked against the text of the Act. "Use" means the kind of finding the prompt now sends to that section.

| Section | Title in the Act | Use in scans | Verdict |
|---|---|---|---|
| **7A** (new) | General duties of the occupier. (2)(a) safe plant & systems of work; (b) use, handling, storage, transport of articles & substances; (c) information, instruction, training, supervision; (d) safe workplace, access & egress; (e) safe working environment | (a) LOTO/permits; (b) coils, stacks, stockpiles; (d) plant roads/rail/access, corroded structures; (e) noise. Fallback only when no specific section fits | Correct. Noise under (2)(e) is an interpretation, because the Act itself has no noise section (state Factories Rules carry the limits) |
| **11** (new) | Cleanliness | Housekeeping, spillage, scrap | Correct |
| **12** (new) | Disposal of wastes and effluents | Drains, sludge, effluent | Correct |
| **13** (new) | Ventilation and temperature, incl. protection from excessive heat | Radiant heat, furnace/runner areas | Correct |
| **14** (new) | Dust and fume | Dust plumes, fugitive emission, fume | Correct |
| **17** (new) | Lighting | Dark or dim areas, glare | Correct |
| 21 | Fencing of machinery | Reachable moving parts only | Unchanged, now with an explicit "not a default" rule |
| 22 | Work on or near machinery in motion | Cleaning/lubricating/adjusting running machinery | Unchanged |
| **24** (new) | Striking gear and devices for cutting off power | E-stop, pull-cord, isolator | Correct |
| 28, 29 | Hoists & lifts; lifting machines, chains, ropes, tackle | Cranes, slings | Unchanged |
| **30** (new) | Revolving machinery (max safe speed of grinding wheels etc.) | Grinding/abrasive wheels | Correct |
| 31 | Pressure plant | Unchanged | — |
| 32 | Floors, stairs and means of access: (a) sound, unobstructed, non-slip, handrails; (b) safe access; (c) protection where a person may fall from height | Meaning corrected to list (a)/(b)/(c); height → S32(c) | Correct ((c) was inserted in 1987) |
| 33 | Pits, sumps, openings in floors | Unchanged | — |
| **34** (new) | Excessive weights | Manual lifting/carrying | Correct |
| 35 | Protection of eyes | Grinding, molten metal | Unchanged |
| 36 | Precautions against dangerous fumes, gases (confined space) | Unchanged; `neverFor` height still enforced | — |
| **36A** (new) | Precautions regarding the use of portable electric light (≤ 24 V; flameproof where flammable) | Hand lamps in vessels/confined spaces | Correct |
| 37, 38 | Explosive/inflammable dust or gas; fire | Unchanged | — |
| **40** (new) | Safety of buildings and machinery. **This is the Inspector's power** to order repair or prohibit use | Kept citable, but the guide sends corroded structures to **S7A(2)(d)** first and to S40 only when the structure is dangerous to life | Corrected during this audit (see §5) |
| 41C | Specific responsibility of the occupier in relation to hazardous processes: health records, qualified supervision, "all necessary facilities for protecting the workers" | PPE not provided in hot-metal areas. Integrated iron & steel is item 1 of the First Schedule | Meaning corrected (it used to say only "PPE provision") |
| **41F** (new) | Permissible limits of exposure of chemical and toxic substances (Second Schedule) | CO / H2S exposure outside confined spaces | Correct |
| **111** (new) | Obligations of workers: (1)(a) not misuse/interfere with safety appliances; (b) not wilfully endanger self or others; (c) not neglect to use appliances/PPE provided | Worker not wearing PPE that is provided, standing under a load, bypassing a guard | Correct. S111A (rights of workers) is a different section, and the chat prompt had confused the two |
| 39 (removed from preset) | Power to require specifications of defective parts or tests of stability. **This is an Inspector power** | Was used in the Near Miss "process tubing" preset | Replaced by S7A(2)(a) |

Not added on purpose: S41G/S41H (safety committee, imminent danger: these are about how the plant is organised, not about something visible in a photo), S40B (safety officer), and the penalty sections.

## 4. How the change is enforced

- The prompt table is generated from the catalogue, so the model is offered exactly the 25 sections above.
- The new HARD RULES say: cite the most specific section, S21/S32 are not defaults, give the subject→section guide, write the sub-clause, and give one citation per hazard.
- `hazard_validator` already normalises sub-clauses (`S7A(2)(b)` → `FA1948|S7A`). It flags citations outside the table, checks the existing `neverFor` misapplications (S21 for gas cylinders, S36 for height), and checks topical fit against `appliesTo`.
- `kHazardPromptRev` 2 → 3: cached scan answers (keyed by image hash) are ignored, so a re-scan of an old photo gets the new citations.

## 5. Issues found by this audit and fixed before commit

1. **S40 was described as an occupier duty.** It is the Inspector's order power, the same reasoning that removed S39. Its meaning now says so, and the guide sends structures to S7A(2)(d).
2. **chat_tab.dart** told the safety chat the Act covers "S21–S39, S111A". S111A is workers' *rights*; the obligations are S111. Corrected.
3. **local_ai.dart** (the offline answer) described S39 as "Defective equipment — take out of service immediately", which is not what S39 says. Replaced with the correct sections.

## 6. Verification

| Check | Result |
|---|---|
| `dart analyze lib` | 52 issues, **0 errors** (same as the baseline) |
| `tools/regulation_catalog_test.dart` (6 tests): unique signatures; all 25 sections resolve; sub-clause and long forms ("Factories Act, 1948 – Section 7A(2)(d)", "Sec. 14", "S111(1)(c)") resolve; S39/S45 still rejected; S21-for-cylinder and S36-for-height still flagged; new sections fit their hazards; the prompt table lists the new groups | Pass |
| Existing hazard_quality + hazard_person_attribution (131 cases) | Pass, no regressions |
| voice_field_test (earlier fix) | Pass |
| PDF render with the longest new citations, `audit_2026-10-06/pdf_fa_citations.png` | "FA 1948 S7A(2)(b)" and "FA 1948 S111(1)(c)" wrap cleanly to two lines inside the REGULATION column, and no row grows, because the description is always taller |

## 7. Residual risks and what to watch after deploy

- **S7A could become the new default.** Its `appliesTo` words are broad, so the validator will rarely flag it. The meaning says "use ONLY when no specific section fits". **Watch:** if more than about a third of rows say S7A after deploy, tighten the rule.
- **This is a prompt change.** The model can still choose badly on an unusual photo, and the validator only catches citations that are outside the table or known misapplications.
- **One-time cost.** Every photo is analysed afresh the first time it is re-scanned after deploy, so expect slightly more AI calls for a day or two.
- **Knowledge Bank seed** (`kb_seed_data.dart`) has detailed documents only for the older sections. The new sections are cited from the table text. Adding KB documents for S7A, S11–S17 and S111 is a possible follow-up.
- **Not reviewed in this change:** the CEA Regulations 2010 and IE Rules 1956 entries. The CEA (Measures relating to Safety and Electric Supply) Regulations 2023 supersede the 2010 ones, so a separate check is worth doing.
- **State rules:** limits such as noise dB(A) or the 55 kg / 30 kg weight limits come from the state Factories Rules (Jharkhand, Odisha, Chhattisgarh, West Bengal, Karnataka), not from the Act itself.
- This is a software review of statutory references, not a legal opinion. A plant safety officer should confirm the section mapping against current state rules.

## 8. Rollback

This is a single commit. `git revert <sha>` and push. No data migration is involved; reverting restores the old table and rev 2. Old cached answers would come back, because rev-2 cache keys are still valid.

## 9. To deploy

`git push` from Windows (GitHub Pages workflow). Then re-scan 2–3 photos (dust, coil yard, worker without PPE) and check that the REGULATION column shows S14, S7A(2)(b) and S111(1)(c) rather than S21/S32.
