// lib/services/local_ai.dart
// v9 — FULL KNOWLEDGE BASE UPDATE
// Sources:
//   • Ministry of Steel Safety Guidelines SG/01–SG/25 (2019/2020)
//   • Process-Based Safety Guidelines SG/26–SG/41 (2024)
//   • SMPV Rules 2016 (complete)
//   • Factories Act 1948 (all safety sections)
//   • IS 14489:2018, CEA Regulations 2023, BIS PPE Standards
//   • WSA 13 Causes, ILO Code of Practice
// Used by: Ask AI (Suraksha Saathi) chatbot + offline fallback

import 'dart:io';
import 'admin_master_data.dart';

class LocalAI {

  // ══════════════════════════════════════════════════════════════════
  //  FULL KNOWLEDGE BASE
  //  Each entry: keywords (list) → detailed answer
  //  Used by chat() and also exposed to the Apps Script prompt
  // ══════════════════════════════════════════════════════════════════
  static const Map<String, String> _kb = {

    // ── FACTORIES ACT 1948 ─────────────────────────────────────────
    'factories act|section|fa 1948|factories|act sections':
      'FACTORIES ACT 1948 — KEY SAFETY SECTIONS:\n\n'
      'S21: Fencing of machinery — all dangerous moving parts must be guarded\n'
      'S22: Work on machinery in motion — written permit from manager required\n'
      'S28: Hoists & lifts — enclosure, safety devices, 6-monthly inspection\n'
      'S29: Lifting machines/cranes — SWL displayed, 6-monthly inspection\n'
      'S30: Revolving machinery — max safe speed must be marked\n'
      'S31: Pressure plant — SWP marked, relief valves functional\n'
      'S32: Floors/stairs/gangways — sound, unobstructed, handrails required\n'
      'S32: Safe means of access to every place of work\n'
      'S32: WORKING AT HEIGHT — fencing OR harness MUST be provided. '
      'ALWAYS cite S32 for height. NEVER S36 for height.\n'
      'S33: Pits, floor openings — securely covered or fenced\n'
      'S34: Excessive weights — Men max 55 kg, Women max 30 kg\n'
      'S35: Eye protection — goggles/shields mandatory where sparks, chemicals, molten metal\n'
      'S36: DANGEROUS FUMES / CONFINED SPACE ONLY — never cite for height\n'
      'S37: Explosive/flammable dust or gas — no ignition sources\n'
      'S38: Fire precautions — extinguishers, exits clear, fire watch\n'
      'S39: Defective equipment — take out of service immediately\n'
      'S111A: Workers have the right to obtain safety information from employer\n\n'
      'Penalty for violation: up to ₹2 lakh fine + 2 years imprisonment\n'
      'Ref: Factories Act 1948 (amended 1987)',

    // ── SECTION 32(c) — HEIGHT ─────────────────────────────────────
    'working at height|wah|height|fall|harness|lanyard|scaffold|guardrail|s32|section 32':
      'WORKING AT HEIGHT — SG/02 + FA S32:\n\n'
      '⚠️ Applicable above 1.8 metres (IS 14489 Clause 4)\n\n'
      'MANDATORY EQUIPMENT:\n'
      '• Full body harness — IS 3521:1999; anchor min 15 kN\n'
      '• Double lanyard (100% tie-off rule — always connected)\n'
      '• Guardrail: top rail 1.0m, mid-rail 0.5m, toe board 150mm (IS 4912)\n'
      '• Scaffolding per IS 3696 — load rating marked, inspection tag required\n'
      '  Tag colours: Green=Safe, Yellow=Restricted, Red=Unsafe/Do Not Use\n\n'
      'PTW: Work at Height permit mandatory\n'
      'NEVER work at height during: wind >45 km/h, lightning, rain\n'
      '100% tie-off: always connected to anchor — no exceptions\n\n'
      'Correct regulation: FA 1948 S32, IS 3521:1999, IS 4912:1978\n'
      'WRONG: S36 is for fumes/confined space only\n\n'
      'Ref: SG/02 Ministry of Steel, IS 14489:2018 Cl.4',

    // ── CONFINED SPACE ─────────────────────────────────────────────
    'confined space|confined|vessel entry|tank entry|manhole|silo|tunnel|pit|cs entry':
      'CONFINED SPACE ENTRY — SG/03 + FA S36:\n\n'
      'Classified confined spaces: bins, silos, tunnels, ESPs, manholes, '
      'furnaces, gas pipelines, gas holders, sumps, pits, oil cellars, '
      'conveyor/cable galleries\n\n'
      'PRINCIPAL HAZARDS:\n'
      '• Toxic gas: CO, H2S, NH3\n'
      '• Flammable gas: BF gas, COG, methane\n'
      '• Oxygen deficiency/enrichment\n'
      '• Engulfment in granular material\n\n'
      'SAFE ATMOSPHERE LIMITS (before entry):\n'
      '• O2: 19.5–23.5% (below 19.5% = danger; above 23.5% = fire risk)\n'
      '• CO: <50 ppm (IDLH 1200 ppm)\n'
      '• H2S: <10 ppm (IDLH 300 ppm)\n'
      '• LEL (flammable gas): <10% of LEL\n\n'
      'MANDATORY STEPS:\n'
      '1. Confined Space Entry PTW from safety officer\n'
      '2. Isolate all energy sources (LOTOTO)\n'
      '3. Purge with inert gas, then ventilate\n'
      '4. Atmosphere test by gas detector — document results\n'
      '5. Minimum 2 persons: 1 inside + 1 standby at entry point\n'
      '6. Full body harness + lifeline\n'
      '7. Rescue tripod + SCBA at entry point\n'
      '8. Radio communication maintained\n\n'
      'Never enter on empty stomach in gas areas\n'
      'Ref: SG/03, SG/04, FA 1948 S36',

    // ── PERMIT TO WORK ─────────────────────────────────────────────
    'permit to work|ptw|permit|hot work permit|wah permit|electrical permit|cold work':
      'PERMIT TO WORK SYSTEM — SG/04:\n\n'
      'PTW TYPES:\n'
      '• Hot Work Permit — welding, cutting, grinding, open flame\n'
      '• Cold Work Permit — maintenance without heat\n'
      '• Height Work Permit (WAH) — any work above 1.8m\n'
      '• Confined Space Entry Permit — entry into any confined space\n'
      '• Electrical Work Permit — any work on electrical systems\n'
      '• Excavation Permit — ground breaking >500mm depth\n'
      '• Radiography Permit — NDT radiation work\n'
      '• Critical Lift Permit — tandem lifts / lifts near live electrical\n\n'
      'PTW MUST SPECIFY:\n'
      '• Exact work scope and location\n'
      '• All hazards identified\n'
      '• Precautions and isolations required\n'
      '• PPE required\n'
      '• Duration and time limits\n'
      '• Emergency contacts and escape routes\n'
      '• Permit issuer (owner dept) AND receiver (maintenance) signatures\n\n'
      'PTW displayed at work location at all times\n'
      'Job Safety Analysis (JSA) mandatory for high-risk work\n'
      'LOTOTO required before any electrical/mechanical isolation\n\n'
      'Ref: SG/04, IS 14489:2018',

    // ── LOTOTO / LOTO ──────────────────────────────────────────────
    'loto|lototo|lock out|lockout|tag out|try out|energy isolation|isolation procedure':
      'LOTOTO — ENERGY ISOLATION — SG/22:\n\n'
      'LOTOTO = Lock Out, Tag Out, Try Out\n\n'
      'STEP-BY-STEP PROCEDURE:\n'
      '1. Identify ALL energy sources: electrical, pneumatic, hydraulic, '
      'gravitational, thermal, chemical\n'
      '2. Notify all affected workers\n'
      '3. Shut down equipment using normal procedure\n'
      '4. Isolate EVERY energy source at its point of isolation\n'
      '5. Each worker applies their OWN personal lock + tag\n'
      '6. Release/restrain stored energy: '
      'bleed pneumatics, release hydraulics, block gravity\n'
      '7. TRY OUT: attempt to start machine — confirm zero energy\n'
      '8. Carry out work safely\n'
      '9. Remove locks in REVERSE order — last person removes last\n\n'
      'CRITICAL RULES:\n'
      '• Each person working applies their OWN lock — never use one lock for all\n'
      '• Multiple energy sources = ALL must be isolated\n'
      '• Try Out confirms isolation before work begins — mandatory step\n'
      '• Green/Red lighting system in some SAIL plants for fit-to-work confirmation\n\n'
      'Ref: SG/22, IS 14489:2018 Cl.7, CEA Regulations 2010, Reg 46',

    // ── GAS CYLINDERS ──────────────────────────────────────────────
    'gas cylinder|cylinder|oxygen cylinder|acetylene|lpg cylinder|cylinder colour|cylinder colour code|smpv':
      'GAS CYLINDER SAFETY — SG/01 + SMPV Rules 2016:\n\n'
      'STORAGE RULES:\n'
      '• Chain ALL cylinders upright to wall/post — toppling fractures valve → explosion\n'
      '• Valve protection cap MUST be on when not in use (IS 8198)\n'
      '• ISI mark + last hydraulic test date must be clearly visible\n'
      '• Max 12 cylinders per 10m² storage area\n'
      '• Not near heat sources, electrical panels, or ignition sources\n'
      '• Separate full and empty cylinders — label empties as "EMPTY"\n\n'
      'SEPARATION RULE (SMPV Rule 14 Table-3):\n'
      '• Oxygen + flammable gas: minimum 6 METRES or fire-rated wall\n'
      '• LPG vessel from buildings: ≤500L=3m; >500-2000L=7.5m; >2000-20000L=15m\n\n'
      'COLOUR CODES (IS 15222):\n'
      '• Oxygen: Black body, White shoulder\n'
      '• Acetylene: Maroon body, Maroon shoulder\n'
      '• LPG: Silver body, Silver shoulder\n'
      '• Nitrogen: Grey body, Grey shoulder\n'
      '• Hydrogen: Red body, Red shoulder\n'
      '• Chlorine: Yellow body, Yellow shoulder\n'
      '• CO2: Black body, Black shoulder\n'
      '• Compressed Air: Grey body, Black shoulder\n'
      '• Argon: Peacock Blue body, Peacock Blue shoulder\n\n'
      'NEVER apply grease/oil to O2 fittings — explosion risk\n'
      'Return leaking cylinders to vendor — do not repair\n\n'
      'Ref: SG/01, SMPV Rules 2016, IS 15222, IS 8198',

    // ── SMPV RULES 2016 ─────────────────────────────────────────────
    'smpv|pressure vessel|relief valve|hydraulic test|static vessel|mobile pressure':
      'SMPV RULES 2016 — Pressure Vessels:\n\n'
      'Rule 10(1): No smoking/fire/ignition near compressed gas storage\n'
      'Rule 10(2): Empty flammable/toxic cylinders must stay closed until purged\n'
      'Rule 14 Table-3: O2 + flammable gas — min 6m separation or fire wall\n'
      'Rule 14: LPG vessel distances from buildings:\n'
      '  ≤500L = 3m | >500-2000L = 7.5m | >2000-20000L = 15m\n'
      'Rule 15: Vessels installed above ground only; not stacked\n'
      'Rule 16: Safety relief valves MANDATORY; must communicate with vapour space\n'
      'Rule 19: Hydraulic test every 10 years; NDT for vessels >100 KL\n'
      'Rule 22: No hot work near flammable gas vessels without permit\n\n'
      'Enforcement: Chief Controller of Explosives (PESO)\n'
      'Applies to: all gas cylinders, LPG vessels, compressed gas storage\n\n'
      'Ref: SMPV (Unfired) Rules 2016, Explosives Act 1884',

    // ── PPE STANDARDS ──────────────────────────────────────────────
    'ppe|personal protective|safety helmet|helmet|hard hat|safety shoes|ear protection|eye protection|gloves|harness':
      'PPE MANAGEMENT — SG/18 + FA S35:\n\n'
      'HIERARCHY OF CONTROLS (PPE is last resort):\n'
      'Eliminate > Substitute > Engineering > Administrative > PPE\n\n'
      'MANDATORY PPE STANDARDS:\n'
      '• IS 2925:1984 — Safety helmets\n'
      '  Colour code: White=Officer/AGM/GM | Yellow=Supervisor | '
      'Blue=Workman | Green=Visitor | Red=Fire brigade\n'
      '• IS 3521:1999 — Full body harness (mandatory >1.8m)\n'
      '• IS 4912:1978 — Guardrails (top 1.0m, mid 0.5m, toe board 150mm)\n'
      '• IS 5852:1993 — Safety footwear (steel toecap)\n'
      '• IS 5983:1980 — Eye protectors (goggles, face shields)\n'
      '• IS 6994:1973 — Heat resistant gloves (furnace/hot metal work)\n'
      '• IS 9167:1979 — Ear defenders (mandatory >85 dB)\n'
      '• IS 11226 — Respiratory protective equipment\n\n'
      'PPE MAINTENANCE:\n'
      '• Inspect before EACH use; damaged PPE replaced immediately\n'
      '• Safety helmet: replace after any impact OR every 3 years\n'
      '• Harness: retire immediately after any fall arrest\n'
      '• Hearing protection: >85dB=mandatory; >105dB=double protection\n\n'
      'Ref: SG/18, IS 14489:2018 Cl.5, FA 1948 S35, IPSS 1-11',

    // ── ELECTRICAL SAFETY ──────────────────────────────────────────
    'electrical|electric|loto electric|arc flash|electrocution|live wire|panel|switchboard|cea':
      'ELECTRICAL SAFETY — SG/15 + CEA Regulations 2023:\n\n'
      'CEA REGULATIONS 2023:\n'
      '• Reg 20: DANGER NOTICE (skull-and-crossbones) on all apparatus >250V\n'
      '• Reg 21: Insulating mats front+rear of ALL panels; rubber gloves mandatory\n'
      '• Reg 39: Minimum 1.0m clearance in front of every switchboard\n'
      '• Reg 43: All motor/transformer frames earthed by TWO connections\n'
      '• Reg 46: Substation fencing min 1.8m; auto fire for transformers >10 MVA\n\n'
      'LOTOTO MANDATORY for all electrical maintenance\n'
      'Test for DEAD before touching any conductor\n'
      'Earth before AND after isolation\n'
      'Arc Flash PPE (ATPV rated) for HV work\n'
      'ELCB (Earth Leakage Circuit Breaker) on all portable tools\n\n'
      'Minimum safe approach distances:\n'
      '• 33 kV = 0.9m | 11 kV = 0.6m | LT (<1kV) = 0.3m\n\n'
      'No work on live equipment without special Live Work permit\n\n'
      'Ref: SG/15, CEA Regulations 2023, IS 732, IS 14489:2018 Cl.7',

    // ── FIRE SAFETY ────────────────────────────────────────────────
    'fire|fire safety|hot work|welding|fire extinguisher|fire class|fire triangle|arson':
      'FIRE SAFETY — SG/16 + FA S38:\n\n'
      'HOT WORK PERMIT REQUIREMENTS:\n'
      '• PTW from Area In-charge + Safety Officer\n'
      '• Fire watch: present during work AND 30 min after completion\n'
      '• Clear combustibles within 10m radius\n'
      '• 9kg DCP extinguisher at site\n'
      '• Gas test for flammable atmosphere (<10% LEL)\n'
      '• Permit valid max 8 hours; must be renewed\n\n'
      'EXTINGUISHER TYPES:\n'
      '• Water: Class A (solid combustibles — paper, wood)\n'
      '• CO2: Class B/C and electrical equipment\n'
      '• DCP (Dry Chemical Powder): Class B/C\n'
      '• Foam: Class A/B\n'
      '• HOT METAL FIRE: NEVER use water — steam explosion. Use dry sand.\n\n'
      'STEEL PLANT FLAMMABLES: tar, naphtha, benzol, fuel gases, LPG, propane, oxygen\n\n'
      'One extinguisher per 15m per NBC 2016 Part 4\n'
      'Fire extinguisher: visual check monthly; annual service\n'
      'Assembly point: clearly marked; all personnel must know it\n\n'
      'Ref: SG/16, FA 1948 S38, NBC 2016 Part 4',

    // ── GASES — BF GAS, CO, COG ────────────────────────────────────
    'gas|bf gas|blast furnace gas|coke oven gas|cog|carbon monoxide|co gas|toxic gas|gas detector|fume|co exposure':
      'GAS SAFETY — SG/21 + SG/28 + SG/30:\n\n'
      'STEEL PLANT GASES — KNOW YOUR HAZARDS:\n'
      '• BF Gas (Blast Furnace): CO ~25–28%, highly TOXIC + EXPLOSIVE\n'
      '  Explosive range: 35–74% in air; TLV: 50 ppm\n'
      '  Most common fatal cause in Indian steel plants\n'
      '• COG (Coke Oven Gas): H2 ~55%, CH4 ~25%; EXPLOSIVE\n'
      '  Explosive range: 4.5–40% in air\n'
      '• CO (Carbon Monoxide): colourless, odourless — silent killer\n'
      '  TWA: 35 ppm | TLV: 50 ppm | IDLH: 1200 ppm\n'
      '• H2S: TLV 1 ppm; IDLH 300 ppm\n'
      '• NH3: TLV 25 ppm; respiratory irritant\n'
      '• O2 enrichment: >23.5% dramatically increases fire/explosion risk\n'
      '• N2 asphyxiation: O2 <19.5%=danger; <16%=unconscious; <6%=fatal\n\n'
      'CRITICAL RULES:\n'
      '• Personal CO detector: mandatory for all BF/Coke area personnel\n'
      '• Buddy system: minimum 2 persons in all gas areas\n'
      '• Never enter gas area on empty stomach (increases CO absorption)\n'
      '• Ensure positive pressure (>50mmwc) in gas pipelines at all times\n'
      '• BA set (breathing apparatus) within 30m of gas work areas\n\n'
      'CO EMERGENCY: Remove to fresh air. DO NOT give mouth-to-mouth '
      '(risk to rescuer). Oxygen therapy. Call ECR — Internal 3333\n\n'
      'Ref: SG/21, SG/28, SG/30, FA 1948 S36/S37',

    // ── LIQUID METAL SAFETY ────────────────────────────────────────
    'liquid metal|hot metal|slag|molten|tapping|ladle|BOF|converter|furnace tap':
      'LIQUID METAL SAFETY — SG/23:\n\n'
      'TEMPERATURE RANGES:\n'
      '• Hot metal: 1450–1550°C\n'
      '• Slag: 1300–1450°C\n'
      '• Operating range in plant: -180°C (cryo) to 1700°C\n\n'
      'CRITICAL RULE — WATER + HOT METAL = EXPLOSION:\n'
      '• NEVER allow water/moisture contact with liquid metal or slag\n'
      '• Before tapping/pouring: ladle must be DRY and preheated to min 800°C\n'
      '• EAF: Scrap must be completely DRY before charging\n'
      '• Water-cooled panel leak in EAF: STOP arcing immediately\n\n'
      'MANDATORY PPE FOR HOT METAL AREAS:\n'
      '• Full aluminised suit (face shield, gloves IS 6994, safety shoes)\n'
      '• All persons within 15m during tap: aluminised PPE mandatory\n\n'
      'SAFETY PROCEDURES:\n'
      '• No persons in hazard zone during tap\n'
      '• Ladle transfer: approved route; pedestrians cleared; barriers in place\n'
      '• BOF gas (CO-rich) recovery: CO monitor mandatory during blow\n'
      '• During blow: all persons minimum 10m from converter, behind blast shield\n\n'
      'Ref: SG/23, IS 14489:2018 Cl.8',

    // ── CRANE / LIFTING ────────────────────────────────────────────
    'crane|lifting|eot crane|overhead crane|swl|slinging|banksman|sling|lift permit':
      'CRANE & LIFTING SAFETY — SG/14 + FA S29:\n\n'
      'MANDATORY REQUIREMENTS:\n'
      '• 6-monthly load test by competent person (FA S29)\n'
      '• SWL (Safe Working Load) prominently marked on crane structure\n'
      '• Crane operator: trained and certified\n'
      '• Banksman: trained in hand signals (IS 4014) or radio communication\n'
      '• No lift when persons are in the lift zone — exclusion area mandatory\n'
      '• Anti-collision devices where multiple cranes operate\n\n'
      'SLING ANGLES — IMPORTANT:\n'
      '• 60° is maximum recommended sling angle\n'
      '• At 30°: sling load = 2× actual load (angle penalty)\n'
      '• Inspect slings before every lift; decommission if >10% wire broken\n\n'
      'PRE-LIFT CHECKLIST:\n'
      '• Approved lifting plan for critical lifts\n'
      '• SWL never exceeded\n'
      '• Ground stability confirmed\n'
      '• Tag lines attached\n'
      '• All persons clear of lift zone\n\n'
      'Ref: SG/14, FA 1948 S29, IS 13367:1992, IS 3832, IS 4014',

    // ── MACHINERY GUARDING ─────────────────────────────────────────
    'machinery|machine guard|rotating part|guarding|conveyor|belt|nip point|unguarded':
      'MACHINERY GUARDING — SG/09 + FA S21:\n\n'
      'ALL ROTATING PARTS must be guarded:\n'
      '• Gears, pulleys, flywheels, couplings, shafts, belt drives\n'
      '• Minimum guard clearance: 100mm at pinch points\n\n'
      'CONVEYOR SAFETY (SG/19):\n'
      '• LOTOTO mandatory before any conveyor maintenance\n'
      '• All gallery walkways: standard guardrail + toe boards\n'
      '• Pull chord (emergency stop) — inspect availability daily\n'
      '• No work on conveyor while running\n'
      '• Hooter alert before restarting conveyor\n'
      '• Long toe guards for overhead conveyors\n\n'
      'INTERLOCKED GUARDS:\n'
      '• If guard is removed, machine stops automatically\n'
      '• NEVER bypass safety interlocks\n\n'
      'Guard inspection: visual daily; formal monthly check\n'
      'LOTOTO mandatory before any work on machinery\n\n'
      'Ref: SG/09, SG/19, FA 1948 S21, IS 14489:2018 Cl.6.2',

    // ── BARRICADING ────────────────────────────────────────────────
    'barricad|barrier|caution tape|warning tape|hard barricad|soft barricad':
      'BARRICADING — SG/11:\n\n'
      'TYPES:\n'
      '• Hard barricading (steel pipe/concrete): excavations, heavy equipment zones\n'
      '• Soft barricading (caution tape): low-risk temporary situations only\n\n'
      'STANDARDS:\n'
      '• Minimum height: 1.0m\n'
      '• Colours: yellow/black striped or red/white\n'
      '• Warning signs at all barricade entry points:\n'
      '  DANGER (red) = high risk\n'
      '  WARNING (orange) = medium risk\n'
      '  CAUTION (yellow) = low risk\n\n'
      'Must be maintained for entire duration of work\n'
      'Inspect daily; repair or replace damaged sections immediately\n\n'
      'Ref: SG/11',

    // ── MATERIAL HANDLING ──────────────────────────────────────────
    'material handling|manual handling|manual lift|weight limit|lifting limit':
      'MATERIAL HANDLING — SG/13 + FA S34:\n\n'
      'MANUAL LIFTING LIMITS (FA S34):\n'
      '• Men: maximum 55 kg\n'
      '• Women: maximum 30 kg\n'
      '• Team lift if above limits\n\n'
      'CORRECT LIFTING TECHNIQUE:\n'
      '• Straight back, bent knees\n'
      '• Load close to body\n'
      '• Smooth lift — no jerking\n'
      '• Turn feet, not twisting back\n\n'
      'MECHANISED HANDLING:\n'
      '• Approved lifting plan mandatory for crane lifts\n'
      '• SWL never exceeded\n'
      '• Tag lines mandatory\n'
      '• No persons under suspended load — ever\n\n'
      'Ref: SG/13, FA 1948 S34',

    // ── ENERGY ISOLATION ───────────────────────────────────────────
    'energy isolation|stored energy|pneumatic|hydraulic isolation|gravity block':
      'ENERGY ISOLATION — SG/22:\n\n'
      'TYPES OF ENERGY TO ISOLATE:\n'
      '• Electrical (primary)\n'
      '• Pneumatic (air pressure)\n'
      '• Hydraulic (oil pressure)\n'
      '• Gravitational (potential energy — use gravity blocks)\n'
      '• Thermal (steam, hot surfaces)\n'
      '• Chemical (process materials)\n\n'
      'STORED ENERGY — MUST BE RELEASED:\n'
      '• Bleed pneumatic systems to atmosphere\n'
      '• Release hydraulic pressure through bleed valves\n'
      '• Install gravity blocks/props under raised equipment\n'
      '• Allow hot surfaces to cool before work\n\n'
      'Each person applies their OWN lock — not a shared lock\n'
      'Try Out (attempt to start) confirms zero energy\n\n'
      'Ref: SG/22, IS 14489:2018 Cl.7',

    // ── OXYGEN & NITROGEN ──────────────────────────────────────────
    'oxygen|nitrogen|o2 line|n2 line|nitrogen asphyxiation|oxygen enrichment|cryogenic':
      'OXYGEN & NITROGEN GAS LINES — SG/20:\n\n'
      'OXYGEN HAZARDS:\n'
      '• O2 enrichment (>23.5%): dramatically increases fire/explosion risk\n'
      '• Never apply grease or oil to O2 pipelines or fittings — explosion\n'
      '• No smoking or naked flame within 3m of O2 lines\n'
      '• O2 line colour: BLUE\n\n'
      'NITROGEN HAZARDS:\n'
      '• N2 is colourless, odourless — asphyxiation without warning\n'
      '• O2 <19.5% = dangerous | <16% = unconsciousness | <6% = fatal\n'
      '• Always monitor O2 level before entry into N2-purged areas\n'
      '• N2 line colour: GREY/BLACK\n\n'
      'CRYOGENIC SAFETY:\n'
      '• Cryogenic liquids: -150°C to -196°C — cryogenic burns\n'
      '• Cryogenic gloves + face shield mandatory\n'
      '• Oxygen plant: cryogenic O2 area — no organic material (fire risk)\n\n'
      'Ref: SG/20, SMPV Rules 2016',

    // ── WSA 13 CAUSES ──────────────────────────────────────────────
    // ⚠ This is the OFFLINE fallback knowledge base and must be a `const` map,
    // so it cannot read the admin's cause list at runtime. The cause lines
    // below are therefore the DEFAULT wording; every answer is passed through
    // [_withLiveWsaCauses] on the way out, which swaps in the admin's list.
    // Keep this block in sync with AdminMasterData.defaultWsaCauses so the
    // substitution can find it.
    'wsa|13 causes|world steel|cause categories|root cause':
      'WSA 13 CAUSE CATEGORIES (World Steel Association):\n\n'
      'Assign ONE cause to every incident/near miss:\n\n'
      '1. Failure to follow procedure\n'
      '2. Lack of hazard awareness\n'
      '3. Improper PPE use\n'
      '4. Unsafe body positioning\n'
      '5. Equipment failure\n'
      '6. Communication failure\n'
      '7. Human error\n'
      '8. Poor housekeeping\n'
      '9. Lack of supervision\n'
      '10. Fatigue / time pressure\n'
      '11. Unauthorized operation\n'
      '12. Inadequate isolation (LOTO/PTW)\n'
      '13. Environmental conditions\n\n'
      'WSA Top 5 causes in steel industry worldwide:\n'
      '1. Moving machinery\n'
      '2. Working at heights\n'
      '3. Falling objects\n'
      '4. On-site traffic\n'
      '5. Process safety incidents\n\n'
      'Ref: World Steel Association Safety Framework, ILO Code of Practice 2005',

    // ── INCIDENT CLASSIFICATION ────────────────────────────────────
    'incident|lti|ltir|fatality|near miss|rwc|fac|dangerous occurrence|accident|injury classification':
      'INCIDENT CLASSIFICATION — SG/26:\n\n'
      'INCIDENT TYPES (most to least severe):\n'
      '• FATALITY: Death of employee/contractor/visitor on site\n'
      '  → Immediate reporting to management + statutory authorities\n'
      '• LTI (Lost Time Injury): Injury preventing work at NEXT scheduled shift\n'
      '  → Report same day\n'
      '• RWC (Restricted Work Case): Can work but not normal duties\n'
      '  → Report same shift\n'
      '• FAC (First Aid Case): Minor treatment; back to work same shift\n'
      '  → Report same shift\n'
      '• NEAR MISS: No injury but potential existed\n'
      '  → Report immediately — same urgency as LTI\n'
      '• DANGEROUS OCCURRENCE: Property/equipment damage, no injury\n'
      '  → Report same day\n\n'
      'PERFORMANCE METRICS:\n'
      '• LTIFR (Frequency Rate): LTIs per million man-hours worked\n'
      '• Severity Rate: Days lost per million man-hours worked\n\n'
      'Root cause investigation: mandatory for all LTIs, fatalities, and near misses\n'
      'Learning shared across all plants within 24 hours of fatality\n\n'
      'Ref: SG/26, ILO Code of Practice on Safety & Health in Steel Industry',

    // ── BLAST FURNACE SAFETY ───────────────────────────────────────
    'blast furnace|bf|tuyere|hot blast|salamander|tap hole|blast furnace gas|bf gas':
      'BLAST FURNACE SAFETY — SG/30:\n\n'
      'TOP HAZARDS:\n'
      '• BF gas (CO 25–28%): highly toxic + explosive — most common fatal cause\n'
      '• Hot metal and slag (1450–1550°C)\n'
      '• High pressure steam\n'
      '• Overhead crane operations\n\n'
      'CRITICAL RULES:\n'
      '• CO personal detector: mandatory for ALL BF area personnel\n'
      '• Buddy system: minimum 2 persons in gas areas\n'
      '• Hot metal splash during tap: all persons within 15m must have aluminised PPE\n'
      '• Tap hole area: cleared before opening; only trained operators within 30m\n'
      '• Campaign maintenance (BF interior): full SCBA required — confined space entry\n'
      '• Positive pressure (>50mmwc) must be maintained in BF gas lines\n\n'
      'BF GAS PROPERTIES:\n'
      '• CO content: 25–28%\n'
      '• Explosive range: 35–74% in air\n'
      '• TLV: 50 ppm (as CO)\n\n'
      'Ref: SG/30, SG/21, SG/23',

    // ── COKE OVEN SAFETY ───────────────────────────────────────────
    'coke oven|coke|by product|coal chemical|coke oven gas|benzol|tar|ammonia':
      'COKE OVEN SAFETY — SG/28:\n\n'
      'MAIN HAZARDS:\n'
      '• CO gas exposure in conveyor tunnels and oven areas\n'
      '• Fire from coal self-ignition and tar spillage\n'
      '• Hot surfaces (coke temperature ~1050°C at CDCP)\n'
      '• Coal/coke dust\n'
      '• Confined spaces: conveyor tunnels, gas holders, by-product sumps\n\n'
      'CO MONITORING:\n'
      '• Personal CO detector mandatory in all coke oven areas\n'
      '• CO TLV: 50 ppm; TWA: 35 ppm; IDLH: 1200 ppm\n\n'
      'CRITICAL RULES:\n'
      '• LOTOTO mandatory for all oven machinery maintenance\n'
      '• Never work in gas areas on empty stomach\n'
      '• Ensure DP plugs in position before opening gas cocks\n'
      '• Confined space in tunnels: PTW + gas test mandatory\n\n'
      'FIRE PREVENTION:\n'
      '• Coal self-ignition: MVWS (Medium Velocity Water Spray) system required\n'
      '• Conveyor fire: FDA (Fire Detection Alarm) + MVWS system\n\n'
      'Ref: SG/28, SG/21',

    // ── ROLLING MILLS ──────────────────────────────────────────────
    'rolling mill|hot rolling|cold rolling|mill floor|cobble|pickling|acid|roll change':
      'ROLLING MILL SAFETY — SG/37 + SG/38:\n\n'
      'HOT ROLLING (SG/37):\n'
      '• Nip points in rolls — no personnel on mill floor during rolling\n'
      '• Material temperature: 800–1200°C\n'
      '• Cobble (pile-up): clear area immediately; cut only after cooling or '
      'with long-handled tool\n'
      '• Roll change: LOTOTO mandatory; min 2 persons; approved lifting plan\n'
      '• Scale pits: confined space — PTW + gas test before entry\n'
      '• Noise: 90–110 dB typical — double hearing protection mandatory\n\n'
      'COLD ROLLING (SG/38):\n'
      '• Hydrogen: explosive range 4–75% in air — no ignition sources in H2 area\n'
      '• Continuous H2 monitor mandatory in bright annealing area\n'
      '• Pickling (HCl/H2SO4): acid splash protection:\n'
      '  Full face shield + acid-resistant gloves + acid-resistant apron\n'
      '• Skin contact HCl/H2SO4: flush with large amounts of water for 15–20 min\n\n'
      'Ref: SG/37, SG/38',

    // ── STEEL MELTING SHOP / BOF ────────────────────────────────────
    'steel melting|sms|bof|converter|ld process|eaf|electric arc furnace|scrap|ladle':
      'STEEL MELTING SHOP SAFETY — SG/39 + SG/34:\n\n'
      'BOF (BASIC OXYGEN FURNACE — SG/39):\n'
      '• LD process produces large CO volumes during blow — CO monitor mandatory\n'
      '• Ladle must be preheated to min 800°C before receiving hot metal\n'
      '• During blow: all persons min 10m from converter + behind blast shield\n'
      '• BOF gas recovery: CO-rich gas; explosion risk during ignition sequence\n\n'
      'EAF (ELECTRIC ARC FURNACE — SG/34):\n'
      '• CRITICAL: Scrap must be COMPLETELY DRY before charging\n'
      '  Moisture + molten metal = violent steam explosion — FATAL\n'
      '• Water leak from water-cooled panel: STOP arcing IMMEDIATELY\n'
      '  Then: stop tilting, identify leak, reduce water flow\n'
      '• Carbon boil: violent throw of metal through slag door\n'
      '  Clear area; slag door shield mandatory\n'
      '• Arc flash: ATPV-rated PPE required; face shield rated for arc energy\n'
      '• LOTOTO mandatory during all tap-to-tap maintenance intervals\n\n'
      'Ref: SG/34, SG/39, SG/23',

    // ── SINTER PLANT ───────────────────────────────────────────────
    'sinter|sinter plant|windbox|sinter machine|iron ore|raw material':
      'SINTER PLANT SAFETY — SG/31:\n\n'
      'MAIN HAZARDS:\n'
      '• CO exposure from windbox and ignition hood\n'
      '• High temperature: sinter discharge at 800–900°C\n'
      '• Dust: iron ore fines (silica dust — silicosis risk)\n'
      '• Rotating machinery: crushers, conveyors, screens\n\n'
      'CRITICAL RULES:\n'
      '• Windbox explosion risk: follow pre-ignition purge procedure strictly\n'
      '• Dust explosion: suppress with water spray in enclosed areas\n'
      '• Hot sinter discharge: aluminised PPE + face shield mandatory\n'
      '• CO personal detector mandatory\n'
      '• Silica dust: dust mask (IS 11226) or respirator mandatory\n\n'
      'Ref: SG/31, SG/23',

    // ── CONTRACTOR SAFETY ──────────────────────────────────────────
    'contractor|contract worker|contractor safety|subcontractor|induction|gate pass':
      'CONTRACTOR SAFETY MANAGEMENT — SG/41:\n\n'
      'FACTS:\n'
      '• Contractors account for ~50% of steel plant workforce\n'
      '• Higher fatality share vs own employees\n'
      '• Unskilled, less trained, unaware of plant-specific hazards\n\n'
      'MANDATORY REQUIREMENTS:\n'
      '• Safety induction BEFORE first day on site (no exceptions)\n'
      '• Gate pass issued ONLY after induction completion\n'
      '• PTW: contractor must obtain from owner department before ANY work\n'
      '• Supervisor ratio: 1 supervisor per 10 contract workers minimum\n\n'
      'SAME STANDARDS as own employees — no lesser safety for contractors\n\n'
      'COMPLIANCE:\n'
      '• Monthly contractor safety audit\n'
      '• Non-compliant contractors: work stoppage + site ban\n\n'
      'Ref: SG/41, FA 1948, Contractor Safety Policy',

    // ── ILLUMINATION ───────────────────────────────────────────────
    'illumination|lighting|lux|workplace lighting':
      'ILLUMINATION AT WORKPLACE — SG/05:\n\n'
      'MINIMUM LUX LEVELS (as per FA 1948 S17 + SG/05):\n'
      '• General plant areas: 50 lux minimum\n'
      '• Fine work / inspection areas: 200–500 lux\n'
      '• Emergency lighting: must operate if main power fails\n\n'
      'Poor lighting effects:\n'
      '• Eyestrain, headaches, increased incident risk\n'
      '• Inability to detect hazards — leads to WSA Cause 2 (lack of hazard awareness)\n\n'
      'Ref: SG/05, FA 1948 S17',

    // ── HYDRAULIC SYSTEM ───────────────────────────────────────────
    'hydraulic|hydraulic system|hydraulic safety|oil fire|high pressure oil':
      'HYDRAULIC SYSTEM SAFETY — SG/10:\n\n'
      'MAIN HAZARDS:\n'
      '• High-pressure oil injection injury (penetrates skin at >100 bar)\n'
      '• Hydraulic oil fire (flash point ~140–200°C)\n'
      '• Sudden equipment movement when pressure released\n\n'
      'SAFETY RULES:\n'
      '• LOTOTO + bleed pressure before any maintenance\n'
      '• Never use hand to check for hydraulic leaks — use paper/cardboard\n'
      '• Oil fire: DCP or CO2 extinguisher; NOT water\n'
      '• Inspect hoses for bulging, cracking, abrasion — replace before failure\n\n'
      'Ref: SG/10',

    // ── TRANSPORTATION ─────────────────────────────────────────────
    'transport|vehicle|loco|train|rail|road|traffic|pedestrian':
      'TRANSPORTATION SAFETY — SG/24 + SG/25:\n\n'
      'INTERNAL TRANSPORT HAZARDS:\n'
      '• Rail/road vehicles, transfer cars, forklifts, ladle carriers\n'
      '• Interaction between vehicles/pedestrians\n'
      '• Loads falling from vehicles\n\n'
      'SAFETY RULES:\n'
      '• Pedestrian walkways: separated from vehicle routes\n'
      '• Speed limits: 15 km/h in plant; 5 km/h in congested areas\n'
      '• Traffic management plan mandatory for busy crossings\n'
      '• Loco operation (SG/25): scotch block under wheels when stationary\n\n'
      'Ref: SG/24, SG/25',

    // ── EMERGENCY RESPONSE ─────────────────────────────────────────
    'emergency|first aid|emergency response|evacuation|rescue|assembly point':
      'EMERGENCY RESPONSE — QUICK GUIDE:\n\n'
      '🔴 CO GAS EXPOSURE:\n'
      'Remove to fresh air. Do NOT give mouth-to-mouth (rescuer risk).\n'
      'Oxygen therapy. Call ECR: Internal 3333\n\n'
      '🔴 HOT METAL/FIRE:\n'
      'NEVER use water. Dry sand only. Remove burning clothing.\n'
      'Call burns unit immediately.\n\n'
      '🔴 ELECTRICAL SHOCK:\n'
      'Do NOT touch victim if still in contact. Isolate power first.\n'
      'CPR if needed. Call medical.\n\n'
      '🔴 CONFINED SPACE COLLAPSE:\n'
      'Do NOT enter without SCBA. Raise alarm. Rescue team only.\n\n'
      '🔴 FALL FROM HEIGHT:\n'
      'Do NOT move person (spinal injury risk). Call medical.\n'
      'Preserve scene for investigation.\n\n'
      '🔴 ACID SPLASH:\n'
      'Flush with large water for 15–20 min. Remove clothing. Call medical.\n\n'
      '🔴 GAS LEAK:\n'
      'Evacuate. No mobile phones (spark risk). Isolate source if safe.\n'
      'Call control room.\n\n'
      'STOP PRINCIPLE: Every worker has the RIGHT to stop unsafe work (FA S111A)',

    // ── EXCAVATION ─────────────────────────────────────────────────
    'excavation|dig|trench|ground breaking':
      'EXCAVATION SAFETY — SG/17:\n\n'
      '• Excavation permit required for depth >500mm\n'
      '• Check for underground utilities (cables, pipes) before digging\n'
      '• Slope or shore sides for excavations >1.2m depth\n'
      '• Hard barricading around all open excavations\n'
      '• Ladder access for excavations >1.2m depth\n'
      '• No persons below suspended loads near excavations\n\n'
      'Ref: SG/17',

    // ── DEMOLITION ─────────────────────────────────────────────────
    'demolition|demolish|structure|building demolition':
      'DEMOLITION SAFETY — SG/12:\n\n'
      '• Demolition plan approved by competent structural engineer\n'
      '• Survey of underground utilities (electrical, gas, water)\n'
      '• Exclusion zone: 1.5× height of structure being demolished\n'
      '• Sequence: top-down demolition only\n'
      '• Dust suppression: water spraying\n'
      '• NEVER manual demolition without full engineering assessment\n\n'
      'Ref: SG/12',

    // ── INCIDENT CLASSIFICATION DEFINITIONS ────────────────────────
    'riskassessment|risk assessment|jsa|job safety analysis|hazard identification':
      'RISK ASSESSMENT & HAZARD IDENTIFICATION:\n\n'
      'KEY DEFINITIONS (Ministry of Steel SG/26):\n'
      '• Hazard: Inherent potential to cause physical injury or health damage\n'
      '• Risk: Likelihood × Severity of a hazard event\n'
      '• Unsafe Act: Action that may endanger a person (e.g., no harness at height)\n'
      '• Unsafe Condition: Physical situation that may cause injury (e.g., broken handrail)\n'
      '• Incident: Unsafe occurrence where no injury occurred\n'
      '• Accident: Unintended occurrence resulting in injury\n'
      '• Residual Risk: Risk remaining after protective measures applied\n\n'
      'HIERARCHY OF CONTROLS:\n'
      '1. Eliminate (remove the hazard)\n'
      '2. Substitute (replace with lower-risk)\n'
      '3. Engineering controls (guards, ventilation)\n'
      '4. Administrative controls (procedures, training)\n'
      '5. PPE (last resort)\n\n'
      'JSA (Job Safety Analysis): Break job into steps → identify hazards per step → '
      'determine risk controls. Mandatory for high-risk tasks.\n\n'
      'Ref: SG/26, IS 14489:2018',

    // ── SAFETY MANAGEMENT SYSTEM ────────────────────────────────────
    'safety management|sms|ohsas|iso 45001|safety system|safety culture':
      'SAFETY MANAGEMENT SYSTEM:\n\n'
      'STANDARDS:\n'
      '• ISO 45001:2018 (replaces OHSAS 18001) — OSH Management System\n'
      '• IS 14489:2018 — OHS Code of Practice for Steel Plants\n'
      '• ILO Code of Practice on Safety & Health in Steel Industry 2005\n\n'
      'PERFORMANCE INDICATORS:\n'
      'LEADING (proactive):\n'
      '• PTW compliance %\n'
      '• Near miss reporting rate\n'
      '• Toolbox talk attendance\n'
      '• Safety observation rate\n'
      '• Inspection completion rate\n\n'
      'LAGGING (reactive):\n'
      '• LTIFR (Lost Time Injury Frequency Rate)\n'
      '• Severity Rate (days lost)\n'
      '• Fatality count\n\n'
      'No-blame culture for near-miss reporting is essential\n'
      'Most successful steel companies are also the safest (WSA)\n\n'
      'Ref: SG/27, ISO 45001:2018',

    // ── IS 14489 STEEL PLANT OHS ────────────────────────────────────
    'is 14489|14489|ohs code|steel ohs|ohs steel':
      'IS 14489:2018 — OHS Code of Practice for Steel Plants:\n\n'
      'Clause 4: Fall protection >1.8m — IS 3521 harness, IS 4912 guardrails\n'
      'Clause 5: PPE mandatory at all times — IS 2925 helmet, IS 5852 footwear\n'
      'Clause 6: Scaffolding per IS 3696 — inspection tag, toe boards, guardrails\n'
      'Clause 7: LOTOTO for all maintenance; IS 8437 electrical clearances\n'
      'Clause 8: Crane/lifting — IS 3832 slinging, SWL marked, IS 4014 signals\n'
      'Clause 9: Housekeeping — walkways clear, spills removed immediately, 5S\n'
      'Clause 10: Fire safety — extinguisher access clear, min 4A:B:C rating\n\n'
      'Ref: IS 14489:2018, Bureau of Indian Standards',
  };

