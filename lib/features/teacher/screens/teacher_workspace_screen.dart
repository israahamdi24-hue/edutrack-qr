import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../services/edutrack_api_client.dart';
import '../../admin/services/admin_data_service.dart' show AdminAttendance;
import '../../admin/widgets/admin_attendance_charts.dart';
import '../../../models/app_user.dart';
import '../services/teacher_data_service.dart';
import '../services/teacher_session_qr_service.dart';

class TeacherWorkspaceScreen extends StatefulWidget {
  const TeacherWorkspaceScreen({
    super.key,
    required this.user,
    required this.sectionIndex,
    this.service,
    this.qrService,
  });

  final AppUser user;
  final int sectionIndex;
  final TeacherWorkspaceRepository? service;
  final TeacherQrRepository? qrService;

  @override
  State<TeacherWorkspaceScreen> createState() => _TeacherWorkspaceScreenState();
}

class _TeacherWorkspaceScreenState extends State<TeacherWorkspaceScreen> {
  late Future<_TeacherData> _data;
  bool _isSaving = false;
  String? _attendanceCourseFilter;
  DateTime? _periodStart;
  DateTime? _periodEnd;

  TeacherWorkspaceRepository get _service =>
      widget.service ?? TeacherDataService();
  TeacherQrRepository get _qrService =>
      widget.qrService ?? TeacherSessionQrService();

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_TeacherData> _load() async {
    final courses = await _service.loadCourses(widget.user.uid);
    final results = await Future.wait([
      _service.loadSessions(widget.user.uid),
      _service.loadAttendance(courses),
    ]);
    return _TeacherData(
      courses: courses,
      sessions: results[0] as List<TeacherSession>,
      attendance: results[1] as List<TeacherAttendance>,
    );
  }

