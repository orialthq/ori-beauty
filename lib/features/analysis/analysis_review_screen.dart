import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/formatters.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../common/capture_action_ui.dart';
import '../common/tag_ui.dart';
import '../common/product_ui.dart';

final class AnalysisReviewScreen extends StatefulWidget {
  const AnalysisReviewScreen({
    required this.controller,
    required this.captureId,
    super.key,
  });

  final AppController controller;
  final String captureId;

  @override
  State<AnalysisReviewScreen> createState() => _AnalysisReviewScreenState();
}

final class _AnalysisReviewScreenState extends State<AnalysisReviewScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _brandController;
  late final TextEditingController _nameController;
  late final TextEditingController _categoryController;
  late final TextEditingController _amountController;
  late List<ContentTag> _selectedTags;
  var _tagsEdited = false;
  var _saving = false;

  CaptureRecord? get _capture =>
      widget.controller.captureById(widget.captureId);

  @override
  void initState() {
    super.initState();
    final mention = _capture?.primaryMention;
    _brandController = TextEditingController(text: mention?.brand.value ?? '');
    _nameController = TextEditingController(text: mention?.name.value ?? '');
    _categoryController = TextEditingController(
      text: mention?.category.value ?? '',
    );
    _amountController = TextEditingController(
      text: mention?.amount.value ?? '',
    );
    _selectedTags = _capture?.contentTags ?? const <ContentTag>[];
  }

  @override
  void dispose() {
    _brandController.dispose();
    _nameController.dispose();
    _categoryController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capture = _capture;
    if (capture == null) {
      return const Scaffold(body: Center(child: Text('가져온 내용을 찾지 못했어요.')));
    }
    final analysis = capture.analysis;
    final mention = capture.primaryMention;
    final statements =
        analysis?.statements
            .where((statement) => statement.type != StatementType.disclosure)
            .toList(growable: false) ??
        const <ContentStatement>[];
    final platform = capture.normalized.urls.isEmpty
        ? SourcePlatform.textOnly
        : capture.normalized.urls.first.platform;
    if (capture.status == CaptureStatus.sourceLimited &&
        capture.raw.attachments.isEmpty &&
        capture.normalized.completeness == MaterialCompleteness.linkOnly) {
      return _LinkOnlyReview(
        capture: capture,
        platform: platform,
        onDelete: _delete,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('분석 결과'),
        actions: [
          IconButton(
            key: const Key('delete-capture-detail'),
            tooltip: '콘텐츠 삭제',
            onPressed: _saving ? null : _delete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            const Row(
              children: [
                _ResultMark(icon: Icons.auto_awesome_rounded),
                SizedBox(width: 10),
                Text(
                  '분석 결과',
                  style: TextStyle(
                    color: AppTheme.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text('이렇게 정리했어요', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              '저장하기 전에 잘못 읽힌 부분만 확인해 주세요.',
              style: TextStyle(color: AppTheme.muted, fontSize: 15),
            ),
            const SizedBox(height: 24),
            _OriginalMaterialCard(capture: capture, platform: platform),
            if (capture.normalized.warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              InfoBanner(
                icon: Icons.info_outline_rounded,
                title: '확인할 내용이 있어요',
                body: capture.normalized.warnings.join(' '),
                background: const Color(0xFF2B1F13),
              ),
            ],
            const SizedBox(height: 32),
            const _SectionHeading(title: '태그', editable: true),
            const SizedBox(height: 14),
            TagEditor(
              key: const Key('content-tag-editor'),
              tags: _selectedTags,
              onChanged: (tags) {
                setState(() {
                  _selectedTags = tags;
                  _tagsEdited = true;
                });
              },
            ),
            const SizedBox(height: 32),
            const _SectionHeading(
              title: '제품 정보',
              description: '같은 제품끼리 묶을 때 사용해요.',
            ),
            const SizedBox(height: 18),
            _AnalysisField(
              label: '브랜드',
              controller: _brandController,
              field: mention?.brand,
              requiredField: true,
            ),
            const SizedBox(height: 18),
            _AnalysisField(
              label: '제품명',
              controller: _nameController,
              field: mention?.name,
              requiredField: true,
            ),
            const SizedBox(height: 18),
            _AnalysisField(
              label: '카테고리',
              controller: _categoryController,
              field: mention?.category,
            ),
            const SizedBox(height: 18),
            _AnalysisField(
              label: '용량·규격',
              controller: _amountController,
              field: mention?.amount,
            ),
            const SizedBox(height: 36),
            const _SectionHeading(title: '콘텐츠에서 말한 점'),
            const SizedBox(height: 14),
            if (statements.isEmpty)
              const _NoStatementsCard()
            else
              _StatementList(statements: statements),
            const SizedBox(height: 32),
            const _SectionHeading(title: '광고·협찬'),
            const SizedBox(height: 14),
            _DisclosureCard(
              disclosure: analysis?.disclosure ?? DisclosureObservation.unknown,
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        maintainBottomViewPadding: true,
        minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _confirm,
                  child: Text(_saving ? '저장하고 있어요…' : '정리함에 저장'),
                ),
              ),
              const SizedBox(height: 2),
              TextButton(
                onPressed: _saving ? null : _keepUnresolved,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.muted,
                  minimumSize: const Size(44, 48),
                ),
                child: const Text('제품을 찾지 못했어요'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirm() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.confirmAndOrganize(
        captureId: widget.captureId,
        identity: ConfirmedProductIdentity(
          brand: _brandController.text.trim(),
          name: _nameController.text.trim(),
          category: _categoryController.text.trim(),
          amount: _amountController.text.trim(),
        ),
        // Null unless this review changed them, so joining an existing product
        // adopts the tags that group already carries.
        tags: _tagsEdited ? _selectedTags : null,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (mounted) {
        _showMessage('저장하지 못했어요. 잠시 후 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _keepUnresolved() async {
    setState(() => _saving = true);
    try {
      await widget.controller.keepUnresolved(widget.captureId);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (mounted) {
        _showMessage('보류 상태로 저장하지 못했어요. 잠시 후 다시 시도해 주세요.');
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _LinkOnlyReview extends StatelessWidget {
  const _LinkOnlyReview({
    required this.capture,
    required this.platform,
    required this.onDelete,
  });

  final CaptureRecord capture;
  final SourcePlatform platform;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('가져온 링크'),
        actions: [
          IconButton(
            key: const Key('delete-capture-detail'),
            tooltip: '콘텐츠 삭제',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFF2B1F13),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.link_rounded,
              color: Color(0xFFB26A00),
              size: 26,
            ),
          ),
          const SizedBox(height: 20),
          Text('링크는 저장했어요', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '${sourcePlatformLabel(platform)}에서 게시물 이미지나 본문을 '
            '함께 보내지 않아 아직 내용을 정리할 수 없어요.',
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 15,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 24),
          _OriginalMaterialCard(capture: capture, platform: platform),
          const SizedBox(height: 28),
          const _SectionHeading(
            title: '스크린샷으로 이어서 저장하기',
            description: '보이는 화면 한 장이면 Trun On이 이미지에서 내용을 읽을 수 있어요.',
          ),
          const SizedBox(height: 14),
          const _ScreenshotGuideCard(),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('알겠어요'),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ScreenshotGuideCard extends StatelessWidget {
  const _ScreenshotGuideCard();

  @override
  Widget build(BuildContext context) {
    const steps = [
      ('1', '원래 게시물로 돌아가 화면을 캡처해요.'),
      ('2', '캡처 미리보기의 공유 버튼을 눌러요.'),
      ('3', 'Trun On을 선택하면 바로 저장하고 분석해요.'),
    ];
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (var index = 0; index < steps.length; index++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppTheme.primarySoft,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    steps[index].$1,
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      steps[index].$2,
                      style: const TextStyle(
                        color: AppTheme.ink,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (index != steps.length - 1) const SizedBox(height: 15),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 14),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 17,
                color: AppTheme.subtle,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '공유가 끝나면 갤러리 원본을 남길지 Trun On에서 직접 선택할 수 있어요.',
                  style: TextStyle(
                    color: AppTheme.subtle,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    this.description,
    this.editable = false,
  });

  final String title;
  final String? description;
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
                  letterSpacing: -0.3,
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
        if (description case final description?) ...[
          const SizedBox(height: 5),
          Text(
            description,
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

final class _OriginalMaterialCard extends StatefulWidget {
  const _OriginalMaterialCard({required this.capture, required this.platform});

  final CaptureRecord capture;
  final SourcePlatform platform;

  @override
  State<_OriginalMaterialCard> createState() => _OriginalMaterialCardState();
}

final class _OriginalMaterialCardState extends State<_OriginalMaterialCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rawText = widget.capture.raw.rawText.trim();
    final content = rawText.isEmpty ? '공유된 내용이 없어요.' : rawText;
    final canExpand = content.length > 110 || content.contains('\n');

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppTheme.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  sourcePlatformIcon(widget.platform),
                  color: AppTheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '가져온 내용',
                      style: TextStyle(
                        color: AppTheme.ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${sourcePlatformLabel(widget.platform)} · '
                      '${formatCaptureTime(widget.capture.raw.receivedAt)}',
                      style: const TextStyle(
                        color: AppTheme.subtle,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_expanded)
            SelectableText(
              content,
              style: const TextStyle(
                color: AppTheme.muted,
                fontSize: 14,
                height: 1.55,
              ),
            )
          else
            Text(
              content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.muted,
                fontSize: 14,
                height: 1.55,
              ),
            ),
          if (canExpand) ...[
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                ),
                child: Text(_expanded ? '접기' : '원문 전체 보기'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _AnalysisField extends StatelessWidget {
  const _AnalysisField({
    required this.label,
    required this.controller,
    required this.field,
    this.requiredField = false,
  });

  final String label;
  final TextEditingController controller;
  final ExtractedField<String>? field;
  final bool requiredField;

  @override
  Widget build(BuildContext context) {
    final guidance = _guidanceFor(field);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppTheme.ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!requiredField) ...[
              const SizedBox(width: 5),
              const Text(
                '선택',
                style: TextStyle(color: AppTheme.subtle, fontSize: 12),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('analysis-field-$label'),
          controller: controller,
          validator: requiredField
              ? (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '$label 입력이 필요해요.';
                  }
                  return null;
                }
              : null,
          decoration: InputDecoration(
            hintText: '$label을 입력해 주세요',
            suffixIcon: const Icon(
              Icons.edit_rounded,
              size: 18,
              color: AppTheme.muted,
            ),
            helperText: guidance,
            helperMaxLines: 2,
            helperStyle: const TextStyle(color: AppTheme.caution, fontSize: 12),
            filled: true,
            fillColor: AppTheme.surfaceRaised,
            border: _fieldBorder(AppTheme.border),
            enabledBorder: _fieldBorder(AppTheme.border),
            focusedBorder: _fieldBorder(AppTheme.primary, width: 1.5),
            errorBorder: _fieldBorder(AppTheme.negative),
            focusedErrorBorder: _fieldBorder(AppTheme.negative, width: 1.5),
          ),
        ),
      ],
    );
  }

  String? _guidanceFor(ExtractedField<String>? extractedField) {
    final value = extractedField?.value;
    if (extractedField == null || value == null || value.trim().isEmpty) {
      return requiredField ? '원문에서 확실히 찾지 못했어요.' : '확실하지 않다면 비워두셔도 돼요.';
    }

    return switch (extractedField.confidenceBand) {
      ConfidenceBand.high => null,
      ConfidenceBand.reviewRecommended => '맞는 정보인지 한 번만 확인해 주세요.',
      ConfidenceBand.reviewRequired => '원문에서 확실히 찾지 못했어요.',
    };
  }

  OutlineInputBorder _fieldBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}

final class _StatementList extends StatelessWidget {
  const _StatementList({required this.statements});

  final List<ContentStatement> statements;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (var index = 0; index < statements.length; index++) ...[
            _StatementRow(statement: statements[index]),
            if (index != statements.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Divider(),
              ),
          ],
        ],
      ),
    );
  }
}

final class _StatementRow extends StatelessWidget {
  const _StatementRow({required this.statement});

  final ContentStatement statement;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 7),
            decoration: const BoxDecoration(
              color: AppTheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statement.topic,
                  style: const TextStyle(
                    color: AppTheme.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '“${statement.originalExpression}”',
                  style: const TextStyle(
                    color: AppTheme.muted,
                    fontSize: 14,
                    height: 1.5,
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

final class _DisclosureCard extends StatelessWidget {
  const _DisclosureCard({required this.disclosure});

  final DisclosureObservation disclosure;

  @override
  Widget build(BuildContext context) {
    final (icon, title) = switch (disclosure) {
      DisclosureObservation.explicitlyObserved => (
        Icons.check_circle_outline_rounded,
        '광고·협찬 표시가 있어요',
      ),
      DisclosureObservation.notObservedInCapturedMaterial => (
        Icons.remove_circle_outline_rounded,
        '가져온 내용에서 표시를 찾지 못했어요',
      ),
      DisclosureObservation.unknown => (
        Icons.help_outline_rounded,
        '광고·협찬 여부를 확인하기 어려워요',
      ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.muted, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  '표시가 보이지 않아도 광고가 아니라고 단정하지 않아요.',
                  style: TextStyle(
                    color: AppTheme.subtle,
                    fontSize: 12,
                    height: 1.45,
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

final class _NoStatementsCard extends StatelessWidget {
  const _NoStatementsCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        children: [
          Icon(Icons.notes_outlined, color: AppTheme.subtle, size: 21),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              '가져온 내용에서 정리할 만한 표현을 찾지 못했어요.',
              style: TextStyle(color: AppTheme.muted, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ResultMark extends StatelessWidget {
  const _ResultMark({required this.icon});

  final IconData icon;

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
      child: Icon(icon, size: 22, color: AppTheme.primary),
    );
  }
}
