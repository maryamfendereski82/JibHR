import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/design_system/surfaces.dart';
import '../../core/localization/fa.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../session/workspace_session.dart';
import 'report_rules.dart';

/// Entry point for the existing reports. Adds no report of its own: each card
/// opens a page that already existed, and each page keeps its server scope.
class ReportsCenterPage extends ConsumerWidget {
  const ReportsCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final canExport = session != null && canExportReports(session.permissions);
    final cards = [
      (key: 'attendance', title: Fa.attendanceReport, body: Fa.reportAttendanceHint, icon: AppIcons.attendance, path: '/reports/attendance'),
      (key: 'work', title: Fa.workReport, body: Fa.reportWorkHint, icon: AppIcons.work, path: '/reports/work'),
      (key: 'leave', title: Fa.leaveReport, body: Fa.reportLeaveHint, icon: AppIcons.leave, path: '/reports/leave'),
      if (canExport) (key: 'export', title: Fa.exportReport, body: Fa.reportExportHint, icon: AppIcons.export, path: '/reports/export'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = AppSpace.gutter(constraints.maxWidth);
        final columns = constraints.maxWidth >= 1000 ? 2 : 1;
        return ListView(
          padding: EdgeInsets.all(gutter),
          children: [
            Text(Fa.reports, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpace.xs),
            Text(Fa.reportsCenterHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpace.xl),
            Wrap(
              spacing: AppSpace.l,
              runSpacing: AppSpace.l,
              children: [
                for (final card in cards)
                  SizedBox(
                    width: columns == 1
                        ? constraints.maxWidth - gutter * 2
                        : (constraints.maxWidth - gutter * 2 - AppSpace.l) / 2,
                    child: _ReportCard(
                      key: ValueKey('report-${card.key}'),
                      title: card.title,
                      body: card.body,
                      icon: card.icon,
                      onTap: () => context.go(card.path),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({super.key, required this.title, required this.body, required this.icon, required this.onTap});

  final String title;
  final String body;
  final AppIcon icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Semantics(
      button: true,
      label: title,
      child: AppSurface(
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.l),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                    child: Center(child: AppIconView(icon, color: p.jade)),
                  ),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.titleMedium),
                        Text(body, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  AppIconView(AppIcons.open, color: p.muted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