  void _reload() {
    setState(() {
      _data = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TeacherData>(
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
          return _ErrorPanel(error: snapshot.error!, onRetry: _reload);
        }
        final data = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(_title, style: _headingStyle)),
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
              1 => _courses(data),
              2 => _sessions(data),
              3 => _attendance(data),
              _ => const SizedBox.shrink(),
            },
          ],
        );
      },
    );
  }

  String get _title => switch (widget.sectionIndex) {
    0 => 'Tableau de bord enseignant',
    1 => 'Mes cours et étudiants inscrits',
    2 => 'Séances et QR de présence',
    3 => 'Suivi des présences',
    _ => 'Espace enseignant',
  };

  Widget _dashboard(_TeacherData data) {
    final now = DateTime.now();
    final upcoming = data.sessions
        .where((s) => s.startsAt.isAfter(now))
        .toList();
    final today = data.sessions
        .where(
          (s) =>
              s.startsAt.year == now.year &&
              s.startsAt.month == now.month &&
              s.startsAt.day == now.day,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatsRow(
          items: [
            (
              'Cours affectés',
              '${data.courses.length}',
              Icons.menu_book_outlined,
            ),
            ('Séances à venir', '${upcoming.length}', Icons.event_outlined),
            (
              'Pointages',
              '${data.attendance.length}',
              Icons.fact_check_outlined,
            ),
            (
              'Séances ouvertes',
              '${data.sessions.where((s) => s.status == 'open').length}',
              Icons.qr_code_2,
            ),
          ],
        ),
        const SizedBox(height: 22),
        const Text('Séances du jour', style: _subheadingStyle),
        const SizedBox(height: 8),
        if (today.isEmpty)
          const _EmptyPanel('Aucune séance prévue aujourd’hui.')
        else
          for (final session in today) _sessionTile(session, allowQr: true),
        const SizedBox(height: 18),
        const Text('Prochaines séances', style: _subheadingStyle),
        const SizedBox(height: 8),
        if (upcoming.isEmpty)
          const _EmptyPanel('Aucune séance à venir pour vos cours affectés.')
        else
          for (final session in upcoming.take(5))
            _sessionTile(session, allowQr: false),
      ],
    );
  }

  Widget _courses(_TeacherData data) {
    if (data.courses.isEmpty) {
      return const _EmptyPanel(
        'Aucun cours ne vous est affecté pour le moment.',
      );
    }
    return Column(
      children: [
        for (final course in data.courses)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: AppColors.paleBlue,
                child: Icon(Icons.menu_book_outlined, color: AppColors.primary),
              ),
              title: Text(
                course.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                course.description?.isNotEmpty == true
                    ? course.description!
                    : 'Aucune description renseignée.',
              ),
              trailing: IconButton(
                tooltip: 'Étudiants inscrits',
                onPressed: () => _showStudents(course),
                icon: const Icon(Icons.people_alt_outlined),
              ),
            ),
          ),
      ],
    );
  }

  Widget _sessions(_TeacherData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _isSaving || data.courses.isEmpty
              ? null
              : () => _createSession(data.courses),
          icon: const Icon(Icons.add),
          label: const Text('Créer une séance'),
        ),
        const SizedBox(height: 12),
        if (data.sessions.isEmpty)
          const _EmptyPanel('Aucune séance enregistrée pour vos cours.')
        else
          for (final session in data.sessions)
            _sessionTile(session, allowQr: true),
      ],
    );
  }

  Widget _attendance(_TeacherData data) {
    if (_attendanceCourseFilter != null &&
        !data.courses.any((course) => course.id == _attendanceCourseFilter)) {
      _attendanceCourseFilter = null;
    }
    final courseFiltered = data.attendance
        .where(
          (record) =>
              _attendanceCourseFilter == null ||
              record.courseId == _attendanceCourseFilter,
        )
        .toList();
    final periodStart = _periodStart == null
        ? null
        : DateTime(_periodStart!.year, _periodStart!.month, _periodStart!.day);
    final periodEndExclusive = _periodEnd == null
        ? null
        : DateTime(_periodEnd!.year, _periodEnd!.month, _periodEnd!.day + 1);
    final filtered = courseFiltered.where((record) {
      return (periodStart == null ||
              !record.recordedAt.isBefore(periodStart)) &&
          (periodEndExclusive == null ||
              record.recordedAt.isBefore(periodEndExclusive));
    }).toList();
    final present = filtered.where((r) => r.status == 'present').length;
    final late = filtered.where((r) => r.status == 'late').length;
    final absent = filtered.where((r) => r.status == 'absent').length;
    final absencesByStudent = <String, int>{};
    for (final record in filtered.where(
      (record) => record.status == 'absent',
    )) {
      absencesByStudent.update(
        record.studentUid,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final repeatedAbsences = absencesByStudent.values
        .where((count) => count >= 2)
        .length;
    final courseNames = {
      for (final course in data.courses) course.id: course.name,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatsRow(
          items: [
            ('Présents', '$present', Icons.check_circle_outline),
            ('En retard', '$late', Icons.schedule),
            ('Absences enregistrées', '$absent', Icons.cancel_outlined),
          ],
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String?>(
          initialValue: _attendanceCourseFilter,
          decoration: const InputDecoration(
            labelText: 'Filtrer par classe et matière',
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Toutes les affectations'),
            ),
            for (final course in data.courses)
              DropdownMenuItem<String?>(
                value: course.id,
                child: Text(course.name),
              ),
          ],
          onChanged: (value) => setState(() => _attendanceCourseFilter = value),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 365)),
              initialDateRange: _periodStart != null && _periodEnd != null
                  ? DateTimeRange(start: _periodStart!, end: _periodEnd!)
                  : null,
              helpText: 'Période du rapport',
              cancelText: 'Annuler',
              confirmText: 'Appliquer',
            );
            if (range != null && mounted) {
              setState(() {
                _periodStart = range.start;
                _periodEnd = range.end;
              });
            }
          },
          icon: const Icon(Icons.date_range_outlined),
          label: Text(
            _periodStart == null || _periodEnd == null
                ? 'Choisir une période'
                : 'Du ${_periodStart!.day}/${_periodStart!.month}/${_periodStart!.year} au ${_periodEnd!.day}/${_periodEnd!.month}/${_periodEnd!.year}',
          ),
        ),
        if (repeatedAbsences > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Alerte : $repeatedAbsences étudiant(s) comptent au moins deux absences.',
              style: const TextStyle(
                color: AppColors.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        const SizedBox(height: 16),
        AdminAttendanceCharts(
          records: [
            for (final record in filtered)
              AdminAttendance(
                studentUid: record.studentUid,
                courseId: record.courseId,
                sessionId: record.sessionId,
                status: record.status,
                recordedAt: record.recordedAt,
              ),
          ],
          periodStart: _periodStart,
          periodEnd: _periodEnd,
        ),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          const _EmptyPanel(
            'Aucun pointage serveur n’est disponible pour vos cours.',
          )
        else
          for (final record in filtered)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  _statusIcon(record.status),
                  color: _statusColor(record.status),
                ),
                title: Text(courseNames[record.courseId] ?? 'Cours'),
                subtitle: Text(
                  'Étudiant ${record.studentUid} • Séance ${record.sessionId}',
                ),
                trailing: Text(_statusName(record.status)),
              ),
            ),
        const SizedBox(height: 22),
        const Text('Notifications et signalements', style: _subheadingStyle),
        const SizedBox(height: 8),
        StreamBuilder<List<TeacherNotification>>(
          stream: _service.watchNotifications(widget.user.uid),
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Text('Notifications indisponibles : ${snapshot.error}');
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            if (snapshot.data!.isEmpty)
              return const _EmptyPanel('Aucune notification pour le moment.');
            return Column(
              children: [
                for (final notification in snapshot.data!)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        notification.isRead
                            ? Icons.notifications_none
                            : Icons.notifications_active_outlined,
                        color: notification.isRead
                            ? AppColors.secondary
                            : AppColors.primary,
                      ),
                      title: Text(notification.title),
                      subtitle: Text(notification.message),
                      trailing: notification.isRead
                          ? const Icon(Icons.done, size: 18)
                          : IconButton(
                              tooltip: 'Marquer comme lue',
                              icon: const Icon(Icons.mark_email_read_outlined),
                              onPressed: () => _service.markNotificationRead(
                                widget.user.uid,
                                notification.id,
                              ),
                            ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _sessionTile(TeacherSession session, {required bool allowQr}) {
    final date = session.startsAt;
    final dateText =
        '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year} • '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: ListTile(
        leading: const Icon(
          Icons.event_available_outlined,
          color: AppColors.primary,
        ),
        title: Text(
          session.title?.isNotEmpty == true
              ? session.title!
              : session.courseName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '$dateText • ${session.mode == 'online' ? 'En ligne' : 'Présentiel'}${session.room?.isNotEmpty == true ? ' • ${session.room}' : ''}${session.meetingUrl?.isNotEmpty == true ? ' • ${session.meetingUrl}' : ''}\n${switch (session.status) {
            'open' => 'Séance ouverte',
            'closed' => 'Séance clôturée',
            _ => 'Séance planifiée',
          }}',
        ),
        trailing: allowQr
            ? PopupMenuButton<String>(
                tooltip: 'Gérer la séance',
                onSelected: (action) {
                  switch (action) {
                    case 'qr':
                      _showQr(session);
                    case 'attendance':
                      _showAttendance(session);
                    case 'close':
                      _closeSession(session);
                    case 'edit':
                      _editSession(session);
                    case 'delete':
                      _removeSession(session);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'qr',
                    child: Text('Ouvrir / afficher le QR de présence'),
                  ),
                  PopupMenuItem(
                    value: 'attendance',
                    child: Text('Feuille de présence'),
                  ),
                  PopupMenuItem(
                    value: 'close',
                    child: Text('Clôturer la séance'),
                  ),
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Modifier la séance'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Supprimer la séance'),
                  ),
                ],
                icon: const Icon(Icons.more_vert),
              )
            : null,
      ),
    );
  }

  Future<void> _showStudents(TeacherCourse course) async {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Étudiants • ${course.name}'),
        content: FutureBuilder<List<EnrolledStudent>>(
          future: _service.loadEnrolledStudents(course.id),
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Text(
                'Impossible de charger les inscriptions (${snapshot.error}).',
              );
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            if (snapshot.data!.isEmpty)
              return const Text('Aucun étudiant inscrit activement.');
            return SizedBox(
              width: 380,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final student in snapshot.data!)
                    ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.person_outline),
                      ),
                      title: Text(student.displayName),
                      subtitle: Text(
                        student.className ?? 'Classe non renseignée',
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  Future<void> _createSession(List<TeacherCourse> courses) async {
    final formKey = GlobalKey<FormState>();
    final roomController = TextEditingController();
    final titleController = TextEditingController();
    final meetingController = TextEditingController();
    var courseId = courses.first.id;
    var mode = 'inPerson';
    var durationHours = 2;
    var startsAt = DateTime.now().add(const Duration(hours: 1));
    var endsAt = startsAt.add(const Duration(hours: 2));
    final createMode = await showDialog<_SessionCreationMode>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          child: SizedBox(
            width: MediaQuery.sizeOf(context).width * 0.9,
            height: MediaQuery.sizeOf(context).height * 0.9,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Nouvelle séance',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Form(
                        key: formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: courseId,
                              decoration: const InputDecoration(
                                labelText: 'Cours',
                              ),
                              items: [
                                for (final c in courses)
                                  DropdownMenuItem(
                                    value: c.id,
                                    child: Text(c.name),
                                  ),
                              ],
                              onChanged: (value) =>
                                  courseId = value ?? courseId,
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: titleController,
                              decoration: const InputDecoration(
                                labelText: 'Titre de la séance',
                              ),
                              maxLength: 120,
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? 'Le titre est obligatoire.'
                                  : null,
                            ),
                            DropdownButtonFormField<String>(
                              initialValue: mode,
                              decoration: const InputDecoration(
                                labelText: 'Mode',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'inPerson',
                                  child: Text('Présentiel'),
                                ),
                                DropdownMenuItem(
                                  value: 'online',
                                  child: Text('En ligne • Smart Learning'),
                                ),
                              ],
                              onChanged: (value) =>
                                  setDialogState(() => mode = value ?? mode),
                            ),
                            if (mode == 'online')
                              TextFormField(
                                controller: meetingController,
                                decoration: const InputDecoration(
                                  labelText: 'Lien de visioconférence',
                                ),
                                keyboardType: TextInputType.url,
                                validator: (value) {
                                  if (mode != 'online') return null;
                                  final uri = Uri.tryParse(value?.trim() ?? '');
                                  return uri != null &&
                                          const {
                                            'http',
                                            'https',
                                          }.contains(uri.scheme) &&
                                          uri.host.isNotEmpty
                                      ? null
                                      : 'Saisissez un lien de réunion valide.';
                                },
                              ),
                            DropdownButtonFormField<int>(
                              initialValue: durationHours,
                              decoration: const InputDecoration(
                                labelText: 'Durée',
                              ),
                              items: const [1, 2, 3, 4]
                                  .map(
                                    (hours) => DropdownMenuItem(
                                      value: hours,
                                      child: Text('$hours h'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) => setDialogState(() {
                                durationHours = value ?? durationHours;
                                endsAt = startsAt.add(
                                  Duration(hours: durationHours),
                                );
                              }),
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: () async {
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: startsAt,
                                  firstDate: DateTime.now().subtract(
                                    const Duration(days: 1),
                                  ),
                                  lastDate: DateTime.now().add(
                                    const Duration(days: 365),
                                  ),
                                );
                                if (date == null || !context.mounted) return;
                                final time = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay.fromDateTime(startsAt),
                                );
                                if (time == null) return;
                                setDialogState(() {
                                  startsAt = DateTime(
                                    date.year,
                                    date.month,
                                    date.day,
                                    time.hour,
                                    time.minute,
                                  );
                                  endsAt = startsAt.add(
                                    Duration(hours: durationHours),
                                  );
                                });
                              },
                              icon: const Icon(Icons.calendar_month_outlined),
                              label: Text(
                                'Début : ${startsAt.day}/${startsAt.month}/${startsAt.year} ${startsAt.hour.toString().padLeft(2, '0')}:${startsAt.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                            TextFormField(
                              controller: roomController,
                              decoration: const InputDecoration(
                                labelText: 'Salle (facultatif)',
                              ),
                              maxLength: 80,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Annuler'),
                      ),
                      OutlinedButton(
                        onPressed: () => Navigator.pop(
                          dialogContext,
                          formKey.currentState!.validate()
                              ? _SessionCreationMode.schedule
                              : null,
                        ),
                        child: const Text('Planifier'),
                      ),
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(
                          dialogContext,
                          formKey.currentState!.validate()
                              ? _SessionCreationMode.startNow
                              : null,
                        ),
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('Créer et démarrer + QR'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (createMode == null) {
      roomController.dispose();
      titleController.dispose();
      meetingController.dispose();
      return;
    }
    setState(() => _isSaving = true);
    try {
      final token = await _service.createSession(
        courseId: courseId,
        teacherUid: widget.user.uid,
        startsAt: startsAt,
        endsAt: endsAt,
        room: roomController.text,
        title: titleController.text,
        mode: mode,
        meetingUrl: meetingController.text,
        startImmediately: createMode == _SessionCreationMode.startNow,
      );
      _reload();
      if (token != null && mounted) {
        final course = courses.firstWhere((item) => item.id == courseId);
        await showDialog<void>(
          context: context,
          builder: (context) => _SessionQrDialog(
            session: TeacherSession(
              id: token.sessionId,
              courseId: course.id,
              courseName: course.name,
              startsAt: token.startedAt,
              endsAt: token.startedAt.add(Duration(hours: durationHours)),
              title: titleController.text.trim(),
              mode: mode,
              meetingUrl: meetingController.text.trim().isEmpty
                  ? null
                  : meetingController.text.trim(),
              status: 'open',
              startedAt: token.startedAt,
              qrExpiresAt: token.expiresAt,
            ),
            initialToken: SessionQrToken(
              payload: token.payload,
              expiresAt: token.expiresAt,
            ),
            qrService: _qrService,
          ),
        );
      } else if (mounted) {
        _message('Séance planifiée.');
      }
    } on EduTrackApiException catch (error) {
      if (mounted) _message('Création refusée : ${error.message}');
    } on FirebaseException catch (error) {
      if (mounted) {
        _message('Connexion Firebase indisponible (${error.code}).');
      }
    } finally {
      roomController.dispose();
      titleController.dispose();
      meetingController.dispose();
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showQr(TeacherSession session) async {
    try {
      final token = session.status == 'open'
          ? await _qrService.generate(session.id)
          : await _qrService.start(session.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _SessionQrDialog(
          session: session,
          initialToken: token,
          qrService: _qrService,
        ),
      );
      _reload();
    } on EduTrackApiException catch (error) {
      if (!mounted) return;
      _message('Impossible de générer le QR : ${error.message}');
    } catch (error) {
      if (mounted) _message('Le QR n’a pas pu être généré : $error');
    }
  }

  Future<void> _closeSession(TeacherSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clôturer la séance ?'),
        content: const Text(
          'Les étudiants sans pointage seront marqués absents et recevront une notification.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clôturer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _qrService.close(session.id);
      _reload();
      if (mounted)
        _message('Séance clôturée et feuille de présence mise à jour.');
    } catch (error) {
      if (mounted) _message('Clôture impossible : $error');
    }
  }

  Future<void> _showAttendance(TeacherSession session) async {
    final students = await _service.loadEnrolledStudents(session.courseId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Présences • ${session.courseName}'),
        content: SizedBox(
          width: 440,
          child: StreamBuilder<List<TeacherAttendance>>(
            stream: _service.watchAttendance([
              TeacherCourse(
                id: session.courseId,
                name: session.courseName,
                teacherName: widget.user.displayName,
                teacherUid: widget.user.uid,
              ),
            ]),
            builder: (context, snapshot) {
              final records = (snapshot.data ?? [])
                  .where((record) => record.sessionId == session.id)
                  .toList();
              return ListView(
                shrinkWrap: true,
                children: [
                  for (final student in students)
                    ListTile(
                      title: Text(student.displayName),
                      subtitle: Text(
                        _statusName(
                          records
                                  .where((r) => r.studentUid == student.uid)
                                  .firstOrNull
                                  ?.status ??
                              (session.status == 'closed'
                                  ? 'absent'
                                  : 'pending'),
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: 'Corriger la présence',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _correctAttendance(
                          session,
                          student,
                          records
                                  .where((r) => r.studentUid == student.uid)
                                  .firstOrNull
                                  ?.status ??
                              (session.status == 'closed'
                                  ? 'absent'
                                  : 'pending'),
                        ),
                      ),
                    ),
                  if (students.isEmpty)
                    const ListTile(title: Text('Aucun étudiant inscrit.')),
                  if (snapshot.hasError)
                    Text('Erreur du suivi : ${snapshot.error}'),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  Future<void> _correctAttendance(
    TeacherSession session,
    EnrolledStudent student,
    String current,
  ) async {
    final reason = TextEditingController();
    var status = current == 'pending' ? 'absent' : current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Corriger • ${student.displayName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Statut'),
                items: const [
                  DropdownMenuItem(value: 'present', child: Text('Présent')),
                  DropdownMenuItem(value: 'late', child: Text('En retard')),
                  DropdownMenuItem(value: 'absent', child: Text('Absent')),
                ],
                onChanged: (value) =>
                    setDialogState(() => status = value ?? status),
              ),
              TextField(
                controller: reason,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Motif obligatoire',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, reason.text.trim().isNotEmpty),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      try {
        await _service.correctAttendance(
          sessionId: session.id,
          studentUid: student.uid,
          status: status,
          reason: reason.text,
        );
        if (mounted) _message('Correction enregistrée avec sa trace d’audit.');
      } catch (error) {
        if (mounted) _message('Correction impossible : $error');
      }
    } else if (reason.text.isEmpty && mounted) {
      _message('Un motif est obligatoire pour enregistrer une correction.');
    }
    reason.dispose();
  }

  Future<void> _editSession(TeacherSession session) async {
    var startsAt = session.startsAt;
    final room = TextEditingController(text: session.room ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Modifier • ${session.courseName}'),
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
      final duration =
          session.endsAt?.difference(session.startsAt) ??
          const Duration(hours: 2);
      setState(() => _isSaving = true);
      try {
        await _service.updateSession(
          session: session,
          teacherUid: widget.user.uid,
          startsAt: startsAt,
          endsAt: startsAt.add(duration),
          room: room.text,
        );
        _reload();
        if (mounted) _message('Séance mise à jour.');
      } on FirebaseException catch (error) {
        if (mounted) _message('Modification refusée (${error.code}).');
      } finally {
        if (mounted) setState(() => _isSaving = false);
      }
    }
    room.dispose();
  }

  Future<void> _removeSession(TeacherSession session) async {
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
    if (yes != true) return;
    setState(() => _isSaving = true);
    try {
      await _service.removeSession(session);
      _reload();
      if (mounted) _message('Séance supprimée.');
    } on FirebaseException catch (error) {
      if (mounted) _message('Suppression refusée (${error.code}).');
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _message(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
}

class _TeacherData {
  const _TeacherData({
    required this.courses,
    required this.sessions,
    required this.attendance,
  });
  final List<TeacherCourse> courses;
  final List<TeacherSession> sessions;
  final List<TeacherAttendance> attendance;
}

enum _SessionCreationMode { schedule, startNow }

class _SessionQrDialog extends StatefulWidget {
  const _SessionQrDialog({
    required this.session,
    required this.initialToken,
    required this.qrService,
  });
  final TeacherSession session;
  final SessionQrToken initialToken;
  final TeacherQrRepository qrService;

  @override
  State<_SessionQrDialog> createState() => _SessionQrDialogState();
}

class _SessionQrDialogState extends State<_SessionQrDialog> {
  late SessionQrToken _token = widget.initialToken;
  late Timer _timer;
  bool _refreshing = false;
  String? _refreshError;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _token.expiresAt.difference(_now);
    final expired = remaining <= Duration.zero;
    final minutes = remaining.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final seconds = remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 440,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'QR de présence • ${widget.session.courseName}',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              if (!expired)
                QrImageView(
                  data: _token.payload,
                  size: 240,
                  backgroundColor: Colors.white,
                )
              else
                const SizedBox(
                  width: 240,
                  height: 240,
                  child: Center(
                    child: Icon(Icons.qr_code_2, size: 100, color: Colors.grey),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                expired
                    ? 'QR expiré. Le pointage par QR est bloqué.'
                    : 'Expiration dans $minutes:$seconds',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: expired ? AppColors.error : AppColors.primary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Jeton signé sans donnée personnelle, valable 15 minutes à partir de l’ouverture.',
                textAlign: TextAlign.center,
              ),
              if (_refreshError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _refreshError!,
                  style: const TextStyle(color: AppColors.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: expired || _refreshing
                        ? null
                        : () async {
                            setState(() => _refreshing = true);
                            try {
                              final token = await widget.qrService.generate(
                                widget.session.id,
                              );
                              if (mounted)
                                setState(() {
                                  _token = token;
                                  _now = DateTime.now();
                                  _refreshError = null;
                                });
                            } on Exception catch (error) {
                              if (mounted)
                                setState(
                                  () => _refreshError =
                                      'Actualisation impossible : $error',
                                );
                            } finally {
                              if (mounted) setState(() => _refreshing = false);
                            }
                          },
                    child: Text(
                      expired
                          ? 'QR expiré'
                          : _refreshing
                          ? 'Actualisation…'
                          : 'Actualiser le QR',
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Fermer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.items});
  final List<(String, String, IconData)> items;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final item in items)
        SizedBox(
          width: 185,
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
                      fontSize: 21,
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

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(22),
    child: Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.secondary),
      ),
    ),
  );
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
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
        OutlinedButton(onPressed: onRetry, child: const Text('Réessayer')),
      ],
    ),
  );
}

const _headingStyle = TextStyle(
  color: AppColors.primaryDark,
  fontSize: 20,
  fontWeight: FontWeight.w800,
);
const _subheadingStyle = TextStyle(
  color: AppColors.primaryDark,
  fontSize: 16,
  fontWeight: FontWeight.w700,
);

IconData _statusIcon(String status) => switch (status) {
  'present' => Icons.check_circle_outline,
  'late' => Icons.schedule,
  _ => Icons.cancel_outlined,
};
Color _statusColor(String status) => switch (status) {
  'present' => AppColors.success,
  'late' => Colors.orange,
  _ => AppColors.error,
};
String _statusName(String status) => switch (status) {
  'present' => 'Présent',
  'late' => 'En retard',
  'pending' => 'En attente',
  _ => 'Absent',
};