  // ══════════════════════════════════════════════════════════════════
  //  CHAT — Main answer function used by ChatTab
  // ══════════════════════════════════════════════════════════════════
  static String chat(String question) {
    final q = question.toLowerCase().trim();
    if (q.isEmpty) return _defaultHelp();

    // Score each KB entry by keyword matches
    String bestKey = '';
    int bestScore = 0;

    for (final entry in _kb.entries) {
      final keywords = entry.key.split('|');
      int score = 0;
      for (final kw in keywords) {
        if (q.contains(kw.trim())) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        bestKey = entry.key;
      }
    }

    if (bestScore > 0) return _withLiveWsaCauses(_kb[bestKey]!);

    // Fuzzy fallback — check individual important words
    if (q.contains('sg/') || q.contains('sg 0') || q.contains('guideline')) {
      return _guidelineIndex();
    }
    if (q.contains('what') && q.contains('colour') || q.contains('color') && q.contains('helmet')) {
      return _withLiveWsaCauses(_kb[
          'ppe|personal protective|safety helmet|helmet|hard hat|safety shoes|ear protection|eye protection|gloves|harness']!);
    }

    return _defaultHelp();
  }

  /// Replace the DEFAULT WSA cause list embedded in the const [_kb] with the
  /// admin's current list, so an offline chatbot answer quotes the same
  /// categories the near-miss dropdown offers. A no-op when the admin hasn't
  /// customised them, or when the answer doesn't contain the cause block.
  static String _withLiveWsaCauses(String answer) {
    final live = AdminMasterData.wsaCausesSync;
    const defaults = AdminMasterData.defaultWsaCauses;
    final defaultBlock = '${defaults.join('\n')}\n';
    if (!answer.contains(defaultBlock)) return answer;
    final liveBlock = live.isEmpty
        ? 'No cause categories are configured.\n'
        : '${live.join('\n')}\n';
    return answer.replaceAll(defaultBlock, liveBlock);
  }

