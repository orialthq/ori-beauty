/// The alphabet a tag is written in, shared by every pass that emits or reads
/// one so the four places that used to hold a copy cannot drift apart.
///
/// Hangul, Latin, digits, and a small set of joiners between words. No emoji,
/// hashtag, URL, or sentence punctuation: a tag is a word to search under, not
/// a caption. The string form is what a JSON schema `pattern` takes; the RegExp
/// is the same source compiled once for the validators.
export const TAG_PATTERN_SOURCE =
  "^[가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+(?:[ ·ㆍ&/+＋~-][가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+)*$";

export const TAG_PATTERN = new RegExp(TAG_PATTERN_SOURCE, "u");

export const TAG_MIN_LENGTH = 2;
export const TAG_MAX_LENGTH = 20;

/// Everything `tagKey` drops: whitespace and every joiner the alphabet allows.
const DROPPED = /[\s·ㆍ&/+＋~\-]/gu;

/// The key under which two spellings of one tag are the same tag.
///
/// `스킨케어`, `스킨 케어` and `스킨-케어` are one word written three ways, and
/// which of them a reader typed, or a model happened to emit, is not a decision
/// about meaning. Case, whitespace and every separator the alphabet allows are
/// dropped; what is left is the word itself.
///
/// This is deliberately all the key does. `카페` and `커피숍` mean the same thing
/// and have different keys, because deciding that takes judgement, and judgement
/// is what the librarian pass and the reader are for.
///
/// Mirrors `lib/domain/tag_key.dart`, which the app and the eval tool use. The
/// Dart side skips NFKC because it only ever keys strings that passed tag
/// validation, and those are already NFKC-normalised; doing it here as well
/// makes the key safe on raw input too. Separators are dropped before
/// normalising as well as after: NFKC turns ㆍ (U+318D) into a conjoining jamo
/// that is neither a separator nor a letter, and would otherwise survive.
export function tagKey(value) {
  return value
    .replace(DROPPED, "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(DROPPED, "");
}

/// The one shape a tag value has anywhere in the system: NFKC, trimmed, inner
/// whitespace collapsed to one space, 2-20 characters in the tag alphabet.
/// Returns null for anything else so callers decide whether that is a rejected
/// request, a dropped label, or a broken model answer.
export function normalizeTagValue(value) {
  if (typeof value !== "string") return null;
  const normalized = value.normalize("NFKC").trim().replace(/\s+/gu, " ");
  const length = Array.from(normalized).length;
  if (
    length < TAG_MIN_LENGTH ||
    length > TAG_MAX_LENGTH ||
    !TAG_PATTERN.test(normalized)
  ) {
    return null;
  }
  return normalized;
}
