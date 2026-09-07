import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/services/dji_mic_import_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/recording_transfer_coordinator.dart';
import 'package:omi/utils/dji_mic_import_registry.dart';
import 'package:omi/utils/dji_mic_recordings.dart';
import 'package:omi/utils/logger.dart';

/// Where the "already imported" list is kept.
const String djiMicImportRegistryPrefsKey = 'djiMicImportRegistry';

/// How many imports to remember. Comfortably more than a transmitter holds
/// takes, so in practice nothing is ever forgotten while it is still on the
/// mic — but bounded, because this is a preference and not a database.
const int djiMicImportRegistryLimit = 2000;

/// Bringing recordings off a DJI transmitter into Omi.
///
/// The transfer is USB-C: plug the transmitter (or its charging case) into the
/// phone, and its `DJI_AUDIO` folder appears in Android's own file picker like
/// any other drive. There is no wireless path a third-party app can use — DJI's
/// Mimo app downloads files over its own closed link, with no SDK and no
/// documented protocol — so this screen says "connect by USB-C" rather than
/// offering something that cannot work.
class DjiMicImportPage extends StatefulWidget {
  const DjiMicImportPage({super.key});

  @override
  State<DjiMicImportPage> createState() => _DjiMicImportPageState();
}

/// One picked file, as this screen tracks it between picking and importing.
class _Candidate {
  final DjiMicImportSource source;
  final DjiMicRecording recording;
  final bool alreadyImported;

  /// True when this is the copy of a take that is *not* offered by default —
  /// the raw `_orig` beside a processed `_edit`. Still selectable, just not
  /// ticked, so one moment does not become two conversations.
  final bool hasSiblingVariant;

  bool selected;

  _Candidate({
    required this.source,
    required this.recording,
    required this.alreadyImported,
    required this.hasSiblingVariant,
    required this.selected,
  });
}

class _DjiMicImportPageState extends State<DjiMicImportPage> {
  DjiMicImportRegistry _registry = const DjiMicImportRegistry.empty();
  List<_Candidate> _candidates = [];
  List<DjiMicSplitChain> _chains = [];
  final List<String> _skippedNames = [];

  bool _picking = false;
  bool _importing = false;
  String? _currentFile;
  double _fileProgress = 0;
  int _doneCount = 0;
  List<DjiMicImportOutcome> _results = [];

  @override
  void initState() {
    super.initState();
    _registry = DjiMicImportRegistry.decode(SharedPreferencesUtil().getString(djiMicImportRegistryPrefsKey));
  }

