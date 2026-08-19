/**
 * ═══════════════════════════════════════════════════════════════════════
 * SAIL SAFETY LENS — ALERT SYSTEM (Apps Script Backend)
 * ═══════════════════════════════════════════════════════════════════════
 *
 * This script handles real-time SMS and Email notifications when:
 *   • AI Scan detects CRITICAL/HIGH hazards in a department
 *   • Near Miss is reported
 *   • Critical/High incident is logged
 *   • Daily threshold is exceeded
 *   • HIGH/CRITICAL incidents remain open > 7 days
 *
 * DEPLOYMENT:
 *   1. Open your existing Apps Script project (same one used for sync)
 *   2. Create a new file: AlertSystem.gs
 *   3. Paste this entire code
 *   4. Set Script Properties (File → Project properties → Script properties):
 *      - SMS_API_KEY: Your Fast2SMS or MSG91 API key
 *      - SMS_PROVIDER: 'fast2sms' or 'msg91' or 'textlocal'
 *      - SMS_SENDER_ID: 'SAILSF' (6-char sender ID registered with DLT)
 *      - ALERT_ADMIN_EMAIL: fallback admin email if no recipients configured
 *   5. Re-deploy the web app (Deploy → New deployment → Web app)
 *
 * SHEETS USED:
 *   - 'AlertRules' — synced alert rules from app
 *   - 'AlertLog'  — delivery log (timestamp, rule, recipients, status)
 *   - 'Incidents' — existing incident data (for threshold/stale checks)
 *
 * ACTIONS HANDLED:
 *   - syncAlertRules: Receive and store alert rules from app
 *   - fireAlert: Fire a specific alert rule immediately
 *   - evaluateAndAlert: Evaluate all rules against new data and fire matching ones
 *   - getAlertHistory: Return recent alert delivery log
 *
 * SMS PROVIDERS SUPPORTED:
 *   - Fast2SMS (India, cheapest, ₹0.20/SMS) — https://www.fast2sms.com
 *   - MSG91 (India, enterprise) — https://msg91.com
 *   - Textlocal (India/UK) — https://www.textlocal.in
 *
 * @author SAIL Safety Lens Team
 * @version 35.0
 */

// ═══════════════════════════════════════════════════════════════════════
// CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════

/**
 * Get configuration from Script Properties
 */
function getAlertConfig_() {
  const props = PropertiesService.getScriptProperties();
  return {
    smsApiKey: props.getProperty('SMS_API_KEY') || '',
    smsProvider: props.getProperty('SMS_PROVIDER') || 'fast2sms',
    smsSenderId: props.getProperty('SMS_SENDER_ID') || 'SAILSF',
    adminEmail: props.getProperty('ALERT_ADMIN_EMAIL') || '',
    msg91TemplateId: props.getProperty('MSG91_TEMPLATE_ID') || '',
    msg91AuthKey: props.getProperty('MSG91_AUTH_KEY') || '',
    textlocalApiKey: props.getProperty('TEXTLOCAL_API_KEY') || '',
    textlocalSender: props.getProperty('TEXTLOCAL_SENDER') || 'SAILSF',
  };
}

// ═══════════════════════════════════════════════════════════════════════
// MAIN ACTION ROUTER — Add these cases to your existing doPost()
// ═══════════════════════════════════════════════════════════════════════

/**
 * Handle alert-related actions.
 * Call this from your existing doPost() function:
 *
 *   function doPost(e) {
 *     const data = JSON.parse(e.postData.contents);
 *     const action = data.action;
 *
 *     // ... your existing actions ...
 *
 *     // Alert actions
 *     if (action === 'syncAlertRules') return handleSyncAlertRules_(data);
 *     if (action === 'fireAlert') return handleFireAlert_(data);
 *     if (action === 'evaluateAndAlert') return handleEvaluateAndAlert_(data);
 *     if (action === 'getAlertHistory') return handleGetAlertHistory_(data);
 *   }
 */

