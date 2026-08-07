import 'package:bitwindow/providers/blockchain_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sail_ui/gen/bitwindowd/v1/bitwindowd.pb.dart';

Block _block(int height) => Block(height: height, hash: 'h$height');

void main() {
  group('mergeTipBlocks', () {
    test('empty existing takes the tip page wholesale', () {
      final tip = [_block(3), _block(2), _block(1)];
      final (blocks, heights) = mergeTipBlocks([], {}, tip);

      expect(blocks.map((b) => b.height), [3, 2, 1]);
      expect(heights, {1, 2, 3});
    });

    test('new tip heights are prepended and sorted descending', () {
      // Regression for #1861: after the first fetch, blocks was non-empty so
      // later listBlocks pages never replaced the tip — Latest Blocks froze.
      final existing = [_block(2), _block(1)];
      final heights = {1, 2};
      final tip = [_block(4), _block(3), _block(2)];

      final (blocks, nextHeights) = mergeTipBlocks(existing, heights, tip);

      expect(blocks.map((b) => b.height), [4, 3, 2, 1]);
      expect(nextHeights, {1, 2, 3, 4});
    });

    test('no-op when tip page is already loaded', () {
      final existing = [_block(3), _block(2)];
      final heights = {2, 3};
      final tip = [_block(3), _block(2)];

      final (blocks, nextHeights) = mergeTipBlocks(existing, heights, tip);

      expect(identical(blocks, existing), isTrue);
      expect(identical(nextHeights, heights), isTrue);
    });

    test('preserves older pages loaded via loadMoreBlocks', () {
      final existing = [_block(5), _block(4), _block(3), _block(2), _block(1)];
      final heights = {1, 2, 3, 4, 5};
      final tip = [_block(6), _block(5), _block(4)];

      final (blocks, nextHeights) = mergeTipBlocks(existing, heights, tip);

      expect(blocks.map((b) => b.height), [6, 5, 4, 3, 2, 1]);
      expect(nextHeights, {1, 2, 3, 4, 5, 6});
    });
  });
}
