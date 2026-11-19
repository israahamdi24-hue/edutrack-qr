import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../models/app_user.dart';
import '../../../services/edutrack_api_client.dart';
import '../services/admin_data_service.dart';
import '../widgets/admin_attendance_charts.dart';

class AdminWorkspaceScreen extends StatefulWidget {
  const AdminWorkspaceScreen({
    super.key,
    required this.sectionIndex,
    this.service,
  });
  final int sectionIndex;
  final AdminDataService? service;

  @override
  State<AdminWorkspaceScreen> createState() => _AdminWorkspaceScreenState();
}

class _AdminWorkspaceScreenState extends State<AdminWorkspaceScreen> {
  late Future<AdminWorkspaceData> _data;
  bool _working = false;
  final _userSearchController = TextEditingController();
  final _classSearchController = TextEditingController();
  final _enrollmentSearchController = TextEditingController();
  final _notificationTitleController = TextEditingController();
  final _notificationMessageController = TextEditingController();
  AppRole? _userRoleFilter;
  String? _classLevelFilter;
  String? _enrollmentClassFilter;
  String _notificationAudience = 'students';
  DateTimeRange? _attendanceDateRange;
  String? _attendanceStudentUid;
  String? _attendanceTeacherUid;
  String? _attendanceClassId;
  String? _attendanceSubjectId;
  String? _attendanceCourseId;
  String? _attendanceSessionId;
  String _attendanceStatus = 'all';
  AdminDataService get _service => widget.service ?? AdminDataService();

