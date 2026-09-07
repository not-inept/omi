import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/dji_mic_import_service.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/utils/dji_mic_import_registry.dart';
import 'package:omi/utils/dji_mic_recordings.dart';
import 'package:omi/utils/dji_mic_wav.dart';

/// Fixtures are synthetic and say so. The DJI file layout they imitate —
/// `TX{unit}_MIC{index}_{yyyyMMdd}_{HHmmss}_{variant}.wav` inside a
/// `TX_MIC*` folder, 24-bit/48 kHz mono, cut every 30 minutes — is documented
/// in DJI's own Mic 3 manual and was verified against real transmitters by the
/// sibling projects `labs/dji-mic-controller` and `labs/notewell`. No real
/// recording is checked in, and nothing here substitutes for running an
/// import against a transmitter.
Uint8List synthDjiWav({
  required double seconds,
  int sampleRate = 48000,
  int bitsPerSample = 24,
  int audioFormat = wavFormatPcm,
}) {
  final frames = (seconds * sampleRate).round();
  final blockAlign = bitsPerSample ~/ 8;
  final data = Uint8List(frames * blockAlign);
  final view = ByteData.sublistView(data);
  for (int f = 0; f < frames; f++) {
    final v = math.sin(2 * math.pi * 440 * f / sampleRate) * 0.4;
    final at = f * blockAlign;
    if (audioFormat == wavFormatIeeeFloat) {
      view.setFloat32(at, v, Endian.little);
    } else if (bitsPerSample == 24) {
      final i = (v * 8388607).round();
      final u = i < 0 ? i + 0x1000000 : i;
      data[at] = u & 0xFF;
      data[at + 1] = (u >> 8) & 0xFF;
      data[at + 2] = (u >> 16) & 0xFF;
    } else {
      view.setInt16(at, (v * 32767).round(), Endian.little);
    }
  }
  return Uint8List.fromList([
    ...buildPcmWavHeader(
      sampleRate: sampleRate,
      channels: 1,
      bitsPerSample: bitsPerSample,
      dataLength: data.length,
      audioFormat: audioFormat,
    ),
    ...data,
  ]);
}

DjiMicImportSource sourceOf(String name, Uint8List bytes, {int? pieceSize}) {
  return DjiMicImportSource(
    fileName: name,
    sizeBytes: bytes.length,
    open: () async* {
      final step = pieceSize ?? bytes.length;
      for (int at = 0; at < bytes.length; at += step) {
        yield Uint8List.sublistView(bytes, at, math.min(at + step, bytes.length));
      }
    },
  );
}

