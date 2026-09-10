import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart';

/// Hand-computed golden `0xA014` estimator frame (16 bytes, big-endian).
///
/// | off | field        | raw (BE) | decoded            |
/// |-----|--------------|----------|--------------------|
/// |  0  | Rev          | 0x01     | 1                  |
/// |  1  | Flags        | 0x89     | 137                |
/// |  2  | R1           | 0x00B1   | 177/100  = 1.77    |
/// |  4  | R2           | 0x0352   | 850/1000 = 0.85    |
/// |  6  | C            | 0x05C8   | 1480/1000 = 1.48   |
/// |  8  | ConfR        | 0xCC     | 204/255  = 0.8     |
/// |  9  | Lag          | 0x06     | 6/10     = 0.6     |
/// | 10  | LagConf      | 0x66     | 102/255  = 0.4     |
/// | 11  | SigmaQ       | 0x0F     | 15/100   = 0.15    |
/// | 12  | VAbs         | 0x00D7   | 215/10   = 21.5    |
/// | 14  | LastPauseTau | 0x0140   | 320/100  = 3.2     |
final List<int> _goldenBytes = [
  0x01, //       Rev
  0x89, //       Flags
  0x00, 0xB1, // R1
  0x03, 0x52, // R2
  0x05, 0xC8, // C
  0xCC, //       ConfR
  0x06, //       Lag
  0x66, //       LagConf
  0x0F, //       SigmaQ
  0x00, 0xD7, // VAbs
  0x01, 0x40, // LastPauseTau
];

/// Hand-computed golden Rev-2 (`0xA014`) frame (21 bytes, big-endian). Bytes
/// 0–15 mirror [_goldenBytes] EXCEPT byte 0 is `Rev = 2` so the R1-collapse
/// detector tail is decoded; bytes 16–20 are the detector summary.
///
/// | off | field             | raw (BE) | decoded          |
/// |-----|-------------------|----------|------------------|
/// | 16  | DetEventCount     | 0x02     | 2                |
/// | 17  | DetLastEventT     | 0x012C   | 300 * 0.1 = 30.0 |
/// | 19  | DetLastEventMag   | 0x5A     | 90 / 200  = 0.45 |
/// | 20  | DetLastEventConc  | 0xAA     | 170 / 200 = 0.85 |
final List<int> _goldenV2Bytes = [
  0x02, //       Rev = 2 (detector tail present)
  ..._goldenBytes.sublist(1, 16), // flags..lastPauseTau, byte-identical
  0x02, //       DetEventCount = 2
  0x01, 0x2C, // DetLastEventT  BE 0x012C = 300 -> 30.0 s
  0x5A, //       DetLastEventMag  90 -> 0.45
  0xAA, //       DetLastEventConc 170 -> 0.85
];

ByteData _bytes(List<int> b) => ByteData.sublistView(Uint8List.fromList(b));

