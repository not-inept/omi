/// Bringing recordings off a DJI transmitter into Omi as conversations.
///
/// **The transfer itself is USB-C.** A transmitter's internal storage has no
/// documented public protocol a third-party app can pull from: DJI's own Mimo
/// app has a File Download feature over its Bluetooth link, but that is a
/// closed, undocumented protocol with no SDK — DJI's developer programme
/// covers aircraft and gimbals, not the Mic line. What DJI documents for
/// everyone else is the wire: connect the transmitter (or its charging case)
/// to a computer and copy the files out of `DJI_AUDIO`. On Android that same
/// USB mass-storage volume is reachable through the system file picker, which
/// is what this importer reads from. See docs/DJI-STATUS.md for what a
/// wireless path would actually require.
///
/// **What an import does.** A picked recording is decoded from whatever the
/// transmitter wrote (24-bit or 32-bit float, 48 kHz) into the 16 kHz mono
/// PCM16 that the rest of Omi already speaks, written into the WAL directory
/// in chunks, and handed to [LocalWalSync.addExternalWal] — the same door the
/// SD-card and flash-page syncs use. From there the existing upload,
/// transcription and conversation-creation path runs untouched: no new
/// endpoint, nothing added to the backend, and an import that happens offline
/// simply syncs later like any other recording.
///
/// **Timestamps are the whole point.** The transmitter's filename carries the
/// wall-clock time it started recording, and that becomes the WAL's
/// `timerStart`, so a conversation from a lunch three days ago lands on the
/// day it happened rather than the day it was plugged in.
///
/// **Nothing is written to the transmitter.** Not a marker file, not a
/// rename, not a delete. What has been imported is remembered on the phone
/// (see [DjiMicImportRegistry]) — the same read-only rule the sibling desktop
/// tool `labs/dji-mic-controller` holds to, for the same reason: the file on
/// the mic is the only original.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/dji_mic_recordings.dart';
import 'package:omi/utils/dji_mic_import_registry.dart';
import 'package:omi/utils/dji_mic_wav.dart';
import 'package:omi/utils/logger.dart';

/// Seconds of audio per WAL chunk.
///
/// Matched to [sdcardChunkSizeSecs], and for the same reason: one upload batch
/// is one server-side sync job, and a job has to finish inside the backend's
/// stale-job window. A whole 30-minute DJI take as a single file would be a
/// 57 MB upload against that clock; in three-minute pieces it is a queue that
/// makes progress and survives losing signal halfway.
const int djiMicImportChunkSeconds = sdcardChunkSizeSecs;

/// Device id stamped on imported WALs.
///
/// The transmitter's own line number is part of it because [Wal.id] is
/// `device_timerStart`, and two transmitters recording the same conversation
/// start within the same second — the exact case DJI hardware creates and the
/// one where a shared id would silently drop the second mic's audio. (The
/// number is a line number, not a serial: the same physical unit is TX00 alone
/// and TX01 when it shares a receiver. That is fine here; all it has to do is
/// separate two mics running at once.)
String djiMicImportDeviceId(int txUnit) => 'djimic3tx$txUnit';

/// Display name carried on imported WALs.
const String djiMicImportDeviceModel = 'DJI Mic 3';

/// A file the user picked, as this importer needs to see it.
///
/// [open] must return the file's bytes from the beginning. It is called once
/// per import, so a platform that can only hand over a single-use stream (an
/// Android content URI) satisfies this as readily as a real path does.
class DjiMicImportSource {
  final String fileName;
  final int sizeBytes;
  final Stream<List<int>> Function() open;

  const DjiMicImportSource({
    required this.fileName,
    required this.sizeBytes,
    required this.open,
  });

  /// A source backed by a real file on this device.
  factory DjiMicImportSource.file(File file) {
    return DjiMicImportSource(
      fileName: file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : file.path.split('/').last,
      sizeBytes: file.lengthSync(),
      open: () => file.openRead(),
    );
  }
}

/// Why an import did not happen. Kept as a value the UI can render per file —
/// a batch where three of twelve files were skipped has to be able to say
/// which three and why, not just report a smaller number than expected.
enum DjiMicImportSkip {
  /// The filename is not a DJI recording name.
  notADjiRecording,

  /// Already imported, and the user did not ask to import it again.
  alreadyImported,

  /// The file is not readable as a WAV, or is in a format this cannot decode.
  unreadable,

  /// There was no audio in it.
  empty,

  /// The read or the write failed part way.
  failed,
}