function handleSyncAlertRules_(data) {
  try {
    const rules = data.rules || [];
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let sheet = ss.getSheetByName('AlertRules');

    // Create sheet if it doesn't exist
    if (!sheet) {
      sheet = ss.insertSheet('AlertRules');
      sheet.getRange(1, 1, 1, 10).setValues([[
        'id', 'name', 'trigger', 'threshold', 'plant', 'department',
        'recipients', 'channel', 'enabled', 'updatedAt'
      ]]);
      sheet.getRange(1, 1, 1, 10).setFontWeight('bold');
      sheet.setFrozenRows(1);
    }

    // Clear existing rules and write fresh
    if (sheet.getLastRow() > 1) {
      sheet.getRange(2, 1, sheet.getLastRow() - 1, 10).clearContent();
    }

    if (rules.length > 0) {
      const rows = rules.map(r => [
        r.id || '',
        r.name || '',
        r.trigger || '',
        r.threshold || 0,
        r.plant || '',
        r.department || '',
        JSON.stringify(r.recipients || []),
        r.channel || 'email',
        r.enabled === true ? 'TRUE' : 'FALSE',
        new Date().toISOString(),
      ]);
      sheet.getRange(2, 1, rows.length, 10).setValues(rows);
    }

    return ContentService.createTextOutput(JSON.stringify({
      ok: true,
      message: `${rules.length} alert rules synced`,
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (e) {
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: e.toString(),
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

function handleFireAlert_(data) {
  try {
    const rule = data.rule || {};
    const reason = data.reason || '';
    const incidents = data.incidents || [];
    const scanData = data.scanData || null;
    const nearMissData = data.nearMissData || null;
    const timestamp = data.timestamp || new Date().toISOString();

    const recipients = rule.recipients || [];
    const channel = rule.channel || 'email';

    if (recipients.length === 0) {
      // Use admin fallback
      const config = getAlertConfig_();
      if (config.adminEmail) {
        recipients.push(config.adminEmail);
      } else {
        logAlert_('NO_RECIPIENTS', rule, reason, 'SKIPPED — no recipients configured');
        return ContentService.createTextOutput(JSON.stringify({
          ok: false,
          error: 'No recipients configured for this rule',
        })).setMimeType(ContentService.MimeType.JSON);
      }
    }

    // Build alert message
    const message = buildAlertMessage_(rule, reason, incidents, scanData, nearMissData);
    const subject = buildAlertSubject_(rule, reason);

    let emailSent = false;
    let smsSent = false;

    // Send Email
    if (channel === 'email' || channel === 'both') {
      const emails = recipients.filter(r => r.includes('@'));
      if (emails.length > 0) {
        emailSent = sendEmail_(emails, subject, message);
      }
    }

    // Send SMS
    if (channel === 'sms' || channel === 'both') {
      const phones = recipients.filter(r => !r.includes('@') && r.length >= 10);
      if (phones.length > 0) {
        const smsText = buildSmsText_(rule, reason, scanData, nearMissData);
        smsSent = sendSms_(phones, smsText);
      }
    }

    // Log the alert
    const status = (emailSent || smsSent) ? 'DELIVERED' : 'FAILED';
    logAlert_(recipients.join(', '), rule, reason, status);

    return ContentService.createTextOutput(JSON.stringify({
      ok: emailSent || smsSent,
      emailSent: emailSent,
      smsSent: smsSent,
      recipients: recipients.length,
      timestamp: timestamp,
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (e) {
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: e.toString(),
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

function handleEvaluateAndAlert_(data) {
  try {
    const type = data.type || 'incident'; // 'ai_scan' | 'near_miss' | 'incident'
    const incData = data.data || {};
    const timestamp = data.timestamp || new Date().toISOString();

    // Load rules from sheet
    const rules = loadAlertRules_();
    if (rules.length === 0) {
      return ContentService.createTextOutput(JSON.stringify({
        ok: true,
        message: 'No alert rules configured',
        alertsFired: 0,
      })).setMimeType(ContentService.MimeType.JSON);
    }

    // Evaluate which rules should fire
    const firingRules = evaluateRules_(rules, type, incData);

    if (firingRules.length === 0) {
      return ContentService.createTextOutput(JSON.stringify({
        ok: true,
        message: 'No rules matched',
        alertsFired: 0,
      })).setMimeType(ContentService.MimeType.JSON);
    }

    // Fire each matching rule
    let successCount = 0;
    for (const rule of firingRules) {
      const result = fireRule_(rule, incData, type);
      if (result) successCount++;
    }

    return ContentService.createTextOutput(JSON.stringify({
      ok: true,
      message: `${successCount}/${firingRules.length} alerts sent`,
      alertsFired: successCount,
      rulesMatched: firingRules.length,
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (e) {
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: e.toString(),
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

function handleGetAlertHistory_(data) {
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = ss.getSheetByName('AlertLog');
    if (!sheet || sheet.getLastRow() <= 1) {
      return ContentService.createTextOutput(JSON.stringify({
        ok: true,
        history: [],
      })).setMimeType(ContentService.MimeType.JSON);
    }

    // Get last 50 entries
    const lastRow = sheet.getLastRow();
    const startRow = Math.max(2, lastRow - 49);
    const numRows = lastRow - startRow + 1;
    const data2 = sheet.getRange(startRow, 1, numRows, 7).getValues();

    const history = data2.reverse().map(row => ({
      timestamp: row[0],
      ruleName: row[1],
      trigger: row[2],
      reason: row[3],
      recipients: row[4],
      channel: row[5],
      status: row[6],
    }));

    return ContentService.createTextOutput(JSON.stringify({
      ok: true,
      history: history,
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (e) {
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: e.toString(),
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// RULE EVALUATION ENGINE
// ═══════════════════════════════════════════════════════════════════════

/**
 * Load alert rules from the AlertRules sheet
 */
function loadAlertRules_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sheet = ss.getSheetByName('AlertRules');
  if (!sheet || sheet.getLastRow() <= 1) return [];

  const data = sheet.getRange(2, 1, sheet.getLastRow() - 1, 10).getValues();
  return data
    .filter(row => row[8] === 'TRUE' || row[8] === true) // enabled only
    .map(row => ({
      id: row[0],
      name: row[1],
      trigger: row[2],
      threshold: parseInt(row[3]) || 0,
      plant: row[4] || '',
      department: row[5] || '',
      recipients: JSON.parse(row[6] || '[]'),
      channel: row[7] || 'email',
    }));
}

/**
 * Evaluate which rules should fire for the given data
 */
function evaluateRules_(rules, type, incData) {
  const severity = (incData.severity || '').toUpperCase();
  const plant = incData.plant || '';
  const dept = incData.dept || incData.department || '';
  const section = incData.detectedSection || '';

  const firingRules = [];

  for (const rule of rules) {
    // Plant filter
    if (rule.plant && rule.plant !== plant) continue;

    // Department/section filter
    if (rule.department) {
      const ruleDept = rule.department.toUpperCase();
      const matchDept = dept.toUpperCase().indexOf(ruleDept) >= 0 ||
                        section.toUpperCase().indexOf(ruleDept) >= 0;
      if (!matchDept) continue;
    }

    // Trigger matching
    switch (rule.trigger) {
      case 'critical_incident':
        if (severity === 'CRITICAL') {
          firingRules.push({...rule, reason: `CRITICAL: ${incData.title || incData.summary || 'Incident'}`});
        }
        break;

      case 'high_incident':
        if (severity === 'HIGH') {
          firingRules.push({...rule, reason: `HIGH: ${incData.title || incData.summary || 'Incident'}`});
        }
        break;

      case 'ai_scan_hazard':
        if (type === 'ai_scan' && (severity === 'CRITICAL' || severity === 'HIGH')) {
          const hazardCount = incData.hazardCount || 0;
          firingRules.push({
            ...rule,
            reason: `AI Scan: ${severity} risk in ${section || dept || 'Unknown Section'} (${hazardCount} hazards)`,
          });
        }
        break;

      case 'near_miss':
        if (type === 'near_miss') {
          firingRules.push({
            ...rule,
            reason: `Near Miss in ${dept || section || 'Unspecified'}: ${incData.title || ''}`,
          });
        }
        break;

      case 'threshold_daily':
        // This requires checking today's count from Incidents sheet
        const todayCount = getTodayIncidentCount_(plant, rule.department);
        if (todayCount >= rule.threshold) {
          firingRules.push({
            ...rule,
            reason: `${todayCount} incidents today (threshold: ${rule.threshold})`,
          });
        }
        break;

      case 'high_open_7d':
        // Check for stale HIGH/CRITICAL — only fire once per day
        if (!hasAlertFiredToday_(rule.id)) {
          const staleCount = getStaleHighCriticalCount_(plant, rule.department);
          if (staleCount > 0) {
            firingRules.push({
              ...rule,
              reason: `${staleCount} HIGH/CRITICAL incidents open > 7 days`,
            });
          }
        }
        break;
    }
  }

  return firingRules;
}

/**
 * Fire a single rule — send notifications
 */
function fireRule_(rule, incData, type) {
  const recipients = rule.recipients || [];
  const channel = rule.channel || 'email';
  const config = getAlertConfig_();

  // Fallback to admin
  if (recipients.length === 0 && config.adminEmail) {
    recipients.push(config.adminEmail);
  }
  if (recipients.length === 0) return false;

  const subject = buildAlertSubject_(rule, rule.reason);
  const message = buildAlertMessage_(rule, rule.reason, [],
    type === 'ai_scan' ? incData : null,
    type === 'near_miss' ? incData : null);

  let success = false;

  // Email
  if (channel === 'email' || channel === 'both') {
    const emails = recipients.filter(r => r.includes('@'));
    if (emails.length > 0) {
      success = sendEmail_(emails, subject, message) || success;
    }
  }

  // SMS
  if (channel === 'sms' || channel === 'both') {
    const phones = recipients.filter(r => !r.includes('@') && r.length >= 10);
    if (phones.length > 0) {
      const smsText = buildSmsText_(rule, rule.reason,
        type === 'ai_scan' ? incData : null,
        type === 'near_miss' ? incData : null);
      success = sendSms_(phones, smsText) || success;
    }
  }

  // Log
  logAlert_(recipients.join(', '), rule, rule.reason, success ? 'DELIVERED' : 'FAILED');
  return success;
}

// ═══════════════════════════════════════════════════════════════════════
// MESSAGE BUILDERS
// ═══════════════════════════════════════════════════════════════════════

function buildAlertSubject_(rule, reason) {
  const prefix = '⚠️ SAIL Safety Lens Alert';
  const trigger = rule.trigger || '';

  if (trigger === 'critical_incident') return `🔴 ${prefix}: CRITICAL Incident`;
  if (trigger === 'high_incident') return `🟠 ${prefix}: HIGH Severity Incident`;
  if (trigger === 'ai_scan_hazard') return `📸 ${prefix}: AI Scan — Hazard Detected`;
  if (trigger === 'near_miss') return `⚡ ${prefix}: Near Miss Reported`;
  if (trigger === 'threshold_daily') return `📊 ${prefix}: Daily Threshold Exceeded`;
  if (trigger === 'high_open_7d') return `⏰ ${prefix}: Stale Incident Escalation`;
  if (trigger === 'daily_digest') return `📋 ${prefix}: Daily Safety Digest`;

  return `${prefix}: ${rule.name || 'Notification'}`;
}

function buildAlertMessage_(rule, reason, incidents, scanData, nearMissData) {
  let html = '';

  // Header
  html += '<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">';
  html += '<div style="background: #1a237e; color: white; padding: 16px 20px; border-radius: 8px 8px 0 0;">';
  html += '<h2 style="margin: 0; font-size: 18px;">⚠️ SAIL Safety Lens Alert</h2>';
  html += `<p style="margin: 4px 0 0; opacity: 0.9; font-size: 13px;">${rule.name || 'Safety Notification'}</p>`;
  html += '</div>';

  // Body
  html += '<div style="background: #fff; border: 1px solid #e0e0e0; padding: 20px; border-radius: 0 0 8px 8px;">';

  // Reason
  html += `<div style="background: #fff3e0; border-left: 4px solid #ff9800; padding: 12px; margin-bottom: 16px; border-radius: 4px;">`;
  html += `<strong style="color: #e65100;">Trigger:</strong> <span style="color: #333;">${reason}</span>`;
  html += '</div>';

  // Filters applied
  if (rule.plant || rule.department) {
    html += '<p style="color: #666; font-size: 12px; margin: 0 0 12px;">';
    if (rule.plant) html += `<strong>Plant:</strong> ${rule.plant} `;
    if (rule.department) html += `<strong>Department:</strong> ${rule.department}`;
    html += '</p>';
  }

  // AI Scan Data
  if (scanData) {
    html += '<div style="background: #fce4ec; padding: 12px; border-radius: 6px; margin-bottom: 12px;">';
    html += '<h3 style="margin: 0 0 8px; color: #c62828; font-size: 14px;">📸 AI Scan Results</h3>';
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Section:</strong> ${scanData.detectedSection || scanData.section || 'N/A'}</p>`;
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Risk Score:</strong> ${scanData.riskScore || 0}/100</p>`;
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Hazards Found:</strong> ${scanData.hazardCount || 0}</p>`;
    if (scanData.summary) {
      html += `<p style="margin: 6px 0 0; font-size: 12px; color: #555;">${scanData.summary}</p>`;
    }
    if (scanData.topHazards && scanData.topHazards.length > 0) {
      html += '<ul style="margin: 8px 0 0; padding-left: 16px; font-size: 12px;">';
      scanData.topHazards.forEach(h => {
        html += `<li style="color: #c62828;">${h}</li>`;
      });
      html += '</ul>';
    }
    html += '</div>';
  }

  // Near Miss Data
  if (nearMissData) {
    html += '<div style="background: #e8f5e9; padding: 12px; border-radius: 6px; margin-bottom: 12px;">';
    html += '<h3 style="margin: 0 0 8px; color: #2e7d32; font-size: 14px;">⚡ Near Miss Details</h3>';
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Description:</strong> ${nearMissData.title || 'N/A'}</p>`;
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Department:</strong> ${nearMissData.dept || 'N/A'}</p>`;
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Severity:</strong> ${nearMissData.severity || 'N/A'}</p>`;
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Reported By:</strong> ${nearMissData.reportedBy || 'N/A'}</p>`;
    html += `<p style="margin: 2px 0; font-size: 13px;"><strong>Date:</strong> ${nearMissData.date || 'N/A'}</p>`;
    html += '</div>';
  }

  // Incident list
  if (incidents && incidents.length > 0) {
    html += '<h3 style="margin: 12px 0 8px; font-size: 14px; color: #333;">Related Incidents:</h3>';
    html += '<table style="width: 100%; border-collapse: collapse; font-size: 12px;">';
    html += '<tr style="background: #f5f5f5;"><th style="padding: 6px; text-align: left; border: 1px solid #e0e0e0;">Date</th><th style="padding: 6px; text-align: left; border: 1px solid #e0e0e0;">Title</th><th style="padding: 6px; text-align: left; border: 1px solid #e0e0e0;">Severity</th><th style="padding: 6px; text-align: left; border: 1px solid #e0e0e0;">Dept</th></tr>';
    incidents.slice(0, 5).forEach(inc => {
      const sevColor = inc.severity === 'CRITICAL' ? '#d32f2f' : inc.severity === 'HIGH' ? '#f57c00' : '#333';
      html += `<tr><td style="padding: 6px; border: 1px solid #e0e0e0;">${(inc.date || '').substring(0, 10)}</td><td style="padding: 6px; border: 1px solid #e0e0e0;">${inc.title || ''}</td><td style="padding: 6px; border: 1px solid #e0e0e0; color: ${sevColor}; font-weight: bold;">${inc.severity || ''}</td><td style="padding: 6px; border: 1px solid #e0e0e0;">${inc.dept || inc.detectedSection || ''}</td></tr>`;
    });
    html += '</table>';
  }

  // Footer
  html += '<hr style="border: none; border-top: 1px solid #e0e0e0; margin: 16px 0;">';
  html += '<p style="color: #999; font-size: 11px; margin: 0;">';
  html += `Alert fired at: ${new Date().toLocaleString('en-IN', {timeZone: 'Asia/Kolkata'})} IST<br>`;
  html += 'Rule: ' + (rule.name || rule.id || 'Unknown') + '<br>';
  html += 'Powered by SAIL Safety Lens — "Safety Starts with Me"';
  html += '</p>';

  html += '</div></div>';

  return html;
}

/**
 * Build SMS text — must be under 160 chars for single SMS, or 460 for multi-part
 */
function buildSmsText_(rule, reason, scanData, nearMissData) {
  let text = 'SAIL SAFETY ALERT\n';

  if (scanData) {
    const section = scanData.detectedSection || scanData.section || '';
    const score = scanData.riskScore || 0;
    const hazards = scanData.hazardCount || 0;
    text += `AI Scan: ${(scanData.severity || 'HIGH').toUpperCase()} risk in ${section}\n`;
    text += `Score: ${score}/100, ${hazards} hazard(s)\n`;
    if (scanData.topHazards && scanData.topHazards.length > 0) {
      text += scanData.topHazards[0] + '\n';
    }
  } else if (nearMissData) {
    text += `Near Miss: ${nearMissData.dept || ''}\n`;
    text += `${(nearMissData.title || '').substring(0, 80)}\n`;
    text += `By: ${nearMissData.reportedBy || 'Unknown'}\n`;
  } else {
    text += `${reason}\n`;
  }

  if (rule.plant) text += `Plant: ${rule.plant}\n`;
  if (rule.department) text += `Dept: ${rule.department}\n`;
  text += 'Action Required. Check Safety Lens app.';

  // Trim to 460 chars (3-part SMS max)
  return text.substring(0, 460);
}

// ═══════════════════════════════════════════════════════════════════════
// EMAIL DELIVERY
// ═══════════════════════════════════════════════════════════════════════

function sendEmail_(emailAddresses, subject, htmlBody) {
  try {
    // Google Apps Script MailApp — free, 100 emails/day limit
    MailApp.sendEmail({
      to: emailAddresses.join(','),
      subject: subject,
      htmlBody: htmlBody,
      name: 'SAIL Safety Lens',
      noReply: true,
    });
    Logger.log(`Email sent to: ${emailAddresses.join(', ')}`);
    return true;
  } catch (e) {
    Logger.log(`Email failed: ${e.toString()}`);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SMS DELIVERY — Multiple providers supported
// ═══════════════════════════════════════════════════════════════════════

function sendSms_(phoneNumbers, message) {
  const config = getAlertConfig_();

  if (!config.smsApiKey && !config.textlocalApiKey && !config.msg91AuthKey) {
    Logger.log('SMS: No API key configured — skipping SMS delivery');
    return false;
  }

  switch (config.smsProvider) {
    case 'fast2sms':
      return sendSmsFast2Sms_(phoneNumbers, message, config);
    case 'msg91':
      return sendSmsMsg91_(phoneNumbers, message, config);
    case 'textlocal':
      return sendSmsTextlocal_(phoneNumbers, message, config);
    default:
      return sendSmsFast2Sms_(phoneNumbers, message, config);
  }
}

/**
 * Fast2SMS — India's cheapest SMS gateway
 * Sign up: https://www.fast2sms.com
 * DLT registration required for transactional SMS
 * Cost: ~₹0.20 per SMS
 */
function sendSmsFast2Sms_(phones, message, config) {
  try {
    // Clean phone numbers (remove +91, spaces, dashes)
    const cleanPhones = phones.map(p => {
      let clean = p.replace(/[\s\-\+]/g, '');
      if (clean.startsWith('91') && clean.length === 12) clean = clean.substring(2);
      if (clean.length === 10) return clean;
      return null;
    }).filter(Boolean);

    if (cleanPhones.length === 0) return false;

    const url = 'https://www.fast2sms.com/dev/bulkV2';
    const payload = {
      route: 'dlt', // Use 'dlt' for transactional, 'q' for quick (promotional)
      sender_id: config.smsSenderId || 'SAILSF',
      message: message,
      language: 'english',
      flash: 0,
      numbers: cleanPhones.join(','),
    };

    const options = {
      method: 'post',
      headers: {
        'authorization': config.smsApiKey,
        'Content-Type': 'application/json',
      },
      payload: JSON.stringify(payload),
      muteHttpExceptions: true,
    };

    const response = UrlFetchApp.fetch(url, options);
    const result = JSON.parse(response.getContentText());

    if (result.return === true || result.status_code === 200) {
      Logger.log(`Fast2SMS: Sent to ${cleanPhones.length} numbers`);
      return true;
    } else {
      Logger.log(`Fast2SMS error: ${JSON.stringify(result)}`);
      return false;
    }
  } catch (e) {
    Logger.log(`Fast2SMS exception: ${e.toString()}`);
    return false;
  }
}

/**
 * MSG91 — Enterprise SMS gateway (India)
 * Sign up: https://msg91.com
 * Supports template-based DLT compliant messaging
 */
function sendSmsMsg91_(phones, message, config) {
  try {
    const cleanPhones = phones.map(p => {
      let clean = p.replace(/[\s\-\+]/g, '');
      if (!clean.startsWith('91')) clean = '91' + clean;
      return clean;
    });

    const url = 'https://control.msg91.com/api/v5/flow/';
    const payload = {
      template_id: config.msg91TemplateId,
      recipients: cleanPhones.map(p => ({
        mobiles: p,
        message: message,
      })),
    };

    const options = {
      method: 'post',
      headers: {
        'authkey': config.msg91AuthKey,
        'Content-Type': 'application/json',
      },
      payload: JSON.stringify(payload),
      muteHttpExceptions: true,
    };

    const response = UrlFetchApp.fetch(url, options);
    const result = JSON.parse(response.getContentText());

    if (result.type === 'success') {
      Logger.log(`MSG91: Sent to ${cleanPhones.length} numbers`);
      return true;
    } else {
      Logger.log(`MSG91 error: ${JSON.stringify(result)}`);
      return false;
    }
  } catch (e) {
    Logger.log(`MSG91 exception: ${e.toString()}`);
    return false;
  }
}

/**
 * Textlocal — SMS gateway (India/UK)
 * Sign up: https://www.textlocal.in
 */
function sendSmsTextlocal_(phones, message, config) {
  try {
    const cleanPhones = phones.map(p => {
      let clean = p.replace(/[\s\-\+]/g, '');
      if (!clean.startsWith('91')) clean = '91' + clean;
      return clean;
    });

    const url = 'https://api.textlocal.in/send/';
    const payload = {
      apikey: config.textlocalApiKey,
      numbers: cleanPhones.join(','),
      message: message,
      sender: config.textlocalSender || 'SAILSF',
    };

    const options = {
      method: 'post',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      payload: payload,
      muteHttpExceptions: true,
    };

    const response = UrlFetchApp.fetch(url, options);
    const result = JSON.parse(response.getContentText());

    if (result.status === 'success') {
      Logger.log(`Textlocal: Sent to ${cleanPhones.length} numbers`);
      return true;
    } else {
      Logger.log(`Textlocal error: ${JSON.stringify(result)}`);
      return false;
    }
  } catch (e) {
    Logger.log(`Textlocal exception: ${e.toString()}`);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════

/**
 * Log alert delivery to AlertLog sheet
 */
function logAlert_(recipients, rule, reason, status) {
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let sheet = ss.getSheetByName('AlertLog');

    if (!sheet) {
      sheet = ss.insertSheet('AlertLog');
      sheet.getRange(1, 1, 1, 7).setValues([[
        'Timestamp', 'Rule Name', 'Trigger', 'Reason', 'Recipients', 'Channel', 'Status'
      ]]);
      sheet.getRange(1, 1, 1, 7).setFontWeight('bold');
      sheet.setFrozenRows(1);
    }

    sheet.appendRow([
      new Date().toISOString(),
      rule.name || rule.id || 'Unknown',
      rule.trigger || '',
      reason || '',
      recipients || '',
      rule.channel || 'email',
      status || 'UNKNOWN',
    ]);

    // Auto-trim: keep only last 500 rows
    if (sheet.getLastRow() > 501) {
      sheet.deleteRows(2, sheet.getLastRow() - 501);
    }
  } catch (e) {
    Logger.log(`AlertLog error: ${e.toString()}`);
  }
}

/**
 * Get today's incident count (for threshold trigger)
 */
function getTodayIncidentCount_(plant, department) {
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = ss.getSheetByName('Incidents');
    if (!sheet || sheet.getLastRow() <= 1) return 0;

    const today = new Date();
    const todayStr = Utilities.formatDate(today, 'Asia/Kolkata', 'yyyy-MM-dd');

    const data = sheet.getDataRange().getValues();
    const headers = data[0];
    const dateCol = headers.indexOf('date');
    const plantCol = headers.indexOf('plant');
    const deptCol = headers.indexOf('dept');

    if (dateCol < 0) return 0;

    let count = 0;
    for (let i = 1; i < data.length; i++) {
      const rowDate = (data[i][dateCol] || '').toString().substring(0, 10);
      if (rowDate !== todayStr) continue;
      if (plant && plantCol >= 0 && data[i][plantCol] !== plant) continue;
      if (department && deptCol >= 0 &&
          data[i][deptCol].toString().toUpperCase().indexOf(department.toUpperCase()) < 0) continue;
      count++;
    }
    return count;
  } catch (e) {
    return 0;
  }
}

/**
 * Get count of HIGH/CRITICAL incidents open > 7 days
 */
function getStaleHighCriticalCount_(plant, department) {
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = ss.getSheetByName('Incidents');
    if (!sheet || sheet.getLastRow() <= 1) return 0;

    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 7);

    const data = sheet.getDataRange().getValues();
    const headers = data[0];
    const dateCol = headers.indexOf('date');
    const sevCol = headers.indexOf('severity');
    const statusCol = headers.indexOf('status');
    const plantCol = headers.indexOf('plant');
    const deptCol = headers.indexOf('dept');

    if (dateCol < 0 || sevCol < 0) return 0;

    let count = 0;
    for (let i = 1; i < data.length; i++) {
      const sev = (data[i][sevCol] || '').toString().toUpperCase();
      if (sev !== 'CRITICAL' && sev !== 'HIGH') continue;

      const status = (data[i][statusCol] || '').toString().toUpperCase();
      if (status === 'CLOSED') continue;

      const incDate = new Date(data[i][dateCol]);
      if (isNaN(incDate.getTime()) || incDate > cutoff) continue;

      if (plant && plantCol >= 0 && data[i][plantCol] !== plant) continue;
      if (department && deptCol >= 0 &&
          data[i][deptCol].toString().toUpperCase().indexOf(department.toUpperCase()) < 0) continue;

      count++;
    }
    return count;
  } catch (e) {
    return 0;
  }
}

/**
 * Check if a rule has already fired today (to prevent spam)
 */
function hasAlertFiredToday_(ruleId) {
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = ss.getSheetByName('AlertLog');
    if (!sheet || sheet.getLastRow() <= 1) return false;

    const today = Utilities.formatDate(new Date(), 'Asia/Kolkata', 'yyyy-MM-dd');

    // Check last 20 rows for today's entries with same rule
    const lastRow = sheet.getLastRow();
    const startRow = Math.max(2, lastRow - 19);
    const data = sheet.getRange(startRow, 1, lastRow - startRow + 1, 3).getValues();

    for (const row of data) {
      const ts = (row[0] || '').toString().substring(0, 10);
      const ruleName = row[1] || '';
      if (ts === today && ruleName.indexOf(ruleId) >= 0) return true;
    }
    return false;
  } catch (e) {
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// TIME-BASED TRIGGERS (Set up via Apps Script Triggers menu)
// ═══════════════════════════════════════════════════════════════════════

/**
 * DAILY DIGEST — Run this at 8 AM IST via Apps Script time-based trigger
 *
 * Setup:
 *   1. Go to Triggers (clock icon in Apps Script editor)
 *   2. Add Trigger → Function: dailyDigestTrigger
 *   3. Event source: Time-driven
 *   4. Type: Day timer → 8am to 9am
 */
function dailyDigestTrigger() {
  const rules = loadAlertRules_();
  const digestRules = rules.filter(r => r.trigger === 'daily_digest');

  if (digestRules.length === 0) return;

  // Build yesterday's summary
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const yStr = Utilities.formatDate(yesterday, 'Asia/Kolkata', 'yyyy-MM-dd');

  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sheet = ss.getSheetByName('Incidents');
  if (!sheet || sheet.getLastRow() <= 1) return;

  const data = sheet.getDataRange().getValues();
  const headers = data[0];
  const dateCol = headers.indexOf('date');
  const sevCol = headers.indexOf('severity');
  const deptCol = headers.indexOf('dept');
  const typeCol = headers.indexOf('type');

  // Count yesterday's stats
  let total = 0, critical = 0, high = 0, medium = 0, low = 0;
  let aiScans = 0, nearMisses = 0;
  const deptCounts = {};

  for (let i = 1; i < data.length; i++) {
    const rowDate = (data[i][dateCol] || '').toString().substring(0, 10);
    if (rowDate !== yStr) continue;

    total++;
    const sev = (data[i][sevCol] || '').toString().toUpperCase();
    if (sev === 'CRITICAL') critical++;
    else if (sev === 'HIGH') high++;
    else if (sev === 'MEDIUM') medium++;
    else low++;

    const type = (data[i][typeCol] || '').toString();
    if (type === 'AI_SCAN') aiScans++;
    if (type === 'NEAR_MISS' || type === 'Near Miss') nearMisses++;

    const dept = data[i][deptCol] || 'Unknown';
    deptCounts[dept] = (deptCounts[dept] || 0) + 1;
  }

  if (total === 0) return; // Nothing to report

  // Build digest email
  let html = '<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">';
  html += '<div style="background: #1a237e; color: white; padding: 16px 20px; border-radius: 8px 8px 0 0;">';
  html += '<h2 style="margin: 0; font-size: 18px;">📋 SAIL Safety Lens — Daily Digest</h2>';
  html += `<p style="margin: 4px 0 0; opacity: 0.9; font-size: 13px;">Summary for ${yStr}</p>`;
  html += '</div>';
  html += '<div style="background: #fff; border: 1px solid #e0e0e0; padding: 20px; border-radius: 0 0 8px 8px;">';

  // Stats
  html += '<table style="width: 100%; border-collapse: collapse; margin-bottom: 16px;">';
  html += '<tr>';
  html += `<td style="padding: 12px; text-align: center; background: #ffebee; border-radius: 6px;"><strong style="color: #c62828; font-size: 24px;">${critical}</strong><br><span style="font-size: 11px; color: #666;">CRITICAL</span></td>`;
  html += `<td style="padding: 12px; text-align: center; background: #fff3e0; border-radius: 6px;"><strong style="color: #e65100; font-size: 24px;">${high}</strong><br><span style="font-size: 11px; color: #666;">HIGH</span></td>`;
  html += `<td style="padding: 12px; text-align: center; background: #e8f5e9; border-radius: 6px;"><strong style="color: #2e7d32; font-size: 24px;">${medium + low}</strong><br><span style="font-size: 11px; color: #666;">MED+LOW</span></td>`;
  html += `<td style="padding: 12px; text-align: center; background: #e3f2fd; border-radius: 6px;"><strong style="color: #1565c0; font-size: 24px;">${total}</strong><br><span style="font-size: 11px; color: #666;">TOTAL</span></td>`;
  html += '</tr></table>';

  // Type breakdown
  html += `<p style="font-size: 13px; color: #333;">📸 AI Scans: <strong>${aiScans}</strong> | ⚡ Near Misses: <strong>${nearMisses}</strong></p>`;

  // Department breakdown
  if (Object.keys(deptCounts).length > 0) {
    html += '<h3 style="font-size: 14px; margin: 12px 0 8px;">Department Breakdown:</h3>';
    html += '<table style="width: 100%; border-collapse: collapse; font-size: 12px;">';
    Object.entries(deptCounts)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 10)
      .forEach(([dept, count]) => {
        html += `<tr><td style="padding: 4px 8px; border-bottom: 1px solid #eee;">${dept}</td><td style="padding: 4px 8px; border-bottom: 1px solid #eee; text-align: right; font-weight: bold;">${count}</td></tr>`;
      });
    html += '</table>';
  }

  html += '<hr style="border: none; border-top: 1px solid #e0e0e0; margin: 16px 0;">';
  html += '<p style="color: #999; font-size: 11px;">Generated by SAIL Safety Lens at ' +
    new Date().toLocaleString('en-IN', {timeZone: 'Asia/Kolkata'}) + ' IST</p>';
  html += '</div></div>';

  // Send to all digest rule recipients
  for (const rule of digestRules) {
    const emails = (rule.recipients || []).filter(r => r.includes('@'));
    if (emails.length > 0) {
      sendEmail_(emails, `📋 SAIL Safety Digest — ${yStr} (${total} incidents)`, html);
      logAlert_(emails.join(', '), rule, `Daily digest: ${total} incidents on ${yStr}`, 'DELIVERED');
    }
  }
}

/**
 * STALE INCIDENT CHECK — Run daily at 9 AM via time-based trigger
 *
 * Setup: Same as dailyDigestTrigger but set to 9am-10am
 */
function staleIncidentTrigger() {
  const rules = loadAlertRules_();
  const staleRules = rules.filter(r => r.trigger === 'high_open_7d');

  for (const rule of staleRules) {
    const count = getStaleHighCriticalCount_(rule.plant, rule.department);
    if (count > 0) {
      const reason = `${count} HIGH/CRITICAL incidents open > 7 days`;
      const subject = `⏰ SAIL Safety Alert: ${reason}`;
      const message = buildAlertMessage_(rule, reason, [], null, null);

      const emails = (rule.recipients || []).filter(r => r.includes('@'));
      const phones = (rule.recipients || []).filter(r => !r.includes('@') && r.length >= 10);

      let sent = false;
      if (emails.length > 0 && (rule.channel === 'email' || rule.channel === 'both')) {
        sent = sendEmail_(emails, subject, message) || sent;
      }
      if (phones.length > 0 && (rule.channel === 'sms' || rule.channel === 'both')) {
        sent = sendSms_(phones, `SAIL ALERT: ${reason}. Action required. Check Safety Lens.`) || sent;
      }

      logAlert_((rule.recipients || []).join(', '), rule, reason, sent ? 'DELIVERED' : 'FAILED');
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
// INTEGRATION WITH EXISTING doPost() — ADD THESE LINES
// ═══════════════════════════════════════════════════════════════════════

/**
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  ADD THE FOLLOWING TO YOUR EXISTING doPost() FUNCTION:          ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║                                                                  ║
 * ║  // Alert system actions                                         ║
 * ║  if (action === 'syncAlertRules')   return handleSyncAlertRules_(data);  ║
 * ║  if (action === 'fireAlert')        return handleFireAlert_(data);       ║
 * ║  if (action === 'evaluateAndAlert') return handleEvaluateAndAlert_(data);║
 * ║  if (action === 'getAlertHistory')  return handleGetAlertHistory_(data); ║
 * ║                                                                  ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║  ALSO: In your existing addIncident handler, add at the end:    ║
 * ║                                                                  ║
 * ║  // Auto-evaluate alerts after incident is saved                 ║
 * ║  try {                                                           ║
 * ║    handleEvaluateAndAlert_({                                     ║
 * ║      type: data.type === 'AI_SCAN' ? 'ai_scan'                  ║
 * ║          : data.type === 'Near Miss' ? 'near_miss' : 'incident',║
 * ║      data: data,                                                 ║
 * ║    });                                                           ║
 * ║  } catch(e) { Logger.log('Alert eval error: ' + e); }           ║
 * ║                                                                  ║
 * ╚══════════════════════════════════════════════════════════════════╝
 */
