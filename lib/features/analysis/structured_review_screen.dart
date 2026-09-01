import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/place_reminder_service.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../common/capture_action_ui.dart';
import '../common/tag_ui.dart';
import '../sharing/share_tip_screen.dart';

typedef MapOpenedCallback =
    FutureOr<void> Function({
      required MapProvider provider,
      required String captureId,
      String? planId,
    });

final class StructuredReviewScreen extends StatefulWidget {
  const StructuredReviewScreen({
    required this.controller,
    required this.captureId,
    this.planId,
    this.onMapOpened,
    super.key,
  });

  final AppController controller;
  final String captureId;
  final String? planId;
  final MapOpenedCallback? onMapOpened;

  @override
  State<StructuredReviewScreen> createState() => _StructuredReviewScreenState();
}

final class _StructuredReviewScreenState extends State<StructuredReviewScreen> {
  var _saving = false;
  List<ContentTag>? _selectedTags;

  @override
  Widget build(BuildContext context) {
    final capture = widget.controller.captureById(widget.captureId);
    final structured = capture?.analysis?.structuredContent;
    if (capture == null || structured == null) {
      return const Scaffold(body: Center(child: Text('분석 결과를 찾지 못했어요.')));
    }
    final isOrganized = capture.status == CaptureStatus.organized;
    final isPortableTip = capture.raw.origin == CaptureOrigin.portableTip;
    final selectedTags = _selectedTags ?? capture.contentTags;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isPortableTip
              ? '받은 팁'
              : isOrganized
              ? '저장한 정보'
              : '분석 결과',
        ),
        actions: [
          IconButton(
            tooltip: '정보 보내기',
            onPressed: () => ShareTipScreen.open(context, capture),
            icon: const Icon(Icons.ios_share_rounded),
          ),
          IconButton(
            key: const Key('delete-capture-detail'),
            tooltip: '콘텐츠 삭제',
            onPressed: _saving ? null : _delete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
        children: [
          Row(
            children: [
              const _ResultMark(),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isPortableTip
                      ? '친구에게 받은 정보'
                      : isOrganized
                      ? '정리함에 저장됨'
                      : '분석 결과',
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            structured.title.value?.trim().isNotEmpty == true
                ? structured.title.value!
                : '제목을 확인해 주세요',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          if (structured.title.status != ObservedStatus.observed) ...[
            const SizedBox(height: 8),
            Text(
              structured.title.status == ObservedStatus.inferred
                  ? '이미지 내용으로 추정한 제목이에요.'
                  : '이미지에서 제목을 확인하지 못했어요.',
              style: const TextStyle(
                color: AppTheme.caution,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (structured.summary.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              structured.summary,
              style: const TextStyle(
                color: AppTheme.muted,
                fontSize: 15,
                height: 1.55,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _KindBadge(kind: structured.contentKind),
              _CompletenessBadge(completeness: structured.completeness),
            ],
          ),
          if (capture.raw.attachments.isNotEmpty) ...[
            const SizedBox(height: 24),
            _SourceGallery(attachments: capture.raw.attachments),
          ],
          const SizedBox(height: 32),
          _SectionTitle(title: isPortableTip ? '받은 태그' : '태그', editable: true),
          const SizedBox(height: 14),
          TagEditor(
            key: const Key('content-tag-editor'),
            tags: selectedTags,
            onChanged: (tags) {
              setState(() => _selectedTags = tags);
              // Already filed, so a change here is a correction to something
              // the library is showing rather than part of filing it.
              if (isOrganized) {
                unawaited(
                  widget.controller.updateCaptureTags(widget.captureId, tags),
                );
              }
            },
          ),
          if (structured.place case final place? when place.hasAddress) ...[
            const SizedBox(height: 32),
            const _SectionTitle(title: '장소'),
            const SizedBox(height: 12),
            _PlaceCard(
              captureId: capture.raw.id,
              title: place.name ?? structured.title.value ?? '저장한 장소',
              place: place,
              planId: widget.planId,
              onMapOpened: widget.onMapOpened,
            ),
          ],
          if (structured.conflicts.isNotEmpty ||
              structured.warnings.isNotEmpty) ...[
            const SizedBox(height: 20),
            _ReviewNotice(structured: structured),
          ],
          if (structured.ingredientGroups.isNotEmpty) ...[
            const SizedBox(height: 32),
            const _SectionTitle(title: '재료'),
            const SizedBox(height: 12),
            for (final group in structured.ingredientGroups) ...[
              _IngredientGroupCard(group: group),
              const SizedBox(height: 12),
            ],
          ],
          if (structured.steps.isNotEmpty) ...[
            const SizedBox(height: 20),
            const _SectionTitle(title: '만드는 순서'),
            const SizedBox(height: 12),
            _StepsCard(steps: structured.steps),
          ],
          if (structured.facts.isNotEmpty) ...[
            const SizedBox(height: 32),
            const _SectionTitle(title: '화면에서 확인한 정보'),
            const SizedBox(height: 12),
            _FactsCard(facts: structured.facts),
          ],
          if (structured.evidence.isNotEmpty) ...[
            const SizedBox(height: 32),
            _EvidenceDisclosure(evidence: structured.evidence),
          ],
        ],
      ),
      bottomNavigationBar: isOrganized
          ? null
          : SafeArea(
              top: false,
              maintainBottomViewPadding: true,
              minimum: const EdgeInsets.only(
                bottom: AppTheme.bottomSheetSafeInset,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  border: const Border(top: BorderSide(color: AppTheme.border)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 20,
                      offset: const Offset(0, -6),
                    ),
                  ],
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _confirm,
                    child: Text(_saving ? '저장하고 있어요…' : '정리함에 저장'),
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _confirm() async {
    final capture = widget.controller.captureById(widget.captureId);
    if (capture == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.confirmStructured(
        widget.captureId,
        tags: _selectedTags ?? capture.contentTags,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('저장하지 못했어요. 잠시 후 다시 시도해 주세요.')),
          );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _delete() async {
    final deleted = await confirmCaptureDeletion(
      context,
      controller: widget.controller,
      captureId: widget.captureId,
    );
    if (deleted && mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _SourceGallery extends StatefulWidget {
  const _SourceGallery({required this.attachments});

  final List<IncomingAttachment> attachments;

  @override
  State<_SourceGallery> createState() => _SourceGalleryState();
}

final class _SourceGalleryState extends State<_SourceGallery> {
  var _page = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '원본 캡처',
                style: TextStyle(
                  color: AppTheme.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (widget.attachments.length > 1)
              Text(
                '${_page + 1} / ${widget.attachments.length}',
                style: const TextStyle(
                  color: AppTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        AspectRatio(
          aspectRatio: 4 / 5,
          child: PageView.builder(
            itemCount: widget.attachments.length,
            onPageChanged: (page) => setState(() => _page = page),
            itemBuilder: (context, index) {
              final attachment = widget.attachments[index];
              return Padding(
                padding: EdgeInsets.only(
                  right: index == widget.attachments.length - 1 ? 0 : 8,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: ColoredBox(
                    color: AppTheme.surfaceRaised,
                    child: Image.file(
                      File(attachment.filePath),
                      fit: BoxFit.cover,
                      semanticLabel: '원본 캡처 ${index + 1}',
                      errorBuilder: (_, _, _) => const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.broken_image_outlined,
                              color: AppTheme.subtle,
                              size: 36,
                            ),
                            SizedBox(height: 8),
                            Text(
                              '이미지를 불러오지 못했어요',
                              style: TextStyle(
                                color: AppTheme.muted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

final class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final ContentKind kind;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (kind) {
      ContentKind.recipe => ('레시피', Icons.restaurant_menu_rounded),
      ContentKind.sauceRecipe => ('소스 레시피', Icons.soup_kitchen_outlined),
      ContentKind.commerceProduct => ('상품', Icons.shopping_bag_outlined),
      ContentKind.productReview => ('리뷰', Icons.rate_review_outlined),
      ContentKind.menuComparison => ('메뉴 비교', Icons.compare_arrows_rounded),
      ContentKind.beautyProduct => ('뷰티 제품', Icons.spa_outlined),
      ContentKind.place => ('장소', Icons.location_on_outlined),
      ContentKind.unknown => ('정보', Icons.article_outlined),
    };
    return _Badge(label: label, icon: icon, color: AppTheme.primary);
  }
}

final class _CompletenessBadge extends StatelessWidget {
  const _CompletenessBadge({required this.completeness});

  final StructuredCompleteness completeness;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (completeness) {
      StructuredCompleteness.complete => ('내용 충분', AppTheme.positive),
      StructuredCompleteness.partial => ('일부만 확인', AppTheme.caution),
      StructuredCompleteness.conflicted => ('서로 다른 내용', AppTheme.negative),
      StructuredCompleteness.needsReview => ('확인 필요', AppTheme.caution),
      StructuredCompleteness.unsupported => ('분류 어려움', AppTheme.muted),
    };
    return _Badge(label: label, icon: Icons.check_circle_outline, color: color);
  }
}

final class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.icon, required this.color});

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.editable = false});

  final String title;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: AppTheme.ink,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (editable) ...[
              const Icon(Icons.edit_rounded, size: 16, color: AppTheme.muted),
              const SizedBox(width: 4),
              const Text(
                '수정 가능',
                style: TextStyle(
                  color: AppTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

final class _IngredientGroupCard extends StatelessWidget {
  const _IngredientGroupCard({required this.group});

  final IngredientGroup group;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (group.name.trim().isNotEmpty) ...[
            Text(
              group.name,
              style: const TextStyle(
                color: AppTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final ingredient in group.ingredients)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      ingredient.name,
                      style: const TextStyle(
                        color: AppTheme.ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    _ingredientAmount(ingredient),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color:
                          ingredient.amount == null && ingredient.unit == null
                          ? AppTheme.subtle
                          : AppTheme.muted,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _ingredientAmount(RecipeIngredient ingredient) {
    final amount = [
      ingredient.amount,
      ingredient.unit,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' ');
    if (amount.isNotEmpty) {
      return ingredient.optional ? '$amount · 선택' : amount;
    }
    return ingredient.optional ? '분량 미표기 · 선택' : '분량 미표기';
  }
}

final class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.steps});

  final List<RecipeStep> steps;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: AppTheme.primarySoft,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${step.order}',
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.instruction,
                          style: const TextStyle(
                            color: AppTheme.ink,
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),
                        if (step.durationSeconds != null ||
                            step.temperature != null) ...[
                          const SizedBox(height: 5),
                          Text(
                            [
                              if (step.durationSeconds case final seconds?)
                                _formatDuration(seconds),
                              ?step.temperature,
                            ].join(' · '),
                            style: const TextStyle(
                              color: AppTheme.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _formatDuration(int seconds) {
    if (seconds < 60) {
      return '$seconds초';
    }
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return remainder == 0 ? '$minutes분' : '$minutes분 $remainder초';
  }
}

final class _FactsCard extends StatelessWidget {
  const _FactsCard({required this.facts});

  final List<AnalysisFact> facts;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (final fact in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 138,
                    child: Text(
                      fact.label,
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      fact.value,
                      style: const TextStyle(
                        color: AppTheme.ink,
                        fontSize: 14,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

final class _EvidenceDisclosure extends StatefulWidget {
  const _EvidenceDisclosure({required this.evidence});

  final List<StructuredEvidence> evidence;

  @override
  State<_EvidenceDisclosure> createState() => _EvidenceDisclosureState();
}

final class _EvidenceDisclosureState extends State<_EvidenceDisclosure> {
  var _expanded = false;

  void _toggle() {
    final expanding = !_expanded;
    setState(() => _expanded = expanding);
    if (!expanding) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.08,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: AppTheme.surfaceRaised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppTheme.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('analysis-evidence-disclosure'),
            onTap: _toggle,
            child: Semantics(
              button: true,
              label: _expanded ? '원본 근거 접기' : '원본 근거 펼치기',
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.fact_check_outlined,
                      color: AppTheme.muted,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '원본 근거',
                        style: TextStyle(
                          color: AppTheme.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: AppTheme.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 10),
          _EvidenceCard(evidence: widget.evidence),
        ],
      ],
    );
  }
}

final class _EvidenceCard extends StatelessWidget {
  const _EvidenceCard({required this.evidence});

  final List<StructuredEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (var index = 0; index < evidence.length; index++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.format_quote_rounded,
                    size: 17,
                    color: AppTheme.subtle,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      evidence[index].text,
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (index != evidence.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

final class _ReviewNotice extends StatelessWidget {
  const _ReviewNotice({required this.structured});

  final StructuredContentAnalysis structured;

  @override
  Widget build(BuildContext context) {
    final messages = [
      ...structured.conflicts.map(
        (conflict) => '${conflict.field}: ${conflict.details}',
      ),
      ...structured.warnings,
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B1F13),
        border: Border.all(color: AppTheme.caution),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: AppTheme.caution,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              messages.join('\n'),
              style: const TextStyle(
                color: AppTheme.ink,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _PlaceCard extends StatefulWidget {
  const _PlaceCard({
    required this.captureId,
    required this.title,
    required this.place,
    this.planId,
    this.onMapOpened,
  });

  final String captureId;
  final String title;
  final StructuredPlace place;
  final String? planId;
  final MapOpenedCallback? onMapOpened;

  @override
  State<_PlaceCard> createState() => _PlaceCardState();
}

final class _PlaceCardState extends State<_PlaceCard>
    with WidgetsBindingObserver {
  static const _service = PlaceReminderService();

  var _enabled = false;
  var _radiusMeters = PlaceReminderService.defaultRadiusMeters;
  var _foregroundGranted = false;
  var _backgroundGranted = false;
  var _backgroundPermissionLabel = '항상 허용';
  var _loading = true;
  var _busy = false;
  var _radiusEffectRevision = 0;
  var _waitingForBackgroundPermission = false;

  String get _address => widget.place.address!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed ||
        !_waitingForBackgroundPermission) {
      return;
    }
    _waitingForBackgroundPermission = false;
    _resumeAfterSettings();
  }

  Future<void> _loadState() async {
    try {
      final state = await _service.getState(widget.captureId);
      if (!mounted) return;
      setState(() {
        _enabled = state.enabled;
        _radiusMeters = state.radiusMeters;
        _foregroundGranted = state.foregroundGranted;
        _backgroundGranted = state.backgroundGranted;
        _backgroundPermissionLabel = state.backgroundPermissionLabel;
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resumeAfterSettings() async {
    try {
      final state = await _service.getState(widget.captureId);
      if (!mounted) return;
      setState(() {
        _enabled = state.enabled;
        _radiusMeters = state.radiusMeters;
        _foregroundGranted = state.foregroundGranted;
        _backgroundGranted = state.backgroundGranted;
        _backgroundPermissionLabel = state.backgroundPermissionLabel;
      });
      if (state.backgroundGranted) {
        await _enable();
        return;
      }
      setState(() => _busy = false);
      _showMessage('위치 권한을 “${state.backgroundPermissionLabel}”으로 바꿔 주세요.');
    } on Object {
      if (!mounted) return;
      setState(() => _busy = false);
      _showMessage('위치 권한 상태를 확인하지 못했어요.');
    }
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    if (value) {
      await _enable();
    } else {
      setState(() => _busy = true);
      try {
        await _service.disable(widget.captureId);
        if (mounted) setState(() => _enabled = false);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _enable() async {
    if (!_busy && mounted) setState(() => _busy = true);
    try {
      var result = await _service.enable(
        id: widget.captureId,
        title: widget.title,
        address: _address,
        radiusMeters: _radiusMeters,
      );
      if (!mounted) return;

      if (result.status ==
          PlaceReminderEnableStatus.needsForegroundPermission) {
        final granted = await _service.requestForegroundPermission();
        if (!granted || !mounted) {
          _showMessage('근처 알림을 받으려면 위치 권한이 필요해요.');
          return;
        }
        setState(() => _foregroundGranted = true);
        result = await _service.enable(
          id: widget.captureId,
          title: widget.title,
          address: _address,
          radiusMeters: _radiusMeters,
        );
      }
      if (!mounted) return;

      switch (result.status) {
        case PlaceReminderEnableStatus.enabled:
          setState(() {
            _enabled = true;
            _foregroundGranted = true;
            _backgroundGranted = true;
            _radiusMeters = result.radiusMeters ?? _radiusMeters;
          });
          _showMessage('${_formatRadius(_radiusMeters)} 안에 들어오면 알려드릴게요.');
        case PlaceReminderEnableStatus.needsBackgroundPermission:
          final label = result.backgroundPermissionLabel ?? '항상 허용';
          setState(() {
            _foregroundGranted = true;
            _backgroundGranted = false;
            _backgroundPermissionLabel = label;
          });
          final openSettings = await _confirmBackgroundPermission(label);
          if (!mounted || !openSettings) return;
          _waitingForBackgroundPermission = true;
          await _service.openBackgroundLocationSettings();
          return;
        case PlaceReminderEnableStatus.addressNotFound:
          _showMessage('주소 위치를 찾지 못했어요. 주소가 더 선명한 캡처로 시도해 주세요.');
        case PlaceReminderEnableStatus.unavailable:
          _showMessage('근처 알림은 현재 안드로이드에서 사용할 수 있어요.');
        case PlaceReminderEnableStatus.failed:
          _showMessage('근처 알림을 켜지 못했어요. 잠시 후 다시 시도해 주세요.');
        case PlaceReminderEnableStatus.needsForegroundPermission:
          _showMessage('위치 권한을 허용해 주세요.');
      }
    } on Object {
      if (mounted) _showMessage('근처 알림을 켜지 못했어요.');
    } finally {
      if (mounted && !_waitingForBackgroundPermission) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openAlwaysAllowSettings() async {
    if (_busy) return;
    if (!Platform.isAndroid) {
      _showMessage('근처 알림 설정은 현재 안드로이드에서 사용할 수 있어요.');
      return;
    }
    setState(() => _busy = true);
    _waitingForBackgroundPermission = true;
    try {
      await _service.openBackgroundLocationSettings();
    } on Object {
      _waitingForBackgroundPermission = false;
      if (!mounted) return;
      setState(() => _busy = false);
      _showMessage('위치 설정을 열지 못했어요.');
    }
  }

  Future<bool> _confirmBackgroundPermission(String label) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('앱을 닫아도 알려드릴까요?'),
            content: Text(
              '설정에서 위치 권한을 “$label”으로 선택해 주세요. '
              '위치는 휴대폰 안에서만 확인해요.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('나중에'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('설정 열기'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _updateRadius(double value) async {
    if (mounted) {
      setState(() => _radiusEffectRevision++);
    }
    if (!_enabled || _busy) return;
    await _enable();
  }

  Future<void> _openMap({MapQueryMode mode = MapQueryMode.place}) async {
    try {
      final options = await _service.getMapProviderOptions();
      if (!mounted) return;
      final provider = await showModalBottomSheet<MapProvider>(
        context: context,
        useSafeArea: true,
        builder: (_) => _MapProviderSheet(options: options),
      );
      if (provider == null) return;
      final result = await _service.openMapWithProvider(
        provider: provider,
        name: widget.place.name,
        address: _address,
        searchArea: widget.place.searchArea,
        mode: mode,
      );
      final onMapOpened = widget.onMapOpened;
      if (onMapOpened != null) {
        try {
          await onMapOpened(
            provider: result.provider,
            captureId: widget.captureId,
            planId: widget.planId,
          );
        } on Object catch (error, stackTrace) {
          // Opening the map already succeeded. An analytics persistence
          // failure must not be presented as a navigation failure.
          debugPrint(
            'Map-open interaction recording failed: $error\n$stackTrace',
          );
        }
      }
    } on Object {
      if (mounted) _showMessage('지도를 열지 못했어요.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final category = _placeCategoryLabel(widget.place.category);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 116,
            width: double.infinity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned.fill(
                  child: CustomPaint(painter: _MapPainter()),
                ),
                _AnimatedMapRadius(
                  radiusMeters: _radiusMeters,
                  pulseRevision: _radiusEffectRevision,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (category != null) ...[
                  Text(
                    category,
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                ],
                Text(
                  widget.place.name ?? widget.title,
                  style: const TextStyle(
                    color: AppTheme.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _address,
                  style: const TextStyle(
                    color: AppTheme.muted,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openMap,
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text('지도에서 보기'),
                  ),
                ),
                if (widget.place.name != null) ...[
                  const SizedBox(height: 6),
                  // The captured address is often an SNS location tag rather
                  // than the shop's own address, so the default search leads
                  // with the name. This is the way back to the address when the
                  // name was read wrong.
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => _openMap(mode: MapQueryMode.address),
                      child: const Text(
                        '주소로만 찾기',
                        style: TextStyle(color: AppTheme.muted, fontSize: 13),
                      ),
                    ),
                  ),
                ],
                const Divider(height: 34),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '근처에 가면 알림',
                        style: TextStyle(
                          color: AppTheme.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_loading || _busy)
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Switch(value: _enabled, onChanged: _toggle),
                  ],
                ),
                if (!_loading && !_backgroundGranted) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(13, 12, 13, 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2B1F13),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.caution),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(
                                Icons.location_disabled_outlined,
                                size: 18,
                                color: AppTheme.caution,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _foregroundGranted
                                        ? '“$_backgroundPermissionLabel”이 필요해요'
                                        : '위치 권한이 필요해요',
                                    style: const TextStyle(
                                      color: AppTheme.ink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _foregroundGranted
                                        ? '권한 → 위치 → $_backgroundPermissionLabel'
                                        : '근처 알림을 켜려면 먼저 허용해 주세요.',
                                    style: const TextStyle(
                                      color: AppTheme.muted,
                                      fontSize: 12,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            onPressed: _busy
                                ? null
                                : _foregroundGranted
                                ? _openAlwaysAllowSettings
                                : _enable,
                            icon: Icon(
                              _foregroundGranted
                                  ? Icons.settings_outlined
                                  : Icons.location_on_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _foregroundGranted ? '항상 허용 설정 열기' : '위치 권한 허용하기',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Text(
                      '알림 반경',
                      style: TextStyle(color: AppTheme.muted, fontSize: 14),
                    ),
                    const Spacer(),
                    Text(
                      _formatRadius(_radiusMeters),
                      style: const TextStyle(
                        color: AppTheme.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Slider(
                  min: PlaceReminderService.minRadiusMeters,
                  max: PlaceReminderService.maxRadiusMeters,
                  divisions: 49,
                  value: _radiusMeters.clamp(
                    PlaceReminderService.minRadiusMeters,
                    PlaceReminderService.maxRadiusMeters,
                  ),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _radiusMeters = value),
                  onChangeEnd: _updateRadius,
                ),
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 15,
                      color: AppTheme.subtle,
                    ),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '위치는 휴대폰 안에서만 확인해요.',
                        style: TextStyle(
                          color: AppTheme.subtle,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatRadius(double meters) {
    if (meters < 1000) return '${meters.round()}m';
    final kilometers = meters / 1000;
    return '${kilometers.toStringAsFixed(kilometers == kilometers.round() ? 0 : 1)}km';
  }

  static String? _placeCategoryLabel(PlaceCategory? category) =>
      switch (category) {
        PlaceCategory.restaurant => '맛집',
        PlaceCategory.cafe => '카페',
        PlaceCategory.beauty => '뷰티',
        PlaceCategory.shopping => '쇼핑',
        PlaceCategory.lodging => '숙소',
        PlaceCategory.activity => '놀거리',
        PlaceCategory.other => '장소',
        null => null,
      };
}

final class _MapProviderSheet extends StatelessWidget {
  const _MapProviderSheet({required this.options});

  final List<MapProviderOption> options;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('어떤 지도로 볼까요?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            const Text(
              '설치된 앱을 먼저 열고, 없으면 웹 지도로 연결해요.',
              style: TextStyle(color: AppTheme.muted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            for (final option in options) ...[
              Material(
                color: AppTheme.surfaceRaised,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  key: ValueKey('map-provider-${option.provider.id}'),
                  enabled: option.available,
                  minTileHeight: 64,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  leading: _MapProviderMark(provider: option.provider),
                  title: Text(
                    option.label,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    option.available ? option.destinationLabel : '열 수 없음',
                  ),
                  trailing: const Icon(Icons.arrow_forward_rounded, size: 19),
                  onTap: option.available
                      ? () => Navigator.pop(context, option.provider)
                      : null,
                ),
              ),
              if (option != options.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

final class _MapProviderMark extends StatelessWidget {
  const _MapProviderMark({required this.provider});

  final MapProvider provider;

  @override
  Widget build(BuildContext context) {
    final (label, background, foreground) = switch (provider) {
      MapProvider.naver => ('N', const Color(0xFF03C75A), Colors.white),
      MapProvider.kakao => (
        'K',
        const Color(0xFFFEE500),
        const Color(0xFF191919),
      ),
      MapProvider.google => ('G', const Color(0xFF4285F4), Colors.white),
    };
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

final class _AnimatedMapRadius extends StatefulWidget {
  const _AnimatedMapRadius({
    required this.radiusMeters,
    required this.pulseRevision,
  });

  final double radiusMeters;
  final int pulseRevision;

  @override
  State<_AnimatedMapRadius> createState() => _AnimatedMapRadiusState();
}

final class _AnimatedMapRadiusState extends State<_AnimatedMapRadius>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );

  @override
  void didUpdateWidget(covariant _AnimatedMapRadius oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulseRevision != widget.pulseRevision) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  double get _targetDiameter {
    final normalized =
        ((widget.radiusMeters - PlaceReminderService.minRadiusMeters) /
                (PlaceReminderService.maxRadiusMeters -
                    PlaceReminderService.minRadiusMeters))
            .clamp(0.0, 1.0);
    return 62 + (Curves.easeOut.transform(normalized) * 50);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 46, end: _targetDiameter),
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 820),
          curve: Curves.easeInOutCubic,
          builder: (context, diameter, _) {
            return AnimatedBuilder(
              animation: _pulseController,
              builder: (context, _) {
                final pulse = reduceMotion ? 1.0 : _pulseController.value;
                final pulseOpacity = reduceMotion
                    ? 0.0
                    : (1 - Curves.easeOut.transform(pulse)) * 0.42;
                final pulseDiameter = diameter + (pulse * 34);
                return SizedBox.square(
                  dimension: 116,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                        opacity: pulseOpacity,
                        child: Container(
                          width: pulseDiameter,
                          height: pulseDiameter,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppTheme.primary,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                      Container(
                        width: diameter,
                        height: diameter,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.primary.withValues(alpha: 0.12),
                          border: Border.all(
                            color: AppTheme.primary.withValues(alpha: 0.62),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.16),
                              blurRadius: 18,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.28),
                              blurRadius: 16,
                              offset: const Offset(0, 7),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.location_on_rounded,
                          color: AppTheme.background,
                          size: 25,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

final class _MapPainter extends CustomPainter {
  const _MapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1C211D),
    );
    final roadPaint = Paint()
      ..color = const Color(0xFF333936)
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(-12, size.height * 0.78),
      Offset(size.width + 18, size.height * 0.22),
      roadPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.18, -10),
      Offset(size.width * 0.72, size.height + 10),
      roadPaint..strokeWidth = 9,
    );
    final blockPaint = Paint()..color = const Color(0xFF252C28);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(18, 14, size.width * 0.24, 29),
        const Radius.circular(8),
      ),
      blockPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.72, 68, size.width * 0.2, 30),
        const Radius.circular(8),
      ),
      blockPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

final class _ResultMark extends StatelessWidget {
  const _ResultMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.14),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.36)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Icon(
        Icons.auto_awesome_rounded,
        size: 22,
        color: AppTheme.primary,
      ),
    );
  }
}