void main() {
  group('parseBengleEstSample', () {
    test('golden frame decodes byte-exact (big-endian, correct scaling)', () {
      expect(_goldenBytes, hasLength(bengleEstSampleBytes));
      final s = parseBengleEstSample(_bytes(_goldenBytes))!;

      expect(s.rev, 1);
      expect(s.flags, 0x89);
      // The status byte is opaque and forwarded verbatim; masking just proves
      // the raw value round-trips through the decoder.
      expect(s.flags & 0x07, 1);
      expect(s.flags & 0x08, isNonZero);
      expect((s.flags >> 6) & 0x03, 2);

      expect(s.r1, closeTo(1.77, 1e-9));
      expect(s.r2, closeTo(0.85, 1e-9));
      expect(s.c, closeTo(1.48, 1e-9));
      expect(s.confR, closeTo(0.8, 1e-9));
      expect(s.lag, closeTo(0.6, 1e-9));
      expect(s.lagConf, closeTo(0.4, 1e-9));
      expect(s.sigmaQ, closeTo(0.15, 1e-9));
      expect(s.vAbs, closeTo(21.5, 1e-9));
      expect(s.lastPauseTau, closeTo(3.2, 1e-9));
    });

    test(
      'R2 (÷1000) and R1 (÷100) use different scales — a diverging case',
      () {
        // Same raw 0x0064 = 100 in both slots decodes to 1.0 (R1, ÷100) vs
        // 0.1 (R2, ÷1000): proves the two scales are not accidentally shared.
        final b = List<int>.from(_goldenBytes);
        b[2] = 0x00;
        b[3] = 0x64; // R1 raw 100
        b[4] = 0x00;
        b[5] = 0x64; // R2 raw 100
        final s = parseBengleEstSample(_bytes(b))!;
        expect(s.r1, closeTo(1.0, 1e-9));
        expect(s.r2, closeTo(0.1, 1e-9));
      },
    );

    test('U16 sentinels (0xFFFF) decode to null, not a fake value', () {
      final b = List<int>.from(_goldenBytes);
      b[2] = 0xFF;
      b[3] = 0xFF; // R1
      b[4] = 0xFF;
      b[5] = 0xFF; // R2
      b[6] = 0xFF;
      b[7] = 0xFF; // C
      b[12] = 0xFF;
      b[13] = 0xFF; // VAbs
      b[14] = 0xFF;
      b[15] = 0xFF; // LastPauseTau
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.r1, isNull);
      expect(s.r2, isNull);
      expect(s.c, isNull);
      expect(s.vAbs, isNull);
      expect(s.lastPauseTau, isNull);
      // Fields WITHOUT a sentinel stay present.
      expect(s.confR, closeTo(0.8, 1e-9));
      expect(s.sigmaQ, closeTo(0.15, 1e-9));
      expect(s.flags, 0x89);
    });

    test('the Lag U8 sentinel (0xFF) decodes to null', () {
      final b = List<int>.from(_goldenBytes);
      b[9] = 0xFF;
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.lag, isNull);
      // LagConf (neighbouring, no sentinel) is untouched.
      expect(s.lagConf, closeTo(0.4, 1e-9));
    });

    test('multi-byte fields are big-endian (byte order matters)', () {
      // R1 bytes 0x12,0x34 -> big-endian 0x1234 = 4660 -> /100 = 46.6
      // (little-endian 0x3412 = 13330 -> 133.3 would be wrong).
      final b = List<int>.from(_goldenBytes);
      b[2] = 0x12;
      b[3] = 0x34;
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.r1, closeTo(46.6, 1e-9));
    });

    test('SigmaQ caps at 2.55 mL/s (0xFF is NOT a sentinel here)', () {
      // Unlike Lag, SigmaQ has no sentinel: 0xFF = 255 -> 2.55 (the cap).
      final b = List<int>.from(_goldenBytes);
      b[11] = 0xFF;
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.sigmaQ, closeTo(2.55, 1e-9));
    });

    test('frames shorter than 16 bytes are dropped (null, no RangeError)', () {
      expect(parseBengleEstSample(_bytes(_goldenBytes.sublist(0, 15))), isNull);
      expect(parseBengleEstSample(_bytes(_goldenBytes.sublist(0, 8))), isNull);
      expect(parseBengleEstSample(_bytes(const [])), isNull);
    });

    test('trailing bytes beyond 16 are ignored', () {
      final s = parseBengleEstSample(_bytes([..._goldenBytes, 0xFF, 0xAA]))!;
      expect(s.r1, closeTo(1.77, 1e-9));
      expect(s.lastPauseTau, closeTo(3.2, 1e-9));
    });
  });

  // The Rev-2 R1-collapse detector tail (offsets 16–20) is decoded ONLY when
  // len >= 21 AND rev >= 2.
  group('parseBengleEstSample rev-2 detector tail', () {
    test('golden Rev-2 frame decodes the tail byte-exact', () {
      expect(_goldenV2Bytes, hasLength(bengleEstSampleV2Bytes));
      final s = parseBengleEstSample(_bytes(_goldenV2Bytes))!;

      expect(s.rev, 2);
      expect(s.detEventCount, 2);
      expect(s.detLastEventT, closeTo(30.0, 1e-9));
      expect(s.detLastEventMag, closeTo(0.45, 1e-9));
      expect(s.detLastEventConc, closeTo(0.85, 1e-9));

      // The base (offset 0–15) fields still decode exactly as Rev-1.
      expect(s.r1, closeTo(1.77, 1e-9));
      expect(s.r2, closeTo(0.85, 1e-9));
      expect(s.confR, closeTo(0.8, 1e-9));
      expect(s.lastPauseTau, closeTo(3.2, 1e-9));
    });

    test('DetLastEventT is big-endian (byte order matters)', () {
      // 0x00,0xFA -> BE 0x00FA = 250 -> *0.1 = 25.0 s
      // (little-endian 0xFA00 = 64000 -> 6400.0 would be wrong).
      final b = List<int>.from(_goldenV2Bytes);
      b[17] = 0x00;
      b[18] = 0xFA;
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.detLastEventT, closeTo(25.0, 1e-9));
    });

    test('DetLastEventT sentinel 0xFFFF -> null (count still real)', () {
      final b = List<int>.from(_goldenV2Bytes);
      b[17] = 0xFF;
      b[18] = 0xFF;
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.detLastEventT, isNull);
      // detEventCount has no sentinel — still a real value alongside.
      expect(s.detEventCount, 2);
      expect(s.detLastEventMag, closeTo(0.45, 1e-9));
    });

    test('DetLastEventMag / DetLastEventConc sentinel 0xFF -> null', () {
      final b = List<int>.from(_goldenV2Bytes);
      b[19] = 0xFF; // Mag
      b[20] = 0xFF; // Conc
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.detLastEventMag, isNull);
      expect(s.detLastEventConc, isNull);
      // T unaffected.
      expect(s.detLastEventT, closeTo(30.0, 1e-9));
    });

    test(
      'detEventCount 0 is a REAL value (not null) when the tail is present',
      () {
        final b = List<int>.from(_goldenV2Bytes);
        b[16] = 0x00; // no collapse yet this shot
        final s = parseBengleEstSample(_bytes(b))!;
        expect(s.detEventCount, 0);
        expect(s.detEventCount, isNotNull);
      },
    );

    test('Mag/Conc quantization bounds: raw 200 -> 1.0 (max non-sentinel)', () {
      final b = List<int>.from(_goldenV2Bytes);
      b[19] = 0xC8; // 200 -> 1.0 (firmware clamps the raw byte here)
      b[20] = 0xC8; // 200 -> 1.0
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.detLastEventMag, closeTo(1.0, 1e-9));
      expect(s.detLastEventConc, closeTo(1.0, 1e-9));
    });

    test(
      '16-byte Rev-1 frame: every detector-tail field is null (fallback)',
      () {
        // The unchanged Rev-1 golden (rev 1, 16 bytes) must decode the base
        // fields and leave the whole detector tail null.
        final s = parseBengleEstSample(_bytes(_goldenBytes))!;
        expect(s.rev, 1);
        expect(s.r1, closeTo(1.77, 1e-9)); // base fields intact
        expect(s.detEventCount, isNull);
        expect(s.detLastEventT, isNull);
        expect(s.detLastEventMag, isNull);
        expect(s.detLastEventConc, isNull);
      },
    );

    test('20-byte truncated Rev-2 frame: tail null, first 16 still decode', () {
      final truncated = _goldenV2Bytes.sublist(0, 20); // one byte short of 21
      expect(truncated, hasLength(20));
      final s = parseBengleEstSample(_bytes(truncated))!;
      // Not >= 21 bytes -> tail dropped entirely (even though rev == 2).
      expect(s.detEventCount, isNull);
      expect(s.detLastEventT, isNull);
      expect(s.detLastEventMag, isNull);
      expect(s.detLastEventConc, isNull);
      // Base fields (0–15) still decode.
      expect(s.rev, 2);
      expect(s.r1, closeTo(1.77, 1e-9));
      expect(s.lastPauseTau, closeTo(3.2, 1e-9));
    });

    test('21-byte frame with rev < 2: tail ignored (rev gate)', () {
      // A full-length frame that (defensively) still advertises rev 1 must NOT
      // decode the tail — the rev gate wins over the length gate.
      final b = List<int>.from(_goldenV2Bytes);
      b[0] = 0x01; // rev 1 despite 21 bytes
      final s = parseBengleEstSample(_bytes(b))!;
      expect(s.detEventCount, isNull);
      expect(s.detLastEventT, isNull);
      expect(s.detLastEventMag, isNull);
      expect(s.detLastEventConc, isNull);
      expect(s.r1, closeTo(1.77, 1e-9)); // base still decodes
    });
  });
}
