import 'package:flutter/widgets.dart';
import 'package:iconsax/iconsax.dart';

/// The only place in the app that names an icon glyph.
///
/// All glyphs come from the `iconsax` package (pinned 0.0.8). That package
/// ships six styles in one class, told apart by a numeric suffix:
/// no suffix is Linear and `5` is Bold. Suffixes `1` to `3` are layers of the
/// multi-colour styles and are never used here.
///
/// Rules:
/// * Linear is the default everywhere.
/// * Bold is used only for a selected navigation item or a filled status, and
///   only where the Bold glyph was checked by eye ([AppIcon.bold] is null
///   otherwise).
/// * Iconsax glyphs do not mirror in RTL. Direction-bearing icons below are
///   already chosen for a right-to-left layout: [back] points right.
///
/// Licence: package code GPL-3.0, artwork under the Iconsax licence.
/// See docs/third-party-licenses.md.
abstract final class AppIcons {
  // Navigation.
  static const home = AppIcon(Iconsax.home_2, Iconsax.home_25);
  static const attendance = AppIcon(Iconsax.clock, Iconsax.clock5);
  static const leave = AppIcon(Iconsax.calendar_2, Iconsax.calendar_25);
  static const work = AppIcon(Iconsax.task_square, Iconsax.task_square5);
  static const reports = AppIcon(Iconsax.chart_square, Iconsax.chart_square5);
  static const notifications = AppIcon(Iconsax.notification, Iconsax.notification5);
  static const notificationsUnread = AppIcon(Iconsax.notification_bing, Iconsax.notification_bing5);
  static const settings = AppIcon(Iconsax.setting_2, Iconsax.setting_25);
  static const more = AppIcon(Iconsax.element_4, Iconsax.element_45);
  static const sidebarCollapse = AppIcon(Iconsax.sidebar_right);
  static const sidebarExpand = AppIcon(Iconsax.sidebar_left);

  // Work.
  static const projects = AppIcon(Iconsax.folder_2, Iconsax.folder_25);
  static const myTasks = AppIcon(Iconsax.task);
  static const kanban = AppIcon(Iconsax.kanban);
  static const list = AppIcon(Iconsax.row_vertical, Iconsax.row_vertical5);
  static const calendar = AppIcon(Iconsax.calendar_1, Iconsax.calendar_15);
  static const priority = AppIcon(Iconsax.flag, Iconsax.flag5);
  static const due = AppIcon(Iconsax.timer_1, Iconsax.timer_15);
  static const checklist = AppIcon(Iconsax.tick_square, Iconsax.tick_square5);
  static const subtask = AppIcon(Iconsax.hierarchy_square_2, Iconsax.hierarchy_square_25);
  static const sprint = AppIcon(Iconsax.repeat, Iconsax.repeat5);
  static const milestone = AppIcon(Iconsax.routing_2, Iconsax.routing_25);
  static const label = AppIcon(Iconsax.tag, Iconsax.tag5);
  static const workflow = AppIcon(Iconsax.routing, Iconsax.routing5);
  static const activity = AppIcon(Iconsax.activity, Iconsax.activity5);
  static const reviews = AppIcon(Iconsax.message_text, Iconsax.message_text5);
  static const description = AppIcon(Iconsax.document_text, Iconsax.document_text5);
  static const approvalPolicy = AppIcon(Iconsax.shield_tick, Iconsax.shield_tick5);
  static const archive = AppIcon(Iconsax.archive, Iconsax.archive5);
  static const restore = AppIcon(Iconsax.rotate_left);
  static const restricted = AppIcon(Iconsax.lock, Iconsax.lock5);
  static const projectWide = AppIcon(Iconsax.global, Iconsax.global5);

  // People.
  static const person = AppIcon(Iconsax.user, Iconsax.user5);
  static const profile = AppIcon(Iconsax.profile_circle, Iconsax.profile_circle5);
  static const reviewer = AppIcon(Iconsax.user_tick, Iconsax.user_tick5);
  static const people = AppIcon(Iconsax.profile_2user, Iconsax.profile_2user5);
  static const team = AppIcon(Iconsax.people, Iconsax.people5);

  // Attendance and leave.
  static const clockIn = AppIcon(Iconsax.timer_start, Iconsax.timer_start5);
  static const clockOut = AppIcon(Iconsax.timer_pause, Iconsax.timer_pause5);
  static const customRange = AppIcon(Iconsax.calendar_edit, Iconsax.calendar_edit5);
  static const leaveApproved = AppIcon(Iconsax.calendar_tick, Iconsax.calendar_tick5);
  static const absence = AppIcon(Iconsax.calendar_remove, Iconsax.calendar_remove5);
  static const pending = AppIcon(Iconsax.clock, Iconsax.clock5);