/// What happened to one picked file.
class DjiMicImportOutcome {
  final String fileName;
  final DjiMicRecording? recording;
  final DjiMicImportSkip? skip;

  /// Free text for the skip, safe to show the user.
  final String? detail;

  /// WAL chunks created. Zero for anything skipped.
  final int chunkCount;

  /// Seconds of audio imported.
  final double durationSec;

  const DjiMicImportOutcome({
    required this.fileName,
    this.recording,
    this.skip,
    this.detail,
    this.chunkCount = 0,
    this.durationSec = 0,
  });

  bool get imported => skip == null;
}

/// Reads a header out of what has arrived so far.
///
/// Returns null when the bytes seen are simply not enough yet, and throws when
/// the file is definitively not something this can read. Without that
/// distinction a large header (a recorder that writes `LIST`/`bext` metadata
/// before the audio) is indistinguishable from a corrupt file, and one of the
/// two gets treated wrongly.
DjiMicWavInfo? readDjiMicHeaderIfComplete(Uint8List buffered) {
  if (buffered.length < 12) return null;
  final signature = String.fromCharCodes(buffered.sublist(0, 4));
  if (signature != 'RIFF') {
    // Not a RIFF file at all — more bytes will never help.
    return parseDjiMicWavHeader(buffered);
  }
  if (buffered.length < 44) return null;
  try {
    return parseDjiMicWavHeader(buffered);
  } on DjiMicWavException {
    if (buffered.length >= djiMicMaxHeaderBytes) rethrow;
    return null;
  }
}

/// Turns picked recordings into WAL chunks.
class DjiMicImportService {
  /// Where WAL `.bin` files live. Injected rather than resolved here so the
  /// whole import runs against a temp directory in a test.
  final Future<Directory> Function() walDirectory;

  /// Hands a finished chunk to the sync layer. In the app this is
  /// `ServiceManager.instance().wal.getSyncs().phone.addExternalWal`.
  final Future<void> Function(Wal wal) registerWal;

  /// Injected so an import's bookkeeping timestamp is deterministic in tests.
  final DateTime Function() now;

