import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../library/library_scan_service.dart';
import '../../library/library_scrape_runner.dart';
import '../../library/library_settings.dart';
import '../../library/local_library_client.dart';
import '../../library/scrapers/scraped_metadata.dart';
import '../../library/scrapers/scraper_http.dart';
import '../../library/scrapers/server_metadata_provider.dart';
import '../../library/scrapers/tmdb_provider.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../ttplay_admin/ttplay_admin_guard.dart';
import 'mounts_screen.dart';

/// Mode-aware scraper settings screen:
/// - Offline mode: edits standalone TMDB API key, mirrors, HTTP proxy, language,
///   and Bangumi preference stored locally in [LibrarySettingsStore].
/// - Sync mode: displays the read-only sync metadata service status & check.
class ScraperSettingsScreen extends StatefulWidget {
  const ScraperSettingsScreen({super.key});

  @override
  State<ScraperSettingsScreen> createState() => _ScraperSettingsScreenState();
}

class _ScraperSettingsScreenState extends State<ScraperSettingsScreen> {
  static const double _gap = 14;
  static const List<String> _languages = ['zh-CN', 'zh-TW', 'zh-HK', 'en-US', 'ja-JP', 'ko-KR'];

  final _apiKey = TextEditingController();
  final _apiBase = TextEditingController();
  final _imageBase = TextEditingController();
  final _proxy = TextEditingController();
  String _language = ScraperSettings.defaultLanguage;
  bool _bangumi = true;
  bool _loaded = false;
  bool _saving = false;
  ({bool ok, String message})? _testResult;
  bool _testing = false;

