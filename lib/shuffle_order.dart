import 'package:just_audio/just_audio.dart';

/// Preserve the existing random order while honoring an explicit Play next.
class SonifyShuffleOrder extends DefaultShuffleOrder {
  int? insertAfter;

  @override
  void insert(int index, int count) {
    final anchor = insertAfter;
    insertAfter = null;
    super.insert(index, count);
    if (anchor == null || count == 0) return;
    final shiftedAnchor = anchor >= index ? anchor + count : anchor;
    final added = List.generate(count, (i) => index + i);
    indices.removeWhere(added.contains);
    final after = indices.indexOf(shiftedAnchor);
    indices.insertAll(after < 0 ? indices.length : after + 1, added);
  }

  @override
  void clear() {
    insertAfter = null;
    super.clear();
  }
}