  Future<void> _saveRegistry() async {
    _registry = _registry.trimmedTo(djiMicImportRegistryLimit);
    await SharedPreferencesUtil().saveString(djiMicImportRegistryPrefsKey, _registry.encode());
  }

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _results = [];
      _skippedNames.clear();
    });
    try {
      // No `withReadStream`: on Android it buys nothing. file_picker 8.3.2's
      // FileUtils.openFileStream copies every picked content URI into the app's
      // cache and hands back a path either way, and `withReadStream` then just
      // opens a stream over that copy (checked in the plugin source, not
      // assumed). So each picked take is duplicated into phone storage at pick
      // time — a 30-minute one is about 260 MB — which is why the screen asks
      // for a few at a time and why _clearPickerCache() runs after an import.
      // `withData` is the one that would load whole files into memory; it is
      // deliberately left off.
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;

      final candidates = <_Candidate>[];
      final sources = <String, DjiMicImportSource>{};
      final recordings = <DjiMicRecording>[];
      for (final file in result.files) {
        final source = _sourceFor(file);
        if (source == null) continue;
        // Duration here is estimated from the file's size — reading the real
        // one means opening every picked file before the list can be drawn.
        // The measured duration, from the file's own header, replaces it as
        // each recording is imported; `durationEstimated` marks the guess with
        // a leading "≈" so an estimate never reads as a measurement.
        final recording = djiMicRecordingFromHeader(
          path: file.name,
          fileName: file.name,
          sizeBytes: source.sizeBytes,
          folderKey: '',
        );
        if (recording == null) {
          _skippedNames.add(file.name);
          continue;
        }
        sources[file.name] = source;
        recordings.add(recording);
      }

      // What is ticked and why lives in djiMicImportOffers, where it is
      // testable: an already-imported take is shown but not ticked, and of the
      // two copies DJI's dual-file mode writes for every take only the
      // processed one is.
      final offers = djiMicImportOffers(
        recordings,
        isAlreadyImported: (r) => _registry.contains(r.fileName, sources[r.fileName]!.sizeBytes),
      );

      for (final offer in offers) {
        final source = sources[offer.recording.fileName]!;
        candidates.add(_Candidate(
          source: source,
          recording: offer.recording,
          alreadyImported: _registry.contains(source.fileName, source.sizeBytes),
          hasSiblingVariant: offer.hasSiblingVariant,
          selected: offer.selected,
        ));
      }

      candidates.sort((a, b) => a.recording.startedAt.compareTo(b.recording.startedAt));
      setState(() {
        _candidates = candidates;
        // Chain detection buckets by variant, so counting chains across both
        // copies of every take would double every long recording. Count them
        // over the offered set only.
        _chains = findDjiMicSplitChains(
          candidates.where((c) => !c.hasSiblingVariant).map((c) => c.recording).toList(),
        );
      });
    } on PlatformException catch (e) {
      _snack('Could not open the file picker: ${e.message ?? e.code}');
    } catch (e) {
      Logger.debug('DJI import: picking failed: $e');
      _snack('Could not read the picked files.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  DjiMicImportSource? _sourceFor(PlatformFile file) {
    final path = file.path;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      // A real path can be re-read, so a retry after a failure works.
      return DjiMicImportSource.file(File(path));
    }
    final stream = file.readStream;
    if (stream == null) return null;
    return DjiMicImportSource(
      fileName: file.name,
      sizeBytes: file.size,
      open: () => stream,
    );
  }

  Future<void> _import() async {
    final selected = _candidates.where((c) => c.selected).toList();
    if (selected.isEmpty) return;

    setState(() {
      _importing = true;
      _doneCount = 0;
      _fileProgress = 0;
      _results = [];
    });

    final service = DjiMicImportService(
      walDirectory: getApplicationDocumentsDirectory,
      registerWal: (wal) => ServiceManager.instance().wal.getSyncs().phone.addExternalWal(wal),
    );

    final results = <DjiMicImportOutcome>[];
    for (final candidate in selected) {
      if (!mounted) break;
      setState(() {
        _currentFile = candidate.source.fileName;
        _fileProgress = 0;
      });
      final outcome = await service.importOne(
        candidate.source,
        // The user ticked it deliberately; re-importing is theirs to decide.
        alreadyImported: false,
        onProgress: (p) {
          // A 250 MB file arrives in ~64 KB pieces; rebuilding the screen four
          // thousand times to move a progress bar is work taken away from the
          // decode. Whole percents only.
          if (!mounted) return;
          if ((p * 100).floor() == (_fileProgress * 100).floor()) return;
          setState(() => _fileProgress = p);
        },
      );
      results.add(outcome);
      if (outcome.imported) {
        _registry = _registry.withRecord(service.recordFor(candidate.source, outcome));
      }
      if (mounted) setState(() => _doneCount += 1);
    }

    await _saveRegistry();

    // Nothing else would start the upload. Imported WALs land as
    // `WalStatus.miss` on disk, and RecordingTransferCoordinator only drains on
    // a wake — startup, foreground, connectivity, a device connecting. Without
    // this the recordings would sit there until the app was next backgrounded
    // and reopened. `userRetry` is the right trigger: the user asked for this
    // explicitly, and it is the one trigger that does not also require the
    // auto-sync-offline-recordings preference to be on.
    unawaited(RecordingTransferCoordinator.instance.wake(WakeTrigger.userRetry));

    // The picker's copies of the source files have served their purpose; left
    // alone they are a second copy of everything ever imported sitting in the
    // app's cache.
    await _clearPickerCache();

    if (!mounted) return;
    setState(() {
      _importing = false;
      _currentFile = null;
      _results = results;
      // Everything imported is now known-imported; re-picking the same folder
      // will show it as such.
      _candidates = [];
      _chains = [];
    });
  }

  Future<void> _clearPickerCache() async {
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (e) {
      // Best effort: a cache the OS reclaims anyway is not worth failing an
      // import that already succeeded.
      Logger.debug('DJI import: could not clear the picker cache: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('DJI Mic', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_importing) return _buildProgress();
    if (_results.isNotEmpty) return _buildResults();
    if (_candidates.isEmpty) return _buildEmptyState();
    return _buildCandidateList();
  }

  /// The empty state teaches how the transfer works rather than showing an
  /// example: a transmitter's recordings are the user's own, and there is
  /// nothing to put here until they plug one in.
  Widget _buildEmptyState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
      children: [
        Icon(Icons.usb_rounded, size: 48, color: Colors.grey.shade600),
        const SizedBox(height: 20),
        const Text(
          'Connect by USB-C to transfer',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(
          'Recordings live on the transmitters, not the receiver — each transmitter is its own drive, '
          'so two mics on one conversation means plugging in twice.',
          style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.45),
        ),
        const SizedBox(height: 16),
        _step(1, 'Plug the transmitter into the phone with a USB-C cable, or put it in the charging case '
            'and plug that in.'),
        _step(2, 'Tap Choose recordings, then open the transmitter and its DJI_AUDIO folder.'),
        _step(3, 'Pick the takes you want, a few at a time. Android copies each one onto the phone '
            'before Omi can read it, so a long take needs room twice over until the import finishes.'),
        _step(4, 'Long takes arrive as several files — the recorder cuts every 30 minutes — and they '
            'are joined back up by their timestamps.'),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFF1F1F25), borderRadius: BorderRadius.circular(12)),
          child: Text(
            'Nothing is ever written to the transmitter — no deletes, no renames. Omi remembers on the '
            'phone which takes it already has.',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13, height: 1.4),
          ),
        ),
        if (_skippedNames.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'Not DJI recordings, so they were left out: ${_skippedNames.join(', ')}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _step(int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.deepPurple.withValues(alpha: 0.8), shape: BoxShape.circle),
            child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: Colors.grey.shade300, fontSize: 14, height: 1.45)),
          ),
        ],
      ),
    );
  }

  Widget _buildCandidateList() {
    final chainOf = <String, DjiMicSplitChain>{};
    for (final chain in _chains) {
      for (final part in chain.parts) {
        chainOf[part.fileName] = chain;
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: _candidates.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          final joinable = _chains.where((c) => c.confident).length;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              joinable > 0
                  ? '${_candidates.length} recordings. $joinable long take${joinable == 1 ? '' : 's'} arrived '
                      'in parts; each part keeps its own start time, so they land back to back.'
                  : '${_candidates.length} recordings.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13, height: 1.4),
            ),
          );
        }
        final candidate = _candidates[index - 1];
        return _buildCandidateTile(candidate, chainOf[candidate.recording.fileName]);
      },
    );
  }

  Widget _buildCandidateTile(_Candidate candidate, DjiMicSplitChain? chain) {
    final rec = candidate.recording;
    final subtitle = StringBuffer(_formatStart(rec.startedAt));
    subtitle.write('  ·  ');
    subtitle.write('${rec.durationEstimated ? '≈' : ''}${_formatDuration(rec.durationSec)}');
    if (candidate.hasSiblingVariant) {
      subtitle.write('  ·  unprocessed copy of the take above');
    }
    if (chain != null) {
      final position = chain.parts.indexWhere((p) => p.fileName == rec.fileName) + 1;
      subtitle.write(
        chain.confident
            // A 30-minute cut is the recorder's own doing and safe to state.
            ? '  ·  part $position of ${chain.parts.length}, 30-minute cut'
            // A quick manual stop/restart looks the same from the outside;
            // say what was seen, not what it means.
            : '  ·  starts right after the previous take',
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: const Color(0xFF1F1F25), borderRadius: BorderRadius.circular(12)),
      child: CheckboxListTile(
        value: candidate.selected,
        onChanged: (v) => setState(() => candidate.selected = v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: Colors.deepPurple,
        checkColor: Colors.white,
        title: Row(
          children: [
            Expanded(
              child: Text(
                rec.fileName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
            if (candidate.alreadyImported)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.grey.shade800, borderRadius: BorderRadius.circular(4)),
                child: Text(
                  'Imported',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 10, fontWeight: FontWeight.w500),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(subtitle.toString(), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _buildProgress() {
    final total = _candidates.where((c) => c.selected).length;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Importing ${_doneCount + 1} of $total',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            _currentFile ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _fileProgress == 0 ? null : _fileProgress,
              minHeight: 6,
              backgroundColor: Colors.grey.shade900,
              color: Colors.deepPurple,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Keep the transmitter plugged in until this finishes.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final imported = _results.where((r) => r.imported).toList();
    final skipped = _results.where((r) => !r.imported).toList();
    final seconds = imported.fold<double>(0, (s, r) => s + r.durationSec);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      children: [
        Text(
          imported.isEmpty
              ? 'Nothing was imported.'
              : '${imported.length} recording${imported.length == 1 ? '' : 's'} imported '
                  '(${_formatDuration(seconds)} of audio).',
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        if (imported.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            'Uploading has started. They transcribe the same way a recording made on the phone does, '
            'and pick up again by themselves if the connection drops. Watch them in Sync.',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.45),
          ),
        ],
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            'Left out',
            style: TextStyle(color: Colors.grey.shade300, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final r in skipped)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${r.fileName} — ${r.detail ?? r.skip?.name ?? 'skipped'}',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13, height: 1.4),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildFooter() {
    final selected = _candidates.where((c) => c.selected).length;
    final label = _candidates.isEmpty
        ? 'Choose recordings'
        : (selected == 0 ? 'Nothing selected' : 'Import $selected recording${selected == 1 ? '' : 's'}');
    final enabled = !_importing && !_picking && (_candidates.isEmpty || selected > 0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: enabled ? (_candidates.isEmpty ? _pick : _import) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple,
            disabledBackgroundColor: Colors.grey.shade800,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: _picking
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  static String _formatStart(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)}  ${two(at.hour)}:${two(at.minute)}';
  }

  static String _formatDuration(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}
