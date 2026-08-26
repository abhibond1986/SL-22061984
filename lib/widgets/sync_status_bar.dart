// lib/widgets/sync_status_bar.dart
// ★ v25: Shows sync status — last sync time + pending items count.
// Displayed at top of home/analytics screens so users know their data state.

import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL;
import '../services/sync_service.dart';

class SyncStatusBar extends StatefulWidget {
  final VoidCallback? onRefresh;
  const SyncStatusBar({super.key, this.onRefresh});

  @override
  State<SyncStatusBar> createState() => _SyncStatusBarState();
}

class _SyncStatusBarState extends State<SyncStatusBar> {
  int _pendingCount = 0;
  String _lastSyncText = '';
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final pending = await SyncService.getPendingCount();
    final lastSync = await SyncService.getLastSyncTime();
    if (!mounted) return;
    setState(() {
      _pendingCount = pending;
      _lastSyncText = _formatSyncTime(lastSync);
    });
  }

  String _formatSyncTime(DateTime? time) {
    if (time == null) return 'Never synced';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _triggerSync() async {
    setState(() => _syncing = true);
    try {
      await SyncService.drainPendingQueue();
      await _loadStatus();
      widget.onRefresh?.call();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final hasIssues = _pendingCount > 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: hasIssues
            ? AppColors.amber.withOpacity(0.08)
            : AppColors.green.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hasIssues
              ? AppColors.amber.withOpacity(0.3)
              : AppColors.green.withOpacity(0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            hasIssues ? Icons.cloud_queue_rounded : Icons.cloud_done_rounded,
            color: hasIssues ? AppColors.amber : AppColors.green,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hasIssues
                      ? '$_pendingCount report${_pendingCount > 1 ? 's' : ''} pending sync'
                      : 'All synced',
                  style: TextStyle(
                    color: sl.text1,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Last sync: $_lastSyncText',
                  style: TextStyle(color: sl.text4, fontSize: 9),
                ),
              ],
            ),
          ),
          if (_syncing)
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            GestureDetector(
              onTap: _triggerSync,
              child: Icon(
                Icons.refresh_rounded,
                color: sl.accentText,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }
}
