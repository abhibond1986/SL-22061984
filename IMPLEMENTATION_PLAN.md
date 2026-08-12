# Safety Lens Enhancement - Implementation Plan

**Date**: August 12, 2026  
**Project**: Safety Lens (SAIL)  
**Objective**: Add department analytics, error logging, and plant-specific dashboards

---

## 🎯 Overview

Based on the comprehensive audit, we need to implement **4 major enhancements**:

1. 🔴 **Error Logging System** (Critical - 2-3 days)
2. 🟡 **Department-Wise Analytics** (High - 1-2 days)
3. 🟡 **Plant-Specific User Dashboard** (High - 1 day)
4. 🟢 **Enhanced AI Context** (Medium - 1 day)

**Total Estimated Time**: 5-7 development days

---

## 📋 Phase 1: Error Logging (Days 1-3) 🔴 CRITICAL

### Goal
Track all AI analysis failures so admins can diagnose issues and improve system reliability.

### What We'll Build

#### 1. Error Log Service
**New File**: `lib/services/error_log_service.dart`

```dart
class ErrorLogEntry {
  String id;              // UUID
  DateTime timestamp;
  String errorType;       // 'AI_ANALYSIS_FAILED', 'API_TIMEOUT', etc.
  String errorMessage;
  String stackTrace;
  String userId;
  String plant;
  String department;
  String apiEndpoint;     // 'OpenRouter', 'Gemini', 'Groq'
  String appVersion;
  String platform;
}

class ErrorLogService {
  static Future<void> logError(ErrorLogEntry entry);
  static Future<List<ErrorLogEntry>> getErrors({filters});
  static Future<Map<String, int>> getErrorStats();
}
```

#### 2. Integration Points
- **AI Scan Tab**: Wrap image analysis in try-catch
- **Chatbot**: Wrap API calls in try-catch
- **Sync Service**: Wrap backend sync in try-catch

```dart
// Example integration
try {
  final result = await _analyzeImage(imageBase64);
  // ... process
} catch (e, stackTrace) {
  await ErrorLogService.logError(ErrorLogEntry(
    timestamp: DateTime.now(),
    errorType: 'AI_ANALYSIS_FAILED',
    errorMessage: e.toString(),
    userId: _user['pno'],
    plant: _user['plant'],
    apiEndpoint: _selectedAiProvider,
  ));
  // Show user error
}
```

#### 3. Admin Panel UI
**File to Modify**: `admin/index.html`

Add new tab:
```html
<button class="anb" onclick="switchTab('errors')">⚠️ Error Logs</button>

<div id="errors-tab">
  <!-- Summary Cards -->
  <div class="stats">
    <div class="card">Errors (24h): <span id="errors-24h">0</span></div>
    <div class="card">AI Failures: <span id="ai-failures">0</span></div>
    <div class="card">Success Rate: <span id="success-rate">0%</span></div>
  </div>
  
  <!-- Filters -->
  <select id="error-type">
    <option>All Types</option>
    <option>AI Analysis Failed</option>
    <option>API Timeout</option>
    <option>Parse Error</option>
  </select>
  
  <select id="error-timerange">
    <option>Today</option>
    <option>This Week</option>
    <option>This Month</option>
  </select>
  
  <!-- Error Table -->
  <table id="error-table">
    <thead>
      <tr>
        <th>Time</th>
        <th>Type</th>
        <th>Message</th>
        <th>User</th>
        <th>Plant</th>
        <th>API</th>
        <th>Details</th>
      </tr>
    </thead>
    <tbody id="error-rows"></tbody>
  </table>
  
  <button onclick="exportErrors()">Export CSV</button>
</div>
```

#### 4. Backend API
**Apps Script Endpoint**: Add `pushErrorLog` function

```javascript
function pushErrorLog(errorData) {
  const sheet = getSheet('ErrorLogs');
  sheet.appendRow([
    errorData.timestamp,
    errorData.errorType,
    errorData.errorMessage,
    errorData.userId,
    errorData.plant,
    errorData.department,
    errorData.apiEndpoint,
    errorData.appVersion,
    errorData.platform,
  ]);
  return {success: true};
}
```

