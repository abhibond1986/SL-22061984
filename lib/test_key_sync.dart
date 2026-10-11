// Quick diagnostic to test if API keys are syncing from backend
// Run this in your Flutter app to check what's happening

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/sync_service.dart';
import 'services/admin_master_data.dart';

class KeySyncDiagnostic extends StatefulWidget {
  const KeySyncDiagnostic({super.key});

  @override
  State<KeySyncDiagnostic> createState() => _KeySyncDiagnosticState();
}

class _KeySyncDiagnosticState extends State<KeySyncDiagnostic> {
  String _log = 'Starting diagnostic...\n';
  bool _running = false;

  void _addLog(String msg) {
    if (mounted) {
      setState(() {
        _log += '${DateTime.now().toString().substring(11, 19)} - $msg\n';
      });
    }
  }

  Future<void> _runDiagnostic() async {
    if (_running) return;
    setState(() {
      _running = true;
      _log = '';
    });

    try {
      _addLog('=== KEY SYNC DIAGNOSTIC ===\n');

      // Step 1: Check backend URL
      final backendUrl = await SyncService.getBackendUrl();
      _addLog('✓ Backend URL: $backendUrl');

      // Step 2: Check what's in local storage NOW
      final prefs = await SharedPreferences.getInstance();
      final localGemini = prefs.getString('gemini_vision_api_key') ?? '';
      final localGroq = prefs.getString('groq_api_key') ?? '';
      final localOR1 = prefs.getString('openrouter_api_key_1') ?? '';
      final localOR2 = prefs.getString('openrouter_api_key_2') ?? '';
      final localNara = prefs.getString('nara_api_key') ?? '';

      _addLog('\n--- LOCAL STORAGE ---');
      _addLog('Gemini: ${localGemini.isEmpty ? "EMPTY" : "${localGemini.substring(0, 8)}..."}');
      _addLog('Groq: ${localGroq.isEmpty ? "EMPTY" : "${localGroq.substring(0, 8)}..."}');
      _addLog('OpenRouter 1: ${localOR1.isEmpty ? "EMPTY" : "${localOR1.substring(0, 8)}..."}');
      _addLog('OpenRouter 2: ${localOR2.isEmpty ? "EMPTY" : localOR2.substring(0, 8)}...');
      _addLog('Nara: ${localNara.isEmpty ? "EMPTY" : "${localNara.substring(0, 8)}..."}');

      // Step 3: Call getMasterData from backend
      _addLog('\n--- FETCHING FROM BACKEND ---');
      final result = await SyncService.fetchMasterData();

      if (result == null) {
        _addLog('❌ FAILED: fetchMasterData returned null');
        _addLog('This means the backend request failed completely.');
        return;
      }

      _addLog('✓ Backend responded');

      // Step 4: Check what keys came back
      final geminiKey = result['geminiApiKey'] as String?;
      final groqKey = result['groqApiKey'] as String?;
      final openRouterKey = result['openRouterApiKey'] as String?;
      final openRouterKey2 = result['openRouterApiKey2'] as String?;
      final naraKey = result['naraApiKey'] as String?;

      _addLog('\n--- KEYS FROM BACKEND ---');
      _addLog('Gemini: ${geminiKey == null || geminiKey.isEmpty ? "NOT RETURNED" : "${geminiKey.substring(0, 8)}..."}');
      _addLog('Groq: ${groqKey == null || groqKey.isEmpty ? "NOT RETURNED" : "${groqKey.substring(0, 8)}..."}');
      _addLog('OpenRouter 1: ${openRouterKey == null || openRouterKey.isEmpty ? "NOT RETURNED" : "${openRouterKey.substring(0, 8)}..."}');
      _addLog('OpenRouter 2: ${openRouterKey2 == null || openRouterKey2.isEmpty ? "NOT RETURNED" : "${openRouterKey2.substring(0, 8)}..."}');
      _addLog('Nara: ${naraKey == null || naraKey.isEmpty ? "NOT RETURNED" : "${naraKey.substring(0, 8)}..."}');

      // Step 5: Force a sync
      _addLog('\n--- FORCING SYNC ---');
      await AdminMasterData.syncFromBackend(result);
      _addLog('✓ syncFromBackend() completed');

      // Step 6: Check what's in local storage AFTER sync
      final newGemini = prefs.getString('gemini_vision_api_key') ?? '';
      final newGroq = prefs.getString('groq_api_key') ?? '';
      final newOR1 = prefs.getString('openrouter_api_key_1') ?? '';
      final newOR2 = prefs.getString('openrouter_api_key_2') ?? '';
      final newNara = prefs.getString('nara_api_key') ?? '';

      _addLog('\n--- LOCAL STORAGE AFTER SYNC ---');
      _addLog('Gemini: ${newGemini.isEmpty ? "STILL EMPTY" : "${newGemini.substring(0, 8)}..."}');
      _addLog('Groq: ${newGroq.isEmpty ? "STILL EMPTY" : "${newGroq.substring(0, 8)}..."}');
      _addLog('OpenRouter 1: ${newOR1.isEmpty ? "STILL EMPTY" : "${newOR1.substring(0, 8)}..."}');
      _addLog('OpenRouter 2: ${newOR2.isEmpty ? "STILL EMPTY" : "${newOR2.substring(0, 8)}..."}');
      _addLog('Nara: ${newNara.isEmpty ? "STILL EMPTY" : "${newNara.substring(0, 8)}..."}');

      _addLog('\n=== DIAGNOSTIC COMPLETE ===');
      _addLog('\n💡 WHAT THIS MEANS:');
      if (newGemini.isEmpty && newGroq.isEmpty && newOR1.isEmpty) {
        _addLog('❌ KEYS ARE NOT SYNCING');
        _addLog('');
        _addLog('TROUBLESHOOTING:');
        _addLog('1. Check Apps Script Script Properties');
        _addLog('   - GOOGLE_AI_KEY = AIza...');
        _addLog('   - GROQ_API_KEY = gsk_...');
        _addLog('   - OPENROUTER_API_KEY = sk-or-v1-...');
        _addLog('');
        _addLog('2. Did you DEPLOY the Apps Script?');
        _addLog('   - Deploy → Manage deployments → Edit');
        _addLog('   - New version → Deploy');
        _addLog('');
        _addLog('3. Check backend URL is correct:');
        _addLog('   $backendUrl');
      } else {
        _addLog('✅ KEYS ARE SYNCING!');
        _addLog('Keys successfully synced from backend.');
        _addLog('');
        _addLog('If admin panel still shows empty:');
        _addLog('- Close and restart the app completely');
        _addLog('- Admin panel loads keys on first view');
      }

    } catch (e, stack) {
      _addLog('\n❌ ERROR: $e');
      _addLog('Stack: ${stack.toString().split('\n').take(5).join('\n')}');
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Key Sync Diagnostic'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy log',
            onPressed: () {
              // Copy log to clipboard would go here
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: _running ? null : _runDiagnostic,
              icon: _running
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(_running ? 'Running...' : 'Run Diagnostic'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: SingleChildScrollView(
                child: Text(
                  _log,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.greenAccent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
