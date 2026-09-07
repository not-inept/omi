import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/dji_mic_wav.dart';

/// Synthetic recordings, marked as synthetic: no real transmitter file is
/// checked in, and none of these assertions stand in for a run against real
/// hardware. What they do pin down is the arithmetic that a wrong header or a
/// wrong resampler would silently corrupt — a 33% duration error on a float
/// take, or aliased sibilants — neither of which is visible by ear in a
/// transcript until it is too late.
Uint8List _synthWav({
  int sampleRate = 48000,
  int channels = 1,
  int bitsPerSample = 24,
  int audioFormat = wavFormatPcm,
  int frames = 480,
  double Function(int)? sample,
}) {
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final dataLength = frames * blockAlign;
  final header = buildPcmWavHeader(
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bitsPerSample,
    dataLength: dataLength,
    audioFormat: audioFormat,
  );
  final data = Uint8List(dataLength);
  final view = ByteData.sublistView(data);
  for (int f = 0; f < frames; f++) {
    final v = sample?.call(f) ?? 0.0; // -1.0 .. 1.0
    for (int c = 0; c < channels; c++) {
      final at = f * blockAlign + c * (bitsPerSample ~/ 8);
      switch (audioFormat) {
        case wavFormatIeeeFloat:
          view.setFloat32(at, v, Endian.little);
          break;
        default:
          if (bitsPerSample == 24) {
            final i = (v * 8388607).round().clamp(-8388608, 8388607);
            final u = i < 0 ? i + 0x1000000 : i;
            data[at] = u & 0xFF;
            data[at + 1] = (u >> 8) & 0xFF;
            data[at + 2] = (u >> 16) & 0xFF;
          } else if (bitsPerSample == 16) {
            view.setInt16(at, (v * 32767).round().clamp(-32768, 32767), Endian.little);
          } else if (bitsPerSample == 8) {
            data[at] = ((v * 127).round() + 128).clamp(0, 255);
          } else {
            view.setInt32(at, (v * 2147483647).round().clamp(-2147483648, 2147483647), Endian.little);
          }
      }
    }
  }
  return Uint8List.fromList([...header, ...data]);
}

/// Peak absolute amplitude of a PCM16 byte run, as a fraction of full scale.
///
/// [skip] drops that many samples from each end. Any FIR has a start and end
/// transient while its kernel fills and drains, and that transient is
/// broadband by nature — measuring stopband rejection across it measures the
/// transient, not the filter. For a 30-minute import the transient is a
/// couple of milliseconds at each edge.
double _peak(Uint8List pcm, {int skip = 0}) {
  final view = ByteData.sublistView(pcm);
  double peak = 0;
  final from = skip * 2;
  final to = pcm.length - skip * 2;
  for (int i = from; i + 1 < to; i += 2) {
    final v = view.getInt16(i, Endian.little).abs() / 32767.0;
    if (v > peak) peak = v;
  }
  return peak;
}

