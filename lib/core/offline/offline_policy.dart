const offlineLimit = Duration(hours: 72);

const readRpcNames = {
  'my_session',
  'preview_open_attendance',
  'attendance_totals',
  'dashboard_summary',
  'dashboard_people',
  'attendance_analytics',
  'work_analytics',
  'leave_absence_report',
  'report_filters',
  'project_sprint_counts',
  'sprint_breakdown',
  'project_milestone_counts',
};

/// Cached records stay readable only inside 72 hours of the last online check.
bool offlineAccessOpen({required DateTime? validatedAt, required DateTime now, required bool online}) {
  if (online) return true;
  if (validatedAt == null) return false;
  return now.difference(validatedAt) <= offlineLimit;
}

/// Reads may be served from cache. Everything else is refused with no queue.
bool offlineBlocksRequest(String method, String path) {
  if (path.contains('/auth/v1/logout')) return false;
  final upper = method.toUpperCase();
  if (upper == 'GET' || upper == 'HEAD') return false;
  final rpc = RegExp(r'/rpc/([^/?]+)').firstMatch(path);
  if (rpc != null) return !readRpcNames.contains(rpc.group(1));
  return true;
}

String periodStatusLabel(String code) {
  return switch (code) {
    'none' => 'بدون گزارش',
    'pending' => 'در انتظار بررسی',
    'approved' => 'تأییدشده',
    'partial' => 'تأیید جزئی',
    'has_rejected' => 'دارای موارد ردشده',
    'needs_revision' => 'نیازمند اصلاح',
    _ => code,
  };
}
