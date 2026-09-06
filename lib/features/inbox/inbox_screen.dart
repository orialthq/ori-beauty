import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../core/formatters.dart';
import '../../data/incoming_share_service.dart';
import '../../domain/models.dart';
import '../../domain/portable_tip_package.dart';
import '../../state/app_controller.dart';
import '../analysis/analysis_review_screen.dart';
import '../analysis/structured_review_screen.dart';
import '../common/capture_action_ui.dart';
import '../common/product_ui.dart';
import '../product/product_detail_screen.dart';

final class InboxScreen extends StatelessWidget {
  const InboxScreen({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final captures = controller.filteredCaptures;

        return ListView(
          key: const PageStorageKey('content-inbox'),
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 36),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '콘텐츠',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(82, 46),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  onPressed: () => openManualInput(context, controller),
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('추가'),
                ),
              ],
            ),
            const SizedBox(height: 28),
            _CaptureSummaryCard(controller: controller),
            const SizedBox(height: 22),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  for (
                    var index = 0;
                    index < CaptureFilter.values.length;
                    index++
                  )
                    Builder(
                      builder: (context) {
                        final filter = CaptureFilter.values[index];
                        return Padding(
                          padding: EdgeInsets.only(
                            right: index == CaptureFilter.values.length - 1
                                ? 0
                                : 4,
                          ),
                          child: _FilterButton(
                            label: _filterLabel(filter),
                            count: _countForFilter(controller, filter),
                            color: _filterColor(filter),
                            selected: controller.filter == filter,
                            onPressed: () => controller.setFilter(filter),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (captures.isEmpty)
              _EmptyInbox(
                onShowAll: () {
                  controller.setFilter(CaptureFilter.all);
                },
              )
            else
              Material(
                color: AppTheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: const BorderSide(color: AppTheme.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var index = 0; index < captures.length; index++) ...[
                      _CaptureCard(
                        key: Key('capture-card-${captures[index].raw.id}'),
                        capture: captures[index],
                        controller: controller,
                        onTap: () => _openCapture(context, captures[index]),
                        onLongPress: () =>
                            _openCaptureActions(context, captures[index]),
                      ),
                      if (index != captures.length - 1)
                        const Divider(height: 1, indent: 18, endIndent: 18),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static Future<void> openManualInput(
    BuildContext context,
    AppController controller,
  ) async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      builder: (_) => _ManualInputSheet(controller: controller),
    );
    if (result == null || !context.mounted) {
      return;
    }
    if (result is CapturePickerResult) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(_capturePickerResultMessage(result))),
        );
      return;
    }
    if (result is! String) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AnalysisReviewScreen(controller: controller, captureId: result),
      ),
    );
  }

  static String _capturePickerResultMessage(CapturePickerResult result) {
    if (result.importedCount == 0) {
      return '선택한 사진 ${result.rejectedCount}장을 가져오지 못했어요.';
    }
    if (result.rejectedCount > 0) {
      return '사진 ${result.importedCount}장을 가져왔어요. '
          '${result.rejectedCount}장은 가져오지 못했어요.';
    }
    return '사진 ${result.importedCount}장을 가져왔어요.';
  }

  void _openCapture(BuildContext context, CaptureRecord capture) {
    if (capture.status == CaptureStatus.analyzing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            capture.analysisMode == CaptureAnalysisMode.batch
                ? _batchStatusMessage(capture)
                : '이미지를 읽고 있어요. 잠시만 기다려 주세요.',
          ),
        ),
      );
      return;
    }
    if (capture.analysis?.structuredContent != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StructuredReviewScreen(
            controller: controller,
            captureId: capture.raw.id,
          ),
        ),
      );
      return;
    }
    final groupId = capture.groupId;
    if (capture.status == CaptureStatus.organized && groupId != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ProductDetailScreen(controller: controller, groupId: groupId),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnalysisReviewScreen(
          controller: controller,
          captureId: capture.raw.id,
        ),
      ),
    );
  }

  Future<void> _openCaptureActions(
    BuildContext context,
    CaptureRecord capture,
  ) async {
    final action = await showCaptureActionSheet(
      context,
      canOrganize: capture.status == CaptureStatus.needsReview,
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case CaptureListAction.organize:
        final saved = controller.canQuickOrganize(capture.raw.id)
            ? await controller.quickOrganize(capture.raw.id)
            : false;
        if (!context.mounted) return;
        if (saved) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('정리함에 저장했어요.')));
        }
        if (!saved) {
          final current = controller.captureById(capture.raw.id);
          if (current != null) _openCapture(context, current);
        }
        return;
      case CaptureListAction.delete:
        await confirmCaptureDeletion(
          context,
          controller: controller,
          captureId: capture.raw.id,
        );
        return;
    }
  }

  static int _countForFilter(AppController controller, CaptureFilter filter) {
    return switch (filter) {
      CaptureFilter.all => controller.captures.length,
      CaptureFilter.needsReview => controller.needsReviewCount,
      CaptureFilter.organized => controller.organizedCount,
      CaptureFilter.limitedOrFailed => controller.limitedOrFailedCount,
    };
  }

  static String _filterLabel(CaptureFilter filter) {
    return switch (filter) {
      CaptureFilter.all => '전체',
      CaptureFilter.needsReview => '확인 필요',
      CaptureFilter.organized => '정리 완료',
      CaptureFilter.limitedOrFailed => '내용 부족',
    };
  }

  static Color _filterColor(CaptureFilter filter) {
    return switch (filter) {
      CaptureFilter.all => AppTheme.primary,
      CaptureFilter.needsReview => AppTheme.caution,
      CaptureFilter.organized => AppTheme.positive,
      CaptureFilter.limitedOrFailed => AppTheme.negative,
    };
  }
}