  // Actions.
  static const search = AppIcon(Iconsax.search_normal_1);
  static const add = AppIcon(Iconsax.add);
  static const addBoxed = AppIcon(Iconsax.add_square, Iconsax.add_square5);
  static const edit = AppIcon(Iconsax.edit_2, Iconsax.edit_25);
  static const delete = AppIcon(Iconsax.trash, Iconsax.trash5);
  static const moreActions = AppIcon(Iconsax.more);
  static const filter = AppIcon(Iconsax.filter, Iconsax.filter5);
  static const sort = AppIcon(Iconsax.sort);
  static const export = AppIcon(Iconsax.document_download, Iconsax.document_download5);
  static const retry = AppIcon(Iconsax.refresh_circle, Iconsax.refresh_circle5);
  static const close = AppIcon(Iconsax.close_circle, Iconsax.close_circle5);
  static const signOut = AppIcon(Iconsax.logout, Iconsax.logout5);
  static const themeLight = AppIcon(Iconsax.sun_1, Iconsax.sun_15);
  static const themeDark = AppIcon(Iconsax.moon, Iconsax.moon5);

  // Decisions and states.
  static const approve = AppIcon(Iconsax.tick_circle, Iconsax.tick_circle5);
  static const reject = AppIcon(Iconsax.close_circle, Iconsax.close_circle5);
  static const revise = AppIcon(Iconsax.edit, Iconsax.edit5);
  static const warning = AppIcon(Iconsax.warning_2, Iconsax.warning_25);
  static const info = AppIcon(Iconsax.info_circle, Iconsax.info_circle5);
  static const error = AppIcon(Iconsax.danger, Iconsax.danger5);
  static const offline = AppIcon(Iconsax.cloud_cross, Iconsax.cloud_cross5);
  static const empty = AppIcon(Iconsax.document);

  // Direction, chosen for RTL.
  /// Back to the previous page: points right, towards the start edge.
  static const back = AppIcon(Iconsax.arrow_right_1);

  /// Open a row or go deeper: points left, towards the end edge.
  static const open = AppIcon(Iconsax.arrow_left_2);

  /// Earlier period (previous month or week). Sits on the start (right) side.
  static const previous = AppIcon(Iconsax.arrow_right_3);

  /// Later period. Sits on the end (left) side.
  static const next = AppIcon(Iconsax.arrow_left_2);
  static const moveUp = AppIcon(Iconsax.arrow_up_3);
  static const moveDown = AppIcon(Iconsax.arrow_down);
  static const expand = AppIcon(Iconsax.arrow_down_1);
  static const collapse = AppIcon(Iconsax.arrow_up_2);

  /// Every registered icon, for tests and the icon sheet.
  static const all = <String, AppIcon>{
    'home': home,
    'attendance': attendance,
    'leave': leave,
    'work': work,
    'reports': reports,
    'notifications': notifications,
    'notificationsUnread': notificationsUnread,
    'settings': settings,
    'more': more,
    'sidebarCollapse': sidebarCollapse,
    'sidebarExpand': sidebarExpand,
    'projects': projects,
    'myTasks': myTasks,
    'kanban': kanban,
    'list': list,
    'calendar': calendar,
    'priority': priority,
    'due': due,
    'checklist': checklist,
    'subtask': subtask,
    'sprint': sprint,
    'milestone': milestone,
    'label': label,
    'workflow': workflow,
    'activity': activity,
    'reviews': reviews,
    'description': description,
    'approvalPolicy': approvalPolicy,
    'archive': archive,
    'restore': restore,
    'restricted': restricted,
    'projectWide': projectWide,
    'person': person,
    'profile': profile,
    'reviewer': reviewer,
    'people': people,
    'team': team,
    'clockIn': clockIn,
    'clockOut': clockOut,
    'customRange': customRange,
    'leaveApproved': leaveApproved,
    'absence': absence,
    'pending': pending,
    'search': search,
    'add': add,
    'addBoxed': addBoxed,
    'edit': edit,
    'delete': delete,
    'moreActions': moreActions,
    'filter': filter,
    'sort': sort,
    'export': export,
    'retry': retry,
    'close': close,
    'signOut': signOut,
    'themeLight': themeLight,
    'themeDark': themeDark,
    'approve': approve,
    'reject': reject,
    'revise': revise,
    'warning': warning,
    'info': info,
    'error': error,
    'offline': offline,
    'empty': empty,
    'back': back,
    'open': open,
    'previous': previous,
    'next': next,
    'moveUp': moveUp,
    'moveDown': moveDown,
    'expand': expand,
    'collapse': collapse,
  };
}

/// A Linear glyph and, when one was verified, its Bold counterpart.
@immutable
class AppIcon {
  const AppIcon(this.linear, [this.bold]);

  final IconData linear;
  final IconData? bold;

  /// Bold when [selected] and a Bold glyph exists; Linear otherwise.
  IconData of({bool selected = false}) => selected ? (bold ?? linear) : linear;
}

/// Icon sizes. Use these instead of literal numbers.
abstract final class AppIconSize {
  static const inline = 16.0;
  static const control = 20.0;
  static const nav = 24.0;
}

/// An [Icon] from the registry. Decorative by default: when [semanticLabel] is
/// null the icon is excluded from the accessibility tree, because the control
/// around it (or the text beside it) carries the name.
class AppIconView extends StatelessWidget {
  const AppIconView(this.icon, {super.key, this.selected = false, this.size = AppIconSize.control, this.color, this.semanticLabel});

  final AppIcon icon;
  final bool selected;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      icon.of(selected: selected),
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );
    return semanticLabel == null ? ExcludeSemantics(child: glyph) : glyph;
  }
}