  String _endpointUrl = ServerMetadataProvider.defaultOfficialMetadataUrl;
  List<String> _enabledProviders = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final controller in [_apiKey, _apiBase, _imageBase, _proxy]) {
      controller.dispose();
    }
    super.dispose();
  }

  T? _maybeRead<T>() {
    try {
      return Provider.of<T>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final store = _maybeRead<LibrarySettingsStore>();
    final runner = _maybeRead<LibraryScrapeRunner>();

    final settings = store != null ? await store.loadScraper() : const ScraperSettings();
    var endpointUrl = ServerMetadataProvider.defaultOfficialMetadataUrl;
    if (runner != null) {
      final resolved = await runner.resolveActiveMetadataEndpoint();
      endpointUrl = resolved.serverUrl;
    }

    if (!mounted) return;
    setState(() {
      _apiKey.text = settings.tmdbApiKey;
      _apiBase.text = settings.tmdbApiBase.isEmpty ? TmdbProvider.defaultApiHost : settings.tmdbApiBase;
      _imageBase.text = settings.tmdbImageBase.isEmpty ? TmdbProvider.defaultImageHost : settings.tmdbImageBase;
      _proxy.text = settings.proxy;
      _language = settings.language;
      _bangumi = settings.bangumiEnabled;
      _endpointUrl = endpointUrl;
      _loaded = true;
    });
  }

  Future<void> _testLocalConnection() async {
    if (_testing) return;
    final key = _apiKey.text.trim();
    if (key.isEmpty) {
      setState(() => _testResult = (ok: false, message: t.storage.tmdbTestNoKey));
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final provider = TmdbProvider(
      apiKey: key,
      language: _language,
      apiBase: _apiBase.text,
      imageBase: _imageBase.text,
      http: ScraperHttp(proxy: _proxy.text),
    );
    ({bool ok, String message}) result;
    try {
      await provider.checkConnection();
      result = (ok: true, message: t.storage.tmdbTestOk);
    } on ScrapeException catch (e) {
      result = (ok: false, message: t.storage.tmdbTestFailed(message: e.message));
    } catch (e) {
      result = (ok: false, message: t.storage.tmdbTestFailed(message: '$e'));
    } finally {
      provider.close();
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  Future<void> _testServerConnection() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final runner = _maybeRead<LibraryScrapeRunner>();
    ({bool ok, String message}) result;
    var providers = _enabledProviders;
    try {
      final res = runner != null
          ? await runner.checkMetadataServerConnection()
          : (
              serverUrl: _endpointUrl,
              isOfficial: true,
              config: await ServerMetadataProvider.fetchConfig(serverUrl: _endpointUrl),
            );
      if (mounted) {
        setState(() {
          _endpointUrl = res.serverUrl;
        });
      }
      final cfg = res.config;
      providers = cfg.enabledProviders;
      if (cfg.tmdbConfigured) {
        result = (
          ok: true,
          message: t.storage.metadataServerTestOk(
            works: cfg.cachedWorks,
            seasons: cfg.cachedSeasons,
            people: cfg.cachedPeople,
          ),
        );
      } else {
        result = (ok: false, message: t.storage.metadataServerTestNoKey);
      }
    } on ScrapeException catch (e) {
      result = (ok: false, message: t.storage.tmdbTestFailed(message: e.message));
    } catch (e) {
      result = (ok: false, message: t.storage.tmdbTestFailed(message: '$e'));
    }

    if (mounted) {
      setState(() {
        _testing = false;
        _enabledProviders = providers;
        _testResult = result;
      });
    }
  }

  Future<void> _saveLocal() async {
    if (_saving) return;
    final store = _maybeRead<LibrarySettingsStore>();
    final scans = _maybeRead<LibraryScanService>();
    final localClient = _maybeRead<LocalLibraryClient>();
    final navigator = Navigator.of(context);

    setState(() => _saving = true);
    final saved = ScraperSettings(
      tmdbApiKey: _apiKey.text,
      tmdbApiBase: _apiBase.text,
      tmdbImageBase: _imageBase.text,
      language: _language,
      proxy: _proxy.text,
      bangumiEnabled: _bangumi,
    );
    if (store != null) {
      await store.saveScraper(saved);
    }
    if (localClient != null) {
      localClient.tmdbImageBase = TmdbProvider.normalizeBase(
        saved.tmdbImageBase,
        TmdbProvider.defaultImageBase,
        defaultPath: '/t/p',
      );
    }
    if (scans != null) {
      unawaited(scans.scrapeLibrary(retryUnmatched: true, restart: true));
    }
    if (mounted) navigator.pop();
  }

  Future<void> _pickLanguage() async {
    final picked = await showOptionPickerDialog<String>(
      context,
      title: t.storage.metadataLanguage,
      options: [
        for (final code in _languages)
          (icon: code == _language ? Symbols.check_rounded : null, label: code, value: code),
      ],
    );
    if (picked != null && mounted) setState(() => _language = picked);
  }

  InputDecoration _decoration(String label, {String? hint, String? helper}) => InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    helperMaxLines: 3,
    border: const OutlineInputBorder(),
  );

  @override
  Widget build(BuildContext context) {
    final isSelfHosted = maybeWatchAppSession(context)?.isSelfHosted == true;
    return isSelfHosted ? _buildSyncServerView(context) : _buildOfflineLocalView(context);
  }

  Widget _buildOfflineLocalView(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.storage.scraperSettings)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _apiKey,
                      autofocus: PlatformDetector.isTV(),
                      decoration: _decoration(t.storage.tmdbKey, helper: t.storage.tmdbKeyHelp),
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                    const SizedBox(height: _gap),
                    FocusableListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: false,
                      leading: const AppIcon(Symbols.translate_rounded),
                      title: Text(t.storage.metadataLanguage),
                      subtitle: Text(_language),
                      trailing: const AppIcon(Symbols.chevron_right_rounded),
                      onTap: _pickLanguage,
                    ),
                    FocusableSwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: false,
                      title: Text(t.storage.bangumiForAnime),
                      subtitle: Text(t.storage.bangumiForAnimeHelp),
                      value: _bangumi,
                      onChanged: (value) => setState(() => _bangumi = value),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 20, bottom: 12),
                      child: Text(
                        t.storage.sectionAdvanced,
                        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ),
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _proxy,
                      decoration: _decoration(
                        t.storage.metadataProxy,
                        hint: '127.0.0.1:7890',
                        helper: t.storage.metadataProxyHelp,
                      ),
                      autocorrect: false,
                    ),
                    const SizedBox(height: _gap),
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _apiBase,
                      decoration: _decoration(t.storage.tmdbApiBase, hint: TmdbProvider.defaultApiHost),
                      autocorrect: false,
                    ),
                    const SizedBox(height: _gap),
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _imageBase,
                      decoration: _decoration(t.storage.tmdbImageBase, hint: TmdbProvider.defaultImageHost),
                      autocorrect: false,
                    ),
                    const SizedBox(height: _gap),
                    Row(
                      children: [
                        FocusableButton(
                          onPressed: _testing ? null : _testLocalConnection,
                          child: OutlinedButton.icon(
                            onPressed: _testing ? null : _testLocalConnection,
                            icon: _testing
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const AppIcon(Symbols.network_check_rounded),
                            label: Text(t.storage.tmdbTest),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (_testResult case final result?)
                          Expanded(
                            child: Text(
                              result.message,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: result.ok ? theme.colorScheme.primary : theme.colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FocusableButton(
                useBackgroundFocus: true,
                onPressed: _saving || !_loaded ? null : _saveLocal,
                child: FilledButton(
                  onPressed: _saving || !_loaded ? null : _saveLocal,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  child: Text(t.common.save),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSyncServerView(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.storage.scraperSettings)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                AppIcon(Symbols.cloud_done_rounded, size: 22, color: colorScheme.primary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    t.storage.metadataServiceTitle,
                                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              t.storage.metadataServiceSelfHosted,
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                            ),
                            if (_endpointUrl.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                _endpointUrl,
                                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                              ),
                            ],
                            if (_enabledProviders.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final p in _enabledProviders)
                                    Chip(label: Text(p.toUpperCase()), visualDensity: VisualDensity.compact),
                                ],
                              ),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              t.storage.metadataServiceManagedHint,
                              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 12),
                            FocusableButton(
                              onPressed: _testing ? null : _testServerConnection,
                              child: OutlinedButton.icon(
                                onPressed: _testing ? null : _testServerConnection,
                                icon: _testing
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const AppIcon(Symbols.network_check_rounded, size: 18),
                                label: Text(t.storage.metadataServerTest),
                              ),
                            ),
                            if (_testResult case final result?) ...[
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: result.ok ? colorScheme.primaryContainer : colorScheme.errorContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: [
                                    AppIcon(
                                      result.ok ? Symbols.check_circle_rounded : Symbols.error_outline_rounded,
                                      size: 18,
                                      color: result.ok
                                          ? colorScheme.onPrimaryContainer
                                          : colorScheme.onErrorContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        result.message,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: result.ok
                                              ? colorScheme.onPrimaryContainer
                                              : colorScheme.onErrorContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
