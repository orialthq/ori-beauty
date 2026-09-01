import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import 'plan_date_dialog.dart';
import 'plan_scope_sheet.dart';
import 'plan_wizard_chrome.dart';

/// Trigger shape selected in the manual plan editor.
///
/// These cases map directly to a time condition, a location condition, or an
/// AND condition in the domain layer.
enum PlanDraftTriggerKind { time, location, timeAndLocation }

/// Recurrence choices supported by the baseline scheduler contract.
enum PlanDraftRecurrence { once, daily, weekly, onReentry }

/// How far before a plan the notification arrives.
///
/// When it happens and when to be told are two different times, and the app
/// used to have only one. A dinner at seven with a reminder at seven is a
/// reminder that arrives after the reader is already there.
///
/// A lead rather than a second date picker: what a reader knows is "tell me an
/// hour before", not the clock time that works out to.
enum PlanLeadTime {
  onTime(Duration.zero, '정시'),
  tenMinutes(Duration(minutes: 10), '10분 전'),
  thirtyMinutes(Duration(minutes: 30), '30분 전'),
  oneHour(Duration(hours: 1), '1시간 전'),
  twoHours(Duration(hours: 2), '2시간 전'),
  oneDay(Duration(days: 1), '하루 전'),
  twoDays(Duration(days: 2), '이틀 전'),
  oneWeek(Duration(days: 7), '일주일 전');

  const PlanLeadTime(this.ahead, this.label);

  final Duration ahead;
  final String label;

  /// An hour rather than none. Being told at the moment something starts is
  /// almost always too late, and a default that is usually wrong teaches the
  /// reader to distrust the notification rather than to change the setting.
  static const fallback = PlanLeadTime.oneHour;

  static PlanLeadTime? named(Object? value) {
    if (value is! String) return null;
    for (final lead in PlanLeadTime.values) {
      if (lead.name == value) return lead;
    }
    return null;
  }
}

/// Optional captured content that can be linked to a manually created plan.
final class PlanSourceOption {
  const PlanSourceOption({
    required this.captureId,
    required this.title,
    required this.tags,
    this.subtitle,
  }) : assert(captureId != ''),
       assert(title != '');

  final String captureId;
  final String title;

  /// Every word it is filed under. The editor builds its picker out of these
  /// rather than being handed a list, so it still needs no controller.
  final List<String> tags;

  final String? subtitle;
}

/// Where a plan looks for what the reader saved.
///
/// A fence around the search rather than a link to one capture. The
/// recommendation sends the library to a model, and sending all of it means the
/// answer gets worse and dearer as the library grows. Naming a tag is the
/// reader saying "it's in here", which is a thing they know and the model has
/// to guess.
///
/// Reducing is the app's job; choosing inside what is left is the model's.
///
/// An empty list is "everywhere" rather than "nowhere": a plan with no fence is
/// the default, and a plan that can never find anything is not a state worth
/// being able to express. Several tags widen rather than narrow — a trip wants
/// places and shopping and tips, and a saved thing carrying any one of them is
/// worth showing.
bool planScopeMatches(List<String> scope, List<String> tags) {
  if (scope.isEmpty) return true;
  for (final tag in tags) {
    if (scope.contains(tag)) return true;
  }
  return false;
}

/// Validated output from [PlanEditorScreen].
///
/// A location remains a user-entered query here. The integration layer can
/// resolve it to coordinates before creating a schedulable domain plan.
final class PlanDraft {
  const PlanDraft({
    required this.title,
    required this.triggerKind,
    required this.recurrence,
    this.scheduledAt,
    this.endsAt,
    this.locationQuery,
    this.sourceCaptureId,
    this.scopes = const <String>[],
    this.leadTime = PlanLeadTime.fallback,
  });

  final String title;
  final PlanDraftTriggerKind triggerKind;
  final PlanDraftRecurrence recurrence;
  final DateTime? scheduledAt;

  /// The last day a plan spans, for the ones that are not over in an afternoon.
  ///
  /// A trip is a plan the way dinner is, but it has a shape a single moment
  /// cannot hold: to-dos are due against its start while the plan itself runs
  /// until this day. Null means the plan is one day, which is most of them.
  ///
  /// The notification is not scheduled against this — [notifyAt] counts back
  /// from the start. It sets how long the plan stays live, and what a card says.
  final DateTime? endsAt;