### Deliverables
- ✅ ErrorLogService class with logging methods
- ✅ Integration in AI Scan, Chatbot, Sync
- ✅ Admin panel Error Logs tab
- ✅ Backend API endpoint
- ✅ LocalDB schema update for error storage
- ✅ Export to CSV functionality

### Success Criteria
- [ ] All AI failures are logged
- [ ] Admin can view errors by type/date/plant
- [ ] Error stats displayed (24h count, failure rate)
- [ ] Errors synced to backend
- [ ] CSV export working

---

## 📊 Phase 2: Department-Wise Analytics (Days 4-5) 🟡 HIGH

### Goal
Analyze incidents by department to identify high-risk areas and target interventions.

### What We'll Build

#### 1. Department Analytics Charts
**File to Modify**: `lib/screens/analytics/data_analysis_tab.dart`

Add new charts:
1. **Incidents by Department** (Pie Chart)
2. **Department Risk Profile** (Bar Chart showing total vs critical)
3. **Department Trends** (Line chart over time)

```dart
Widget _buildDepartmentAnalysis(SL sl) {
  // Group incidents by department
  Map<String, List<Map>> byDept = {};
  for (var inc in _filteredIncidents) {
    String dept = inc['dept'] ?? 'Unknown';
    byDept.putIfAbsent(dept, () => []);
    byDept[dept].add(inc);
  }
  
  // Calculate metrics
  Map<String, int> deptCounts = {};
  Map<String, int> deptCritical = {};
  
  byDept.forEach((dept, incidents) {
    deptCounts[dept] = incidents.length;
    deptCritical[dept] = incidents.where((i) => 
      i['severity'] == 'CRITICAL').length;
  });
  
  return Column(
    children: [
      // Pie Chart
      SizedBox(
        height: 300,
        child: PieChart(
          PieChartData(
            sections: deptCounts.entries.map((e) =>
              PieChartSectionData(
                value: e.value.toDouble(),
                title: '${e.key}\n${e.value}',
                color: _getDepartmentColor(e.key),
              )).toList(),
          ),
        ),
      ),
      
      // Bar Chart
      SizedBox(
        height: 300,
        child: BarChart(
          BarChartData(
            barGroups: deptCounts.keys.toList().asMap().entries.map((entry) {
              int index = entry.key;
              String dept = entry.value;
              return BarChartGroupData(
                x: index,
                barRods: [
                  BarChartRodData(
                    toY: deptCounts[dept].toDouble(),
                    color: AppColors.accent,
                    width: 20,
                  ),
                  BarChartRodData(
                    toY: deptCritical[dept].toDouble(),
                    color: AppColors.crit,
                    width: 20,
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    ],
  );
}
```

#### 2. Department Filter
**File to Modify**: `lib/screens/analytics/incident_log_tab.dart`

Add department dropdown:
```dart
String _departmentFilter = 'All';
List<String> _departments = [];

@override
void initState() {
  super.initState();
  _loadDepartments();
}

Future<void> _loadDepartments() async {
  final depts = await AdminMasterData.getDepartments();
  setState(() => _departments = ['All', ...depts]);
}

// In _filtered getter
List<Map<String, dynamic>> get _filtered {
  return _all.where((inc) {
    // ... existing filters
    if (_departmentFilter != 'All') {
      if (inc['dept']?.toString() != _departmentFilter) return false;
    }
    return true;
  }).toList();
}

// In UI
DropdownButton<String>(
  value: _departmentFilter,
  items: _departments.map((d) => DropdownMenuItem(
    value: d, child: Text(d))).toList(),
  onChanged: (v) => setState(() => _departmentFilter = v!),
)
```

### Deliverables
- ✅ Department pie chart showing distribution
- ✅ Department bar chart (total vs critical)
- ✅ Department filter in incident log
- ✅ Department risk matrix (if time permits)
- ✅ Export functionality

### Success Criteria
- [ ] Charts display correctly
- [ ] Department filter works
- [ ] Can identify high-risk departments visually
- [ ] Charts update when filters change
- [ ] Responsive on mobile

---