  DjiMicImportService({
    required this.walDirectory,
    required this.registerWal,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// Imports one recording.
  ///
  /// [onProgress] is called with 0..1 of the source file's bytes read.
  /// [alreadyImported] short-circuits a file the registry has seen; pass false
  /// when the user has explicitly asked for it again.
  Future<DjiMicImportOutcome> importOne(
    DjiMicImportSource source, {
    bool alreadyImported = false,
    void Function(double progress)? onProgress,
  }) async {
    final parsedName = parseDjiMicRecordingName(source.fileName);
    if (parsedName == null) {
      return DjiMicImportOutcome(
        fileName: source.fileName,
        skip: DjiMicImportSkip.notADjiRecording,
        detail: 'Not a DJI recording filename.',
      );
    }
    if (alreadyImported) {
      return DjiMicImportOutcome(
        fileName: source.fileName,
        skip: DjiMicImportSkip.alreadyImported,
        detail: 'Already imported.',
      );
    }

    final directory = await walDirectory();
    final created = <Wal>[];
    final writtenPaths = <String>[];

    DjiMicWavInfo? info;
    DjiMicPcm16Converter? converter;
    final headerBuffer = BytesBuilder(copy: true);

    // Everything below counts in the output domain: 16 kHz mono PCM16.
    var chunk = BytesBuilder(copy: true);

    /// Samples already flushed into chunks — both this recording's running
    /// length and the offset the next chunk starts at.
    int writtenSamples = 0;
    const chunkBytes = djiMicImportChunkSeconds * omiPcmSampleRate * 2;
    int bytesRead = 0;

    Future<void> flushChunkOf(Uint8List bytes) async {
      if (bytes.isEmpty) return;
      final wal = _buildWal(
        parsedName: parsedName,
        startSampleOffset: writtenSamples,
        pcmBytes: bytes.length,
      );
      final path = '${directory.path}/${wal.getFileName()}';
      await File(path).writeAsBytes(bytes, flush: true);
      wal.filePath = wal.getFileName();
      writtenPaths.add(path);
      created.add(wal);
      writtenSamples += bytes.length ~/ 2;
    }

    try {
      await for (final piece in source.open()) {
        bytesRead += piece.length;
        if (source.sizeBytes > 0) {
          onProgress?.call(math.min(1.0, bytesRead / source.sizeBytes));
        }

        Uint8List audio;
        if (info == null) {
          headerBuffer.add(piece);
          final buffered = headerBuffer.takeBytes();
          final parsed = readDjiMicHeaderIfComplete(buffered);
          if (parsed == null) {
            headerBuffer.add(buffered);
            continue;
          }
          info = parsed;
          converter = DjiMicPcm16Converter(parsed);
          // Everything after the header in this same piece is already audio.
          audio = buffered.length > parsed.dataOffset
              ? Uint8List.sublistView(buffered, parsed.dataOffset)
              : Uint8List(0);
        } else {
          audio = piece is Uint8List ? piece : Uint8List.fromList(piece);
        }

        if (audio.isEmpty) continue;
        final pcm = converter!.addBytes(audio);
        if (pcm.isEmpty) continue;
        chunk.add(pcm);
        while (chunk.length >= chunkBytes) {
          // takeBytes() empties the builder, so whatever is past the chunk
          // boundary has to be put back rather than dropped.
          final all = chunk.takeBytes();
          await flushChunkOf(Uint8List.sublistView(all, 0, chunkBytes));
          chunk = BytesBuilder(copy: true);
          chunk.add(Uint8List.sublistView(all, chunkBytes));
        }
      }

      if (info == null) {
        // The stream ended before a header was complete.
        final buffered = headerBuffer.takeBytes();
        if (buffered.isNotEmpty) parseDjiMicWavHeader(buffered);
        throw const DjiMicWavException('The file ended before its header was complete.');
      }

      chunk.add(converter!.finish());
      await flushChunkOf(chunk.takeBytes());
    } on DjiMicWavException catch (e) {
      await _discard(writtenPaths);
      return DjiMicImportOutcome(
        fileName: source.fileName,
        skip: DjiMicImportSkip.unreadable,
        detail: e.message,
      );
    } catch (e) {
      Logger.debug('DJI import failed for ${source.fileName}: $e');
      await _discard(writtenPaths);
      return DjiMicImportOutcome(
        fileName: source.fileName,
        skip: DjiMicImportSkip.failed,
        detail: '$e',
      );
    }

    if (created.isEmpty) {
      return DjiMicImportOutcome(
        fileName: source.fileName,
        skip: DjiMicImportSkip.empty,
        detail: 'The recording holds no audio.',
      );
    }

    // Register only after every chunk is on disk. A half-registered import is
    // a set of WALs pointing at files that were never written, which the sync
    // layer would then have to discover as corrupt one at a time.
    for (final wal in created) {
      await registerWal(wal);
    }

    final recording = djiMicRecordingFromHeader(
      path: source.fileName,
      fileName: source.fileName,
      sizeBytes: source.sizeBytes,
      folderKey: '',
      header: info,
    );

    return DjiMicImportOutcome(
      fileName: source.fileName,
      recording: recording,
      chunkCount: created.length,
      durationSec: writtenSamples / omiPcmSampleRate,
    );
  }

  /// The bookkeeping row for a finished import. The caller persists it —
  /// keeping the write out of here is what lets one screen import a batch and
  /// save the registry once.
  DjiMicImportRecord recordFor(DjiMicImportSource source, DjiMicImportOutcome outcome) {
    return DjiMicImportRecord(
      fileName: source.fileName,
      sizeBytes: source.sizeBytes,
      importedAtMs: now().toUtc().millisecondsSinceEpoch,
      chunkCount: outcome.chunkCount,
      durationSec: outcome.durationSec,
    );
  }

  Wal _buildWal({
    required DjiMicParsedName parsedName,
    required int startSampleOffset,
    required int pcmBytes,
  }) {
    final startedAt = parsedName.startedAt.add(Duration(milliseconds: startSampleOffset * 1000 ~/ omiPcmSampleRate));
    final samples = pcmBytes ~/ 2;
    const codec = BleAudioCodec.pcm16;
    return Wal(
      // Seconds since the epoch, in the phone's own zone: the DJI filename
      // carries a local wall-clock time with no zone in it, which is the same
      // convention the desktop tool and notewell read it under.
      timerStart: startedAt.millisecondsSinceEpoch ~/ 1000,
      codec: codec,
      sampleRate: omiPcmSampleRate,
      channel: 1,
      seconds: (samples / omiPcmSampleRate).round(),
      status: WalStatus.miss,
      storage: WalStorage.disk,
      device: djiMicImportDeviceId(parsedName.txUnit),
      deviceModel: djiMicImportDeviceModel,
      totalFrames: samples ~/ codec.getFrameSize(),
      syncedFrameOffset: 0,
      originalStorage: WalStorage.disk,
    );
  }

  Future<void> _discard(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (e) {
        Logger.debug('DJI import: could not clean up $path: $e');
      }
    }
  }
}
