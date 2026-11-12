import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/features/session/workspace_session.dart';
import 'package:jibhr/features/shell/navigation.dart';

WorkspaceSession _session(Set<String> permissions) => WorkspaceSession(
      profileId: 'p',
      firstName: 'سارا',
      lastName: 'احمدی',
      status: 'active',
      mustChangePassword: false,
      permissions: permissions,
    );

List<String> _ids(WorkspaceSession? s) => navDestinations(s).map((d) => d.id).toList();

void main() {
  group('who sees what', () {
    test('signed out sees home and settings only', () {
      expect(_ids(null), ['home', 'settings']);
    });

    test('a person with no feature permission still gets reports, inbox, settings', () {
      expect(_ids(_session({})), ['home', 'reports', 'notifications', 'settings']);
    });

    test('employee', () {
      final s = _session({'attendance.view.self', 'attendance.clock', 'leave.request', 'leave.view.self', 'tasks.create.personal'});
      expect(_ids(s), ['home', 'attendance', 'leave', 'work', 'reports', 'notifications', 'settings']);
    });

    test('attendance appears for any one of its five permissions', () {
      for (final key in ['attendance.view.self', 'attendance.clock', 'attendance.approve.team', 'attendance.approve.all', 'attendance.correct.self']) {
        expect(_ids(_session({key})), contains('attendance'), reason: key);
      }
    });

    test('work appears for project permissions without task ones', () {
      expect(_ids(_session({'projects.view.all'})), contains('work'));
      expect(_ids(_session({'leave.request'})), isNot(contains('work')));
    });

    test('leave appears for absence permissions alone', () {
      expect(_ids(_session({'absence.view.self'})), contains('leave'));
    });
  });

  group('active destination', () {
    final all = navDestinations(_session({'attendance.view.self', 'leave.request', 'tasks.create.personal'}));
    NavDestination? at(String path) => activeDestination(path, all);

    test('home only on the root', () {
      expect(at('/')?.id, 'home');
      expect(at('/unknown'), isNull);
    });

    test('nested paths belong to their section', () {
      expect(at('/attendance/approvals')?.id, 'attendance');
      expect(at('/work/p/1/sprint/2')?.id, 'work');
      expect(at('/leave/queue')?.id, 'leave');
    });

    test('reports and notifications no longer light up home', () {
      expect(at('/reports/attendance')?.id, 'reports');
      expect(at('/reports')?.id, 'reports');
      expect(at('/notifications')?.id, 'notifications');
    });

    test('a path that only shares a prefix does not match', () {
      expect(at('/workshop'), isNull);
    });
  });

  test('every destination a role can see has its own router branch', () {
    final everything = navDestinations(_session({
      'attendance.view.self', 'leave.request', 'tasks.create.personal', 'projects.view.all',
    }));
    final indexes = everything.map((d) => branchIndexOf(d.id)).toList();
    expect(indexes.toSet().length, everything.length);
    expect(branchOrder.length, everything.length);
    expect(() => branchIndexOf('nope'), throwsArgumentError);
  });

  group('bottom bar split', () {
    test('five or fewer stay in the bar', () {
      final few = navDestinations(_session({}));
      final split = splitForBottomBar(few);
      expect(split.bar.length, few.length);
      expect(split.overflow, isEmpty);
    });

    test('seven become four plus more', () {
      final all = navDestinations(_session({'attendance.view.self', 'leave.request', 'tasks.create.personal'}));
      final split = splitForBottomBar(all);
      expect(split.bar.map((d) => d.id), ['home', 'attendance', 'work', 'leave']);
      expect(split.overflow.map((d) => d.id), ['reports', 'notifications', 'settings']);
    });

    test('six without work fill the bar in order', () {
      final six = navDestinations(_session({'attendance.view.self', 'leave.request'}));
      final split = splitForBottomBar(six);
      expect(split.bar.length, 4);
      expect([...split.bar, ...split.overflow].length, six.length);
    });
  });
}