## 🏭 Phase 3: Plant-Specific Dashboard (Day 6) 🟡 HIGH

### Goal
Give each user a summary of their plant's safety performance on the home dashboard.

### What We'll Build

#### Plant Summary Widget
**File to Modify**: `lib/screens/dashboard_tab.dart`

```dart
Widget _buildPlantSummary(SL sl) {
  final userPlant = _user['plant'] ?? 'Unknown';
  
  // Filter for user's plant
  final plantIncidents = _allIncidents.where((inc) => 
    inc['plant'] == userPlant).toList();
  
  final total = plantIncidents.length;
  final critical = plantIncidents.where((i) => 
    i['severity'] == 'CRITICAL').length;
  final open = plantIncidents.where((i) => 
    i['status'] == 'OPEN').length;
  
  // Last 30 days
  final last30Days = DateTime.now().subtract(Duration(days: 30));
  final recent = plantIncidents.where((inc) {
    try {
      return DateTime.parse(inc['date']).isAfter(last30Days);
    } catch (_) {
      return false;
    }
  }).length;
  
  return GlassCard(
    padding: EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(Icons.factory_outlined, color: AppColors.accent, size: 24),
            SizedBox(width: 8),
            Text('$userPlant Safety Summary',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
        SizedBox(height: 16),
        
        // Metrics
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _metricTile('Total', total, Icons.warning_amber, AppColors.amber),
            _metricTile('Critical', critical, Icons.error, AppColors.crit),
            _metricTile('Open', open, Icons.pending, AppColors.cyan),
          ],
        ),
        
        SizedBox(height: 16),
        
        // Trend
        Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: recent > (total * 0.5)
              ? AppColors.red.withOpacity(0.1)
              : AppColors.green.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                recent > (total * 0.5) 
                  ? Icons.trending_up 
                  : Icons.trending_down,
                color: recent > (total * 0.5) 
                  ? AppColors.red 
                  : AppColors.green,
              ),
              SizedBox(width: 8),
              Text('$recent incidents in last 30 days'),
            ],
          ),
        ),
        
        SizedBox(height: 12),
        
        // Top Department
        _buildTopDepartment(plantIncidents, sl),
      ],
    ),
  );
}

Widget _metricTile(String label, int value, IconData icon, Color color) {
  return Column(
    children: [
      Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: color, size: 28),
      ),
      SizedBox(height: 4),
      Text(value.toString(),
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
      Text(label, style: TextStyle(fontSize: 11, color: sl.text4)),
    ],
  );
}

Widget _buildTopDepartment(List<Map> incidents, SL sl) {
  Map<String, int> deptCounts = {};
  for (var inc in incidents) {
    String dept = inc['dept'] ?? 'Unknown';
    deptCounts[dept] = (deptCounts[dept] ?? 0) + 1;
  }
  
  if (deptCounts.isEmpty) return SizedBox();
  
  var sorted = deptCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  
  final topDept = sorted.first.key;
  final topCount = sorted.first.value;
  
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Department Needing Most Attention:',
        style: TextStyle(fontSize: 11, color: sl.text4)),
      SizedBox(height: 4),
      Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.accent.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.engineering, size: 14, color: AppColors.accent),
            SizedBox(width: 6),
            Text('$topDept ($topCount incidents)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    ],
  );
}
```

### Deliverables
- ✅ Plant summary card on dashboard
- ✅ Total/Critical/Open metrics
- ✅ 30-day trend indicator
- ✅ Top department highlight
- ✅ Responsive design

### Success Criteria
- [ ] Plant summary shows correct data
- [ ] Metrics update in real-time
- [ ] Trend indicator reflects recent activity
- [ ] Top department identified correctly
- [ ] Works for all plants

---

## 🤖 Phase 4: Enhanced AI Context (Day 7) 🟢 MEDIUM

### Goal
Make AI chatbot and hazard analysis context-aware (plant, department).

### What We'll Build

#### 1. Chatbot Enhancement
**File to Modify**: `lib/screens/chat_tab.dart`