  @override
  void initState() {
    super.initState();
    _data = _service.load();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _data = _service.load();
    });
  }

  @override
  void dispose() {
    _userSearchController.dispose();
    _classSearchController.dispose();
    _enrollmentSearchController.dispose();
    _notificationTitleController.dispose();
    _notificationMessageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AdminWorkspaceData>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(),
          ),
        );
      }
      if (snapshot.hasError) {
        return _AdminError(error: snapshot.error!, retry: _reload);
      }
      final data = snapshot.data!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(_title, style: _titleStyle)),
              IconButton(
                tooltip: 'Actualiser',
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 14),
          switch (widget.sectionIndex) {
            0 => _dashboard(data),
            1 => _users(data),
            2 => _management(data),
            3 => _statistics(data),
            4 => _notifications(data),
            _ => const SizedBox.shrink(),
          },
        ],
      );
    },
  );

  String get _title => switch (widget.sectionIndex) {
    0 => 'Tableau de bord administrateur',
    1 => 'Étudiants et enseignants',
    2 => 'Gestion académique',
    3 => 'Statistiques des présences',
    4 => 'Notifications administratives',
    _ => 'Administration EduTrack',
  };

  Widget _dashboard(AdminWorkspaceData data) {
    final now = DateTime.now();
    final students = data.users
        .where((user) => user.role == AppRole.student)
        .length;
    final teachers = data.users
        .where((user) => user.role == AppRole.teacher)
        .length;
    final present = data.attendance
        .where((item) => item.status == 'present' || item.status == 'late')
        .length;
    final rate = data.attendance.isEmpty
        ? null
        : present / data.attendance.length;
    final openSessions = data.sessions
        .where(
          (session) =>
              !session.startsAt.isAfter(now) &&
              (session.endsAt == null || session.endsAt!.isAfter(now)),
        )
        .length;
    final completedSessions = data.sessions
        .where(
          (session) => session.endsAt != null && !session.endsAt!.isAfter(now),
        )
        .length;
    final absenceCounts = <String, int>{};
    for (final record in data.attendance.where(
      (record) => record.status == 'absent',
    )) {
      absenceCounts.update(
        record.studentUid,
        (currentCount) => currentCount + 1,
        ifAbsent: () => 1,
      );
    }
    final repeatedAbsenceCount = absenceCounts.values
        .where((absenceCount) => absenceCount >= 2)
        .length;
    final recentSessions = [...data.sessions]
      ..sort((a, b) => b.startsAt.compareTo(a.startsAt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MetricGrid(
          items: [
            ('Étudiants', '$students', Icons.school_outlined),
            ('Enseignants', '$teachers', Icons.co_present_outlined),
            ('Classes', '${data.classes.length}', Icons.school_outlined),
            ('Matières', '${data.subjects.length}', Icons.menu_book_outlined),
            ('Cours', '${data.courses.length}', Icons.menu_book_outlined),
            ('Séances', '${data.sessions.length}', Icons.event_outlined),
            ('Séances ouvertes', '$openSessions', Icons.play_circle_outline),
            (
              'Séances terminées',
              '$completedSessions',
              Icons.event_available_outlined,
            ),
            (
              'Absences répétées (≥ 2)',
              '$repeatedAbsenceCount',
              Icons.warning_amber_outlined,
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          rate == null
              ? 'Aucun pointage serveur disponible.'
              : 'Présence constatée sur les pointages enregistrés : ${(rate * 100).round()}%',
          style: const TextStyle(color: AppColors.secondary),
        ),
        const SizedBox(height: 18),
        const Text('Séances récentes', style: _sectionStyle),
        const SizedBox(height: 8),
        if (recentSessions.isEmpty)
          const _AdminEmpty('Aucune séance enregistrée.')
        else
          for (final session in recentSessions.take(5))
            _sessionCard(session, data.courses),
        const SizedBox(height: 16),
        const Text('Pointages récents', style: _sectionStyle),
        const SizedBox(height: 8),
        if (data.attendance.isEmpty)
          const _AdminEmpty('Aucun pointage serveur enregistré.')
        else
          for (final record in ([
            ...data.attendance,
          ]..sort((a, b) => b.recordedAt.compareTo(a.recordedAt))).take(5))
            ListTile(
              leading: Icon(
                _statusIcon(record.status),
                color: _statusColor(record.status),
              ),
              title: Text(_userLabel(data.users, record.studentUid)),
              subtitle: Text(_courseLabel(data.courses, record.courseId)),
              trailing: Text(_statusLabel(record.status)),
            ),
      ],
    );
  }

  Widget _users(AdminWorkspaceData data) {
    if (data.users.isEmpty)
      return const _AdminEmpty('Aucun profil utilisateur.');
    final query = _userSearchController.text.trim().toLowerCase();
    final users = data.users.where((user) {
      final matchesRole =
          _userRoleFilter == null || user.role == _userRoleFilter;
      final matchesQuery =
          query.isEmpty ||
          user.displayName.toLowerCase().contains(query) ||
          user.email.toLowerCase().contains(query) ||
          user.uid.toLowerCase().contains(query) ||
          (user.className?.toLowerCase().contains(query) ?? false);
      return matchesRole && matchesQuery;
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Les comptes enseignant et administrateur sont provisionnés manuellement dans un environnement de confiance. Cette page ne permet pas de modifier les rôles.',
          style: TextStyle(color: AppColors.secondary, height: 1.45),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _userSearchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Rechercher un utilisateur',
            hintText: 'Nom, e-mail, UID ou classe',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Effacer la recherche',
                    onPressed: () {
                      _userSearchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.clear),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in <(AppRole?, String)>[
              (null, 'Tous'),
              (AppRole.student, 'Étudiants'),
              (AppRole.teacher, 'Enseignants'),
              (AppRole.admin, 'Administrateurs'),
            ])
              ChoiceChip(
                label: Text(entry.$2),
                selected: _userRoleFilter == entry.$1,
                onSelected: (_) => setState(() => _userRoleFilter = entry.$1),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (users.isEmpty)
          const _AdminEmpty('Aucun utilisateur ne correspond à ces filtres.'),
        for (final user in users)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(child: Icon(_roleIcon(user.role))),
              title: Text(user.displayName),
              subtitle: Text(
                '${user.email}\n${user.role.label} • ${user.isActive ? 'Actif' : 'Désactivé'}${user.className?.isNotEmpty == true ? ' • ${user.className}' : ''}',
              ),
              isThreeLine: true,
              onTap: () => _showUserDetails(user, data),
              trailing: Wrap(
                children: [
                  if (user.role == AppRole.student)
                    IconButton(
                      tooltip: 'Attribuer une classe',
                      onPressed: _working
                          ? null
                          : () => _editStudentClass(user),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  if (user.role != AppRole.admin)
                    IconButton(
                      tooltip: user.isActive
                          ? 'Désactiver le compte'
                          : 'Activer le compte',
                      onPressed: _working
                          ? null
                          : () => _toggleUserStatus(user),
                      icon: Icon(
                        user.isActive
                            ? Icons.person_off_outlined
                            : Icons.person_outline,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _showUserDetails(
    AppUser user,
    AdminWorkspaceData data,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(user.displayName),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Rôle : ${user.role.label}'),
          Text('Compte : ${user.isActive ? 'Actif' : 'Désactivé'}'),
          const SizedBox(height: 8),
          SelectableText('E-mail : ${user.email}'),
          const SizedBox(height: 8),
          SelectableText('UID : ${user.uid}'),
          if (user.className?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text('Classe : ${user.className}'),
          ],
          if (user.role == AppRole.student) ...[
            const SizedBox(height: 12),
            const Text('Inscriptions actives', style: _sectionStyle),
            for (final enrollment
                in data.enrollments
                    .where(
                      (item) =>
                          item.studentUid == user.uid &&
                          item.status == 'active',
                    )
                    .take(10))
              Text(
                '• ${_courseLabel(data.courses, enrollment.courseId)}${enrollment.classId == null ? '' : ' — ${_classLabel(data.classes, enrollment.classId!)}'}',
              ),
          ],
          if (user.role == AppRole.teacher) ...[
            const SizedBox(height: 12),
            const Text('Cours affectés', style: _sectionStyle),
            for (final course
                in data.courses
                    .where((item) => item.teacherUid == user.uid)
                    .take(10))
              Text('• ${course.name}'),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );

  Widget _management(AdminWorkspaceData data) => DefaultTabController(
    length: 6,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TabBar(
          isScrollable: true,
          tabs: [
            Tab(text: 'Cours'),
            Tab(text: 'Inscriptions'),
            Tab(text: 'Séances'),
            Tab(text: 'Classes'),
            Tab(text: 'Matières'),
            Tab(text: 'Affectations'),
          ],
        ),
        SizedBox(
          height: 560,
          child: TabBarView(
            children: [
              _courseList(data),
              _enrollmentList(data),
              _sessionList(data),
              _classList(data),
              _subjectList(data),
              _assignmentList(data),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _courseList(AdminWorkspaceData data) => ListView(
    padding: const EdgeInsets.only(top: 12),
    children: [
      FilledButton.icon(
        onPressed:
            _working ||
                data.users
                    .where((u) => u.role == AppRole.teacher && u.isActive)
                    .isEmpty
            ? null
            : () => _createCourse(data),
        icon: const Icon(Icons.add),
        label: const Text('Créer un cours et affecter un enseignant'),
      ),
      const SizedBox(height: 10),
      if (data.courses.isEmpty)
        const _AdminEmpty('Aucun cours dans Firestore.'),
      for (final course in data.courses)
        Card(
          child: ListTile(
            leading: const Icon(
              Icons.menu_book_outlined,
              color: AppColors.primary,
            ),
            title: Text(course.name),
            subtitle: Text(
              'Enseignant : ${course.teacherName}\n${data.enrollments.where((e) => e.courseId == course.id && e.status == 'active').length} inscription(s) active(s)',
            ),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: 'Modifier le cours ou l’affectation',
              onPressed: _working
                  ? null
                  : () => _editCourse(
                      course,
                      data.users
                          .where((u) => u.role == AppRole.teacher && u.isActive)
                          .toList(),
                    ),
              icon: const Icon(Icons.edit_outlined),
            ),
          ),
        ),
    ],
  );

  Widget _enrollmentList(AdminWorkspaceData data) {
    final query = _enrollmentSearchController.text.trim().toLowerCase();
    final enrollments = data.enrollments.where((enrollment) {
      final student = data.users
          .where((user) => user.uid == enrollment.studentUid)
          .firstOrNull;
      final course = data.courses
          .where((item) => item.id == enrollment.courseId)
          .firstOrNull;
      final matchesClass =
          _enrollmentClassFilter == null ||
          enrollment.classId == _enrollmentClassFilter;
      final matchesQuery =
          query.isEmpty ||
          (student?.displayName.toLowerCase().contains(query) ?? false) ||
          (student?.email.toLowerCase().contains(query) ?? false) ||
          (course?.name.toLowerCase().contains(query) ?? false);
      return matchesClass && matchesQuery;
    }).toList();
    return ListView(
      padding: const EdgeInsets.only(top: 12),
      children: [
        FilledButton.icon(
          onPressed:
              _working ||
                  data.courses.isEmpty ||
                  data.users
                      .where((u) => u.role == AppRole.student && u.isActive)
                      .isEmpty
              ? null
              : () => _addEnrollment(data),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Inscrire un étudiant'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _enrollmentSearchController,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Rechercher un étudiant ou un cours',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue:
              _enrollmentClassFilter != null &&
                  data.classes.any((item) => item.id == _enrollmentClassFilter)
              ? _enrollmentClassFilter
              : 'all',
          decoration: const InputDecoration(labelText: 'Filtrer par classe'),
          items: [
            const DropdownMenuItem(
              value: 'all',
              child: Text('Toutes les classes'),
            ),
            for (final item in data.classes)
              DropdownMenuItem(
                value: item.id,
                child: Text('${item.name} • ${item.group}'),
              ),
          ],
          onChanged: (value) => setState(
            () => _enrollmentClassFilter = value == null || value == 'all'
                ? null
                : value,
          ),
        ),
        const SizedBox(height: 8),
        if (enrollments.isEmpty)
          const _AdminEmpty('Aucune inscription ne correspond aux filtres.'),
        for (final enrollment in enrollments)
          Card(
            child: ListTile(
              leading: const Icon(Icons.assignment_ind_outlined),
              title: Text(_userLabel(data.users, enrollment.studentUid)),
              subtitle: Text(
                '${_courseLabel(data.courses, enrollment.courseId)}${enrollment.classId == null ? '' : ' • ${_classLabel(data.classes, enrollment.classId!)}'} • ${enrollment.status}',
              ),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: enrollment.status == 'active'
                        ? 'Désactiver l’inscription'
                        : 'Réactiver l’inscription',
                    onPressed: _working
                        ? null
                        : () => _run(
                            () => _service.updateEnrollmentStatus(
                              enrollment.id,
                              enrollment.status == 'active'
                                  ? 'inactive'
                                  : 'active',
                            ),
                          ),
                    icon: Icon(
                      enrollment.status == 'active'
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Supprimer l’inscription',
                    onPressed: _working
                        ? null
                        : () => _removeEnrollment(enrollment),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _sessionList(AdminWorkspaceData data) => ListView(
    padding: const EdgeInsets.only(top: 12),
    children: [
      FilledButton.icon(
        onPressed: _working || data.courses.isEmpty
            ? null
            : () => _createSession(data),
        icon: const Icon(Icons.add),
        label: const Text('Créer une séance'),
      ),
      const SizedBox(height: 10),
      if (data.sessions.isEmpty)
        const _AdminEmpty('Aucune séance enregistrée.'),
      for (final session in [
        ...data.sessions,
      ]..sort((a, b) => a.startsAt.compareTo(b.startsAt)))
        _sessionCard(session, data.courses, allowActions: true),
    ],
  );

  Widget _classList(AdminWorkspaceData data) {
    final query = _classSearchController.text.trim().toLowerCase();
    final levels = data.classes.map((item) => item.level).toSet().toList()
      ..sort();
    final classes = data.classes.where((item) {
      final matchesLevel =
          _classLevelFilter == null || item.level == _classLevelFilter;
      final haystack =
          '${item.name} ${item.group} ${item.level} ${item.academicYear}'
              .toLowerCase();
      return matchesLevel && (query.isEmpty || haystack.contains(query));
    }).toList();
    return ListView(
      padding: const EdgeInsets.only(top: 12),
      children: [
        FilledButton.icon(
          onPressed: _working ? null : () => _editClassRecord(data),
          icon: const Icon(Icons.add),
          label: const Text('Créer une classe'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _classSearchController,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Rechercher une classe',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Tous les niveaux'),
              selected: _classLevelFilter == null,
              onSelected: (_) => setState(() => _classLevelFilter = null),
            ),
            for (final level in levels)
              ChoiceChip(
                label: Text(level),
                selected: _classLevelFilter == level,
                onSelected: (_) => setState(() => _classLevelFilter = level),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (classes.isEmpty)
          const _AdminEmpty('Aucune classe ne correspond aux filtres.'),
        for (final item in classes)
          Card(
            child: ListTile(
              title: Text('${item.name} • ${item.group}'),
              subtitle: Text('${item.level} • ${item.academicYear}'),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: 'Modifier la classe',
                    onPressed: _working
                        ? null
                        : () => _editClassRecord(data, item: item),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Supprimer la classe',
                    onPressed: _working
                        ? null
                        : () => _confirmRemoveClass(item),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _subjectList(AdminWorkspaceData data) => ListView(
    padding: const EdgeInsets.only(top: 12),
    children: [
      FilledButton.icon(
        onPressed: _working || data.classes.isEmpty
            ? null
            : () => _editSubjectRecord(data),
        icon: const Icon(Icons.add),
        label: const Text('Créer une matière'),
      ),
      const SizedBox(height: 10),
      if (data.classes.isEmpty)
        const _AdminEmpty(
          'Créez au moins une classe avant d’associer une matière.',
        ),
      if (data.subjects.isEmpty && data.classes.isNotEmpty)
        const _AdminEmpty('Aucune matière enregistrée.'),
      for (final subject in data.subjects)
        Card(
          child: ListTile(
            title: Text(subject.name),
            subtitle: Text(
              '${subject.classIds.length} classe(s) associée(s)${subject.description?.isNotEmpty == true ? '\n${subject.description}' : ''}',
            ),
            isThreeLine: subject.description?.isNotEmpty == true,
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Modifier la matière',
                  onPressed: _working
                      ? null
                      : () => _editSubjectRecord(data, subject: subject),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Supprimer la matière',
                  onPressed: _working
                      ? null
                      : () => _confirmRemoveSubject(subject),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _assignmentList(AdminWorkspaceData data) => ListView(
    padding: const EdgeInsets.only(top: 12),
    children: [
      FilledButton.icon(
        onPressed:
            _working ||
                data.classes.isEmpty ||
                data.subjects.isEmpty ||
                data.users.every(
                  (user) => user.role != AppRole.teacher || !user.isActive,
                )
            ? null
            : () => _editAssignmentRecord(data),
        icon: const Icon(Icons.assignment_ind_outlined),
        label: const Text('Créer une affectation enseignant'),
      ),
      const SizedBox(height: 10),
      if (data.teacherAssignments.isEmpty)
        const _AdminEmpty('Aucune affectation enseignant enregistrée.'),
      for (final assignment in data.teacherAssignments)
        Card(
          child: ListTile(
            leading: Icon(
              assignment.status == 'active'
                  ? Icons.check_circle_outline
                  : Icons.pause_circle_outline,
            ),
            title: Text(_userLabel(data.users, assignment.teacherId)),
            subtitle: Text(
              '${_classLabel(data.classes, assignment.classId)} • ${_subjectLabel(data.subjects, assignment.subject)} • ${assignment.status}',
            ),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Modifier l’affectation',
                  onPressed: _working
                      ? null
                      : () =>
                            _editAssignmentRecord(data, assignment: assignment),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: assignment.status == 'active'
                      ? 'Désactiver l’affectation'
                      : 'Réactiver l’affectation',
                  onPressed: _working
                      ? null
                      : () => _toggleAssignmentStatus(assignment, data),
                  icon: Icon(
                    assignment.status == 'active'
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                  ),
                ),
                IconButton(
                  tooltip: 'Supprimer l’affectation',
                  onPressed: _working
                      ? null
                      : () => _confirmRemoveAssignment(assignment),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _sessionCard(
    AdminSession session,
    List<AdminCourse> courses, {
    bool allowActions = false,
  }) {
    final course = courses.where((c) => c.id == session.courseId).firstOrNull;
    final now = DateTime.now();
    final status = session.startsAt.isAfter(now)
        ? 'Planifiée'
        : session.endsAt != null && !session.endsAt!.isAfter(now)
        ? 'Terminée'
        : 'En cours';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.event_outlined, color: AppColors.primary),
        title: Text(course?.name ?? 'Cours'),
        subtitle: Text(
          '${_sessionLabel(session)} • $status${course == null ? '' : ' • ${course.teacherName}'}${session.room?.isNotEmpty == true ? ' • ${session.room}' : ''}',
        ),
        trailing: allowActions
            ? Wrap(
                spacing: 0,
                children: [
                  IconButton(
                    tooltip: 'Modifier la séance',
                    onPressed: _working
                        ? null
                        : () => _editSession(session, course),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Supprimer la séance',
                    onPressed: _working ? null : () => _removeSession(session),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Widget _statistics(AdminWorkspaceData data) {
    final filtered = _filteredAttendance(data);
    final recentAttendance = [...filtered]
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    final present = filtered.where((r) => r.status == 'present').length;
    final late = filtered.where((r) => r.status == 'late').length;
    final absent = filtered.where((r) => r.status == 'absent').length;
    final known = present + late + absent;
    final attendanceRate = known == 0 ? null : (present + late) / known;
    final absenceRate = known == 0 ? null : absent / known;
    final names = {for (final course in data.courses) course.id: course.name};
    final absencesByStudent = <String, int>{};
    for (final record in filtered.where(
      (record) => record.status == 'absent',
    )) {
      absencesByStudent.update(
        record.studentUid,
        (currentCount) => currentCount + 1,
        ifAbsent: () => 1,
      );
    }
    final repeatedAbsences =
        absencesByStudent.entries.where((entry) => entry.value >= 2).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Les indicateurs utilisent uniquement les documents attendance réellement enregistrés. Aucune absence n’est déduite d’un pointage manquant.',
          style: TextStyle(color: AppColors.secondary, height: 1.45),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            _reportDropdown('Étudiant', _attendanceStudentUid, [
              for (final user in data.users.where(
                (user) => user.role == AppRole.student,
              ))
                (user.uid, user.displayName),
            ], (value) => setState(() => _attendanceStudentUid = value)),
            _reportDropdown('Enseignant', _attendanceTeacherUid, [
              for (final user in data.users.where(
                (user) => user.role == AppRole.teacher,
              ))
                (user.uid, user.displayName),
            ], (value) => setState(() => _attendanceTeacherUid = value)),
            _reportDropdown('Classe', _attendanceClassId, [
              for (final item in data.classes)
                (item.id, '${item.name} • ${item.group}'),
            ], (value) => setState(() => _attendanceClassId = value)),
            _reportDropdown('Matière', _attendanceSubjectId, [
              for (final item in data.subjects) (item.id, item.name),
            ], (value) => setState(() => _attendanceSubjectId = value)),
            _reportDropdown('Cours', _attendanceCourseId, [
              for (final item in data.courses) (item.id, item.name),
            ], (value) => setState(() => _attendanceCourseId = value)),
            _reportDropdown('Séance', _attendanceSessionId, [
              for (final item in data.sessions) (item.id, _sessionLabel(item)),
            ], (value) => setState(() => _attendanceSessionId = value)),
            _reportDropdown(
              'Statut',
              _attendanceStatus == 'all' ? null : _attendanceStatus,
              const [
                ('present', 'Présent'),
                ('late', 'Retard'),
                ('absent', 'Absent'),
              ],
              (value) => setState(() => _attendanceStatus = value ?? 'all'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                final today = DateTime.now();
                final range = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(today.year + 2),
                  initialDateRange: _attendanceDateRange,
                );
                if (range != null) setState(() => _attendanceDateRange = range);
              },
              icon: const Icon(Icons.date_range),
              label: Text(
                _attendanceDateRange == null
                    ? 'Filtrer par période'
                    : '${_dateLabel(_attendanceDateRange!.start)} – ${_dateLabel(_attendanceDateRange!.end)}',
              ),
            ),
            if (_hasAttendanceFilters)
              TextButton.icon(
                onPressed: () => setState(() {
                  _attendanceDateRange = null;
                  _attendanceStudentUid = null;
                  _attendanceTeacherUid = null;
                  _attendanceClassId = null;
                  _attendanceSubjectId = null;
                  _attendanceCourseId = null;
                  _attendanceSessionId = null;
                  _attendanceStatus = 'all';
                }),
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Effacer les filtres'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${filtered.length} enregistrement(s) correspondent aux filtres.',
          style: const TextStyle(color: AppColors.secondary),
        ),
        const SizedBox(height: 12),
        _MetricGrid(
          items: [
            ('Présents', '$present', Icons.check_circle_outline),
            ('Retards', '$late', Icons.schedule),
            ('Absences enregistrées', '$absent', Icons.cancel_outlined),
            (
              'Taux de présence',
              attendanceRate == null
                  ? '—'
                  : '${(attendanceRate * 100).round()}%',
              Icons.analytics_outlined,
            ),
            (
              'Taux d’absence',
              absenceRate == null ? '—' : '${(absenceRate * 100).round()}%',
              Icons.trending_down,
            ),
          ],
        ),
        const SizedBox(height: 14),
        AdminAttendanceCharts(
          records: filtered,
          periodStart: _attendanceDateRange?.start,
          periodEnd: _attendanceDateRange?.end,
        ),
        const SizedBox(height: 18),
        const Text(
          'Absences répétées (au moins deux absences enregistrées)',
          style: _sectionStyle,
        ),
        if (repeatedAbsences.isEmpty)
          const _AdminEmpty(
            'Aucune absence répétée parmi les enregistrements filtrés.',
          ),
        for (final entry in repeatedAbsences.take(20))
          ListTile(
            leading: const Icon(
              Icons.warning_amber_outlined,
              color: Colors.orange,
            ),
            title: Text(_userLabel(data.users, entry.key)),
            subtitle: Text('${entry.value} absences enregistrées'),
          ),
        const SizedBox(height: 8),
        const Text('Enregistrements de présence', style: _sectionStyle),
        if (filtered.isEmpty)
          const _AdminEmpty('Aucun pointage ne correspond aux filtres.'),
        for (final item in recentAttendance.take(40))
          ListTile(
            dense: true,
            leading: Icon(
              _statusIcon(item.status),
              color: _statusColor(item.status),
            ),
            title: Text(names[item.courseId] ?? 'Cours'),
            subtitle: Text(
              '${_userLabel(data.users, item.studentUid)} • Séance ${item.sessionId} • ${_dateLabel(item.recordedAt)}',
            ),
            trailing: Text(_statusLabel(item.status)),
          ),
      ],
    );
  }

  bool get _hasAttendanceFilters =>
      _attendanceDateRange != null ||
      _attendanceStudentUid != null ||
      _attendanceTeacherUid != null ||
      _attendanceClassId != null ||
      _attendanceSubjectId != null ||
      _attendanceCourseId != null ||
      _attendanceSessionId != null ||
      _attendanceStatus != 'all';

  List<AdminAttendance> _filteredAttendance(AdminWorkspaceData data) {
    final courses = {for (final course in data.courses) course.id: course};
    final range = _attendanceDateRange;
    return data.attendance.where((record) {
      final course = courses[record.courseId];
      if (_attendanceStudentUid != null &&
          record.studentUid != _attendanceStudentUid)
        return false;
      if (_attendanceTeacherUid != null &&
          course?.teacherUid != _attendanceTeacherUid)
        return false;
      if (_attendanceClassId != null &&
          !data.enrollments.any(
            (enrollment) =>
                enrollment.studentUid == record.studentUid &&
                enrollment.courseId == record.courseId &&
                enrollment.classId == _attendanceClassId,
          ))
        return false;
      if (_attendanceSubjectId != null &&
          !data.teacherAssignments.any(
            (assignment) =>
                assignment.id == record.courseId &&
                assignment.subject == _attendanceSubjectId,
          ))
        return false;
      if (_attendanceCourseId != null && record.courseId != _attendanceCourseId)
        return false;
      if (_attendanceSessionId != null &&
          record.sessionId != _attendanceSessionId)
        return false;
      if (_attendanceStatus != 'all' && record.status != _attendanceStatus)
        return false;
      if (range != null &&
          (record.recordedAt.isBefore(range.start) ||
              record.recordedAt.isAfter(
                DateTime(
                  range.end.year,
                  range.end.month,
                  range.end.day,
                  23,
                  59,
                  59,
                ),
              )))
        return false;
      return true;
    }).toList();
  }

  Widget _reportDropdown(
    String label,
    String? selected,
    List<(String, String)> options,
    ValueChanged<String?> onChanged,
  ) => SizedBox(
    width: 210,
    child: DropdownButtonFormField<String>(
      initialValue:
          selected != null && options.any((option) => option.$1 == selected)
          ? selected
          : 'all',
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        const DropdownMenuItem(value: 'all', child: Text('Tous')),
        for (final option in options)
          DropdownMenuItem(
            value: option.$1,
            child: Text(option.$2, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) =>
          onChanged(value == null || value == 'all' ? null : value),
    ),
  );

  Widget _notifications(AdminWorkspaceData data) {
    final recipients = data.users
        .where(
          (user) =>
              user.isActive &&
              switch (_notificationAudience) {
                'students' => user.role == AppRole.student,
                'teachers' => user.role == AppRole.teacher,
                'staff' =>
                  user.role == AppRole.admin || user.role == AppRole.teacher,
                _ => true,
              },
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Les notifications sont enregistrées dans le profil de chaque destinataire et apparaissent dans son espace EduTrack.',
          style: TextStyle(color: AppColors.secondary, height: 1.45),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: _notificationAudience,
          decoration: const InputDecoration(labelText: 'Destinataires'),
          items: const [
            DropdownMenuItem(value: 'students', child: Text('Étudiants')),
            DropdownMenuItem(value: 'teachers', child: Text('Enseignants')),
            DropdownMenuItem(
              value: 'staff',
              child: Text('Enseignants et administrateurs'),
            ),
            DropdownMenuItem(
              value: 'all',
              child: Text('Tous les utilisateurs'),
            ),
          ],
          onChanged: _working
              ? null
              : (value) =>
                    setState(() => _notificationAudience = value ?? 'students'),
        ),
        const SizedBox(height: 8),
        Text(
          '${recipients.length} destinataire(s) correspondant(s).',
          style: const TextStyle(color: AppColors.secondary),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notificationTitleController,
          maxLength: 120,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Titre',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _notificationMessageController,
          maxLength: 2000,
          minLines: 3,
          maxLines: 6,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Message',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed:
              _working ||
                  recipients.isEmpty ||
                  _notificationTitleController.text.trim().isEmpty ||
                  _notificationMessageController.text.trim().isEmpty
              ? null
              : () async {
                  await _run(() async {
                    await _service.sendNotification(
                      recipientUids: recipients.map((user) => user.uid),
                      title: _notificationTitleController.text,
                      message: _notificationMessageController.text,
                    );
                    _notificationTitleController.clear();
                    _notificationMessageController.clear();
                  });
                },
          icon: const Icon(Icons.send_outlined),
          label: const Text('Envoyer la notification'),
        ),
      ],
    );
  }

  Future<void> _editClassRecord(
    AdminWorkspaceData data, {
    AdminClass? item,
  }) async {
    final name = TextEditingController(text: item?.name ?? '');
    final group = TextEditingController(text: item?.group ?? '');
    final level = TextEditingController(text: item?.level ?? '');
    final year = TextEditingController(text: item?.academicYear ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item == null ? 'Nouvelle classe' : 'Modifier la classe'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Nom'),
              ),
              TextField(
                controller: group,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Groupe'),
              ),
              TextField(
                controller: level,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Niveau académique',
                ),
              ),
              TextField(
                controller: year,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: 'Année académique',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(item == null ? 'Créer' : 'Enregistrer'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await _run(
        () => item == null
            ? _service.createClass(
                name: name.text,
                group: group.text,
                level: level.text,
                academicYear: year.text,
              )
            : _service.updateClass(
                classId: item.id,
                name: name.text,
                group: group.text,
                level: level.text,
                academicYear: year.text,
              ),
      );
    }
    name.dispose();
    group.dispose();
    level.dispose();
    year.dispose();
  }

  Future<void> _confirmRemoveClass(AdminClass item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette classe ?'),
        content: const Text(
          'La suppression est refusée si des profils, matières, affectations ou inscriptions y sont encore liés.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (yes == true) await _run(() => _service.removeClass(item));
  }

  Future<void> _editSubjectRecord(
    AdminWorkspaceData data, {
    AdminSubject? subject,
  }) async {
    if (data.classes.isEmpty) return;
    final name = TextEditingController(text: subject?.name ?? '');
    final description = TextEditingController(text: subject?.description ?? '');
    final selectedClassIds = subject?.classIds.toSet() ?? <String>{};
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            subject == null ? 'Nouvelle matière' : 'Modifier la matière',
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: name,
                    maxLength: 120,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Nom de la matière',
                    ),
                  ),
                  TextField(
                    controller: description,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: 'Description facultative',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Classes concernées', style: _sectionStyle),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final item in data.classes)
                        FilterChip(
                          label: Text('${item.name} • ${item.group}'),
                          selected: selectedClassIds.contains(item.id),
                          onSelected: (selected) => setDialogState(() {
                            if (selected) {
                              selectedClassIds.add(item.id);
                            } else {
                              selectedClassIds.remove(item.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: name.text.trim().isEmpty || selectedClassIds.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(subject == null ? 'Créer' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _run(
        () => subject == null
            ? _service.createSubject(
                name: name.text,
                description: description.text,
                classIds: selectedClassIds.toList(),
              )
            : _service.updateSubject(
                subjectId: subject.id,
                name: name.text,
                description: description.text,
                classIds: selectedClassIds.toList(),
              ),
      );
    }
    name.dispose();
    description.dispose();
  }

  Future<void> _confirmRemoveSubject(AdminSubject subject) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette matière ?'),
        content: const Text(
          'La suppression est refusée si une affectation enseignant utilise cette matière.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (yes == true) await _run(() => _service.removeSubject(subject));
  }

  Future<void> _editAssignmentRecord(
    AdminWorkspaceData data, {
    AdminTeacherAssignment? assignment,
  }) async {
    final teachers = data.users
        .where((user) => user.role == AppRole.teacher && user.isActive)
        .toList();
    if (teachers.isEmpty || data.classes.isEmpty || data.subjects.isEmpty)
      return;
    var teacher =
        teachers
            .where((user) => user.uid == assignment?.teacherId)
            .firstOrNull ??
        teachers.first;
    var schoolClass =
        data.classes
            .where((item) => item.id == assignment?.classId)
            .firstOrNull ??
        data.classes.first;
    var subjects = data.subjects
        .where((item) => item.classIds.contains(schoolClass.id))
        .toList();
    if (subjects.isEmpty) {
      _message('Associez d’abord une matière à une classe.');
      return;
    }
    var subject =
        subjects.where((item) => item.id == assignment?.subject).firstOrNull ??
        subjects.first;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            assignment == null
                ? 'Nouvelle affectation'
                : 'Modifier l’affectation',
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<AppUser>(
                  initialValue: teacher,
                  decoration: const InputDecoration(labelText: 'Enseignant'),
                  items: [
                    for (final user in teachers)
                      DropdownMenuItem(
                        value: user,
                        child: Text(user.displayName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => teacher = value ?? teacher),
                ),
                DropdownButtonFormField<AdminClass>(
                  key: ValueKey(schoolClass.id),
                  initialValue: schoolClass,
                  decoration: const InputDecoration(labelText: 'Classe'),
                  items: [
                    for (final item in data.classes)
                      DropdownMenuItem(
                        value: item,
                        child: Text('${item.name} • ${item.group}'),
                      ),
                  ],
                  onChanged: (value) => setDialogState(() {
                    schoolClass = value ?? schoolClass;
                    subjects = data.subjects
                        .where((item) => item.classIds.contains(schoolClass.id))
                        .toList();
                    if (subjects.isNotEmpty &&
                        !subjects.any((item) => item.id == subject.id))
                      subject = subjects.first;
                  }),
                ),
                DropdownButtonFormField<AdminSubject>(
                  initialValue: subjects.any((item) => item.id == subject.id)
                      ? subject
                      : null,
                  decoration: const InputDecoration(labelText: 'Matière'),
                  items: [
                    for (final item in subjects)
                      DropdownMenuItem(value: item, child: Text(item.name)),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => subject = value ?? subject),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: subjects.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(assignment == null ? 'Affecter' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _run(
        () => assignment == null
            ? _service.createTeacherAssignment(
                teacher: teacher,
                schoolClass: schoolClass,
                subject: subject,
              )
            : _service.updateTeacherAssignment(
                assignment: assignment,
                teacher: teacher,
                schoolClass: schoolClass,
                subject: subject,
              ),
      );
    }
  }

  Future<void> _toggleAssignmentStatus(
    AdminTeacherAssignment assignment,
    AdminWorkspaceData data,
  ) async {
    final teacher = data.users
        .where((user) => user.uid == assignment.teacherId)
        .firstOrNull;
    final schoolClass = data.classes
        .where((item) => item.id == assignment.classId)
        .firstOrNull;
    final subject = data.subjects
        .where((item) => item.id == assignment.subject)
        .firstOrNull;
    if (teacher == null || schoolClass == null || subject == null) {
      _message(
        'Le profil enseignant, la classe ou la matière liée est introuvable.',
      );
      return;
    }
    final nextStatus = assignment.status == 'active' ? 'inactive' : 'active';
    await _run(
      () => _service.updateTeacherAssignmentStatus(
        assignment: assignment,
        status: nextStatus,
        teacher: teacher,
        schoolClass: schoolClass,
        subject: subject,
      ),
    );
  }

  Future<void> _confirmRemoveAssignment(
    AdminTeacherAssignment assignment,
  ) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette affectation ?'),
        content: const Text(
          'La suppression est refusée si des séances, inscriptions ou présences sont liées. Les historiques doivent être préservés.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (yes == true)
      await _run(() => _service.removeTeacherAssignment(assignment));
  }

  Future<void> _editStudentClass(AppUser student) async {
    final controller = TextEditingController(text: student.className ?? '');
    final value = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Classe de ${student.displayName}'),
        content: TextField(
          controller: controller,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Classe'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Effacer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await _run(() => _service.updateStudentClass(student.uid, value));
  }

  Future<void> _toggleUserStatus(AppUser user) async {
    final nextStatus = !user.isActive;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          nextStatus ? 'Activer ce compte ?' : 'Désactiver ce compte ?',
        ),
        content: Text(
          nextStatus
              ? 'L’utilisateur pourra se connecter et utiliser EduTrack.'
              : 'L’utilisateur ne pourra plus se connecter. Son accès Firestore et les opérations serveur seront également refusés.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(nextStatus ? 'Activer' : 'Désactiver'),
          ),
        ],
      ),
    );
    if (yes == true)
      await _run(() => _service.setAccountActive(user.uid, nextStatus));
  }

  Future<void> _createCourse(AdminWorkspaceData data) async {
    final teachers = data.users
        .where((u) => u.role == AppRole.teacher)
        .toList();
    final name = TextEditingController();
    final description = TextEditingController();
    var teacher = teachers.first;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nouveau cours'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nom du cours'),
                ),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(
                    labelText: 'Description facultative',
                  ),
                ),
                DropdownButtonFormField<AppUser>(
                  initialValue: teacher,
                  decoration: const InputDecoration(labelText: 'Enseignant'),
                  items: [
                    for (final user in teachers)
                      DropdownMenuItem(
                        value: user,
                        child: Text(user.displayName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => teacher = value ?? teacher),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, name.text.trim().isNotEmpty),
              child: const Text('Créer'),
            ),
          ],
        ),
      ),
    );
    if (saved == true)
      await _run(
        () => _service.createCourse(
          name: name.text,
          teacher: teacher,
          description: description.text,
        ),
      );
    name.dispose();
    description.dispose();
  }

  Future<void> _editCourse(AdminCourse course, List<AppUser> teachers) async {
    if (teachers.isEmpty) {
      _message('Aucun compte enseignant n’est provisionné.');
      return;
    }
    final name = TextEditingController(text: course.name);
    final description = TextEditingController(text: course.description ?? '');
    var teacher =
        teachers.where((user) => user.uid == course.teacherUid).firstOrNull ??
        teachers.first;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Modifier le cours'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nom du cours'),
                ),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(
                    labelText: 'Description facultative',
                  ),
                ),
                DropdownButtonFormField<AppUser>(
                  initialValue: teacher,
                  decoration: const InputDecoration(
                    labelText: 'Enseignant affecté',
                  ),
                  items: [
                    for (final user in teachers)
                      DropdownMenuItem(
                        value: user,
                        child: Text(user.displayName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => teacher = value ?? teacher),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, name.text.trim().isNotEmpty),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _run(
        () => _service.updateCourse(
          courseId: course.id,
          name: name.text,
          teacher: teacher,
          description: description.text,
        ),
      );
    }
    name.dispose();
    description.dispose();
  }

  Future<void> _addEnrollment(AdminWorkspaceData data) async {
    final students = data.users
        .where((u) => u.role == AppRole.student && u.isActive)
        .toList();
    var student = students.first;
    var course = data.courses.first;
    AdminClass? schoolClass = data.classes
        .where(
          (item) => data.teacherAssignments.any(
            (assignment) =>
                assignment.id == course.id &&
                assignment.classId == item.id &&
                assignment.status == 'active',
          ),
        )
        .firstOrNull;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Inscrire un étudiant'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<AppUser>(
                  initialValue: student,
                  decoration: const InputDecoration(labelText: 'Étudiant'),
                  items: [
                    for (final user in students)
                      DropdownMenuItem(
                        value: user,
                        child: Text(user.displayName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => student = value ?? student),
                ),
                DropdownButtonFormField<AdminCourse>(
                  initialValue: course,
                  decoration: const InputDecoration(labelText: 'Cours'),
                  items: [
                    for (final item in data.courses)
                      DropdownMenuItem(value: item, child: Text(item.name)),
                  ],
                  onChanged: (value) => setDialogState(() {
                    course = value ?? course;
                    schoolClass = data.classes
                        .where(
                          (item) => data.teacherAssignments.any(
                            (assignment) =>
                                assignment.id == course.id &&
                                assignment.classId == item.id &&
                                assignment.status == 'active',
                          ),
                        )
                        .firstOrNull;
                  }),
                ),
                const SizedBox(height: 8),
                Text(
                  schoolClass == null
                      ? 'Ce cours n’est pas relié à une classe; l’inscription restera au format cours historique.'
                      : 'Classe : ${schoolClass!.name} • ${schoolClass!.group}',
                  style: const TextStyle(color: AppColors.secondary),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Inscrire'),
            ),
          ],
        ),
      ),
    );
    if (saved == true)
      await _run(
        () => _service.createEnrollment(
          student: student,
          course: course,
          classId: schoolClass?.id,
        ),
      );
  }

  Future<void> _createSession(AdminWorkspaceData data) async {
    var course = data.courses.first;
    var startsAt = DateTime.now().add(const Duration(hours: 1));
    final room = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nouvelle séance'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<AdminCourse>(
                  initialValue: course,
                  decoration: const InputDecoration(labelText: 'Cours'),
                  items: [
                    for (final item in data.courses)
                      DropdownMenuItem(value: item, child: Text(item.name)),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => course = value ?? course),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: startsAt,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 1),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (date == null || !context.mounted) return;
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(startsAt),
                    );
                    if (time != null)
                      setDialogState(
                        () => startsAt = DateTime(
                          date.year,
                          date.month,
                          date.day,
                          time.hour,
                          time.minute,
                        ),
                      );
                  },
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text(
                    '${startsAt.day}/${startsAt.month}/${startsAt.year} ${startsAt.hour.toString().padLeft(2, '0')}:${startsAt.minute.toString().padLeft(2, '0')}',
                  ),
                ),
                TextField(
                  controller: room,
                  decoration: const InputDecoration(
                    labelText: 'Salle facultative',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Créer'),
            ),
          ],
        ),
      ),
    );
    if (saved == true)
      await _run(
        () => _service.createSession(
          course: course,
          startsAt: startsAt,
          endsAt: startsAt.add(const Duration(hours: 2)),
          room: room.text,
        ),
      );
    room.dispose();
  }

  Future<void> _editSession(AdminSession session, AdminCourse? course) async {
    if (course == null) {
      _message('Le cours associé à cette séance est introuvable.');
      return;
    }
    var startsAt = session.startsAt;
    final room = TextEditingController(text: session.room ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Modifier • ${course.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: startsAt,
                    firstDate: DateTime.now().subtract(
                      const Duration(days: 365),
                    ),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (date == null || !context.mounted) return;
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(startsAt),
                  );
                  if (time != null)
                    setDialogState(
                      () => startsAt = DateTime(
                        date.year,
                        date.month,
                        date.day,
                        time.hour,
                        time.minute,
                      ),
                    );
                },
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(
                  '${startsAt.day}/${startsAt.month}/${startsAt.year} ${startsAt.hour.toString().padLeft(2, '0')}:${startsAt.minute.toString().padLeft(2, '0')}',
                ),
              ),
              TextField(
                controller: room,
                decoration: const InputDecoration(
                  labelText: 'Salle facultative',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _run(
        () => _service.updateSession(
          sessionId: session.id,
          course: course,
          startsAt: startsAt,
          endsAt: session.endsAt,
          room: room.text,
        ),
      );
    }
    room.dispose();
  }

  Future<void> _removeSession(AdminSession session) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette séance ?'),
        content: const Text(
          'La suppression est refusée si des pointages existent pour cette séance.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (yes == true) await _run(() => _service.removeSession(session));
  }

  Future<void> _removeEnrollment(AdminEnrollment enrollment) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retirer cette inscription ?'),
        content: const Text(
          'L’étudiant perdra l’accès au cours et à ses séances.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (yes == true) await _run(() => _service.removeEnrollment(enrollment.id));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _working = true);
    try {
      await action();
      _reload();
      if (mounted) _message('Enregistré.');
    } on EduTrackApiException catch (error) {
      if (mounted) _message('Opération serveur refusée : ${error.message}');
    } on FirebaseException catch (error) {
      if (mounted) _message('Opération refusée par Firestore (${error.code}).');
    } catch (error) {
      if (mounted) _message('Impossible de terminer l’opération : $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.items});
  final List<(String, String, IconData)> items;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final item in items)
        SizedBox(
          width: 170,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(item.$3, color: AppColors.primary),
                  const SizedBox(height: 8),
                  Text(
                    item.$2,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    item.$1,
                    style: const TextStyle(color: AppColors.secondary),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class _AdminEmpty extends StatelessWidget {
  const _AdminEmpty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.secondary),
      ),
    ),
  );
}

class _AdminError extends StatelessWidget {
  const _AdminError({required this.error, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Impossible de charger les données : $error',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: retry, child: const Text('Réessayer')),
      ],
    ),
  );
}

String _userLabel(List<AppUser> users, String uid) =>
    users.where((u) => u.uid == uid).firstOrNull?.displayName ?? uid;
String _courseLabel(List<AdminCourse> courses, String id) =>
    courses.where((c) => c.id == id).firstOrNull?.name ?? id;
String _classLabel(List<AdminClass> classes, String id) {
  final item = classes.where((entry) => entry.id == id).firstOrNull;
  return item == null ? id : '${item.name} • ${item.group}';
}

String _subjectLabel(List<AdminSubject> subjects, String id) =>
    subjects.where((item) => item.id == id).firstOrNull?.name ?? id;
String _dateLabel(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
String _sessionLabel(AdminSession item) =>
    '${_dateLabel(item.startsAt)} ${item.startsAt.hour.toString().padLeft(2, '0')}:${item.startsAt.minute.toString().padLeft(2, '0')}';
IconData _roleIcon(AppRole role) => switch (role) {
  AppRole.student => Icons.school_outlined,
  AppRole.teacher => Icons.co_present_outlined,
  AppRole.admin => Icons.admin_panel_settings_outlined,
};
IconData _statusIcon(String value) => switch (value) {
  'present' => Icons.check_circle_outline,
  'late' => Icons.schedule,
  _ => Icons.cancel_outlined,
};
Color _statusColor(String value) => switch (value) {
  'present' => AppColors.success,
  'late' => Colors.orange,
  _ => AppColors.error,
};
String _statusLabel(String value) => switch (value) {
  'present' => 'Présent',
  'late' => 'Retard',
  _ => 'Absent',
};

const _titleStyle = TextStyle(
  color: AppColors.primaryDark,
  fontSize: 20,
  fontWeight: FontWeight.w800,
);
const _sectionStyle = TextStyle(
  color: AppColors.primaryDark,
  fontSize: 16,
  fontWeight: FontWeight.w700,
);