  static String _defaultHelp() =>
    'मैं इन विषयों पर जानकारी दे सकता हूँ | I can answer about:\n\n'
    '🔴 Safety regulations: Factories Act 1948, IS 14489, CEA 2023, SMPV Rules 2016\n'
    '🟠 Ministry of Steel guidelines: SG/01 to SG/41 (type "guideline index" for full list)\n'
    '🟡 PPE standards: helmets, harness, footwear, ear/eye protection\n'
    '🟢 Process safety: blast furnace, coke oven, EAF, BOF, rolling mills\n'
    '🔵 Hazardous operations: hot metal, gas handling, confined space, LOTOTO\n'
    '⚡ Emergency response: CO exposure, hot metal fire, electrical shock\n\n'
    'Example questions:\n'
    '• "What is LOTOTO procedure?"\n'
    '• "Gas cylinder colour codes"\n'
    '• "Blast furnace safety rules"\n'
    '• "Confined space entry checklist"\n'
    '• "Incident classification LTI FAC"\n'
    '• "WSA 13 causes"';

  static String _guidelineIndex() =>
    'MINISTRY OF STEEL SAFETY GUIDELINES INDEX:\n\n'
    'SG/01 — Gas cylinder storage, handling & use\n'
    'SG/02 — Working at height\n'
    'SG/03 — Confined space entry\n'
    'SG/04 — Permit to work (all types)\n'
    'SG/05 — Illumination at workplace\n'
    'SG/06 — Lance cutting\n'
    'SG/07 — Gas cutting & welding\n'
    'SG/08 — Arc welding & cutting\n'
    'SG/09 — Equipment & machinery guarding\n'
    'SG/10 — Hydraulic system safety\n'
    'SG/11 — Barricading\n'
    'SG/12 — Demolition of buildings/structures\n'
    'SG/13 — Material handling (manual & mechanised)\n'
    'SG/14 — EOT Crane safety\n'
    'SG/15 — Electrical safety\n'
    'SG/16 — Fire safety\n'
    'SG/17 — Excavation\n'
    'SG/18 — PPE management\n'
    'SG/19 — Conveyor belt operation & maintenance\n'
    'SG/20 — Oxygen & nitrogen gas lines\n'
    'SG/21 — Fuel gas handling (BF gas, COG)\n'
    'SG/22 — Energy isolation (LOTOTO)\n'
    'SG/23 — Safe handling of liquid metal\n'
    'SG/24 — Transportation in steel industry\n'
    'SG/25 — Loco operation\n\n'
    'PROCESS-BASED GUIDELINES (2024):\n'
    'SG/26 — Incident classification & investigation\n'
    'SG/27 — Safety database & proactive data\n'
    'SG/28 — Coke oven safety\n'
    'SG/29 — Asset management safety\n'
    'SG/30 — Blast furnace safety\n'
    'SG/31 — Sinter plant safety\n'
    'SG/32 — DRI plant safety (coal based)\n'
    'SG/33 — DRI plant safety (gas based)\n'
    'SG/34 — Electric arc furnace (EAF) safety\n'
    'SG/35 — Induction furnace safety\n'
    'SG/36 — Semi-automatic rolling & re-rolling\n'
    'SG/37 — Hot rolling mills (automated)\n'
    'SG/38 — Cold rolling mills\n'
    'SG/39 — Steel melting shop (BOF)\n'
    'SG/40 — Pellet plants\n'
    'SG/41 — Contractor safety management\n\n'
    'Ask about any specific guideline for details.';