```dart
Future<void> _send(String msg) async {
  // ... existing code
  
  // Build context-aware prompt
  final userPlant = _user['plant'] ?? 'Unknown';
  final userDept = _user['department'] ?? 'Unknown';
  
  final contextPrompt = '''
$_systemPrompt

CURRENT USER CONTEXT:
- Plant: $userPlant
- Department: $userDept
- Role: ${_user['designation'] ?? 'User'}

INSTRUCTIONS:
1. Prioritize hazards specific to $userDept
2. Reference $userPlant procedures when available
3. Provide department-appropriate PPE recommendations
4. Cite regulations relevant to $userDept operations

USER QUERY: $msg
''';
  
  // Send to AI with context
  // ... rest of existing code
}
```

#### 2. Hazard Analysis Enhancement
**File to Modify**: `lib/screens/ai_scan_tab.dart`

```dart
String _getDepartmentContext(String? dept) {
  final hazardMap = {
    'Blast Furnace': '''
    Common hazards: CO gas (25-28%), hot metal splash, skull formation,
    tuyere burn-through, burden slip, gas leaks, furnace breakout.
    Key checks: CO monitors, SCBA availability, PTW compliance,
    exclusion zones, emergency exits clear.
    ''',
    
    'Steel Melting Shop': '''
    Common hazards: molten metal spills, ladle explosions, arc flash,
    fumes (Fe2O3, MnO), noise >100dB, crane operations.
    Key checks: ladle preheating, tapping zone clear, arc flash PPE,
    ventilation, crane signals.
    ''',
    
    'Coke Ovens': '''
    Common hazards: CO poisoning, H2S exposure, coal gas leaks,
    hot coke burns, oven door leaks, pushing operations.
    Key checks: gas monitors, wind direction, escape routes,
    water spray working, door seals.
    ''',
    
    'Rolling Mill': '''
    Common hazards: pinch points, hot material burns, roll bite,
    scale splash, noise, moving conveyors, crane operations.
    Key checks: guards in place, pinch point clearance, LOTO on maintenance,
    scale pits covered, emergency stops functional.
    ''',
    
    'Power Plant': '''
    Common hazards: electrical flash, steam burns, boiler explosion,
    falls from height, confined spaces, chemical exposure.
    Key checks: electrical isolation, steam line integrity,
    boiler pressure, fall protection, gas-free certificates.
    ''',
    
    // Add more departments...
  };
  
  return hazardMap[dept] ?? 'general industrial hazards';
}

Future<void> _analyzeImage() async {
  final userDept = _user['department'] ?? 'Unknown';
  
  final enhancedPrompt = '''
Analyze this image for safety hazards in a steel plant.

CONTEXT:
- Location: ${_user['plant']}
- Department: $userDept
- Common hazards in $userDept:
  ${_getDepartmentContext(userDept)}

Focus on hazards typically found in $userDept operations.

[Standard hazard analysis instructions...]
''';
  
  // Send to AI
  // ... rest of existing code
}
```

### Deliverables
- ✅ Chatbot uses user plant/department context
- ✅ Hazard analysis checks department-specific risks
- ✅ Department hazard library created
- ✅ AI responses more relevant to user context

### Success Criteria
- [ ] Chatbot mentions user's department in responses
- [ ] Hazard analysis prioritizes department-specific hazards
- [ ] Responses feel more personalized
- [ ] Accuracy improves for department-specific queries

---

## 📁 File Checklist

### New Files to Create
- [ ] `lib/services/error_log_service.dart`
- [ ] `lib/models/error_log_entry.dart`
- [ ] Backend: Apps Script `pushErrorLog()` function

### Files to Modify
- [ ] `lib/screens/ai_scan_tab.dart` (error logging + department context)
- [ ] `lib/screens/chat_tab.dart` (error logging + user context)
- [ ] `lib/screens/analytics/data_analysis_tab.dart` (department charts)
- [ ] `lib/screens/analytics/incident_log_tab.dart` (department filter)
- [ ] `lib/screens/dashboard_tab.dart` (plant summary)
- [ ] `lib/services/local_db.dart` (error log storage)
- [ ] `lib/services/sync_service.dart` (error log sync)
- [ ] `admin/index.html` (error logs tab)
- [ ] `apps_script_v14.js` (error log endpoint)

