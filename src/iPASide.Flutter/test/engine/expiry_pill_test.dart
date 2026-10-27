import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/expiry_pill.dart';
import 'package:ipaside/engine/models.dart';

void main() {
  group('ExpiryPills.classify', () {
    test('expired wins over any day count', () {
      expect(
        ExpiryPills.classify(true, 6),
        const ExpiryPill(ExpiryLevel.expired, 'Expired'),
      );
    });

    test('a null day count is unknown', () {
      expect(
        ExpiryPills.classify(false, null),
        const ExpiryPill(ExpiryLevel.unknown, 'unknown'),
      );
    });

    test('less than a day reads "under a day" and warns', () {
      expect(
        ExpiryPills.classify(false, 0.4),
        const ExpiryPill(ExpiryLevel.warn, 'under a day'),
      );
    });

    test('exactly zero days reads "under a day"', () {
      expect(
        ExpiryPills.classify(false, 0),
        const ExpiryPill(ExpiryLevel.warn, 'under a day'),
      );
    });

    test('a negative day count clamps to zero', () {
      expect(
        ExpiryPills.classify(false, -3.5),
        const ExpiryPill(ExpiryLevel.warn, 'under a day'),
      );
    });

    test('one day is singular', () {
      expect(
        ExpiryPills.classify(false, 1),
        const ExpiryPill(ExpiryLevel.warn, '1 day left'),
      );
    });

    test('a fraction over one day floors to one', () {
      expect(
        ExpiryPills.classify(false, 1.9),
        const ExpiryPill(ExpiryLevel.warn, '1 day left'),
      );
    });

    test('two days still warns', () {
      expect(
        ExpiryPills.classify(false, 2),
        const ExpiryPill(ExpiryLevel.warn, '2 days left'),
      );
    });

    test('just over two days is ok', () {
      expect(
        ExpiryPills.classify(false, 2.01),
        const ExpiryPill(ExpiryLevel.ok, '2 days left'),
      );
    });

    test('three days is ok', () {
      expect(
        ExpiryPills.classify(false, 3),
        const ExpiryPill(ExpiryLevel.ok, '3 days left'),
      );
    });

    test('a full week floors as expected', () {
      expect(
        ExpiryPills.classify(false, 6.99),
        const ExpiryPill(ExpiryLevel.ok, '6 days left'),
      );
    });

    test('non-finite values degrade to unknown instead of throwing', () {
      expect(ExpiryPills.classify(false, double.nan).level, ExpiryLevel.unknown);
      expect(
        ExpiryPills.classify(false, double.infinity).level,
        ExpiryLevel.unknown,
      );
    });
  });

  group('ExpiryPills.classifyRecord', () {
    test('reads expiry off the record', () {
      expect(
        ExpiryPills.classifyRecord(
          const InstallRecord(bundleId: 'com.example.app', daysLeft: 5),
        ),
        const ExpiryPill(ExpiryLevel.ok, '5 days left'),
      );
    });

    test('honours the expired flag', () {
      expect(
        ExpiryPills.classifyRecord(
          const InstallRecord(bundleId: 'com.example.app', expired: true),
        ),
        const ExpiryPill(ExpiryLevel.expired, 'Expired'),
      );
    });
  });
}