  final String? locationQuery;
  final String? sourceCaptureId;

  /// Which tags to look under. Empty searches the whole library.
  final List<String> scopes;

  /// How long before [scheduledAt] to fire.
  ///
  /// Counted from the day the plan *starts*, never from [endsAt]. "여행 하루
  /// 전" means the day before leaving, which is the only reading that leaves
  /// time to act on it.
  final PlanLeadTime leadTime;

  /// When the notification fires. Null for a plan with no time at all.
  DateTime? get notifyAt => scheduledAt?.subtract(leadTime.ahead);

  /// How many days the plan covers, counting both ends. One when it is a day.
  int get dayCount {
    final start = scheduledAt;
    final end = endsAt;
    if (start == null || end == null) return 1;
    final days = DateUtils.dateOnly(
      end,
    ).difference(DateUtils.dateOnly(start)).inDays;
    return days < 1 ? 1 : days + 1;
  }
}

/// Manual plan creation flow.
///
/// Use [open] to receive a [PlanDraft] from navigation, or pass [onSave] and
/// set [popOnSave] to false when embedding the editor in another flow.
final class PlanEditorScreen extends StatefulWidget {
  const PlanEditorScreen({
    this.sources = const [],
    this.initialDraft,
    this.prefill,
    this.onSave,
    this.popOnSave = true,
    super.key,
  });

  final List<PlanSourceOption> sources;
  final PlanDraft? initialDraft;

  /// A new plan's answers, gathered somewhere else.
  ///
  /// Not an [initialDraft]: that is an existing plan being edited, and the
  /// editor says so in its own header. This fills the same fields for a plan
  /// that does not exist yet — whatever the reader already settled on before
  /// arriving, with every remaining question still to answer here.
  final PlanDraft? prefill;

  final ValueChanged<PlanDraft>? onSave;
  final bool popOnSave;

  static Future<PlanDraft?> open(
    BuildContext context, {
    List<PlanSourceOption> sources = const [],
    PlanDraft? initialDraft,
    PlanDraft? prefill,
  }) {
    return Navigator.of(context).push<PlanDraft>(
      MaterialPageRoute<PlanDraft>(
        builder: (_) => PlanEditorScreen(
          sources: sources,
          initialDraft: initialDraft,
          prefill: prefill,
        ),
      ),
    );
  }

  @override
  State<PlanEditorScreen> createState() => _PlanEditorScreenState();
}

final class _PlanEditorScreenState extends State<PlanEditorScreen> {
  static const _noSourceValue = '';

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late bool _hasTime;
  late bool _hasPlace;
  late PlanDraftRecurrence _recurrence;
  late DateTime _scheduledAt;
  DateTime? _endsAt;
  var _leadTime = PlanLeadTime.fallback;
  late String _sourceValue;
  var _scopes = const <String>[];

  /// How many saved things the current scopes cover between them. The whole
  /// library when nothing is picked, so the field says what it will search.
  int get _scopeCount =>
      widget.sources.where((one) => planScopeMatches(_scopes, one.tags)).length;

  /// A span only reads as a span on a plan that happens once. "매주 화요일,
  /// 5일간" is not a thing the rest of the flow could act on.
  bool get _canSpanDays => _usesTime && _recurrence == PlanDraftRecurrence.once;

  bool get _usesTime => _hasTime;

  bool get _usesLocation => _hasPlace;

  /// Read off the fields rather than chosen. The domain still wants one of
  /// three, but that is an output now, not a question.
  PlanDraftTriggerKind get _triggerKind {
    if (_hasTime && _hasPlace) return PlanDraftTriggerKind.timeAndLocation;
    return _hasPlace
        ? PlanDraftTriggerKind.location
        : PlanDraftTriggerKind.time;
  }

  void _removeTime() {
    HapticFeedback.selectionClick();
    setState(() {
      _hasTime = false;
      // Kept in state, so putting the time back restores what was picked
      // rather than starting over at the default hour.
      if (!_availableRecurrences.contains(_recurrence)) {
        _recurrence = PlanDraftRecurrence.once;
      }
    });
  }

