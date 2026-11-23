/// Base URL of the optional relay server: the tracker OAuth proxy (`/auth`), log
/// uploads (`/logs`) and Discord posters (`/posters`). Configured at build time
/// via `--dart-define=TTPLAY_RELAY_BASE_URL=...`.
const String ttplayServerBaseUrl = String.fromEnvironment('TTPLAY_RELAY_BASE_URL');