final class _CaptureSummaryCard extends StatelessWidget {
  const _CaptureSummaryCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final needsReview = controller.needsReviewCount;
    final analyzing = controller.analyzingCount;
    final headline = analyzing > 0
        ? '콘텐츠 $analyzing개를 정리하고 있어요'
        : needsReview == 0
        ? '들어온 콘텐츠를 모두 확인했어요'
        : '확인할 콘텐츠가 $needsReview개 있어요';

    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: AppTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 21),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              headline,
              style: const TextStyle(
                color: AppTheme.ink,
                fontSize: 20,
                height: 1.4,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            if (controller.pendingBatchCount > 0) ...[
              const SizedBox(height: 10),
              Text(
                '절약 분석 ${controller.pendingBatchCount}장 · 접수 후 최대 24시간\n'
                '접수가 끝난 사진은 앱을 닫아도 분석이 이어져요.\n'
                '분석 서버에 연결되면 결과를 받아올 수 있어요.',
                style: const TextStyle(
                  color: AppTheme.muted,
                  height: 1.6,
                  fontSize: 13,
                ),
              ),
              TextButton.icon(
                onPressed: controller.refreshBatchAnalysis,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('결과 새로고침'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final int count;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? Color.alphaBlend(color.withValues(alpha: 0.16), AppTheme.surface)
          : AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? color : color.withValues(alpha: 0.28),
        ),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: selected ? 1 : 0.58),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '$label $count',
                    style: TextStyle(
                      color: selected ? color : AppTheme.muted,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CaptureStatusLabel extends StatelessWidget {
  const _CaptureStatusLabel({required this.capture});

  final CaptureRecord capture;

  @override
  Widget build(BuildContext context) {
    final isLinkOnly =
        capture.status == CaptureStatus.sourceLimited &&
        capture.raw.attachments.isEmpty &&
        capture.normalized.completeness == MaterialCompleteness.linkOnly;
    final (label, color) =
        capture.status == CaptureStatus.analyzing &&
            capture.analysisMode == CaptureAnalysisMode.batch
        ? ('절약 분석', AppTheme.primary)
        : isLinkOnly
        ? ('링크 저장', AppTheme.caution)
        : switch (capture.status) {
            CaptureStatus.received ||
            CaptureStatus.analyzing => ('분석 중', AppTheme.primary),
            CaptureStatus.sourceLimited => ('내용 부족', AppTheme.caution),
            CaptureStatus.needsReview => ('확인 필요', AppTheme.caution),
            CaptureStatus.organized => ('정리 완료', AppTheme.positive),
            CaptureStatus.failed => ('분석 실패', AppTheme.negative),
          };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

final class _CaptureCard extends StatelessWidget {
  const _CaptureCard({
    required this.capture,
    required this.controller,
    required this.onTap,
    required this.onLongPress,
    super.key,
  });

  final CaptureRecord capture;
  final AppController controller;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final platform = capture.normalized.urls.isEmpty
        ? SourcePlatform.textOnly
        : capture.normalized.urls.first.platform;
    final isPortableTip = capture.raw.origin == CaptureOrigin.portableTip;
    final mention = capture.primaryMention;
    final structured = capture.analysis?.structuredContent;
    final isLinkOnly =
        capture.status == CaptureStatus.sourceLimited &&
        capture.raw.attachments.isEmpty &&
        capture.normalized.completeness == MaterialCompleteness.linkOnly;
    final productLabel = [
      mention?.brand.value,
      mention?.name.value,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' ');
    final title = structured?.title.value?.trim().isNotEmpty == true
        ? structured!.title.value!
        : isLinkOnly
        ? '링크를 저장했어요'
        : capture.status == CaptureStatus.analyzing
        ? capture.analysisMode == CaptureAnalysisMode.batch
              ? '절약 모드로 정리하고 있어요'
              : '이미지에서 내용을 읽는 중이에요'
        : capture.status == CaptureStatus.failed
        ? '분석을 완료하지 못했어요'
        : productLabel.isEmpty
        ? capture.raw.attachments.isNotEmpty
              ? '이미지 내용을 확인해 주세요'
              : '제품을 특정하지 못했어요'
        : productLabel;
    final description = _listSummary(
      capture,
      structured: structured,
      isLinkOnly: isLinkOnly,
    );

    return InkWell(
      onTap: capture.status == CaptureStatus.failed
          ? () => controller.retryAnalysis(capture.raw.id)
          : onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 12, 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (capture.raw.attachments.isNotEmpty) ...[
              _CaptureThumbnail(attachment: capture.raw.attachments.first),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (capture.raw.attachments.isEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isPortableTip
                                  ? Icons.redeem_outlined
                                  : sourcePlatformIcon(platform),
                              color: AppTheme.muted,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isPortableTip
                                  ? '받은 팁'
                                  : sourcePlatformLabel(platform),
                              style: const TextStyle(
                                color: AppTheme.muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      Text(
                        formatCaptureTime(capture.raw.receivedAt),
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 12,
                        ),
                      ),
                      _CaptureStatusLabel(capture: capture),
                    ],
                  ),
                  const SizedBox(height: 11),
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppTheme.ink,
                      fontSize: 17,
                      height: 1.35,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.muted,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              capture.status == CaptureStatus.analyzing
                  ? Icons.more_horiz
                  : capture.status == CaptureStatus.failed
                  ? Icons.refresh
                  : Icons.chevron_right,
              color: capture.status == CaptureStatus.failed
                  ? AppTheme.negative
                  : AppTheme.subtle,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  static String _listSummary(
    CaptureRecord capture, {
    required StructuredContentAnalysis? structured,
    required bool isLinkOnly,
  }) {
    final aiSummary = structured?.summary.trim();
    if (aiSummary != null && aiSummary.isNotEmpty) {
      return _singleLine(aiSummary);
    }
    if (isLinkOnly) {
      return '게시물 내용이 없어 스크린샷이 필요해요.';
    }
    if (capture.status == CaptureStatus.analyzing) {
      if (capture.analysisMode == CaptureAnalysisMode.batch) {
        return _batchStatusMessage(capture);
      }
      return '이미지의 핵심 내용을 정리하고 있어요.';
    }
    if (capture.status == CaptureStatus.failed) {
      return _failureMessage(capture.analysis?.failureCode);
    }
    final statements = capture.analysis?.statements;
    if (statements != null && statements.isNotEmpty) {
      return _singleLine(statements.first.originalExpression);
    }
    return capture.raw.attachments.isNotEmpty
        ? '정리된 세부 내용을 확인해 주세요.'
        : '저장한 내용의 세부 정보를 확인해 주세요.';
  }

  static String _singleLine(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _failureMessage(String? code) {
    return switch (code) {
      'multiple_images_not_supported' => '여러 장은 아직 분석할 수 없어요. 한 장씩 공유해 주세요.',
      'analysis_server_unreachable' => '로컬 분석 서버를 확인한 뒤 다시 눌러 주세요.',
      'rate_limited' => '요청이 잠시 몰렸어요. 조금 뒤 다시 눌러 주세요.',
      'image_too_large' => '이미지 용량이 커서 읽지 못했어요.',
      'invalid_image' || 'source_file_changed' => '원본 이미지를 확인하지 못했어요.',
      'analysis_timed_out' => '분석 시간이 길어졌어요. 다시 시도해 주세요.',
      'batch_expired' => '처리 기한이 지났어요. 다시 분석하면 요금이 발생할 수 있어요.',
      'batch_result_expired' => '결과 보관 기간이 지났어요. 새 분석이 필요해요.',
      'batch_cancelled' => '배치 작업이 취소됐어요. 다시 눌러 분석할 수 있어요.',
      'batch_failed' ||
      'batch_item_failed' ||
      'batch_result_missing' => '절약 분석을 마치지 못했어요. 다시 분석하면 요금이 발생할 수 있어요.',
      _ => '오른쪽 새로고침을 눌러 다시 시도할 수 있어요.',
    };
  }
}

final class _CaptureThumbnail extends StatelessWidget {
  const _CaptureThumbnail({required this.attachment});

  final IncomingAttachment attachment;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 64,
        height: 80,
        child: ColoredBox(
          color: AppTheme.fill,
          child: Image.file(
            File(attachment.filePath),
            fit: BoxFit.cover,
            cacheWidth: 192,
            errorBuilder: (_, _, _) => const Icon(
              Icons.image_not_supported_outlined,
              color: AppTheme.subtle,
            ),
          ),
        ),
      ),
    );
  }
}

final class _ManualInputSheet extends StatefulWidget {
  const _ManualInputSheet({required this.controller});

  final AppController controller;

  @override
  State<_ManualInputSheet> createState() => _ManualInputSheetState();
}

final class _ManualInputSheetState extends State<_ManualInputSheet> {
  final _textController = TextEditingController();
  var _importingTip = false;
  var _pickingCapture = false;

  /// Both mobile platforms expose the picker in-app. Android also keeps its
  /// quick settings tile as an optional shortcut.
  bool get _showsCapturePicker =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _textController.text.trim().isNotEmpty;

    return SafeArea(
      key: const Key('manual-input-safe-area'),
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: SingleChildScrollView(
        key: const Key('manual-input-scroll'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          20,
          10,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('콘텐츠 추가', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 7),
            const Text(
              'SNS에서 공유한 본문이나 링크를 붙여넣어 주세요.\n'
              '링크만 입력하면 원본 링크만 저장돼요.',
              style: TextStyle(color: AppTheme.muted, height: 1.5),
            ),
            const SizedBox(height: 18),
            if (_showsCapturePicker) ...[
              if (widget.controller.supportsBatchAnalysis) ...[
                _AnalysisModeOption(
                  title: '절약해서 정리',
                  description: '이미지 분석 비용 50% 절약 · 접수 후 최대 24시간',
                  icon: Icons.eco_outlined,
                  selected:
                      widget.controller.selectedAnalysisMode ==
                      CaptureAnalysisMode.batch,
                  onTap: _pickingCapture
                      ? null
                      : () => setState(() {
                          widget.controller.selectAnalysisMode(
                            CaptureAnalysisMode.batch,
                          );
                        }),
                ),
                const SizedBox(height: 8),
                _AnalysisModeOption(
                  title: '바로 정리',
                  description: '일반 요금 · 최대 10장 동시 분석',
                  icon: Icons.bolt_outlined,
                  selected:
                      widget.controller.selectedAnalysisMode ==
                      CaptureAnalysisMode.instant,
                  onTap: _pickingCapture
                      ? null
                      : () => setState(() {
                          widget.controller.selectAnalysisMode(
                            CaptureAnalysisMode.instant,
                          );
                        }),
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _pickingCapture ? null : _pickCapture,
                  icon: _pickingCapture
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_rounded, size: 20),
                  label: Text(
                    _pickingCapture ? '사진을 가져오는 중…' : '갤러리에서 사진 여러 장 가져오기',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '한 번에 최대 ${CapturePickerResult.maxSelectionCount}장·'
                '${CapturePickerResult.maxBatchSizeMegabytes}MB까지 선택할 수 있어요. '
                '여러 장을 가져와도 갤러리 원본은 그대로 남아요.',
                style: TextStyle(
                  color: AppTheme.muted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _importingTip ? null : _importTipFile,
                icon: _importingTip
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.redeem_rounded, size: 20),
                label: Text(_importingTip ? '팁을 확인하고 있어요…' : '받은 팁 파일 가져오기'),
              ),
            ),
            const SizedBox(height: 18),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '또는 직접 입력',
                    style: TextStyle(color: AppTheme.subtle, fontSize: 12),
                  ),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _textController,
              minLines: 5,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '본문 텍스트 또는 URL을 입력해 주세요',
                hintStyle: const TextStyle(color: AppTheme.subtle),
                filled: true,
                fillColor: AppTheme.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: AppTheme.primary.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canSubmit
                    ? () {
                        final captureId = widget.controller.addManualInput(
                          _textController.text,
                        );
                        Navigator.of(context).pop(captureId);
                      }
                    : null,
                child: const Text('내용 분석하기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCapture() async {
    setState(() => _pickingCapture = true);
    try {
      final result = await widget.controller.presentCapturePicker();
      if (!mounted) return;
      if (result.wasCancelled) {
        // Cancelling the picker is a normal path, so leave the sheet in place
        // without adding a warning.
        return;
      }
      // Images are already in the pending queue. Return the counts so the
      // parent screen can confirm full or partial success after this closes.
      Navigator.of(context).pop(result);
    } on PlatformException catch (error, stackTrace) {
      if (!mounted) return;
      final exceededSelectionLimit =
          error.code == 'capture_picker_too_many' || error.code == 'too_many';
      if (!exceededSelectionLimit) {
        debugPrint('Capture picker failed: $error\n$stackTrace');
      }
      final message = exceededSelectionLimit
          ? '사진은 한 번에 최대 '
                '${CapturePickerResult.maxSelectionCount}장까지 선택할 수 있어요.'
          : '사진을 가져오지 못했어요.';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } on Object catch (error, stackTrace) {
      debugPrint('Capture picker failed: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('사진을 가져오지 못했어요.')));
    } finally {
      if (mounted) {
        setState(() => _pickingCapture = false);
      }
    }
  }

  Future<void> _importTipFile() async {
    setState(() => _importingTip = true);
    try {
      const typeGroup = XTypeGroup(
        label: 'luffi 팁',
        extensions: [PortableTipPackageCodec.fileExtension],
        // Chat and file-provider apps often replace a custom MIME type while
        // preserving the .trunon filename. The codec below still enforces the
        // 64 KiB limit and exact privacy-safe JSON schema after selection.
        mimeTypes: [
          PortableTipPackageCodec.mimeType,
          'application/octet-stream',
          'application/json',
        ],
        uniformTypeIdentifiers: [PortableTipPackageCodec.uniformTypeIdentifier],
      );
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null) return;
      final fileLength = await file.length();
      if (fileLength <= 0 || fileLength > PortableTipLimits.maxPackageBytes) {
        throw const FormatException('팁 파일이 비어 있거나 너무 커서 열 수 없어요.');
      }
      final bytes = await file.readAsBytes();
      final tip = PortableTipPackageCodec.decodeUtf8(bytes);
      if (!mounted) return;
      final transportId = widget.controller.stagePortableTip(
        PortableTipPackageCodec.encode(tip),
        announce: false,
      );
      Navigator.of(context).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.controller.announcePortableTip(transportId);
      });
    } on FormatException catch (error) {
      debugPrint('Portable tip manual import rejected: ${error.message}');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    } on Object catch (error, stackTrace) {
      debugPrint('Portable tip manual import failed: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('이 파일은 luffi 팁으로 열 수 없어요.')),
        );
    } finally {
      if (mounted) setState(() => _importingTip = false);
    }
  }
}

String _batchStatusMessage(CaptureRecord capture) =>
    switch (capture.batchStatus) {
      'pending_upload' => '사진 접수 대기 중이에요. 분석 서버 연결을 유지해 주세요.',
      'queued' => '접수 완료 · 사진을 묶어 분석을 요청하고 있어요.',
      'submission_unknown' => '접수 상태 확인이 필요해요. 중복 과금을 막기 위해 재전송을 보류했어요.',
      _ => '분석을 기다리고 있어요. 접수 후 최대 24시간이 걸릴 수 있어요.',
    };

final class _AnalysisModeOption extends StatelessWidget {
  const _AnalysisModeOption({
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? AppTheme.primary.withValues(alpha: 0.1)
        : AppTheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.ink, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      color: AppTheme.muted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 21,
              color: selected ? AppTheme.primary : AppTheme.subtle,
            ),
          ],
        ),
      ),
    ),
  );
}

final class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox({required this.onShowAll});

  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              color: AppTheme.surface,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.inbox_outlined,
              size: 24,
              color: AppTheme.muted,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '이 상태의 콘텐츠가 없어요',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            '다른 상태를 확인하거나 새 콘텐츠를 추가해 보세요.',
            style: TextStyle(color: AppTheme.muted),
          ),
          const SizedBox(height: 14),
          TextButton(onPressed: onShowAll, child: const Text('전체 보기')),
        ],
      ),
    );
  }
}
