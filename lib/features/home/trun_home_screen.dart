import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../common/shell_menu_button.dart';
import '../plans/plan_date_dialog.dart';
import '../plans/plan_editor_screen.dart';
import '../plans/plan_scope_sheet.dart';

final class TrunHomeScreen extends StatelessWidget {
  const TrunHomeScreen({
    required this.onAdd,
    this.onOpenMenu,
    this.onSubmitPlan,
    this.planSources = const <PlanSourceOption>[],
    super.key,
  });

  final VoidCallback onAdd;

  /// Opens the bar that slides in from the left. Null where there is no
  /// drawer to open, which is how the screen is pumped on its own in tests.
  final VoidCallback? onOpenMenu;

  /// What a sent prompt becomes: a plan, made through the flow 계획함 already
  /// uses. Null when plans are not available at all, and then the box does not
  /// pretend it can send.
  final ValueChanged<PlanDraft>? onSubmitPlan;

  /// What the reader saved, for the one condition that has to count it — the
  /// folders a plan will search.
  final List<PlanSourceOption> planSources;

  @override
  Widget build(BuildContext context) {
    // Three bands, top to bottom: the menu and the way to add content, the line
    // floating in the middle of what is left over, and the box at the bottom
    // within reach of a thumb.
    //
    // Nothing else. 콘텐츠 used to sit under the box; the drawer holds it now,
    // and a door to the same place on the screen behind the drawer was the
    // second thing to read before the only thing home asks for.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: _Masthead(onAdd: onAdd, onOpenMenu: onOpenMenu),
        ),
        // Takes whatever the bottom does not, which is what puts the line in
        // the middle of the empty space rather than a fixed distance above the
        // box. Scrolls rather than clips when a large text size leaves it
        // nothing.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Center(child: _Headline()),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
          child: _PromptBox(onSubmit: onSubmitPlan, sources: planSources),
        ),
      ],
    );
  }
}

/// Home's top row: a way out on the left, a way in on the right.
///
/// No name in the middle. Home says what it is with one line in the middle of
/// the screen, and the same word twice would be the third thing to read before
/// the box.
final class _Masthead extends StatelessWidget {
  const _Masthead({required this.onAdd, required this.onOpenMenu});

  final VoidCallback onAdd;
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return ShellHeader(
      onOpenMenu: onOpenMenu,
      actions: [
        IconButton.filled(
          tooltip: '콘텐츠 추가',
          onPressed: onAdd,
          style: IconButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: const Color(0xFF101208),
          ),
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    );
  }
}

enum _Condition {
  date('날짜', Icons.event_rounded),
  time('시간', Icons.schedule_rounded),
  place('장소', Icons.place_outlined),
  recurrence('반복', Icons.repeat_rounded),
  scope('찾을 폴더', Icons.folder_outlined);

