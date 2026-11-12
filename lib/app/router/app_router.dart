import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/networking/supabase_provider.dart';
import '../../features/attendance/approval_queue_page.dart';
import '../../features/attendance/attendance_page.dart';
import '../../features/attendance/correction_pages.dart';
import '../../features/authentication/auth_pages.dart';
import '../../features/dashboard/dashboard_page.dart';
import '../../features/work/milestone_pages.dart';
import '../../features/work/project_pages.dart';
import '../../features/work/sprint_pages.dart';
import '../../features/work/task_board.dart';
import '../../features/work/task_detail.dart';
import '../../features/notifications/notification_pages.dart';
import '../../features/reports/report_pages.dart';
import '../../features/reports/reports_center_page.dart';
import '../../features/leave/absence_pages.dart';
import '../../features/leave/leave_pages.dart';
import '../../features/session/workspace_session.dart';
import '../../features/settings/settings_page.dart';
import '../../features/shell/app_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(authTickProvider, (_, _) => refresh.value++);
  ref.listen(workspaceSessionProvider, (_, _) => refresh.value++);
  final config = ref.read(appConfigProvider);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final location = state.matchedLocation;
      if (!config.isConfigured) return location == '/setup' ? null : '/setup';

      final signedIn = ref.read(supabaseClientProvider)?.auth.currentSession != null;
      final publicPage = location == '/login' || location == '/forgot-password';
      if (!signedIn) return publicPage ? null : '/login';

      final profile = ref.read(workspaceSessionProvider);
      if (profile.isLoading) return null;
      final mustChange = profile.asData?.value?.mustChangePassword == true;
      if (mustChange && location != '/change-password') return '/change-password';
      if (!mustChange && (publicPage || location == '/setup' || location == '/change-password')) {
        return '/';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/setup', builder: (context, state) => const SetupPage()),
      GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
      GoRoute(path: '/forgot-password', builder: (context, state) => const ForgotPasswordPage()),
      GoRoute(path: '/change-password', builder: (context, state) => const ChangePasswordPage()),
      // One navigator per section, so each keeps its own page stack and state
      // while another section is open. Branch order: navigation.dart branchOrder.
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/', builder: (context, state) => const DashboardPage()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/attendance',
              builder: (context, state) => const AttendancePage(),
              routes: [
                GoRoute(path: 'approvals', builder: (context, state) => const ApprovalQueuePage()),
                GoRoute(path: 'corrections', builder: (context, state) => const CorrectionQueuePage()),
                GoRoute(path: 'mine', builder: (context, state) => const MyCorrectionsPage()),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/leave',
              builder: (context, state) => const MyLeavePage(),
              routes: [
                GoRoute(path: 'queue', builder: (context, state) => const LeaveQueuePage()),
                GoRoute(path: 'calendar', builder: (context, state) => const LeaveCalendarPage()),
                GoRoute(path: 'absence', builder: (context, state) => const AbsenceAdminPage()),
                GoRoute(path: 'my-absence', builder: (context, state) => const MyAbsencePage()),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
          GoRoute(
            path: '/work',
            builder: (context, state) => const ProjectListPage(),
            routes: [
              GoRoute(path: 'personal', builder: (context, state) => const TaskBoardPage(personal: true)),
              GoRoute(path: 'mine', builder: (context, state) => const TaskBoardPage(mine: true)),
              GoRoute(
                path: 'p/:id',
                builder: (context, state) => TaskBoardPage(projectId: state.pathParameters['id']),
                routes: [
                  GoRoute(
                    path: 'settings',
                    builder: (context, state) => ProjectSettingsPage(projectId: state.pathParameters['id']!),
                  ),
                  GoRoute(
                    path: 'sprints',
                    builder: (context, state) => SprintListPage(projectId: state.pathParameters['id']!),
                  ),
                  GoRoute(
                    path: 'sprint/:sprintId',
                    builder: (context, state) => SprintDetailPage(
                      projectId: state.pathParameters['id']!,
                      sprintId: state.pathParameters['sprintId']!,
                    ),
                  ),
                  GoRoute(
                    path: 'milestones',
                    builder: (context, state) => MilestoneListPage(projectId: state.pathParameters['id']!),
                  ),
                  GoRoute(
                    path: 'milestone/:milestoneId',
                    builder: (context, state) => MilestoneDetailPage(
                      projectId: state.pathParameters['id']!,
                      milestoneId: state.pathParameters['milestoneId']!,
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: 't/:id',
                builder: (context, state) => TaskDetailPage(taskId: state.pathParameters['id']!),
              ),
            ],
          ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/reports',
              builder: (context, state) => const ReportsCenterPage(),
              routes: [
                GoRoute(
                  path: 'attendance',
                  builder: (context, state) => AttendanceAnalyticsPage(profileId: state.uri.queryParameters['profile']),
                ),
                GoRoute(path: 'work', builder: (context, state) => const WorkAnalyticsPage()),
                GoRoute(path: 'leave', builder: (context, state) => const LeaveAnalyticsPage()),
                GoRoute(path: 'export', builder: (context, state) => const ExportPage()),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/notifications', builder: (context, state) => const InboxPage()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/settings', builder: (context, state) => const SettingsPage()),
          ]),
        ],
      ),
    ],
  );
});
