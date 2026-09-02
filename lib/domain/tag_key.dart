/// The key under which two spellings of one tag are the same tag.
///
/// `스킨케어`, `스킨 케어` and `스킨-케어` are one word written three ways, and
/// `2~5만원` and `2-5만원` are one price band. Which of those a reader typed, or
/// a model happened to emit, is not a decision about meaning, so it is not one
/// the reader should have to undo by hand. Case, whitespace and every separator
/// the tag alphabet allows are dropped; what is left is the word itself.
///
/// This is deliberately all the key does. `카페` and `커피숍` mean the same
/// thing and have different keys, because deciding that takes judgement, and
/// judgement is what the model — shown the reader's existing words — and the
/// reader are for. A key that guessed at synonyms would be the folder scheme
/// coming back as a dictionary.
///
/// Pure Dart on purpose: the eval tool imports it, and it must produce the same
/// key the server produces for the same spelling.
library;

final _dropped = RegExp(r'[\s·ㆍ&/+＋~\-]');

String tagKey(String value) => value.toLowerCase().replaceAll(_dropped, '');
