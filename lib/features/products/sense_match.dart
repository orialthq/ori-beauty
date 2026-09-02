import '../../domain/models.dart';
import '../../domain/tag_key.dart';

/// Matching a typed word against the library, by meaning as well as by name.
///
/// The meaning half runs against the sense dictionary: for each tag, the words
/// a person would type when looking for it (닭발 ← 매운, 야식), generated once
/// per tag by the model and stored. Nothing here calls anything — this file is
/// the part that runs on every keystroke, so it is string work and under a
/// millisecond, which is the whole design: the slow thinking happened when the
/// tag was made, not while the reader is typing.

/// One suggestion for the row under the search box.
///
/// [via] is what summoned it, or null for a plain name match — shown to the
/// reader as `닭발 ← 매운`, because a suggestion that cannot say why it
/// appeared cannot be corrected. [term] is the typed word the suggestion
/// stands in for, so accepting it can replace that word.
///
/// Three shapes travel through this: a name match or recent tag (`via` null),
/// a sense hit (`via` is the dictionary word, `term` the typed word it
/// answers), and a companion (`via` is the tag the reader already asked for,
/// `term` null — accepting it adds to the search instead of replacing, and
/// there is no dictionary entry behind it to strike out).
typedef SkySuggestion = ({String name, String? via, String? term});

const _leadConsonants = [
  'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ', //
  'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

/// The leading consonants of [value]: 닭발 → ㄷㅂ. Non-Hangul passes through
/// lowercased so a mixed name still lines up with a mixed query.
String chosungOf(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= 0xAC00 && rune <= 0xD7A3) {
      out.write(_leadConsonants[(rune - 0xAC00) ~/ 588]);
    } else {
      out.write(String.fromCharCode(rune).toLowerCase());
    }
  }
  return out.toString();
}

/// Whether the reader is typing in bare consonants, the way Korean apps are
/// expected to be searchable: ㄷㅂ finds 닭발.
bool isChosungQuery(String term) =>
    term.isNotEmpty &&
    term.runes.every((rune) => rune >= 0x3131 && rune <= 0x314E);

/// Whether a typed word finds a tag by its name — substring as before, plus
/// leading-consonant matching.
bool tagNameMatches(String name, String term) {
  final lower = name.toLowerCase();
  if (lower.contains(term)) return true;
  return isChosungQuery(term) && chosungOf(name).contains(term);
}

/// Whether a sense word answers a typed word.
///
/// Prefix in either direction with at least two characters of overlap, which
/// is what stands in for Korean morphology here: 매운거 starts with the sense
/// word 매운, and 조용 starts the sense word 조용한. A suffix-stripping rule
/// list would do the same job with a list of guesses; two-way prefix does it
/// with none.
bool senseWordMatches(String word, String term) {
  final w = word.toLowerCase();
  final t = term.toLowerCase();
  if (w.length < 2 || t.length < 2) return w == t;
  return w.startsWith(t) || t.startsWith(w);
}

/// Every tag the typed words reach through the sense dictionary.
///
/// One way only: a typed word leads to a tag, and a tag's own name never
/// expands to anything. A word that already is a tag name asks for that tag
/// by itself and gets no second reading. Tags come back in [vocabulary] order
/// — most used first — with each tag reached once, by the first word that
/// found it.
List<SkySuggestion> senseHits({
  required List<String> terms,
  required List<TagVocabularyEntry> vocabulary,
  required Map<String, List<String>> senses,
}) {
  if (terms.isEmpty || senses.isEmpty) return const [];
  final names = {for (final entry in vocabulary) entry.value.toLowerCase()};
  final hits = <SkySuggestion>[];
  final taken = <String>{};
  for (final entry in vocabulary) {
    if (!taken.add(entry.value)) continue;
    final words = senses[tagKey(entry.value)];
    if (words == null || words.isEmpty) continue;
    for (final term in terms) {
      if (names.contains(term)) continue;
      String? via;
      for (final word in words) {
        if (senseWordMatches(word, term)) {
          via = word;
          break;
        }
      }
      if (via != null) {
        hits.add((name: entry.value, via: via, term: term));
        break;
      }
    }
  }
  return hits;
}

/// The tags that ride along with what was asked.
///
/// When every typed word exactly names a tag, the saved things filed under
/// all of them name the rest of their tags here: 후암동's captures also carry
/// 카페 and 혼밥, so those are what 후암동 leads on to. Nothing is guessed —
/// a tag appears because it sits on the same saved things, ordered by how
/// many they share, ties kept in [vocabulary] order (most used first).
///
/// A half-typed word returns nothing: while the reader is still spelling,
/// name completion is the right offer, not neighbours of a word they have
/// not finished asking.
List<SkySuggestion> companionHits({
  required List<String> terms,
  required Iterable<Iterable<String>> filings,
  required List<TagVocabularyEntry> vocabulary,
}) {
  if (terms.isEmpty) return const [];
  final asked = <String>[];
  for (final term in terms) {
    final entry = vocabulary.where((e) => e.value.toLowerCase() == term);
    if (entry.isEmpty) return const [];
    asked.add(entry.first.value);
  }
  final counts = <String, int>{};
  for (final filing in filings) {
    final names = filing.toList(growable: false);
    final carriesAll = terms.every(
      (term) => names.any((name) => name.toLowerCase() == term),
    );
    if (!carriesAll) continue;
    for (final name in names) {
      if (terms.contains(name.toLowerCase())) continue;
      counts.update(name, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  final order = <String, int>{};
  for (final entry in vocabulary) {
    order.putIfAbsent(entry.value, () => order.length);
  }
  final companions = counts.keys.toList()
    ..sort((a, b) {
      final byShared = counts[b]!.compareTo(counts[a]!);
      if (byShared != 0) return byShared;
      return (order[a] ?? order.length).compareTo(order[b] ?? order.length);
    });
  final label = asked.join(' ');
  return [for (final name in companions) (name: name, via: label, term: null)];
}
