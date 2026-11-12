import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_review.dart';
import '../session/workspace_session.dart';
import 'widgets/work_ui.dart';
import 'work_repository.dart';
import 'work_rules.dart';
import 'workflow_presentation.dart';

/// Reopening a final rejection needs management permission:
/// `tasks.manage.project`. Seeing every task (`tasks.view.all`) is not a right
/// to change a status (five-status model). This is stricter than today's
/// `rejected_closed` in `transition_task`, and the same as the v9 draft.
bool canReopenRejected(WorkspaceSession? session) => session != null && session.can('tasks.manage.project');

/// The actions a task offers right now: possible in the stored workflow and
/// allowed to this person. [canAct] is `canEditTask` for the task.
List<TaskAction> taskActions(TaskRow task, WorkflowRow? flow, {required bool canAct, required WorkspaceSession? session}) => [
  for (final action in TaskAction.values)
    if (actionPath(task, flow, action) != null && actionPermitted(task, action, canAct: canAct, session: session)) action,
];

/// [actionAllowed] for the signed-in person.
bool actionPermitted(TaskRow task, TaskAction action, {required bool canAct, required WorkspaceSession? session}) =>
    actionAllowed(task, action, isAssignee: session != null && task.assigneeId == session.profileId, canEdit: canAct, canReopenRejected: canReopenRejected(session));


/// Runs one action: confirmation, then the chain of existing, audited
/// `transition_task` calls the stored workflow allows (see [actionPath]).
/// Each step is re-checked by the server and writes its own activity event
/// and audit entry; nothing is written directly. A required-subtask refusal
/// on the way to "done" asks for the override reason, exactly as before.
/// Returns true when the task reached its target.
Future<bool> runTaskAction(BuildContext context, WidgetRef ref, TaskRow task, WorkflowRow? flow, TaskAction action) async {
  final client = ref.read(supabaseClientProvider);
  final messenger = ScaffoldMessenger.of(context);
  if (client == null) return false;
  final path = actionPath(task, flow, action);
  if (path == null) {
    messenger.showSnackBar(SnackBar(content: Text(action == TaskAction.returnToCycle && isFinalRejected(task) ? Fa.returnNeedsMigration : Fa.actionUnavailable)));
    return false;
  }
  final landing = groupLabel(groupOfCategory(path.last.category));
  final (title, body) = switch (action) {
    TaskAction.start => (Fa.confirmStartTitle, Fa.confirmStartBody),
    TaskAction.submit => (Fa.confirmSubmitTitle, Fa.confirmSubmitBody),
    TaskAction.complete => (Fa.confirmCompleteTitle, Fa.confirmCompleteBody),
    TaskAction.returnToCycle => (Fa.confirmReturnTitle, isBlockedTask(task) ? Fa.confirmReturnBlocked(landing) : Fa.confirmReturnRejected),
    TaskAction.block => (Fa.confirmBlockTitle, Fa.confirmBlockBody),
  };
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final p = paletteOf(context);
      return AlertDialog(
        key: const Key('action-confirm'),
        icon: AppIconView(actionIcon(action), size: 28, color: action == TaskAction.block ? p.alert : p.jade),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Fa.cancel)),
          FilledButton(key: const Key('action-confirm-ok'), onPressed: () => Navigator.pop(context, true), child: Text(actionLabel(action))),
        ],
      );
    },
  );
  if (confirmed != true) return false;
  final repo = WorkRepository(client);
  try {
    for (final step in path) {
      try {
        await repo.transition(task.id, step.id);
      } catch (error) {
        if (!error.toString().contains('subtasks_incomplete') || !context.mounted) rethrow;
        final reason = await askDecision(context, title: Fa.overrideSubtasks, reasonRequired: true);
        if (reason == null) return false;
        await repo.transition(task.id, step.id, overrideReason: reason.trim());
      }
    }
    messenger.showSnackBar(const SnackBar(content: Text(Fa.actionDone)));
    return true;
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(taskErrorText(error))));
    return false;
  }
}