  // ══════════════════════════════════════════════════════════════════
  //  NEAR MISS TEXT PROCESSING (used by near_miss_tab)
  // ══════════════════════════════════════════════════════════════════
  /// Resolve a WSA cause by its number against the ADMIN's current list, so a
  /// cause the admin renamed comes back with the admin's wording. [fallback] is
  /// the shared default text, used only if the admin has no entry with that
  /// number (e.g. they replaced the 13-cause taxonomy wholesale).
  static String _wsa(int number, String fallback) =>
      AdminMasterData.wsaCauseByNumber(number) ?? fallback;

  static Map<String, String> processText(String text) {
    final q = text.toLowerCase();
    String wsa   = _wsa(7, '7. Human error');
    String root  = 'Momentary lapse in judgement; task pressure; inadequate hazard recognition training';
    String fix   = 'Conduct toolbox talk before resuming work; update Job Safety Analysis (JSA)';
    String title = 'Near Miss / Unsafe Condition Reported';

    if (q.contains('helmet') || q.contains('hard hat') || q.contains('ppe') || q.contains('gloves') || q.contains('harness') || q.contains('shoe')) {
      wsa   = _wsa(3, '3. Improper PPE use');
      root  = 'Insufficient PPE enforcement at bay entry; supervisor gap at shift start; PPE not issued';
      fix   = 'Issue correct PPE per IS 2925/3521/5852 immediately; stop-work until compliant; supervisor sign-off';
      title = 'PPE Violation — Missing Personal Protective Equipment';
    } else if (q.contains('slip') || q.contains('wet') || q.contains('spill') || q.contains('oil') || q.contains('housekeep') || q.contains('5s')) {
      wsa   = _wsa(8, '8. Poor housekeeping');
      root  = 'Housekeeping schedule not followed; drainage blocked; area owner not assigned';
      fix   = 'Clean spillage immediately; wet floor signs; assign area owner; 5S audit';
      title = 'Slip/Trip Hazard — Floor Contamination';
    } else if (q.contains('crane') || q.contains('lifting') || q.contains('load') || q.contains('sling') || q.contains('swl')) {
      wsa   = _wsa(4, '4. Unsafe body positioning');
      root  = 'Exclusion zone not established; banksman not deployed; pre-lift check bypassed';
      fix   = 'Establish exclusion zone; ensure banksman signals (IS 4014); SWL verified; critical lift permit obtained';
      title = 'Crane/Lifting Operation — Unsafe Condition';
    } else if (q.contains('electric') || q.contains('loto') || q.contains('shock') || q.contains('live') || q.contains('panel')) {
      wsa   = _wsa(12, '12. Inadequate isolation');
      root  = 'LOTOTO procedure not followed; energy isolation incomplete; danger notice not displayed';
      fix   = 'Apply LOTOTO immediately; test for dead; display DANGER notice per Indian Electricity Rules 1956, Rule 50; authorised personnel only';
      title = 'Electrical Safety Violation — Inadequate Isolation';
    } else if (q.contains('fall') || q.contains('height') || q.contains('scaffold') || q.contains('ladder') || q.contains('guardrail')) {
      wsa   = _wsa(11, '11. Unauthorized operation');
      root  = 'WAH permit bypassed; no harness issued; anchor points not inspected; 100% tie-off rule violated';
      fix   = 'Stop work; obtain WAH PTW (SG/02); issue IS 3521 harness; inspect anchor (min 15kN)';
      title = 'Working at Height — Fall Risk (FA S32c)';
    } else if (q.contains('gas') || q.contains('fume') || q.contains('co ') || q.contains('carbon mono') || q.contains('bf gas') || q.contains('confined')) {
      wsa   = _wsa(2, '2. Lack of hazard awareness');
      root  = 'Gas detector not used; atmosphere not tested before entry; confined space PTW not obtained';
      fix   = 'Evacuate area; atmosphere test by gas detector; purge + ventilate; re-entry only with PTW + gas clearance';
      title = 'Gas Hazard — Toxic/Flammable Exposure Risk';
    } else if (q.contains('fire') || q.contains('hot work') || q.contains('weld') || q.contains('grind') || q.contains('spark')) {
      wsa   = _wsa(1, '1. Failure to follow procedure');
      root  = 'Hot work permit not obtained; fire watch not deployed; combustibles not cleared within 10m';
      fix   = 'Stop hot work; obtain hot work PTW (SG/07/SG/08); deploy fire watch; 9kg DCP at site';
      title = 'Hot Work Hazard — Fire Risk';
    } else if (q.contains('liquid metal') || q.contains('hot metal') || q.contains('slag') || q.contains('molten') || q.contains('ladle')) {
      wsa   = _wsa(2, '2. Lack of hazard awareness');
      root  = 'Ladle not preheated; moisture present; personnel in hazard zone during tap';
      fix   = 'Preheat ladle to min 800°C; clear all persons >15m; aluminised PPE mandatory (SG/23)';
      title = 'Hot Metal/Slag — Burn/Explosion Risk';
    } else if (q.contains('machin') || q.contains('guard') || q.contains('rotat') || q.contains('conveyor') || q.contains('belt')) {
      wsa   = _wsa(5, '5. Equipment failure');
      root  = 'Machine guard removed or damaged; LOTOTO not applied; guard interlock bypassed';
      fix   = 'Stop machine via LOTOTO; reinstall/repair guard; test interlock before restart (SG/09)';
      title = 'Machinery Guarding — Rotating Part Exposed';
    } else if (q.contains('supervisor') || q.contains('unsupervised') || q.contains('alone')) {
      wsa   = _wsa(9, '9. Lack of supervision');
      root  = 'Supervisor absent during critical operation; contractor without site supervisor; span of control exceeded';
      fix   = 'Designate qualified supervisor immediately; 1 supervisor per 10 workers (SG/41)';
      title = 'Supervision Gap During Critical Operation';
    } else if (q.contains('cylinder') || q.contains('gas bottle') || q.contains('oxygen') || q.contains('acetylene')) {
      wsa   = _wsa(8, '8. Poor housekeeping');
      root  = 'Cylinders not chained; O2 and flammable stored <6m apart; valve cap missing; SMPV Rules not followed';
      fix   = 'Chain cylinders upright; separate O2 and flammable >6m (SMPV Rule 14); fit valve caps; check ISI mark';
      title = 'Gas Cylinder — Storage Violation (SMPV Rules 2016)';
    } else if (q.contains('contactor') || q.contains('contactor') || q.contains('contractor')) {
      wsa   = _wsa(1, '1. Failure to follow procedure');
      root  = 'Contractor worker not inducted; working without PTW; no safety supervisor assigned';
      fix   = 'Stop work; complete safety induction; obtain PTW; assign supervisor (SG/41)';
      title = 'Contractor Safety Violation';
    }

    return {
      'title': title,
      'wsa':   wsa,
      'root':  root,
      'fix':   fix,
    };
  }