  const _Condition(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Home's own input: one box, typed into rather than tapped through.
///
/// Sending it opens 계획 만들기 with what is here already filled in. The box is
/// a way into that flow, not a second copy of it — every question left unasked
/// here is still asked there.
final class _PromptBox extends StatefulWidget {
  const _PromptBox({required this.onSubmit, required this.sources});

  final ValueChanged<PlanDraft>? onSubmit;
  final List<PlanSourceOption> sources;

  @override
  State<_PromptBox> createState() => _PromptBoxState();
}

final class _PromptBoxState extends State<_PromptBox> {
  final _prompt = TextEditingController();
  final _addButtonKey = GlobalKey();

  // Null means the condition was never added, which is different from an empty
  // one: no scope chip at all searches everywhere, and so does a scope chip set
  // to 어디서든 — but only one of the two is a thing the reader said.
  DateTime? _startDate;
  DateTime? _endDate;
  TimeOfDay? _time;
  String? _place;
  PlanDraftRecurrence? _recurrence;
  List<String>? _scopes;

  @override
  void initState() {
    super.initState();
    _prompt.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  bool _has(_Condition condition) => switch (condition) {
    _Condition.date => _startDate != null,
    _Condition.time => _time != null,
    _Condition.place => _place != null,
    _Condition.recurrence => _recurrence != null,
    _Condition.scope => _scopes != null,
  };

  /// The recurrences that mean anything for what has been said so far.
  ///
  /// 장소를 다시 방문할 때 needs a place to re-enter. The editor draws the same
  /// line, and re-checks it on arrival, so a chip set before a place was
  /// removed cannot survive into a plan.
  List<PlanDraftRecurrence> get _availableRecurrences {
    final hasPlace = _place != null;
    final hasTime = _startDate != null || _time != null;
    if (hasPlace && !hasTime) {
      return const [PlanDraftRecurrence.once, PlanDraftRecurrence.onReentry];
    }
    return const [
      PlanDraftRecurrence.once,
      PlanDraftRecurrence.daily,
      PlanDraftRecurrence.weekly,
    ];
  }

  Future<void> _add() async {
    final missing = _Condition.values
        .where((one) => !_has(one))
        .toList(growable: false);
    if (missing.isEmpty) return;

    final box = _addButtonKey.currentContext!.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showMenu<_Condition>(
      context: context,
      color: AppTheme.surfaceRaised,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height,
        overlay.size.width - origin.dx - box.size.width,
        overlay.size.height - origin.dy,
      ),
      items: [
        for (final condition in missing)
          PopupMenuItem<_Condition>(
            value: condition,
            height: 44,
            child: Row(
              children: [
                Icon(condition.icon, size: 18, color: AppTheme.muted),
                const SizedBox(width: 10),
                Text(
                  condition.label,
                  style: const TextStyle(
                    color: AppTheme.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (picked != null && mounted) await _edit(picked);
  }

  Future<void> _edit(_Condition condition) async {
    switch (condition) {
      case _Condition.date:
        final now = DateTime.now();
        final range = await showPlanDateDialog(
          context,
          initialStart: _startDate ?? now,
          initialEnd: _endDate,
          firstDate: DateTime(now.year - 1),
          lastDate: DateTime(now.year + 5, 12, 31),
          // A span only reads as a span on a plan that happens once, which is
          // the line the editor draws too.
          allowRange:
              _recurrence == null || _recurrence == PlanDraftRecurrence.once,
        );
        if (range == null || !mounted) return;
        setState(() {
          _startDate = range.start;
          _endDate = range.end.isAfter(range.start) ? range.end : null;
        });
      case _Condition.time:
        final picked = await showTimePicker(
          context: context,
          initialTime: _time ?? TimeOfDay.fromDateTime(DateTime.now()),
          helpText: '계획 시간',
          cancelText: '취소',
          confirmText: '선택',
        );
        if (picked == null || !mounted) return;
        setState(() => _time = picked);
      case _Condition.place:
        final typed = await _askPlace();
        if (typed == null || !mounted) return;
        setState(() => _place = typed);
      case _Condition.recurrence:
        final picked = await _askRecurrence();
        if (picked == null || !mounted) return;
        setState(() => _recurrence = picked);
      case _Condition.scope:
        final choice = await showPlanScopeSheet(
          context,
          sources: widget.sources,
          selected: _scopes ?? const <String>[],
        );
        if (choice == null || !mounted) return;
        setState(() => _scopes = choice.scopes);
    }
  }

  /// A place is the one condition with nothing to pick from — it is typed.
  Future<String?> _askPlace() async {
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => _PlaceDialog(initial: _place ?? ''),
    );
    return typed == null || typed.isEmpty ? null : typed;
  }

  Future<PlanDraftRecurrence?> _askRecurrence() {
    return showDialog<PlanDraftRecurrence>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        backgroundColor: AppTheme.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        title: const Text('반복'),
        children: [
          for (final option in _availableRecurrences)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, option),
              child: Text(
                _recurrenceLabel(option),
                style: const TextStyle(
                  color: AppTheme.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _remove(_Condition condition) {
    setState(() {
      switch (condition) {
        case _Condition.date:
          _startDate = null;
          _endDate = null;
        case _Condition.time:
          _time = null;
        case _Condition.place:
          _place = null;
        case _Condition.recurrence:
          _recurrence = null;
        case _Condition.scope:
          _scopes = null;
      }
      // A recurrence the remaining conditions can no longer carry goes with
      // them, rather than being silently corrected on the next screen.
      if (_recurrence != null && !_availableRecurrences.contains(_recurrence)) {
        _recurrence = null;
      }
    });
  }

  /// The day and time the plan happens, or null when nothing was said about
  /// when.
  ///
  /// A time with no date is today, and tomorrow once today's has passed —
  /// nobody sets an alarm for a moment that is already behind them. A date with
  /// no time keeps the editor's own default hour, which the reader will see and
  /// can change there.
  DateTime? get _scheduledAt {
    final date = _startDate;
    final time = _time;
    if (date == null && time == null) return null;
    if (date == null) {
      final now = DateTime.now();
      final today = DateTime(
        now.year,
        now.month,
        now.day,
        time!.hour,
        time.minute,
      );
      return today.isAfter(now) ? today : today.add(const Duration(days: 1));
    }
    final hour = time ?? const TimeOfDay(hour: 9, minute: 0);
    return DateTime(date.year, date.month, date.day, hour.hour, hour.minute);
  }

  PlanDraft? get _draft {
    final title = _prompt.text.trim();
    if (title.isEmpty) return null;
    final place = _place;
    final hasTime = _startDate != null || _time != null;
    final hasPlace = place != null && place.isNotEmpty;
    return PlanDraft(
      title: title,
      triggerKind: hasPlace
          ? (hasTime
                ? PlanDraftTriggerKind.timeAndLocation
                : PlanDraftTriggerKind.location)
          : PlanDraftTriggerKind.time,
      recurrence: _recurrence ?? PlanDraftRecurrence.once,
      scheduledAt: _scheduledAt,
      endsAt: _endDate,
      locationQuery: hasPlace ? place : null,
      scopes: _scopes ?? const <String>[],
    );
  }

  void _send() {
    final draft = _draft;
    if (draft == null) return;
    // Cleared on the way out, conditions and all. Coming back from a saved plan
    // to the sentence that made it reads as though nothing happened.
    _prompt.clear();
    setState(() {
      _startDate = null;
      _endDate = null;
      _time = null;
      _place = null;
      _recurrence = null;
      _scopes = null;
    });
    FocusScope.of(context).unfocus();
    widget.onSubmit?.call(draft);
  }

  @override
  Widget build(BuildContext context) {
    final canSend = widget.onSubmit != null && _draft != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppTheme.border),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: TextField(
                    key: const Key('home-prompt-field'),
                    controller: _prompt,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    cursorColor: AppTheme.primary,
                    style: const TextStyle(
                      color: AppTheme.ink,
                      fontSize: 16,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                      hintText: '예: 성수에서 저장한 식당 가보기',
                      hintStyle: TextStyle(
                        color: AppTheme.subtle,
                        fontSize: 16,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_Condition.values.any((one) => !_has(one)))
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _AddConditionButton(
                          key: _addButtonKey,
                          onTap: _add,
                        ),
                      ),
                    Semantics(
                      button: true,
                      label: '보내기',
                      child: Material(
                        key: const Key('home-prompt-send'),
                        color: canSend ? AppTheme.primary : AppTheme.fill,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: canSend ? _send : null,
                          child: SizedBox.square(
                            dimension: 44,
                            child: Icon(
                              Icons.arrow_upward_rounded,
                              size: 22,
                              color: canSend
                                  ? const Color(0xFF101208)
                                  : AppTheme.subtle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_Condition.values.any(_has)) const SizedBox(height: 10),
        // Under the box rather than inside it. What is typed and what is picked
        // are two different acts, and the row grows as conditions are added.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final condition in _Condition.values)
              if (_has(condition))
                _ConditionChip(
                  condition: condition,
                  label: _valueLabel(condition),
                  onTap: () => _edit(condition),
                  onRemove: () => _remove(condition),
                ),
          ],
        ),
      ],
    );
  }

  String _valueLabel(_Condition condition) => switch (condition) {
    _Condition.date =>
      _endDate == null
          ? _formatDate(_startDate!)
          : '${_formatDate(_startDate!)} – ${_formatDate(_endDate!)}',
    _Condition.time => _time!.format(context),
    _Condition.place => _place!,
    _Condition.recurrence => _recurrenceLabel(_recurrence!),
    _Condition.scope => _scopeLabel(_scopes!),
  };

  static String _formatDate(DateTime value) => '${value.month}월 ${value.day}일';

  static String _recurrenceLabel(PlanDraftRecurrence value) => switch (value) {
    PlanDraftRecurrence.once => '한 번만',
    PlanDraftRecurrence.daily => '매일',
    PlanDraftRecurrence.weekly => '매주',
    PlanDraftRecurrence.onReentry => '다시 방문할 때',
  };

  /// The same shape [PlanScopeField] uses: one tag is named outright, more than
  /// one by the first and a count.
  static String _scopeLabel(List<String> scopes) {
    if (scopes.isEmpty) return '어디서든';
    return scopes.length == 1
        ? scopes.single
        : '${scopes.first} 외 ${scopes.length - 1}개';
  }
}

/// Types a place, and nothing else.
///
/// A widget rather than an inline builder so the field's controller belongs to
/// something with a `dispose` — disposing it the moment the dialog is popped
/// tears it out from under a `TextField` still on screen for the animation.
final class _PlaceDialog extends StatefulWidget {
  const _PlaceDialog({required this.initial});

  final String initial;

  @override
  State<_PlaceDialog> createState() => _PlaceDialogState();
}

final class _PlaceDialogState extends State<_PlaceDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.pop(context, _field.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      title: const Text('장소'),
      content: TextField(
        controller: _field,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(hintText: '예: 성수역, 서울숲길 24'),
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('확인')),
      ],
    );
  }
}

/// The `+` that offers the conditions not yet named.
final class _AddConditionButton extends StatelessWidget {
  const _AddConditionButton({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '조건 더하기',
      child: Material(
        key: const Key('home-prompt-add'),
        color: AppTheme.surface,
        shape: const CircleBorder(side: BorderSide(color: AppTheme.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const SizedBox.square(
            dimension: 44,
            child: Icon(Icons.add_rounded, size: 21, color: AppTheme.muted),
          ),
        ),
      ),
    );
  }
}

/// One condition the reader named, with what it was set to.
///
/// Tapping it opens the same picker again; the `×` takes it off. Both are on
/// the chip because a condition that can only be added is a condition a reader
/// is stuck with.
final class _ConditionChip extends StatelessWidget {
  const _ConditionChip({
    required this.condition,
    required this.label,
    required this.onTap,
    required this.onRemove,
  });

  final _Condition condition;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: Key('home-prompt-chip-${condition.name}'),
      color: AppTheme.primarySoft,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            child: Semantics(
              button: true,
              label: '${condition.label} $label, 바꾸기',
              child: ExcludeSemantics(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 36),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(13, 0, 8, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(condition.icon, size: 15, color: AppTheme.primary),
                        const SizedBox(width: 7),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 168),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.primary,
                              fontSize: 13,
                              height: 1.3,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          InkWell(
            onTap: onRemove,
            child: Semantics(
              button: true,
              label: '${condition.label} 빼기',
              child: const SizedBox(
                width: 30,
                height: 36,
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: AppTheme.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one line home says for itself, typed out as though something is asking.
///
/// The app's own verb — a reader who bought the name already knows what turning
/// something on means here, and the box below is where they answer.
///
/// It types once, on arrival, and then sits still. A line that kept animating
/// would be movement next to a text field, which is where a reader's attention
/// belongs.
final class _Headline extends StatefulWidget {
  const _Headline();

  @override
  State<_Headline> createState() => _HeadlineState();
}

final class _HeadlineState extends State<_Headline>
    with SingleTickerProviderStateMixin {
  static const _line = 'Turn it on.';

  /// Faint enough to sit beside the line without competing with it. The app's
  /// own amber, dimmed against the canvas rather than given a colour of its
  /// own.
  static final _beta = Color.alphaBlend(
    AppTheme.caution.withValues(alpha: 0.62),
    AppTheme.background,
  );

  static const _style = TextStyle(
    color: AppTheme.ink,
    fontSize: 34,
    height: 1.15,
    fontWeight: FontWeight.w900,
    letterSpacing: -1.2,
  );

  late final AnimationController _typing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 62 * _line.length),
  )..forward();

  @override
  void dispose() {
    _typing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _typing,
      builder: (context, _) {
        final shown = (_line.length * _typing.value).round();
        final done = _typing.isCompleted;
        // Shrunk rather than wrapped or clipped when it does not fit. One line
        // is the whole idea, and a narrow screen or a large text size would
        // otherwise break it across two or overflow the side.
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                alignment: Alignment.centerLeft,
                children: [
                  // The finished line, kept invisible so the box is its final
                  // size from the first frame. Without it the layout grows a
                  // character at a time and drags the box below it down the
                  // screen.
                  Opacity(opacity: 0, child: Text(_line, style: _style)),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: _line.substring(0, shown)),
                        if (!done)
                          const TextSpan(
                            text: '▌',
                            style: TextStyle(color: AppTheme.primary),
                          ),
                      ],
                    ),
                    style: _style,
                  ),
                ],
              ),
              const SizedBox(width: 7),
              // Raised beside the line rather than sitting under it, and only
              // once the line has finished typing — arriving with the first
              // character would make it part of the sentence.
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: AnimatedOpacity(
                  opacity: done ? 1 : 0,
                  duration: const Duration(milliseconds: 260),
                  child: Text(
                    'BETA',
                    style: TextStyle(
                      color: _beta,
                      fontSize: 11,
                      height: 1,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