  void _removePlace() {
    HapticFeedback.selectionClick();
    setState(() {
      _hasPlace = false;
      if (!_availableRecurrences.contains(_recurrence)) {
        _recurrence = PlanDraftRecurrence.once;
      }
    });
  }

  List<PlanDraftRecurrence> get _availableRecurrences {
    if (_triggerKind == PlanDraftTriggerKind.location) {
      return const [PlanDraftRecurrence.once, PlanDraftRecurrence.onReentry];
    }
    if (_triggerKind == PlanDraftTriggerKind.time) {
      return const [
        PlanDraftRecurrence.once,
        PlanDraftRecurrence.daily,
        PlanDraftRecurrence.weekly,
      ];
    }
    return PlanDraftRecurrence.values;
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialDraft ?? widget.prefill;
    final defaultSchedule = DateTime.now().add(const Duration(hours: 1));
    _titleController = TextEditingController(text: initial?.title ?? '');
    _locationController = TextEditingController(
      text: initial?.locationQuery ?? '',
    );
    final kind = initial?.triggerKind ?? PlanDraftTriggerKind.time;
    _hasTime = kind != PlanDraftTriggerKind.location;
    _hasPlace = kind != PlanDraftTriggerKind.time;
    _recurrence = initial?.recurrence ?? PlanDraftRecurrence.once;
    if (!_availableRecurrences.contains(_recurrence)) {
      _recurrence = PlanDraftRecurrence.once;
    }
    final initialSchedule = initial?.scheduledAt ?? defaultSchedule;
    _scheduledAt = DateTime(
      initialSchedule.year,
      initialSchedule.month,
      initialSchedule.day,
      initialSchedule.hour,
      initialSchedule.minute,
    );
    _leadTime = initial?.leadTime ?? PlanLeadTime.fallback;
    final initialEnd = initial?.endsAt;
    _endsAt = initialEnd == null ? null : DateUtils.dateOnly(initialEnd);
    // Any that name an emptied folder are dropped, so the field never promises
    // a search over nothing.
    _scopes = <String>[
      for (final scope in initial?.scopes ?? const <String>[])
        if (widget.sources.any((one) => one.tags.contains(scope))) scope,
    ];
    final requestedSource = initial?.sourceCaptureId;
    _sourceValue =
        requestedSource != null &&
            widget.sources.any((source) => source.captureId == requestedSource)
        ? requestedSource
        : _noSourceValue;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.plansTheme(Theme.of(context)),
      child: Builder(
        builder: (planContext) => Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: Text(widget.initialDraft == null ? '계획 만들기' : '계획 수정'),
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: Form(
              key: _formKey,
              child: ListView(
                key: const Key('plan-editor-scroll'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
                children: [
                  if (widget.initialDraft == null) ...[
                    const PlanWizardSteps(activeStep: 1),
                    const SizedBox(height: 4),
                  ],
                  const _EditorIntroduction(),
                  const SizedBox(height: 28),
                  const _SectionTitle(
                    title: '무엇을 켤까요?',
                    description: '저장해둔 것들을 이때 다시 꺼내 드릴게요.',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('plan-title-field'),
                    controller: _titleController,
                    autofocus: false,
                    textInputAction: TextInputAction.next,
                    maxLength: 60,
                    // No floating label: the section above already asked, and
                    // saying "계획 제목" here would ask twice. The hint stays
                    // plain on purpose — it is the only thing teaching the shape
                    // of an answer the recommendation can break into to-dos.
                    decoration: const InputDecoration(
                      hintText: '예: 성수에서 저장한 식당 가보기',
                      counterText: '',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '계획 제목을 입력해 주세요.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 28),
                  // "언제 알려드릴까요?" until the notification got a time of its
                  // own. This section is about when the plan happens; when to
                  // be told is the row underneath.
                  const _SectionTitle(
                    title: '언제, 어디서 하나요?',
                    description: '시간이나 장소, 둘 다 고를 수 있어요.',
                  ),
                  const SizedBox(height: 12),
                  // No "what kind of plan is this?" step. 시간 + 장소 was never a
                  // third kind, only both of the other two, and asking a reader
                  // to name the shape before saying when or where cost three
                  // cards to learn nothing the fields do not already say.
                  if (_usesTime) ...[
                    _PickerField(
                      key: const Key('plan-date-picker'),
                      icon: Icons.calendar_today_rounded,
                      label: _endsAt == null ? '날짜' : '$_dayCount일간',
                      value: _dateValue,
                      // Removable only while a place holds the plan up. A plan
                      // that waits for neither a time nor a place waits for
                      // nothing.
                      onRemove: _usesLocation ? _removeTime : null,
                      onTap: () => _pickDate(planContext),
                    ),
                    const SizedBox(height: 10),
                    _PickerField(
                      key: const Key('plan-time-picker'),
                      icon: Icons.schedule_rounded,
                      label: '시간',
                      value: _formatTime(planContext, _scheduledAt),
                      onTap: () => _pickTime(planContext),
                    ),
                    const SizedBox(height: 10),
                    _LeadTimeField(
                      key: const Key('plan-lead-time-field'),
                      leadTime: _leadTime,
                      notifyAt: _scheduledAt.subtract(_leadTime.ahead),
                      onChanged: (value) => setState(() => _leadTime = value),
                    ),
                  ] else
                    _AddCondition(
                      key: const Key('plan-add-time'),
                      icon: Icons.calendar_today_rounded,
                      label: '시간 정하기',
                      onTap: () => setState(() => _hasTime = true),
                    ),
                  const SizedBox(height: 10),
                  if (_usesLocation) ...[
                    TextFormField(
                      key: const Key('plan-location-field'),
                      controller: _locationController,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: '장소 이름 또는 주소',
                        hintText: '예: 성수역, 서울숲길 24',
                        prefixIcon: const Icon(Icons.location_on_outlined),
                        helperText: '저장할 때 정확한 위치를 한 번 확인해요.',
                        suffixIcon: _usesTime
                            ? IconButton(
                                key: const Key('plan-remove-place'),
                                onPressed: _removePlace,
                                icon: const Icon(Icons.close_rounded, size: 19),
                                color: AppTheme.planSubtle,
                                tooltip: '장소 빼기',
                              )
                            : null,
                      ),
                      validator: (value) {
                        if (_usesLocation &&
                            (value == null || value.trim().isEmpty)) {
                          return '알림을 받을 장소를 입력해 주세요.';
                        }
                        return null;
                      },
                    ),
                  ] else
                    _AddCondition(
                      key: const Key('plan-add-place'),
                      icon: Icons.location_on_outlined,
                      label: '장소 정하기',
                      onTap: () => setState(() => _hasPlace = true),
                    ),
                  const SizedBox(height: 28),
                  const _SectionTitle(
                    title: '반복',
                    description: '한 번 알린 뒤 다시 기다릴지 정해요.',
                  ),
                  const SizedBox(height: 12),
                  KeyedSubtree(
                    key: const Key('plan-recurrence-field'),
                    child: DropdownButtonFormField<PlanDraftRecurrence>(
                      key: ValueKey(
                        'plan-recurrence-${_triggerKind.name}-${_recurrence.name}',
                      ),
                      initialValue: _recurrence,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '반복 방식',
                        prefixIcon: Icon(Icons.repeat_rounded),
                      ),
                      items: [
                        for (final recurrence in _availableRecurrences)
                          DropdownMenuItem(
                            value: recurrence,
                            child: Text(_recurrenceLabel(recurrence)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _recurrence = value;
                          // A repeating plan has no last day, so the span goes
                          // with the one-off it belonged to.
                          if (value != PlanDraftRecurrence.once) _endsAt = null;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 28),
                  const _SectionTitle(
                    title: '어디서 찾을까요?',
                    description: '고른 폴더 안에서만 저장한 것을 꺼내요.',
                  ),
                  const SizedBox(height: 12),
                  if (widget.sources.isEmpty)
                    const _NoSourceNotice()
                  else
                    PlanScopeField(
                      key: const Key('plan-scope-field'),
                      scopes: _scopes,
                      count: _scopeCount,
                      onTap: () => _pickScope(planContext),
                    ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: DecoratedBox(
            decoration: const BoxDecoration(
              color: AppTheme.planSurface,
              border: Border(top: BorderSide(color: AppTheme.planBorder)),
            ),
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(22, 12, 22, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('plan-editor-save'),
                  onPressed: _submit,
                  icon: const Icon(Icons.check_rounded, size: 19),
                  label: Text(widget.initialDraft == null ? '계획 저장' : '변경 저장'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One picker for both shapes.
  ///
  /// A span used to be a switch and a second date field, which asked the reader
  /// to declare the shape of the plan before saying when it was. A calendar
  /// already knows how to mean "these days" — a second tap is the whole gesture,
  /// and there is nothing extra to turn on.
  ///
  /// A repeating plan is offered the same dialog with ranges off: "매주 화요일,
  /// 5일간" is not a thing the rest of the flow could act on.
  Future<void> _pickDate(BuildContext pickerContext) async {
    FocusScope.of(pickerContext).unfocus();
    final today = DateUtils.dateOnly(DateTime.now());
    final current = DateUtils.dateOnly(_scheduledAt);
    final picked = await showPlanDateDialog(
      pickerContext,
      initialStart: current.isBefore(today) ? today : current,
      initialEnd: _endsAt,
      firstDate: today,
      lastDate: DateTime(today.year + 5, 12, 31),
      allowRange: _canSpanDays,
    );
    if (picked == null || !mounted) return;
    setState(() => _applyDates(picked.start, picked.end));
  }

  /// Keeps the clock time and records the span, which is null for one day.
  void _applyDates(DateTime start, DateTime? end) {
    _scheduledAt = DateTime(
      start.year,
      start.month,
      start.day,
      _scheduledAt.hour,
      _scheduledAt.minute,
    );
    final lastDay = end == null ? null : DateUtils.dateOnly(end);
    _endsAt = lastDay != null && lastDay.isAfter(DateUtils.dateOnly(start))
        ? lastDay
        : null;
  }

  /// How many days the plan covers, counting both ends.
  int get _dayCount {
    final endsAt = _endsAt;
    if (endsAt == null) return 1;
    final days = endsAt.difference(DateUtils.dateOnly(_scheduledAt)).inDays;
    return days < 1 ? 1 : days + 1;
  }

  /// A single date, or the two ends of a span.
  String get _dateValue {
    final endsAt = _endsAt;
    if (endsAt == null) return _formatDate(_scheduledAt);
    return '${_formatDate(_scheduledAt)} – ${_formatDate(endsAt)}';
  }

  Future<void> _pickTime(BuildContext pickerContext) async {
    FocusScope.of(pickerContext).unfocus();
    final selected = await showTimePicker(
      context: pickerContext,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt),
      helpText: '계획 시간',
      cancelText: '취소',
      confirmText: '선택',
    );
    if (selected == null || !mounted) return;
    setState(() {
      _scheduledAt = DateTime(
        _scheduledAt.year,
        _scheduledAt.month,
        _scheduledAt.day,
        selected.hour,
        selected.minute,
      );
    });
  }

  Future<void> _pickScope(BuildContext sheetContext) async {
    FocusScope.of(sheetContext).unfocus();
    final picked = await showPlanScopeSheet(
      sheetContext,
      sources: widget.sources,
      selected: _scopes,
    );
    if (picked == null || !mounted) return;
    setState(() => _scopes = picked.scopes);
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    if (_formKey.currentState?.validate() != true) return;

    final draft = PlanDraft(
      title: _titleController.text.trim(),
      triggerKind: _triggerKind,
      recurrence: _recurrence,
      scheduledAt: _usesTime ? _scheduledAt : null,
      endsAt: _canSpanDays ? _endsAt : null,
      locationQuery: _usesLocation ? _locationController.text.trim() : null,
      sourceCaptureId: _sourceValue == _noSourceValue ? null : _sourceValue,
      scopes: _scopes,
      leadTime: _usesTime ? _leadTime : PlanLeadTime.onTime,
    );
    widget.onSave?.call(draft);
    if (widget.popOnSave) Navigator.of(context).pop(draft);
  }

  static String _formatDate(DateTime value) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return '${value.year}. ${value.month}. ${value.day}. '
        '(${weekdays[value.weekday - 1]})';
  }

  static String _formatTime(BuildContext context, DateTime value) {
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(value));
  }

  static String _recurrenceLabel(PlanDraftRecurrence recurrence) {
    return switch (recurrence) {
      PlanDraftRecurrence.once => '한 번만',
      PlanDraftRecurrence.daily => '매일',
      PlanDraftRecurrence.weekly => '매주',
      PlanDraftRecurrence.onReentry => '장소를 다시 방문할 때',
    };
  }
}

final class _EditorIntroduction extends StatelessWidget {
  const _EditorIntroduction();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.planMauveSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Padding(
        padding: EdgeInsets.fromLTRB(16, 15, 16, 15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.notifications_none_rounded,
              color: AppTheme.planMauve,
              size: 21,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '시간이나 장소가 맞으면 저장해 둔 정보를 다시 꺼내 드릴게요.',
                style: TextStyle(
                  color: AppTheme.planInk,
                  fontSize: 14,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          description,
          style: const TextStyle(
            color: AppTheme.planMuted,
            fontSize: 13,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

/// The row that stands where a condition would be, if it were on.
///
/// A plan needs a time or a place, and having said one it can have the other.
/// This is that offer — the same height as the field it turns into, so adding
/// a condition does not make the form jump.
final class _AddCondition extends StatelessWidget {
  const _AddCondition({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.planBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: label,
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(icon, color: AppTheme.planSubtle, size: 19),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: AppTheme.planMuted,
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.add_rounded,
                      color: AppTheme.planSubtle,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _LeadTimeField extends StatelessWidget {
  const _LeadTimeField({
    required this.leadTime,
    required this.notifyAt,
    required this.onChanged,
    super.key,
  });

  final PlanLeadTime leadTime;
  final DateTime notifyAt;
  final ValueChanged<PlanLeadTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.planSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.planBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 66),
          child: Row(
            children: [
              const Icon(
                Icons.notifications_active_outlined,
                color: AppTheme.planMauve,
                size: 21,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '알림',
                      style: TextStyle(
                        color: AppTheme.planSubtle,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      leadTime == PlanLeadTime.onTime
                          ? '계획 시각에'
                          : leadTime.label,
                      style: const TextStyle(
                        color: AppTheme.planInk,
                        fontSize: 15,
                        height: 1.35,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _notifyLabel(context, notifyAt),
                      style: const TextStyle(
                        color: AppTheme.planMuted,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              DropdownButtonHideUnderline(
                child: DropdownButton<PlanLeadTime>(
                  key: const Key('plan-lead-time-menu'),
                  value: leadTime,
                  borderRadius: BorderRadius.circular(14),
                  dropdownColor: AppTheme.planSurface,
                  icon: const Icon(
                    Icons.expand_more_rounded,
                    color: AppTheme.planSubtle,
                  ),
                  items: [
                    for (final lead in PlanLeadTime.values)
                      DropdownMenuItem(
                        value: lead,
                        child: Text(
                          lead.label,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) onChanged(value);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _notifyLabel(BuildContext context, DateTime value) {
    final clock = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(value));
    return '${value.month}월 ${value.day}일 $clock에 알려드려요';
  }
}

final class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.onRemove,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  /// Turns this condition off. Null where the plan would be left waiting for
  /// nothing at all.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.planSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.planBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: '$label, $value',
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(icon, color: AppTheme.planMauve, size: 21),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: const TextStyle(
                              color: AppTheme.planSubtle,
                              fontSize: 12,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            value,
                            style: const TextStyle(
                              color: AppTheme.planInk,
                              fontSize: 15,
                              height: 1.35,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (onRemove case final remove?)
                      IconButton(
                        key: const Key('plan-remove-time'),
                        onPressed: remove,
                        icon: const Icon(Icons.close_rounded, size: 19),
                        color: AppTheme.planSubtle,
                        tooltip: '시간 빼기',
                      )
                    else
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.planSubtle,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _NoSourceNotice extends StatelessWidget {
  const _NoSourceNotice();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('plan-no-source-notice'),
      decoration: BoxDecoration(
        color: AppTheme.planSurface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.planBorder),
      ),
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.link_off_rounded, color: AppTheme.planSubtle, size: 20),
            SizedBox(width: 11),
            Expanded(
              child: Text(
                '연결할 콘텐츠가 없어도 계획은 만들 수 있어요.',
                style: TextStyle(
                  color: AppTheme.planMuted,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