void main() {
  late Directory tempDir;
  late List<Wal> registered;
  late DjiMicImportService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dji_import_test');
    registered = [];
    service = DjiMicImportService(
      walDirectory: () async => tempDir,
      registerWal: (wal) async => registered.add(wal),
      now: () => DateTime.utc(2026, 9, 7, 12),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('importing a recording', () {
    test('a short take becomes one WAL chunk with the transmitter’s own start time', () async {
      final outcome = await service.importOne(
        sourceOf('TX01_MIC002_20250527_202904_orig.wav', synthDjiWav(seconds: 12)),
      );

      expect(outcome.imported, isTrue);
      expect(outcome.chunkCount, 1);
      expect(outcome.durationSec, closeTo(12, 0.01));
      expect(registered, hasLength(1));

      final wal = registered.single;
      // 20:29:04 on 2025-05-27, in the phone's own zone — the DJI filename
      // carries a local wall clock with no zone in it.
      expect(wal.timerStart, DateTime(2025, 5, 27, 20, 29, 4).millisecondsSinceEpoch ~/ 1000);
      expect(wal.codec, BleAudioCodec.pcm16);
      expect(wal.sampleRate, 16000);
      expect(wal.channel, 1);
      expect(wal.status, WalStatus.miss);
      expect(wal.storage, WalStorage.disk);
      expect(wal.deviceModel, 'DJI Mic 3');
      expect(wal.seconds, 12);
      expect(File('${tempDir.path}/${wal.filePath}').existsSync(), isTrue);
    });

    test('the chunk filename is what the backend parses the format out of', () async {
      await service.importOne(sourceOf('TX00_MIC001_20260101_090000_orig.wav', synthDjiWav(seconds: 4)));
      final name = registered.single.filePath!;
      // backend/utils/sync/files.py reads the codec and rate straight out of
      // this name; getting it wrong decodes the audio at the wrong speed.
      expect(name, contains('_pcm16_16000_'));
      expect(name, endsWith('.bin'));
    });

    test('a long take is cut into chunks that carry their own offsets', () async {
      final outcome = await service.importOne(
        sourceOf('TX01_MIC003_20250527_100000_orig.wav', synthDjiWav(seconds: 400)),
      );

      expect(outcome.chunkCount, 3); // 180 + 180 + 40
      expect(outcome.durationSec, closeTo(400, 0.05));
      final base = DateTime(2025, 5, 27, 10, 0, 0).millisecondsSinceEpoch ~/ 1000;
      expect(registered.map((w) => w.timerStart), [base, base + 180, base + 360]);
      expect(registered.map((w) => w.seconds), [180, 180, 40]);
      for (final wal in registered) {
        expect(File('${tempDir.path}/${wal.filePath}').existsSync(), isTrue);
      }
      // 16 kHz mono PCM16: 32000 bytes a second.
      expect(File('${tempDir.path}/${registered.first.filePath}').lengthSync(), 180 * 32000);
    });

    test('every chunk of one file is a distinct WAL, so none is silently dropped', () async {
      await service.importOne(sourceOf('TX01_MIC003_20250527_100000_orig.wav', synthDjiWav(seconds: 400)));
      expect(registered.map((w) => w.id).toSet(), hasLength(3));
    });

    test('two transmitters that started the same second stay separate', () async {
      // Wal.id is device_timerStart, and this is exactly the case DJI hardware
      // makes: two mics on one conversation, both rolling at the same second.
      // A shared id means addExternalWal drops the second mic entirely.
      await service.importOne(sourceOf('TX01_MIC001_20250527_100000_orig.wav', synthDjiWav(seconds: 4)));
      await service.importOne(sourceOf('TX02_MIC001_20250527_100000_orig.wav', synthDjiWav(seconds: 4)));
      expect(registered, hasLength(2));
      expect(registered[0].id, isNot(registered[1].id));
      expect(registered[0].filePath, isNot(registered[1].filePath));
    });

    test('a 32-bit float take is not measured as a third longer than it is', () async {
      final outcome = await service.importOne(
        sourceOf(
          'TX01_MIC004_20250527_110000_orig.wav',
          synthDjiWav(seconds: 30, bitsPerSample: 32, audioFormat: wavFormatIeeeFloat),
        ),
      );
      expect(outcome.imported, isTrue);
      expect(outcome.durationSec, closeTo(30, 0.05));
      expect(outcome.recording!.durationSec, closeTo(30, 0.05));
      expect(outcome.recording!.durationEstimated, isFalse);
    });

    test('the bytes are identical however the platform chops up the stream', () async {
      final wav = synthDjiWav(seconds: 20);
      await service.importOne(sourceOf('TX01_MIC005_20250527_120000_orig.wav', wav));
      final whole = File('${tempDir.path}/${registered.single.filePath}').readAsBytesSync();

      registered.clear();
      // 8191 is prime to the 3-byte sample frame and lands mid-header on the
      // first read: an Android content-URI stream gives no alignment promises.
      await service.importOne(sourceOf('TX01_MIC006_20250527_120000_orig.wav', wav, pieceSize: 8191));
      final pieced = File('${tempDir.path}/${registered.single.filePath}').readAsBytesSync();
      expect(pieced, equals(whole));
    });
  });

  group('skipping', () {
    test('a file that is not a DJI recording is skipped by name alone', () async {
      final outcome = await service.importOne(sourceOf('voice memo.wav', synthDjiWav(seconds: 2)));
      expect(outcome.imported, isFalse);
      expect(outcome.skip, DjiMicImportSkip.notADjiRecording);
      expect(registered, isEmpty);
      expect(tempDir.listSync(), isEmpty);
    });

    test('an already-imported recording is skipped without reading it', () async {
      var opened = false;
      final source = DjiMicImportSource(
        fileName: 'TX01_MIC002_20250527_202904_orig.wav',
        sizeBytes: 1000,
        open: () {
          opened = true;
          return const Stream<List<int>>.empty();
        },
      );
      final outcome = await service.importOne(source, alreadyImported: true);
      expect(outcome.skip, DjiMicImportSkip.alreadyImported);
      expect(opened, isFalse); // a 250 MB file must not be read to decide this
    });

    test('an unreadable file is reported, not half-imported', () async {
      final junk = Uint8List.fromList(List<int>.filled(5000, 7));
      final outcome = await service.importOne(sourceOf('TX01_MIC007_20250527_130000_orig.wav', junk));
      expect(outcome.skip, DjiMicImportSkip.unreadable);
      expect(outcome.detail, isNotNull);
      expect(registered, isEmpty);
      expect(tempDir.listSync(), isEmpty);
    });

    test('a read that dies halfway leaves nothing behind', () async {
      final wav = synthDjiWav(seconds: 400);
      final source = DjiMicImportSource(
        fileName: 'TX01_MIC008_20250527_140000_orig.wav',
        sizeBytes: wav.length,
        open: () async* {
          // Long enough to have written a chunk before the cable is pulled.
          yield Uint8List.sublistView(wav, 0, 48000 * 3 * 200);
          throw const FileSystemException('device removed');
        },
      );
      final outcome = await service.importOne(source);
      expect(outcome.skip, DjiMicImportSkip.failed);
      expect(registered, isEmpty);
      expect(tempDir.listSync(), isEmpty, reason: 'a failed import must not leave orphan WAL files');
    });

    test('a recording with no audio in it is reported as empty', () async {
      final outcome = await service.importOne(
        sourceOf('TX01_MIC009_20250527_150000_orig.wav', synthDjiWav(seconds: 0)),
      );
      expect(outcome.skip, DjiMicImportSkip.empty);
      expect(registered, isEmpty);
    });
  });

  group('bookkeeping', () {
    test('an import is remembered by name and size, and only on the phone', () {
      final source = sourceOf('TX01_MIC002_20250527_202904_orig.wav', synthDjiWav(seconds: 4));
      const outcome = DjiMicImportOutcome(
        fileName: 'TX01_MIC002_20250527_202904_orig.wav',
        chunkCount: 2,
        durationSec: 240,
      );
      final record = service.recordFor(source, outcome);
      expect(record.fileName, 'TX01_MIC002_20250527_202904_orig.wav');
      expect(record.sizeBytes, source.sizeBytes);
      expect(record.chunkCount, 2);
      expect(record.importedAt, DateTime.utc(2026, 9, 7, 12));
    });

    test('the registry answers "have I got this one" and survives a round trip', () {
      var registry = const DjiMicImportRegistry.empty();
      expect(registry.contains('TX01_MIC002_20250527_202904_orig.wav', 100), isFalse);

      registry = registry.withRecord(const DjiMicImportRecord(
        fileName: 'TX01_MIC002_20250527_202904_orig.wav',
        sizeBytes: 100,
        importedAtMs: 1000,
        chunkCount: 1,
        durationSec: 12,
      ));
      expect(registry.contains('TX01_MIC002_20250527_202904_orig.wav', 100), isTrue);
      // A take re-recorded into the same name after a format is a different file.
      expect(registry.contains('TX01_MIC002_20250527_202904_orig.wav', 200), isFalse);

      final restored = DjiMicImportRegistry.decode(registry.encode());
      expect(restored.length, 1);
      expect(restored.lookup('TX01_MIC002_20250527_202904_orig.wav', 100)!.durationSec, 12);
    });

    test('re-importing replaces the record rather than doubling it', () {
      var registry = const DjiMicImportRegistry.empty();
      for (final ts in [1000, 2000]) {
        registry = registry.withRecord(DjiMicImportRecord(
          fileName: 'TX01_MIC002_20250527_202904_orig.wav',
          sizeBytes: 100,
          importedAtMs: ts,
          chunkCount: 1,
          durationSec: 12,
        ));
      }
      expect(registry.length, 1);
      expect(registry.records.single.importedAtMs, 2000);
    });

    test('forgetting an import makes the recording offerable again', () {
      var registry = const DjiMicImportRegistry.empty().withRecord(const DjiMicImportRecord(
        fileName: 'a.wav',
        sizeBytes: 1,
        importedAtMs: 1,
        chunkCount: 1,
        durationSec: 1,
      ));
      registry = registry.without('a.wav', 1);
      expect(registry.contains('a.wav', 1), isFalse);
    });

    test('the list is bounded, keeping the most recent', () {
      var registry = const DjiMicImportRegistry.empty();
      for (int i = 0; i < 10; i++) {
        registry = registry.withRecord(DjiMicImportRecord(
          fileName: 'f$i.wav',
          sizeBytes: i,
          importedAtMs: i * 1000,
          chunkCount: 1,
          durationSec: 1,
        ));
      }
      final trimmed = registry.trimmedTo(3);
      expect(trimmed.length, 3);
      expect(trimmed.records.map((r) => r.fileName), containsAll(['f9.wav', 'f8.wav', 'f7.wav']));
    });

    test('a corrupt blob costs a duplicate import, never the screen', () {
      expect(DjiMicImportRegistry.decode('not json').length, 0);
      expect(DjiMicImportRegistry.decode('{"a":1}').length, 0);
      expect(DjiMicImportRegistry.decode(null).length, 0);
      // One bad row does not take the good ones with it.
      expect(
        DjiMicImportRegistry.decode('[{"fileName":"a.wav","sizeBytes":1},{"nope":true}]').length,
        1,
      );
    });
  });

  group('what to offer from a folder', () {
    test('the processed variant is offered, not both copies of one take', () {
      DjiMicRecording rec(String name, String variant) => djiMicRecordingFromHeader(
            path: name,
            fileName: name,
            sizeBytes: 44 + 144000 * 10,
            folderKey: 'TX_MIC001_20250530_115001',
          )!;
      final all = [
        rec('TX01_MIC002_20250527_202904_orig.wav', 'orig'),
        rec('TX01_MIC002_20250527_202904_edit.wav', 'edit'),
        rec('TX01_MIC003_20250527_210000_orig.wav', 'orig'), // single-file mode
      ];
      final offered = preferredDjiMicVariants(all);
      expect(offered.map((r) => r.fileName), [
        'TX01_MIC002_20250527_202904_edit.wav',
        'TX01_MIC003_20250527_210000_orig.wav',
      ]);
    });

    test('only a device cut is grouped automatically; a manual restart is not', () {
      // notewell/recorders.py and labs/dji-mic-controller both hold this line:
      // a 30-minute cut is the recorder's doing and safe to join, but two
      // takes a second apart are two thoughts unless the user says otherwise.
      DjiMicRecording part(int index, DateTime start, double seconds) => DjiMicRecording(
            path: 'p$index',
            fileName: 'TX01_MIC00$index.wav',
            txUnit: 1,
            micIndex: index,
            startedAt: start,
            variant: 'orig',
            sizeBytes: (seconds * 144000).round(),
            durationSec: seconds,
            folderKey: 'f',
          );

      final deviceCut = findDjiMicSplitChains([
        part(1, DateTime(2025, 5, 27, 10, 0, 0), 1800),
        part(2, DateTime(2025, 5, 27, 10, 30, 0), 600),
      ]);
      expect(deviceCut.single.reason, DjiMicSplitReason.chunkCut);
      expect(deviceCut.single.confident, isTrue);

      final manualRestart = findDjiMicSplitChains([
        part(1, DateTime(2025, 5, 27, 11, 0, 0), 1293),
        part(2, DateTime(2025, 5, 27, 11, 21, 35), 600),
      ]);
      expect(manualRestart.single.reason, DjiMicSplitReason.contiguous);
      expect(manualRestart.single.confident, isFalse);
    });
  });
}