  // ══════════════════════════════════════════════════════════════════
  //  OFFLINE IMAGE FALLBACK (used by GeminiVision when AI unavailable)
  //  NOTE: This returns example scenarios for demonstration purposes.
  //  For true offline AI analysis, integrate TensorFlow Lite model.
  // ══════════════════════════════════════════════════════════════════
  static Future<Map<String, dynamic>> analyseImage(File imageFile) async {
    final scenarios = [
      {
        'riskScore': 72, 'severity': 'HIGH',
        'hazardType': 'PPE Non-Compliance',
        'summary': '⚠️ OFFLINE MODE: Showing example scenario. This is NOT analysis of your photo. AI requires internet connection. Example: Critical PPE violations - Worker without IS 2925 helmet in crane zone.',
        'confidence': 0,  // Set to 0 to indicate this is example data
        'hazards': [
          {'name': 'Missing Safety Helmet', 'severity': 'CRITICAL',
           'desc': 'Worker without ISI-marked helmet — FA 1948 S35, IS 2925:1984',
           'ref': 'FA 1948 S35 · IS 2925:1984 · SG/18'},
          {'name': 'Slip Hazard — Oil Spill', 'severity': 'MEDIUM',
           'desc': 'Liquid spillage on walkway — FA 1948 S32, IS 14489 Cl.9',
           'ref': 'FA 1948 S32 · IS 14489:2018 Cl.9 · SG/18'},
        ],
        'rules': ['FA 1948 S35 — PPE mandatory in hazardous zones',
                  'IS 2925:1984 — Safety helmets standard',
                  'IS 14489:2018 Cl.9 — Housekeeping in steel plants'],
        'corrective': ['Stop work until PPE compliance achieved',
                       'Issue IS 2925 helmet from nearest PPE station',
                       'Clean spillage; place wet floor warning signs'],
        'preventive': ['Daily PPE check at bay entrance',
                       'Toolbox talk on PPE before each shift',
                       'Monthly PPE audit with photographic record (SG/18)'],
        'wsa': ['3. Improper PPE use', '8. Poor housekeeping'],
      },
      {
        'riskScore': 88, 'severity': 'CRITICAL',
        'hazardType': 'Working at Height — Fall Risk',
        'summary': '⚠️ OFFLINE MODE: Showing example scenario. This is NOT analysis of your photo. AI requires internet connection. Example: Worker >1.8m without harness - FA 1948 S32 violation.',
        'confidence': 0,  // Set to 0 to indicate this is example data
        'hazards': [
          {'name': 'No Fall Arrest at Height', 'severity': 'CRITICAL',
           'desc': 'Worker >1.8m without IS 3521 harness — FA 1948 S32',
           'ref': 'FA 1948 S32 · IS 3521:1999 · IS 4912:1978 · SG/02'},
          {'name': 'Unguarded Edge', 'severity': 'HIGH',
           'desc': 'Open edge — no guardrail or toe board — FA S33, IS 4912',
           'ref': 'FA 1948 S33 · IS 4912:1978 · SG/02'},
        ],
        'rules': ['FA 1948 S32 — Fall protection at height (NOT S36)',
                  'IS 3521:1999 — Full body harness; anchor min 15kN',
                  'SG/02 — WAH permit mandatory; 100% tie-off rule'],
        'corrective': ['Immediate stop-work; evacuate worker from height',
                       'Issue IS 3521 harness with double lanyard',
                       'Inspect anchor points (min 15kN) before resuming',
                       'Obtain WAH permit per SG/04'],
        'preventive': ['WAH training every 6 months',
                       'PTW enforcement for all height work',
                       'Install permanent anchor points per IS 4912 (SG/02)'],
        'wsa': ['1. Failure to follow procedure', '11. Unauthorized operation'],
      },
      {
        'riskScore': 82, 'severity': 'CRITICAL',
        'hazardType': 'Gas Cylinder — SMPV Violation',
        'summary': '⚠️ OFFLINE MODE: Showing example scenario. This is NOT analysis of your photo. AI requires internet connection. Example: Gas cylinders unsecured, O2/acetylene <6m apart - SMPV violation.',
        'confidence': 0,  // Set to 0 to indicate this is example data
        'hazards': [
          {'name': 'Cylinders Not Chained', 'severity': 'CRITICAL',
           'desc': 'Cylinders not chained upright — SMPV Rule 10(1), IS 15222',
           'ref': 'SMPV Rules 2016 Rule 10(1) · IS 15222 · SG/01'},
          {'name': 'O2-Flammable Proximity', 'severity': 'CRITICAL',
           'desc': 'O2 and acetylene within 6m — SMPV Rule 14 Table-3',
           'ref': 'SMPV Rules 2016 Rule 14 Table-3 · FA 1948 S37 · SG/01'},
          {'name': 'Valve Cap Missing', 'severity': 'HIGH',
           'desc': 'Valve unprotected — IS 8198, SMPV Rule 10(2)',
           'ref': 'SMPV Rules 2016 Rule 10(2) · IS 8198 · SG/01'},
        ],
        'rules': ['SMPV Rules 2016 Rule 10 — No ignition near cylinders',
                  'SMPV Rule 14 Table-3 — O2 + flammable min 6m separation',
                  'SG/01 — Gas cylinder storage and handling'],
        'corrective': ['Chain all cylinders upright to wall or post',
                       'Separate O2 and flammable >6m or install fire wall',
                       'Fit valve protection caps on all cylinders',
                       'Verify ISI mark and last test date on each cylinder'],
        'preventive': ['Monthly gas cylinder audit (SG/01)',
                       'Storage area redesign to maintain separation distances',
                       'Annual SMPV hydraulic testing compliance check'],
        'wsa': ['8. Poor housekeeping', '2. Lack of hazard awareness'],
      },
    ];
    final idx = DateTime.now().second % scenarios.length;
    final result = Map<String, dynamic>.from(scenarios[idx]);
    result['_source'] = 'offline_demo';
    result['_isOffline'] = true;
    result['_note'] = 'This is an example scenario shown in offline mode. For real AI analysis of your photo, please connect to the internet.';
    return result;
  }

  // ══════════════════════════════════════════════════════════════════
  //  DEMO ANALYSIS (used when no API key / offline UI testing)
  // ══════════════════════════════════════════════════════════════════
  static Map<String, dynamic> demoAnalysis() => {
    'overallRisk': 'HIGH', 'riskScore': 72, 'confidence': 0,
    'summary': 'AI analysis not available (no API key or offline). '
        'This is a demo response. Configure Gemini API key for real AI-powered hazard analysis.',
    'hazards': [{
      'name': 'Demo Hazard',
      'description': 'This is a placeholder. Real analysis requires Gemini API + internet.',
      'severity': 'MEDIUM', 'type': 'Unsafe condition',
      'regulation': 'FA 1948 S35 — PPE compliance',
      'correctiveAction': 'Configure Gemini API key for real AI analysis',
    }],
    'preventive': ['Add Gemini API key', 'Ensure internet connection', 'Retry with real photo'],
    '_source': 'demo_fallback',
  };
}