---

## 🧪 Testing Checklist

### Error Logging
- [ ] AI analysis failure logged correctly
- [ ] Chatbot API failure logged
- [ ] Backend sync failure logged
- [ ] Admin can view all error logs
- [ ] Filters work (type, date, plant)
- [ ] CSV export downloads correctly
- [ ] Error stats display accurately

### Department Analytics
- [ ] Department pie chart displays
- [ ] Department bar chart shows total vs critical
- [ ] Department filter in log works
- [ ] Charts update when filters change
- [ ] All departments included
- [ ] "Unknown" department handled gracefully

### Plant Dashboard
- [ ] Plant summary shows correct metrics
- [ ] Total/Critical/Open counts accurate
- [ ] 30-day trend calculates correctly
- [ ] Top department identified correctly
- [ ] Works for all SAIL plants
- [ ] Handles missing data gracefully

### Enhanced AI Context
- [ ] Chatbot mentions user department
- [ ] Hazard analysis checks dept-specific hazards
- [ ] Responses more relevant
- [ ] Works offline (LocalAI)
- [ ] Works online (OpenRouter/Gemini)

---

## 📊 Success Metrics

### Error Logging
- **Target**: 100% of AI failures logged
- **Measure**: Compare error log count to failed API responses
- **KPI**: Admin visibility into all failures

### Department Analytics
- **Target**: Identify top 3 high-risk departments per plant
- **Measure**: Department chart shows clear distribution
- **KPI**: Actionable insights for safety teams

### Plant Dashboard
- **Target**: 80%+ user engagement with plant summary
- **Measure**: Track dashboard views
- **KPI**: Users check their plant status daily

### AI Context
- **Target**: 30% improvement in response relevance
- **Measure**: User feedback / satisfaction ratings
- **KPI**: Fewer "not applicable" responses

---

## 🚀 Deployment Plan

### Week 1: Development
- Days 1-3: Error logging
- Days 4-5: Department analytics
- Day 6: Plant dashboard
- Day 7: AI context

### Week 2: Testing
- Internal testing by dev team
- Beta testing with 1-2 pilot plants
- Bug fixes and refinements

### Week 3: Rollout
- Deploy to all plants
- Monitor error logs
- Gather user feedback
- Iterate on department charts

### Week 4: Optimization
- Analyze error patterns
- Optimize slow queries
- Enhance visualizations
- Add requested features

---

## 💰 Resource Requirements

### Development
- 1 Flutter developer (7 days)
- 1 Backend developer (2 days for Apps Script endpoints)
- 1 Designer (1 day for UI/UX review)

### Testing
- 2 QA testers (2 days)
- 2 pilot plant users (1 week)

### Documentation
- 1 technical writer (2 days)

---

## 📞 Support & Maintenance

### Monitoring
- Daily check of error logs
- Weekly review of failure rates
- Monthly department analytics review

### Alerts
- >10 errors in 24 hours → notify admin
- >50% failure rate → escalate to dev team
- Critical errors → immediate notification

### Maintenance
- Quarterly review of department list
- Monthly knowledge base updates
- Continuous AI prompt optimization

---

## ✅ Final Checklist

### Before Starting
- [ ] Read full audit report
- [ ] Approve implementation plan
- [ ] Allocate development resources
- [ ] Set up development environment
- [ ] Create feature branch in Git

### During Development
- [ ] Daily standup for progress updates
- [ ] Code review for each feature
- [ ] Unit tests for new services
- [ ] Integration tests for API calls
- [ ] Document all changes

### Before Deployment
- [ ] All tests passing
- [ ] Beta testing completed
- [ ] Documentation updated
- [ ] Admin training materials ready
- [ ] Rollback plan prepared

### After Deployment
- [ ] Monitor error logs for 48 hours
- [ ] Gather user feedback
- [ ] Track success metrics
- [ ] Plan next iteration

---

**Plan Status**: ✅ Ready for Review  
**Estimated Completion**: 2-3 weeks from start  
**Risk Level**: LOW (well-defined scope, clear requirements)  
**Impact**: HIGH (significant improvements to system visibility and insights)