void main() {
  group('header', () {
    test('reads a 24-bit/48kHz mono DJI-shaped file', () {
      final info = parseDjiMicWavHeader(_synthWav());
      expect(info.audioFormat, wavFormatPcm);
      expect(info.sampleRate, 48000);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 24);
      expect(info.blockAlign, 3);
      expect(info.byteRate, 144000); // the rate labs/dji-mic-controller measured
      expect(info.dataOffset, 44);
      expect(info.isSupported, isTrue);
    });

    test('a 32-bit float take is a third longer per byte than a 24-bit one', () {
      // This is the trap the whole module exists to avoid: same wall-clock
      // duration, 4 bytes per sample instead of 3.
      final float = parseDjiMicWavHeader(
        _synthWav(bitsPerSample: 32, audioFormat: wavFormatIeeeFloat, frames: 48000),
      );
      final pcm24 = parseDjiMicWavHeader(_synthWav(frames: 48000));
      expect(float.durationSec, closeTo(1.0, 1e-9));
      expect(pcm24.durationSec, closeTo(1.0, 1e-9));
      expect(float.byteRate, 192000);
      expect(float.isFloat, isTrue);
      // Reading the float file with the 24-bit assumption is the bug:
      expect(float.dataLength / 144000, closeTo(1.333, 0.001));
    });

    test('walks past a LIST chunk instead of assuming offset 44', () {
      final base = _synthWav(frames: 10);
      final list = <int>[
        ...'LIST'.codeUnits,
        8, 0, 0, 0,
        ...'INFOxxxx'.codeUnits,
      ];
      // Splice the extra chunk in between `fmt ` (ends at 36) and `data`.
      final spliced = Uint8List.fromList([...base.sublist(0, 36), ...list, ...base.sublist(36)]);
      final info = parseDjiMicWavHeader(spliced);
      expect(info.dataOffset, 44 + list.length);
      expect(info.dataLength, 30);
    });

    test('unwraps WAVE_FORMAT_EXTENSIBLE to the format it really is', () {
      // fmt chunk of 40 bytes: standard 16 + cbSize/validBits/channelMask +
      // a SubFormat GUID whose leading word names IEEE float.
      final fmtBody = Uint8List(40);
      final fv = ByteData.sublistView(fmtBody);
      fv.setUint16(0, wavFormatExtensible, Endian.little);
      fv.setUint16(2, 1, Endian.little);
      fv.setUint32(4, 48000, Endian.little);
      fv.setUint32(8, 192000, Endian.little);
      fv.setUint16(12, 4, Endian.little);
      fv.setUint16(14, 32, Endian.little);
      fv.setUint16(16, 22, Endian.little); // cbSize
      fv.setUint16(18, 32, Endian.little); // validBitsPerSample
      fv.setUint32(20, 4, Endian.little); // channelMask
      fv.setUint16(24, wavFormatIeeeFloat, Endian.little); // SubFormat GUID head

      final bytes = <int>[
        ...'RIFF'.codeUnits, 0, 0, 0, 0,
        ...'WAVE'.codeUnits,
        ...'fmt '.codeUnits, 40, 0, 0, 0,
        ...fmtBody,
        ...'data'.codeUnits, 8, 0, 0, 0,
        ...List<int>.filled(8, 0),
      ];
      final info = parseDjiMicWavHeader(Uint8List.fromList(bytes));
      expect(info.audioFormat, wavFormatIeeeFloat);
      expect(info.isFloat, isTrue);
      expect(info.isSupported, isTrue);
    });

    test('a truncated recording is measured by what is really there', () {
      final info = parseDjiMicWavHeader(_synthWav(frames: 48000 * 10));
      // Header says ten seconds; the battery died four seconds in.
      expect(info.durationSec, closeTo(10.0, 1e-9));
      expect(info.durationSecForDataBytes(4 * 144000), closeTo(4.0, 1e-9));
    });

    test('says plainly what it cannot read', () {
      expect(
        () => parseDjiMicWavHeader(Uint8List.fromList('not audio at all'.codeUnits)),
        throwsA(isA<DjiMicWavException>()),
      );
      expect(
        () => parseDjiMicWavHeader(Uint8List.fromList([...'RF64'.codeUnits, 0, 0, 0, 0, ...'WAVE'.codeUnits])),
        throwsA(isA<DjiMicWavException>()),
      );
    });
  });

  group('decode', () {
    test('24-bit, 16-bit, 32-bit and float all land on the same amplitude', () {
      double tone(int i) => math.sin(2 * math.pi * 440 * i / 48000) * 0.5;
      final peaks = <int, double>{};
      for (final spec in [
        (24, wavFormatPcm),
        (16, wavFormatPcm),
        (32, wavFormatPcm),
        (32, wavFormatIeeeFloat),
      ]) {
        final wav = _synthWav(bitsPerSample: spec.$1, audioFormat: spec.$2, frames: 4800, sample: tone);
        final info = parseDjiMicWavHeader(wav);
        final samples = decodeWavSamples(Uint8List.sublistView(wav, info.dataOffset), info);
        expect(samples.length, 4800);
        double peak = 0;
        for (final s in samples) {
          if (s.abs() > peak) peak = s.abs();
        }
        peaks[spec.$1 + (spec.$2 == wavFormatIeeeFloat ? 100 : 0)] = peak / 32767.0;
      }
      for (final p in peaks.values) {
        expect(p, closeTo(0.5, 0.01));
      }
    });

    test('a stereo file is averaged down to mono rather than refused', () {
      final wav = _synthWav(channels: 2, bitsPerSample: 16, frames: 4, sample: (i) => 0.5);
      final info = parseDjiMicWavHeader(wav);
      final samples = decodeWavSamples(Uint8List.sublistView(wav, info.dataOffset), info);
      expect(samples.length, 4);
      expect(samples.first / 32767.0, closeTo(0.5, 0.01));
    });
  });

  group('resample to 16 kHz', () {
    Uint8List convert(Uint8List wav, {int chunkBytes = 1 << 30}) {
      final info = parseDjiMicWavHeader(wav);
      final conv = DjiMicPcm16Converter(info);
      final out = BytesBuilder();
      int at = info.dataOffset;
      while (at < wav.length) {
        final end = math.min(at + chunkBytes, wav.length);
        out.add(conv.addBytes(Uint8List.sublistView(wav, at, end)));
        at = end;
      }
      out.add(conv.finish());
      return out.takeBytes();
    }

    test('48 kHz in, 16 kHz out, one third the samples', () {
      final wav = _synthWav(frames: 48000, sample: (i) => math.sin(2 * math.pi * 1000 * i / 48000) * 0.5);
      final pcm = convert(wav);
      // One second at 16 kHz, 2 bytes a sample. The filter's tail makes the
      // exact count vary by a sample or two; the length must not vary by more.
      expect(pcm.length / 2, closeTo(16000, 4));
    });

    test('a 1 kHz tone survives the trip at full amplitude', () {
      final wav = _synthWav(frames: 48000, sample: (i) => math.sin(2 * math.pi * 1000 * i / 48000) * 0.5);
      expect(_peak(convert(wav)), closeTo(0.5, 0.03));
    });

    test('a 15 kHz tone is filtered out instead of aliasing into speech', () {
      // Naive decimation would fold 15 kHz down to 1 kHz — squarely in the
      // middle of what a transcript needs — at nearly full amplitude.
      final wav = _synthWav(frames: 48000, sample: (i) => math.sin(2 * math.pi * 15000 * i / 48000) * 0.5);
      // Better than 30 dB down, against 0.5 straight through.
      expect(_peak(convert(wav), skip: 64), lessThan(0.015));
    });

    test('chunking the file makes no difference to the audio', () {
      final wav = _synthWav(frames: 12000, sample: (i) => math.sin(2 * math.pi * 700 * i / 48000) * 0.6);
      final whole = convert(wav);
      // 1000 is deliberately not a multiple of the 3-byte sample frame, so
      // every chunk boundary lands mid-sample.
      final pieced = convert(wav, chunkBytes: 1000);
      expect(pieced, equals(whole));
    });

    test('a file already at 16 kHz passes straight through', () {
      final wav = _synthWav(sampleRate: 16000, bitsPerSample: 16, frames: 1600, sample: (i) => 0.25);
      final info = parseDjiMicWavHeader(wav);
      final conv = DjiMicPcm16Converter(info);
      expect(conv.addBytes(Uint8List.sublistView(wav, info.dataOffset)).length, 3200);
      expect(_peak(convert(wav)), closeTo(0.25, 0.01));
    });

    test('a float take that went above 0 dBFS clips here, and does not wrap', () {
      // The unclipped original stays on the transmitter; what must not happen
      // is a sample wrapping from +full-scale to -full-scale.
      final wav = _synthWav(
        bitsPerSample: 32,
        audioFormat: wavFormatIeeeFloat,
        frames: 4800,
        sample: (i) => 3.0,
      );
      final info = parseDjiMicWavHeader(wav);
      final samples = decodeWavSamples(Uint8List.sublistView(wav, info.dataOffset), info);
      final conv = DjiMicPcm16Converter(info);
      final pcm = conv.addBytes(Uint8List.sublistView(wav, info.dataOffset));
      expect(samples.first, greaterThan(32767));
      final view = ByteData.sublistView(pcm);
      for (int i = 0; i + 1 < pcm.length; i += 2) {
        expect(view.getInt16(i, Endian.little), greaterThan(0));
      }
    });

    test('refuses a format it cannot read rather than importing noise', () {
      final wav = _synthWav(bitsPerSample: 16);
      final info = parseDjiMicWavHeader(wav);
      final broken = DjiMicWavInfo(
        audioFormat: 0x11, // IMA ADPCM
        channels: info.channels,
        sampleRate: info.sampleRate,
        bitsPerSample: 4,
        byteRate: info.byteRate,
        blockAlign: info.blockAlign,
        dataOffset: info.dataOffset,
        dataLength: info.dataLength,
      );
      expect(broken.isSupported, isFalse);
      expect(() => DjiMicPcm16Converter(broken), throwsA(isA<DjiMicWavException>()));
    });
  });
}
