/// The model that reads screenshots. Not swappable on a whim: the client
/// validates this string, and the analysis path sends images.
export const MODEL = "gpt-5.6-luna";

/// The place lookup can run on a different provider than the screenshot pass.
///
/// It needs three things — the Responses format, a server-side web_search tool,
/// and json_schema output — and no vision at all. DeepSeek's v4-flash documents
/// all three, so it is a candidate for the one pass whose quality we are still
/// measuring. The analysis path stays put: DeepSeek replaces `input_image` parts
/// with placeholder text *without erroring*, which would turn a screenshot into
/// confident nonsense rather than a visible failure.
export const DEEPSEEK_MODEL = "deepseek-v4-flash";

/// Its search loop runs long — 36 to 78 seconds measured across ten shops,
/// against 13 to 16 for the analysis model. The ceiling is generous because a
/// lookup that times out costs the same as one that answers, and the client
/// shows the capture without waiting for it either way.
export const DEEPSEEK_TIMEOUT_MS = 110_000;
export const DEEPSEEK_BASE_URL =
  process.env.DEEPSEEK_BASE_URL || "https://api.deepseek.com";
export const SCHEMA_VERSION = "2.1";

export const DEFAULT_MAX_IMAGE_BYTES = 12 * 1024 * 1024;
export const DEFAULT_MAX_BODY_BYTES = 17 * 1024 * 1024;
export const DEFAULT_BODY_TIMEOUT_MS = 10_000;
// Original-detail screenshots can legitimately take more than 40 seconds.
// Keep the nested limits ordered so a paid upstream request gets time to
// finish before the service and mobile client give up.
export const DEFAULT_OPENAI_TIMEOUT_MS = 75_000;
export const DEFAULT_ANALYSIS_TIMEOUT_MS = 80_000;
export const DEFAULT_UPSTREAM_TIMEOUT_MS = 40_000;
export const DEFAULT_MAX_UPSTREAM_BODY_BYTES = 2 * 1024 * 1024;

export const SUPPORTED_IMAGE_TYPES = Object.freeze([
  "image/jpeg",
  "image/png",
  "image/webp",
]);
