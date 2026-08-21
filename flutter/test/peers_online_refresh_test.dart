import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('visible offline peer bypasses exhausted public query budget', () {
    expect(
      onlineQueryBudgetAllows(
        isPublicServer: true,
        queryCount: 3,
        maxQueryCount: 3,
        fastRefreshActive: true,
      ),
      isTrue,
    );
  });

  test('idle public peer list keeps the normal query budget', () {
    expect(
      onlineQueryBudgetAllows(
        isPublicServer: true,
        queryCount: 3,
        maxQueryCount: 3,
        fastRefreshActive: false,
      ),
      isFalse,
    );
  });
}
