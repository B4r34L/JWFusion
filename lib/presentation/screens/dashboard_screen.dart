import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../domain/merge/merge_report.dart';
import '../state/merge_controller.dart';
import 'settings_screen.dart';

const _monthAbbrev = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// e.g. "Jul 28, 2026". No `intl` dependency needed for one format.
String _friendlyDate(DateTime date) =>
    '${_monthAbbrev[date.month - 1]} ${date.day}, ${date.year}';

/// Best-effort last-modified time for a selected file. Returns null rather
/// than throwing if the file was moved/deleted after being picked.
DateTime? _modifiedTimeOrNull(String path) {
  try {
    return File(path).statSync().modified;
  } on Object {
    return null;
  }
}

/// The single dashboard screen. Three states:
/// * Idle       - add files, review the list, press Merge.
/// * Processing - spinner + percentage + current stage.
/// * Success    - big checkmark + "Save merged file" prompt.
/// Deliberately minimal: one obvious action at every moment, large targets
/// and large text so it works for any age.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final MergeController controller = MergeController();
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
  }

  void _onChanged() {
    final rejection = controller.dropRejectionMessage;
    if (rejection != null) {
      controller.clearDropRejection();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(rejection)));
    }
    setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text('JW Fusion'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: DropTarget(
        onDragDone: (details) {
          setState(() => _dragging = false);
          controller.addDroppedPaths(
              details.files.map((f) => f.path).toList());
        },
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        child: Stack(
          children: [
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: switch (controller.phase) {
                      MergePhase.idle => _IdleView(controller: controller),
                      MergePhase.processing =>
                        _ProcessingView(controller: controller),
                      MergePhase.success =>
                        _SuccessView(controller: controller),
                      MergePhase.failure =>
                        _FailureView(controller: controller),
                    },
                  ),
                ),
              ),
            ),
            if (_dragging)
              IgnorePointer(
                child: Container(
                  color: scheme.primary.withValues(alpha: 0.10),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 18),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: scheme.primary, width: 2),
                      ),
                      child: Text(
                        'Drop .jwlibrary backups anywhere',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Idle
// ---------------------------------------------------------------------------

class _IdleView extends StatelessWidget {
  const _IdleView({required this.controller});

  final MergeController controller;

  /// Path of the selected file with the latest modified time, or null if
  /// there aren't at least two files or none of their timestamps could be
  /// read. The merge engine keeps whichever record is newest across all
  /// selected backups, so surfacing which *file* is newest here removes
  /// the guesswork of an otherwise invisible rule.
  String? _newestPath() {
    String? newestPath;
    DateTime? newestTime;
    for (final path in controller.selectedFiles) {
      final modified = _modifiedTimeOrNull(path);
      if (modified == null) continue;
      if (newestTime == null || modified.isAfter(newestTime)) {
        newestTime = modified;
        newestPath = path;
      }
    }
    return controller.selectedFiles.length > 1 ? newestPath : null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final newestPath = _newestPath();
    return Column(
      children: [
        const SizedBox(height: 8),
        Text('JW Fusion',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Combine your backups into one - nothing gets lost.',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 24),
        // Big, obvious selection card.
        Material(
          color: scheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: controller.addFiles,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.45), width: 2),
              ),
              child: Column(
                children: [
                  Icon(Icons.add_circle_outline,
                      size: 56, color: scheme.primary),
                  const SizedBox(height: 12),
                  Text('Click to add your backup files',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('.jwlibrary files',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Selected files list.
        Expanded(
          child: controller.selectedFiles.isEmpty
              ? Center(
                  child: Text(
                    'Add two or more backups to get started.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  itemCount: controller.selectedFiles.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final path = controller.selectedFiles[index];
                    final modified = _modifiedTimeOrNull(path);
                    final isNewest = path == newestPath;
                    return Card(
                      elevation: 0,
                      color: scheme.primaryContainer.withValues(alpha: 0.18),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      child: ListTile(
                        leading:
                            Icon(Icons.inventory_2, color: scheme.primary),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(p.basename(path),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (isNewest) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('Newest',
                                    style: TextStyle(
                                        color: scheme.onPrimary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (modified != null)
                              Text(_friendlyDate(modified)),
                            Text(p.dirname(path),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        color: scheme.onSurfaceVariant)),
                          ],
                        ),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close),
                          onPressed: () => controller.removeFile(path),
                        ),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 16),
        // Big merge action.
        SizedBox(
          width: double.infinity,
          height: 64,
          child: FilledButton.icon(
            onPressed: controller.canMerge ? controller.startMerge : null,
            icon: const Icon(Icons.merge_type, size: 28),
            label: Text(
              controller.selectedFiles.length < 2
                  ? 'Merge Backups (add ${2 - controller.selectedFiles.length} more)'
                  : 'Merge ${controller.selectedFiles.length} Backups',
              style: const TextStyle(fontSize: 20),
            ),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Processing
// ---------------------------------------------------------------------------

class _ProcessingView extends StatelessWidget {
  const _ProcessingView({required this.controller});

  final MergeController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final percent = (controller.progress * 100).round();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: controller.progress <= 0 ? null : controller.progress,
                strokeWidth: 8,
              ),
              Center(
                child: Text('$percent%',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text('Merging your backups...',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(controller.progressMessage,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Text('This usually takes a few seconds.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 24),
        TextButton.icon(
          onPressed: controller.cancelMerge,
          icon: const Icon(Icons.close),
          label: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Success
// ---------------------------------------------------------------------------

class _SuccessView extends StatelessWidget {
  const _SuccessView({required this.controller});

  final MergeController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final report = controller.report;
    final saved = controller.savedPath;
    final warnings = report?.warnings ?? const <String>[];
    final categories = report?.categorySummaries() ?? const <CategorySummary>[];

    var added = 0;
    var updated = 0;
    for (final category in categories) {
      added += category.added;
      updated += category.updated;
    }

    return Center(
      child: SingleChildScrollView(
        child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_rounded, size: 72, color: Colors.green),
        ),
        const SizedBox(height: 24),
        Text('Your merged backup is ready!',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          '$added records were added and $updated were refreshed from your '
          'older backups. Everything else was already up to date.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                for (final category in categories)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(category.label,
                              style: Theme.of(context).textTheme.bodyMedium),
                        ),
                        Text(
                          [
                            if (category.added > 0) '${category.added} added',
                            if (category.updated > 0)
                              '${category.updated} updated',
                          ].join(', '),
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final warning in warnings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('- $warning',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 28),
        if (saved == null)
          SizedBox(
            width: double.infinity,
            height: 64,
            child: FilledButton.icon(
              onPressed: controller.saveResult,
              icon: const Icon(Icons.save_alt, size: 28),
              label: const Text('Choose where to save it',
                  style: TextStyle(fontSize: 20)),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
          )
        else ...[
          Icon(Icons.task_alt, color: Colors.green.shade700),
          const SizedBox(height: 6),
          Text('Saved to:\n$saved',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: controller.reset,
          child: const Text('Start a new merge', style: TextStyle(fontSize: 16)),
        ),
      ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Failure
// ---------------------------------------------------------------------------

class _FailureView extends StatelessWidget {
  const _FailureView({required this.controller});

  final MergeController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.error_outline, size: 64, color: scheme.error),
        ),
        const SizedBox(height: 24),
        Text('Something went wrong',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          controller.errorMessage ?? 'Unknown error.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Text('Your original backup files were not changed.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 28),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            onPressed: controller.reset,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again', style: TextStyle(fontSize: 18)),
          ),
        ),
      ],
    );
  }
}
