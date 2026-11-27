import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library_cloud/cloud_api_client.dart';
import 'package:ttplay/library_cloud/cloud_keyring.dart';
import 'package:ttplay/library_cloud/cloud_mount_mirror.dart';
import 'package:ttplay/library_cloud/cloud_projection_engine.dart';
import 'package:ttplay/library_cloud/projection_sync.dart';
import 'package:ttplay/library_cloud/scan_session_runner.dart';
import 'package:ttplay/library_cloud/source_repository.dart';
import 'package:ttplay/media/work_identity.dart';
import 'package:ttplay/models/sync_config_entry.dart';
import 'package:ttplay/services/sync_config_store.dart';
import 'package:ttplay/services/work_skip_settings_store.dart';
import 'package:ttplay/storage/mount_registry.dart';
import 'package:ttplay/storage/storage_driver.dart';
import 'package:ttplay/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'CloudMountMirror + CloudProjectionEngine projects cloud snapshot, preserves local mounts, and prunes empty shells',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);

      // Seed a local-folder mount that MUST remain untouched by cloud projection.
      await mountRegistry.upsert(
        const StorageMount(
          id: 'local_1',
          kind: StorageKind.local,
          displayName: 'Local Disk',
          config: {MountKeys.rootPath: 'D:/Movies'},
        ),
      );

      final hk = CloudKeyring.generateMasterKey();
      final webdavCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {'base_url': 'https://nas.example/dav', 'username': 'alice', 'password': 'pw123', 'root_path': '/'},
      );

      var includeMovieFile = true;
      var serverSeq = 10;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_dav',
                  'kind': 'webdav',
                  'name': 'Home WebDAV',
                  'identity_key': 'hmac_1',
                  'status': 'active',
                  'folders': [
                    {'id': 'f1', 'source_id': 'src_dav', 'path': '/Movies'},
                  ],
                },
              ],
            }),
          );
          await req.response.close();
          return;
        }

        if (req.method == 'GET' && path == '/api/v1/sources/src_dav/credential') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {
                'source_id': 'src_dav',
                'ciphertext': webdavCipher,
                'version': 1,
                'key_epoch': 1,
                'status': 'valid',
              },
            }),
          );
          await req.response.close();
          return;
        }

        if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          final kind = req.uri.queryParameters['kind'];
          final items = <Map<String, dynamic>>[];
          if (kind == 'movie' && includeMovieFile) {
            items.add({
              'id': 100,
              'work_key': 'tmdb:movie:27205',
              'kind': 'movie',
              'library_type': 'movie',
              'title': 'Inception',
              'sort_title': 'inception',
              'year': 2010,
              'added_at': 1700000000000,
              'updated_at': 1700000000000,
            });
          }
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': serverSeq,
              'total': items.length,
              'page': 1,
              'page_size': 100,
              'has_more': false,
              'items': items,
            }),
          );
          await req.response.close();
          return;
        }

        if (req.method == 'GET' && path == '/api/v1/items/100') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'item': {
                'id': 100,
                'files': includeMovieFile
                    ? [
                        {
                          'id': 500,
                          'source_id': 'src_dav',
                          'path': '/Movies/Inception.2010.mkv',
                          'size': 2048,
                          'role': 'video',
                        },
                      ]
                    : <Map<String, dynamic>>[],
              },
            }),
          );
          await req.response.close();
          return;
        }

        if (req.method == 'GET' && path == '/api/v1/library/changes') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'reset_required': true,
              'latest_seq': serverSeq,
              'min_retained_seq': serverSeq,
              'next_since_seq': serverSeq,
              'has_more': false,
              'changes': <Map<String, dynamic>>[],
            }),
          );
          await req.response.close();
          return;
        }

        if (req.method == 'GET' && path == '/api/v1/progress') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {'work_key': 'tmdb:movie:27205', 'position_ms': 95000, 'watched': false, 'play_count': 0},
              ],
            }),
          );
          await req.response.close();
          return;
        }

        if (req.method == 'GET' && path == '/api/v1/favorites') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {'work_key': 'tmdb:movie:27205'},
              ],
            }),
          );
          await req.response.close();
          return;
        }

        req.response.statusCode = 404;
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_proj');
      addTearDown(api.close);

      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
      final mirror = CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry);
      final syncClient = CloudProjectionSyncClient(api);
      final engine = CloudProjectionEngine(db: db, syncClient: syncClient, mountMirror: mirror);

      // 1. Full snapshot projects movie, mirrored cloud mount, and user state
      final res1 = await engine.syncFullSnapshot();
      expect(res1.fullReset, isTrue);
      expect(res1.latestSeq, 10);
      expect(res1.itemsProjected, 1);
      expect(res1.filesProjected, 1);

      final mounts = await mountRegistry.list();
      expect(mounts.map((m) => m.id), containsAll(['local_1', 'cloud:src_dav']));
      final mirrored = mounts.firstWhere((m) => m.id == 'cloud:src_dav');
      expect(mirrored.secrets[MountKeys.secretPassword], 'pw123');

      final items1 = await db.select(db.libraryItems).get();
      expect(items1.length, 1);
      expect(items1.single.title, 'Inception');

      final userStates = await db.select(db.libraryUserStates).get();
      expect(userStates.length, 1);
      expect(userStates.single.positionMs, 95000);
      expect(userStates.single.favorite, isTrue);

      // 2. Movie removed on server -> incremental sync hits reset_required -> empty shell pruned
      includeMovieFile = false;
      serverSeq = 12;
      final res2 = await engine.syncIncremental();
      expect(res2.fullReset, isTrue);
      expect(res2.latestSeq, 12);
      expect(res2.emptyShellsPruned, 1);

      final items2 = await db.select(db.libraryItems).get();
      expect(items2, isEmpty);

      // Local mount was preserved
      final localMount = await mountRegistry.get('local_1');
      expect(localMount, isNotNull);

      // 3. Server emits media_file / source_folder delta changes -> triggers full snapshot & sync-state notifications
      includeMovieFile = true;
      serverSeq = 15;
      final syncStates = <bool>[];
      final engine2 = CloudProjectionEngine(
        db: db,
        syncClient: syncClient,
        mountMirror: mirror,
        onSyncStateChanged: syncStates.add,
      );
      addTearDown(engine2.stopListeningEvents);

      // First snapshot puts lastSeq = 15, then verify media_file change at seq 15 triggers resync
      final initialRes = await engine2.syncFullSnapshot();
      expect(initialRes.latestSeq, 15);
      expect(syncStates, [true, false]);

      // Mock /changes: phase 1 returns media_file upsert (no full snapshot reset);
      // phase 2 returns source_folder upsert (triggers full snapshot fallback).
      final deltaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => deltaServer.close(force: true));
      var deltaSnapshotPasses = 0;
      var deltaChangesPhase = 1;
      deltaServer.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(jsonEncode({'code': 0, 'sources': <Map<String, dynamic>>[]}));
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          if (req.uri.queryParameters['kind'] == 'movie') {
            deltaSnapshotPasses++;
          }
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': deltaSnapshotPasses == 1 ? 10 : 14,
              'total': 0,
              'page': 1,
              'page_size': 100,
              'has_more': false,
              'items': <Map<String, dynamic>>[],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
          if (deltaChangesPhase == 1) {
            req.response.write(
              jsonEncode({
                'code': 0,
                'reset_required': false,
                'latest_seq': 12,
                'min_retained_seq': 1,
                'next_since_seq': 12,
                'has_more': false,
                'changes': [
                  {'seq': 11, 'entity': 'media_file', 'entity_id': '1', 'op': 'upsert'},
                ],
              }),
            );
          } else {
            req.response.write(
              jsonEncode({
                'code': 0,
                'reset_required': false,
                'latest_seq': 14,
                'min_retained_seq': 1,
                'next_since_seq': 14,
                'has_more': false,
                'changes': [
                  {'seq': 13, 'entity': 'source_folder', 'entity_id': 'f1', 'op': 'upsert'},
                ],
              }),
            );
          }
        } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final deltaApi = CloudApiClient(baseUrl: 'http://127.0.0.1:${deltaServer.port}', accessToken: 'usr_d');
      addTearDown(deltaApi.close);
      final deltaRepo = CloudSourceRepository(api: deltaApi, masterKeyProvider: () => hk);
      final deltaEngine = CloudProjectionEngine(
        db: db,
        syncClient: CloudProjectionSyncClient(deltaApi),
        mountMirror: CloudMountMirror(sourceRepository: deltaRepo, mountRegistry: mountRegistry),
      );
      addTearDown(deltaEngine.stopListeningEvents);
      await deltaEngine.syncFullSnapshot();
      expect(deltaSnapshotPasses, 1);

      // Phase 1: pending media_file upsert advances seq without triggering full snapshot
      final mfRes = await deltaEngine.syncIncremental();
      expect(mfRes.fullReset, isFalse);
      expect(mfRes.hasChanges, isFalse);
      expect(mfRes.latestSeq, 12);
      expect(deltaSnapshotPasses, 1);

      // Phase 2: structural source_folder change triggers full snapshot fallback
      deltaChangesPhase = 2;
      final deltaRes = await deltaEngine.syncIncremental();
      expect(deltaRes.fullReset, isTrue);
      expect(deltaSnapshotPasses, 2);
    },
  );

  test(
    'CloudProjectionEngine projects movie + show/season/episode with inline files, subtitles, and episode progress without item-detail N+1 calls',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);

      final hk = CloudKeyring.generateMasterKey();
      final quarkCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {'cookie': 'uid=u123; pus=abc', 'root_id': '0'},
      );

      var itemDetailCalls = 0;
      String? seenIncludeFilesParam;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_qk',
                  'kind': 'quark',
                  'name': 'My Quark',
                  'identity_key': 'quark:u123',
                  'status': 'active',
                  'folders': [
                    {'id': 'f1', 'source_id': 'src_qk', 'path': '/Media'},
                  ],
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/sources/src_qk/credential') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {
                'source_id': 'src_qk',
                'ciphertext': quarkCipher,
                'version': 1,
                'key_epoch': 1,
                'status': 'valid',
              },
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          seenIncludeFilesParam = req.uri.queryParameters['include_files'];
          final kind = req.uri.queryParameters['kind'];
          final items = switch (kind) {
            'movie' => [
              {
                'id': 10,
                'work_key': 'tmdb:movie:27205',
                'kind': 'movie',
                'library_type': 'movie',
                'title': 'Inception',
                'sort_title': 'inception',
                'year': 2010,
                'tmdb_id': '27205',
                'imdb_id': 'tt1375666',
                'poster_url': '/api/v1/metadata/artwork?src=%2Fp.jpg',
                'added_at': 1700000000000,
                'source_added_at': 1699999000000,
                'updated_at': 1700000005000,
                'files': [
                  {
                    'id': 101,
                    'source_id': 'src_qk',
                    'path': '/Media/Inception.mkv',
                    'remote_id': 'fid_m1',
                    'size': 4096,
                    'mtime_s': 1700000001,
                    'subtitles': [
                      {
                        'id': 201,
                        'source_id': 'src_qk',
                        'path': '/Media/Inception.zh.srt',
                        'remote_id': 'fid_ms1',
                        'language': 'zh',
                        'size': 512,
                      },
                    ],
                  },
                ],
              },
            ],
            'show' => [
              {
                'id': 20,
                'work_key': 'tmdb:show:100',
                'kind': 'show',
                'library_type': 'anime',
                'title': 'Sample Anime',
                'sort_title': 'sample anime',
                'year': 2024,
                'tmdb_id': '100',
                'added_at': 1700000000000,
                'source_added_at': 1699998000000,
                'updated_at': 1700000006000,
              },
            ],
            'season' => [
              {
                'id': 30,
                'work_key': '',
                'kind': 'season',
                'library_type': 'anime',
                'parent_id': 20,
                'show_id': 20,
                'title': 'Season 1',
                'sort_title': 'season 1',
                'season_number': 1,
                'added_at': 1700000000000,
                'updated_at': 1700000006000,
              },
            ],
            'episode' => [
              {
                'id': 40,
                'work_key': '',
                'kind': 'episode',
                'library_type': 'anime',
                'parent_id': 30,
                'show_id': 20,
                'title': 'Episode 2',
                'sort_title': 'episode 2',
                'season_number': 1,
                'episode_number': 2,
                'added_at': 1700000000000,
                'updated_at': 1700000006000,
                'files': [
                  {
                    'id': 102,
                    'source_id': 'src_qk',
                    'path': '/Media/Anime/S01E02.mkv',
                    'remote_id': 'fid_ep2',
                    'size': 8192,
                    'mtime_s': 1700000002,
                    'subtitles': [
                      {
                        'id': 202,
                        'source_id': 'src_qk',
                        'path': '/Media/Anime/S01E02.zh.srt',
                        'remote_id': 'fid_eps2',
                        'language': 'zh',
                        'size': 256,
                      },
                    ],
                  },
                ],
              },
            ],
            _ => <Map<String, dynamic>>[],
          };
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': 42,
              'total': items.length,
              'page': 1,
              'page_size': 200,
              'has_more': false,
              'items': items,
            }),
          );
        } else if (req.method == 'GET' && path.startsWith('/api/v1/items/')) {
          itemDetailCalls++;
          req.response.statusCode = 404;
        } else if (req.method == 'GET' && path == '/api/v1/progress') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {
                  'progress_key': 'tmdb:show:100:s1:e2',
                  'work_key': 'tmdb:show:100',
                  'season_number': 1,
                  'episode_number': 2,
                  'position_ms': 123000,
                  'duration_ms': 1440000,
                  'watched': false,
                  'play_count': 1,
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/favorites') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {'work_key': 'tmdb:show:100'},
              ],
            }),
          );
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_hier');
      addTearDown(api.close);

      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
      final mirror = CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry);
      final engine = CloudProjectionEngine(db: db, syncClient: CloudProjectionSyncClient(api), mountMirror: mirror);

      final res = await engine.syncFullSnapshot();
      expect(seenIncludeFilesParam, '1');
      expect(itemDetailCalls, 0);
      expect(res.latestSeq, 42);
      expect(res.itemsProjected, 4);
      expect(res.filesProjected, 4); // 2 videos + 2 subtitles
      expect(res.emptyShellsPruned, 0);

      final items = await db.select(db.libraryItems).get();
      expect(items.length, 4);
      final movieRow = items.firstWhere((e) => e.kind == LibraryKinds.movie);
      final showRow = items.firstWhere((e) => e.kind == LibraryKinds.show);
      final seasonRow = items.firstWhere((e) => e.kind == LibraryKinds.season);
      final epRow = items.firstWhere((e) => e.kind == LibraryKinds.episode);

      expect(movieRow.tmdbId, '27205');
      expect(movieRow.metadataSource, 'tmdb');
      expect(movieRow.sourceAddedAt, 1699999000000);
      expect(showRow.libraryType, LibraryTypes.anime);
      expect(seasonRow.parentId, showRow.id);
      expect(seasonRow.showId, showRow.id);
      expect(seasonRow.workKey, 'tmdb:show:100:s1');
      expect(epRow.parentId, seasonRow.id);
      expect(epRow.showId, showRow.id);
      expect(epRow.workKey, 'tmdb:show:100:s1:e2');

      final files = await db.select(db.libraryFiles).get();
      expect(files.length, 4);
      final epVideo = files.firstWhere((f) => f.role == LibraryFileRoles.video && f.itemId == epRow.id);
      expect(epVideo.remoteId, 'fid_ep2');
      expect(epVideo.modifiedAt, 1700000002000);

      final epSub = files.firstWhere((f) => f.role == LibraryFileRoles.subtitle && f.ownerFileId == epVideo.id);
      expect(epSub.itemId, isNull);
      expect(epSub.language, 'zh');
      expect(epSub.path, '/Media/Anime/S01E02.zh.srt');

      final states = await db.select(db.libraryUserStates).get();
      final epState = states.firstWhere((s) => s.itemId == epRow.id);
      expect(epState.positionMs, 123000);
      expect(epState.durationMs, 1440000);
      expect(epState.favorite, isFalse);

      final showState = states.firstWhere((s) => s.itemId == showRow.id);
      expect(showState.favorite, isTrue);
    },
  );

  test(
    'CloudProjectionEngine.syncIncremental emits onSyncStateChanged and hasChanges=false when no server changes',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);
      final hk = CloudKeyring.generateMasterKey();

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(jsonEncode({'code': 0, 'sources': <Map<String, dynamic>>[]}));
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': 50,
              'total': 0,
              'page': 1,
              'page_size': 200,
              'has_more': false,
              'items': <Map<String, dynamic>>[],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'reset_required': false,
              'latest_seq': 50,
              'min_retained_seq': 1,
              'next_since_seq': 50,
              'has_more': false,
              'changes': <Map<String, dynamic>>[],
            }),
          );
        } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_empty');
      addTearDown(api.close);
      final syncStates = <bool>[];
      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
      final engine = CloudProjectionEngine(
        db: db,
        syncClient: CloudProjectionSyncClient(api),
        mountMirror: CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry),
        onSyncStateChanged: syncStates.add,
      );
      addTearDown(engine.stopListeningEvents);

      await engine.syncFullSnapshot();
      syncStates.clear();

      final res = await engine.syncIncremental();
      expect(syncStates, [true, false]);
      expect(res.hasChanges, isFalse);
      expect(res.fullReset, isFalse);
    },
  );

  test(
    'CloudProjectionEngine.syncIncremental projects item+files delta in place and hydrateItemDetailFromCloud pulls details',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);
      final hk = CloudKeyring.generateMasterKey();
      final qkCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {'cookie': 'uid=u1', 'root_id': '0'},
      );

      var snapshotMovieCalls = 0;
      var byWorkKeyCalls = 0;
      String? changesIncludeFiles;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_qk',
                  'kind': 'quark',
                  'name': 'Quark',
                  'identity_key': 'qk_1',
                  'status': 'active',
                  'folders': [
                    {'id': 'f1', 'source_id': 'src_qk', 'path': '/TV'},
                  ],
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/sources/src_qk/credential') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {
                'source_id': 'src_qk',
                'ciphertext': qkCipher,
                'version': 1,
                'key_epoch': 1,
                'status': 'valid',
              },
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          final kind = req.uri.queryParameters['kind'];
          if (kind == 'movie') snapshotMovieCalls++;
          final items = switch (kind) {
            'show' => [
              {
                'id': 20,
                'work_key': 'tmdb:show:279155',
                'kind': 'show',
                'library_type': 'show',
                'title': '谷雨',
                'sort_title': 'gu yu',
                'added_at': 1000,
                'source_added_at': 1000,
                'updated_at': 1000,
              },
            ],
            'season' => [
              {
                'id': 30,
                'kind': 'season',
                'library_type': 'show',
                'parent_id': 20,
                'show_id': 20,
                'title': '第 1 季',
                'season_number': 1,
                'added_at': 1000,
                'updated_at': 1000,
              },
            ],
            'episode' => [
              {
                'id': 40,
                'kind': 'episode',
                'library_type': 'show',
                'parent_id': 30,
                'show_id': 20,
                'title': '第 1 集',
                'season_number': 1,
                'episode_number': 1,
                'added_at': 1000,
                'updated_at': 1000,
                'files': [
                  {
                    'id': 501,
                    'source_id': 'src_qk',
                    'path': '/TV/GuYu/S01E01.mkv',
                    'remote_id': 'rk_e1',
                    'mtime_s': 1000,
                  },
                ],
              },
            ],
            _ => <Map<String, dynamic>>[],
          };
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': 10,
              'total': items.length,
              'page': 1,
              'page_size': 200,
              'has_more': false,
              'items': items,
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
          changesIncludeFiles = req.uri.queryParameters['include_files'];
          req.response.write(
            jsonEncode({
              'code': 0,
              'reset_required': false,
              'latest_seq': 15,
              'min_retained_seq': 1,
              'next_since_seq': 15,
              'has_more': false,
              'changes': [
                {
                  'seq': 12,
                  'entity': 'item',
                  'entity_id': '20',
                  'op': 'upsert',
                  'data': {
                    'id': 20,
                    'work_key': 'tmdb:show:279155',
                    'kind': 'show',
                    'library_type': 'show',
                    'title': '谷雨',
                    'sort_title': 'gu yu',
                    'added_at': 1000,
                    'source_added_at': 5000000,
                    'updated_at': 5000000,
                  },
                },
                {
                  'seq': 15,
                  'entity': 'item',
                  'entity_id': '41',
                  'op': 'upsert',
                  'data': {
                    'id': 41,
                    'kind': 'episode',
                    'library_type': 'show',
                    'parent_id': 30,
                    'show_id': 20,
                    'show_work_key': 'tmdb:show:279155',
                    'title': '第 2 集',
                    'season_number': 1,
                    'episode_number': 2,
                    'added_at': 5000000,
                    'updated_at': 5000000,
                    'files': [
                      {
                        'id': 502,
                        'source_id': 'src_qk',
                        'path': '/TV/GuYu/S01E02.mkv',
                        'remote_id': 'rk_e2',
                        'mtime_s': 5000,
                        'subtitles': [
                          {
                            'id': 602,
                            'source_id': 'src_qk',
                            'path': '/TV/GuYu/S01E02.zh.srt',
                            'remote_id': 'rk_s2',
                            'language': 'zh',
                          },
                        ],
                      },
                    ],
                  },
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/items/by-work-key') {
          byWorkKeyCalls++;
          req.response.write(
            jsonEncode({
              'code': 0,
              'item': {
                'id': 20,
                'work_key': 'tmdb:show:279155',
                'kind': 'show',
                'library_type': 'show',
                'title': '谷雨',
                'sort_title': 'gu yu',
                'summary': 'Detailed summary',
                'tagline': 'Rain of Grain',
                'studio': 'Tencent',
                'genres': ['剧情', '悬疑'],
                'credits': [
                  {
                    'person_id': 1,
                    'name': '张颂文',
                    'job': 'actor',
                    'character': '主角',
                    'photo_url': '/api/v1/metadata/artwork?src=%2Factor.jpg',
                  },
                ],
                'children': [
                  {
                    'id': 30,
                    'work_key': 'tmdb:show:279155',
                    'kind': 'season',
                    'library_type': 'show',
                    'parent_id': 20,
                    'show_id': 20,
                    'show_work_key': 'tmdb:show:279155',
                    'title': '第 1 季',
                    'season_number': 1,
                    'added_at': 1000,
                    'updated_at': 1000,
                  },
                ],
                'episodes': [],
              },
            }),
          );
        } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_inc');
      addTearDown(api.close);
      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
      final engine = CloudProjectionEngine(
        db: db,
        syncClient: CloudProjectionSyncClient(api),
        mountMirror: CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry),
      );
      addTearDown(engine.stopListeningEvents);

      await engine.syncFullSnapshot();
      expect(snapshotMovieCalls, 1);

      final incRes = await engine.syncIncremental();
      expect(changesIncludeFiles, '1');
      expect(snapshotMovieCalls, 1); // zero extra full snapshots
      expect(incRes.fullReset, isFalse);
      expect(incRes.hasChanges, isTrue);
      expect(incRes.itemsProjected, 2);
      expect(incRes.filesProjected, 2); // 1 video + 1 subtitle

      final showRow = await (db.select(db.libraryItems)..where((t) => t.kind.equals('show'))).getSingle();
      expect(showRow.sourceAddedAt, 5000000);
      final eps = await (db.select(db.libraryItems)..where((t) => t.kind.equals('episode'))).get();
      expect(eps.length, 2);
      final ep2 = eps.firstWhere((e) => e.episodeNumber == 2);
      expect(ep2.workKey, 'tmdb:show:279155:s1:e2');

      final hydrated = await engine.hydrateItemDetailFromCloud(showRow.id, showRow.workKey!);
      expect(hydrated, isTrue);
      expect(byWorkKeyCalls, 1);

      final libRepo = LibraryRepository(db);
      final hydratedShow = (await libRepo.getItem(showRow.id))!.item;
      expect(hydratedShow.kind, LibraryKinds.show);
      expect(hydratedShow.parentId, isNull);
      expect(hydratedShow.title, '谷雨');
      expect(hydratedShow.summary, 'Detailed summary');
      expect(hydratedShow.tagline, 'Rain of Grain');
      expect(hydratedShow.studio, 'Tencent');
      final hydratedSeason = await (db.select(
        db.libraryItems,
      )..where((t) => t.kind.equals(LibraryKinds.season))).getSingle();
      expect(hydratedSeason.workKey, 'tmdb:show:279155:s1');
      expect(hydratedSeason.parentId, showRow.id);
      expect((await libRepo.genresOf(showRow.id)).map((g) => g.name), containsAll(['剧情', '悬疑']));
      final credits = await libRepo.creditsOf(showRow.id);
      expect(credits.single.person.name, '张颂文');
      expect(credits.single.person.photoSource, '/api/v1/metadata/artwork?src=%2Factor.jpg');
    },
  );

  test(
    'CloudScanSessionRunner.runQuarkIncrementalScan skips ancestry, dir list, and server session when known files unchanged',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      var scanSessionCalls = 0;
      var ancestryCalls = 0;
      var driverListCalls = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        if (req.method == 'POST' && req.uri.path.endsWith('/scan-sessions')) {
          scanSessionCalls++;
          req.response.write(
            jsonEncode({
              'code': 0,
              'session': {
                'id': 'sess_1',
                'incremental_watermark': 2000000,
                'folders': [
                  {'id': 'f1', 'path': '/TV', 'exclude_paths': <String>[]},
                ],
              },
            }),
          );
        } else if (req.method == 'POST' && req.uri.path.endsWith('/batches')) {
          req.response.write(
            jsonEncode({
              'code': 0,
              'receipt': {'added': 1, 'changed': 0, 'removed': 0},
            }),
          );
        } else if (req.method == 'POST' && req.uri.path.endsWith('/complete')) {
          req.response.write(jsonEncode({'code': 0}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_inc_scan');
      addTearDown(api.close);
      final runner = CloudScanSessionRunner(api: api);
      addTearDown(runner.dispose);

      final fakeDriver = _FakeQuarkIncrementalDriver(onList: () => driverListCalls++);

      // 1. Unchanged file within overlap window -> 0 session calls, 0 ancestry calls, 0 list calls
      final noopProg = await runner.runQuarkIncrementalScan(
        sourceId: 'src_qk',
        driver: fakeDriver,
        knownServerWatermark: 2000000,
        knownFileMtimesByRemoteId: const {'rk_1': 2000000},
        rootFolderIdOverride: '0',
        folderAncestryOverride: (id) async {
          ancestryCalls++;
          return [(id: '0', name: 'root'), (id: 'd1', name: 'TV')];
        },
        searchUpdatedPageOverride: (page, {size = 50}) async => [
          (
            entry: StorageEntry(id: 'rk_1', path: '/S01E01.mkv', name: 'S01E01.mkv', isDirectory: false),
            parentId: 'd1',
            updatedAt: 2000000,
          ),
        ],
      );
      expect(noopProg.completed, isTrue);
      expect(noopProg.filesReported, 0);
      expect(scanSessionCalls, 0);
      expect(ancestryCalls, 0);
      expect(driverListCalls, 0);

      // 2. New file with newer updatedAt -> opens session, resolves ancestry, lists dir, uploads batch
      final dirtyProg = await runner.runQuarkIncrementalScan(
        sourceId: 'src_qk',
        driver: fakeDriver,
        knownServerWatermark: 2000000,
        knownFileMtimesByRemoteId: const {'rk_1': 2000000},
        rootFolderIdOverride: '0',
        folderAncestryOverride: (id) async {
          ancestryCalls++;
          return [(id: '0', name: 'root'), (id: 'd1', name: 'TV')];
        },
        searchUpdatedPageOverride: (page, {size = 50}) async => [
          (
            entry: StorageEntry(id: 'rk_2', path: '/S01E02.mkv', name: 'S01E02.mkv', isDirectory: false),
            parentId: 'd1',
            updatedAt: 2500000,
          ),
        ],
      );
      expect(dirtyProg.completed, isTrue);
      expect(dirtyProg.filesReported, 1);
      expect(scanSessionCalls, 1);
      expect(ancestryCalls, 1);
      expect(driverListCalls, 1);
    },
  );

  test(
    'CloudProjectionEngine projects unmatched and pending cloud files into pending shelf and prunes them once matched or ignored',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);

      final hk = CloudKeyring.generateMasterKey();
      final webdavCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {
          'base_url': 'http://localhost:8085',
          'username': 'testuser',
          'password': 'testpass123',
          'root_path': '/',
        },
      );

      var phase = 1;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_dav',
                  'kind': 'webdav',
                  'name': 'Local WebDAV',
                  'identity_key': 'hmac_dav',
                  'status': 'active',
                  'folders': [
                    {'id': 'f1', 'source_id': 'src_dav', 'path': '/'},
                  ],
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/sources/src_dav/credential') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {
                'source_id': 'src_dav',
                'ciphertext': webdavCipher,
                'version': 1,
                'key_epoch': 1,
                'status': 'valid',
              },
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          final kind = req.uri.queryParameters['kind'];
          final items = <Map<String, dynamic>>[];
          if (phase == 2 && kind == 'movie') {
            items.add({
              'id': 300,
              'work_key': 'tmdb:movie:999',
              'kind': 'movie',
              'library_type': 'movie',
              'title': 'Sample Movie',
              'sort_title': 'sample movie',
              'year': 2024,
              'added_at': 1700000000000,
              'updated_at': 1700000001000,
              'files': [
                {
                  'id': 101,
                  'source_id': 'src_dav',
                  'path': '/Movies/Sample Movie (2024)/Sample Movie (2024).mkv',
                  'size': 2048,
                  'role': 'video',
                },
              ],
            });
          }
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': phase == 1 ? 10 : 12,
              'total': items.length,
              'page': 1,
              'page_size': 200,
              'has_more': false,
              'items': items,
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/unmatched') {
          final unmatchedItems = phase == 1
              ? [
                  {
                    'id': 101,
                    'source_id': 'src_dav',
                    'source_name': 'Local WebDAV',
                    'path': '/Movies/Sample Movie (2024)/Sample Movie (2024).mkv',
                    'size': 2048,
                    'match_state': 'unmatched',
                    'parsed': {'year': 2024},
                    'added_at': 1700000000000,
                    'updated_at': 1700000000000,
                  },
                  {
                    'id': 102,
                    'source_id': 'src_dav',
                    'source_name': 'Local WebDAV',
                    'path': '/Movies/测试电影 (2025)/测试电影 (2025).mp4',
                    'size': 1024,
                    'match_state': 'pending',
                    'added_at': 1700000000000,
                    'updated_at': 1700000000000,
                  },
                  {
                    'id': 103,
                    'source_id': 'src_dav',
                    'source_name': 'Local WebDAV',
                    'path': '/Movies/Ignored.mkv',
                    'size': 512,
                    'match_state': 'ignored',
                    'added_at': 1700000000000,
                    'updated_at': 1700000000000,
                  },
                ]
              : [
                  {
                    'id': 101, // Even if still echoed briefly, matched file must be skipped!
                    'source_id': 'src_dav',
                    'source_name': 'Local WebDAV',
                    'path': '/Movies/Sample Movie (2024)/Sample Movie (2024).mkv',
                    'size': 2048,
                    'match_state': 'unmatched',
                    'added_at': 1700000000000,
                    'updated_at': 1700000000000,
                  },
                  {
                    'id': 104,
                    'source_id': 'src_dav',
                    'source_name': 'Local WebDAV',
                    'path': '/TV/New Unknown.mkv',
                    'size': 4096,
                    'match_state': 'unmatched',
                    'added_at': 1700000002000,
                    'updated_at': 1700000002000,
                  },
                ];
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': unmatchedItems,
              'total': unmatchedItems.length,
              'page': 1,
              'page_size': 200,
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'code': 0,
              'latest_seq': 12,
              'next_since_seq': 12,
              'has_more': false,
              'reset_required': false,
              'changes': [
                {
                  'seq': 11,
                  'entity': 'item',
                  'op': 'upsert',
                  'data': {
                    'id': 300,
                    'work_key': 'tmdb:movie:999',
                    'kind': 'movie',
                    'library_type': 'movie',
                    'title': 'Sample Movie',
                    'sort_title': 'sample movie',
                    'year': 2024,
                    'added_at': 1700000000000,
                    'updated_at': 1700000001000,
                    'files': [
                      {
                        'id': 101,
                        'source_id': 'src_dav',
                        'path': '/Movies/Sample Movie (2024)/Sample Movie (2024).mkv',
                        'size': 2048,
                        'role': 'video',
                      },
                    ],
                  },
                },
                {'seq': 12, 'entity': 'media_file', 'op': 'upsert'},
              ],
            }),
          );
        } else if (req.method == 'GET' &&
            (path == '/api/v1/userdata/progress' || path == '/api/v1/userdata/favorites')) {
          req.response.statusCode = 200;
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'tok');
      addTearDown(api.close);
      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk, keyEpoch: 1);
      final mirror = CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry);
      final sync = CloudProjectionSyncClient(api);
      final engine = CloudProjectionEngine(db: db, syncClient: sync, mountMirror: mirror);
      addTearDown(engine.stopListeningEvents);

      final libRepo = LibraryRepository(db);

      // Phase 1: full snapshot projects unmatched + pending cloud files onto pending shelf, skipping ignored.
      final snapRes = await engine.syncFullSnapshot();
      expect(snapRes.itemsProjected, 2);
      expect(snapRes.filesProjected, 2);

      final counts1 = await libRepo.pendingCounts();
      expect(counts1.queued, 1);
      expect(counts1.unmatched, 1);

      final pendingPage1 = await libRepo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending));
      expect(pendingPage1.items.map((v) => v.item.title), unorderedEquals(['Sample Movie (2024)', '测试电影 (2025)']));
      final sampleItem = pendingPage1.items.firstWhere((v) => v.item.title == 'Sample Movie (2024)').item;
      expect(sampleItem.year, 2024);
      expect(await engine.hydrateItemDetailFromCloud(sampleItem.id, sampleItem.workKey!), isFalse);

      // Phase 2: incremental sync matches 101, ignores 102, and adds unmatched 104.
      phase = 2;
      final incRes = await engine.syncIncremental();
      expect(incRes.hasChanges, isTrue);

      final pendingPage2 = await libRepo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending));
      expect(pendingPage2.items.map((v) => v.item.title), ['New Unknown']);

      final moviePage2 = await libRepo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(moviePage2.items.map((v) => v.item.title), ['Sample Movie']);
      final oldUnmatched = await (db.select(
        db.libraryItems,
      )..where((t) => t.workKey.equals('cloud:unmatched:101'))).getSingleOrNull();
      expect(oldUnmatched, isNull);
    },
  );

  test(
    'CloudProjectionEngine syncs household work_prefs via full snapshot, incremental changes, and detail hydration',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);
      final hk = CloudKeyring.generateMasterKey();
      final davCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {'base_url': 'https://nas.example/dav', 'username': 'alice', 'password': 'pw', 'root_path': '/'},
      );

      var changesPhase = 1;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_dav',
                  'kind': 'webdav',
                  'name': 'Home WebDAV',
                  'identity_key': 'hmac_wp',
                  'status': 'active',
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/sources/src_dav/credential') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {
                'source_id': 'src_dav',
                'ciphertext': davCipher,
                'version': 1,
                'key_epoch': 1,
                'status': 'valid',
              },
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          final kind = req.uri.queryParameters['kind'];
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': 10,
              'total': kind == 'movie' ? 1 : 0,
              'page': 1,
              'page_size': 200,
              'has_more': false,
              'items': kind == 'movie'
                  ? [
                      {
                        'id': 100,
                        'work_key': 'tmdb:movie:27205',
                        'kind': 'movie',
                        'library_type': 'movie',
                        'title': 'Inception',
                        'sort_title': 'inception',
                        'added_at': 1700000000000,
                        'updated_at': 1700000000000,
                        'files': [
                          {
                            'id': 500,
                            'source_id': 'src_dav',
                            'path': '/Movies/Inception.mkv',
                            'size': 2048,
                            'role': 'video',
                          },
                        ],
                      },
                    ]
                  : <Map<String, dynamic>>[],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/unmatched') {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[], 'total': 0}));
        } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else if (req.method == 'GET' && path == '/api/v1/kv') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {
                  'scope': 'household',
                  'namespace': 'work.skip',
                  'item_key': 'tmdb:movie:27205',
                  'work_key': 'tmdb:movie:27205',
                  'value': {
                    'introEnabled': true,
                    'introStartMs': 3000,
                    'introEndMs': 85000,
                    'creditsEnabled': true,
                    'creditsDurationMs': 120000,
                    'creditsResumeBeforeEndMs': 15000,
                  },
                  'updated_at': 1700000000100,
                },
                {
                  'scope': 'member',
                  'namespace': 'work.speed',
                  'item_key': 'tmdb:show:999',
                  'work_key': 'tmdb:show:999',
                  'value': {'speed': 1.5},
                  'updated_at': 1700000000100,
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/lists') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'lists': [
                {
                  'id': 'clist_1',
                  'kind': 'collection',
                  'title': 'Mind Benders',
                  'created_at': 1700000000000,
                  'updated_at': 1700000000100,
                  'entries': [
                    {'work_key': 'tmdb:movie:27205', 'sort_order': 0},
                  ],
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
          if (changesPhase == 1) {
            req.response.write(
              jsonEncode({
                'code': 0,
                'reset_required': false,
                'latest_seq': 11,
                'min_retained_seq': 1,
                'next_since_seq': 11,
                'has_more': false,
                'changes': [
                  {
                    'seq': 11,
                    'entity': 'kv',
                    'entity_id': 'household|work.skip|tmdb%3Ashow%3A999',
                    'op': 'upsert',
                    'data': {
                      'scope': 'household',
                      'namespace': 'work.skip',
                      'item_key': 'tmdb:show:999',
                      'work_key': 'tmdb:show:999',
                      'value': {
                        'introEnabled': true,
                        'introStartMs': 0,
                        'introEndMs': 90000,
                        'creditsEnabled': false,
                        'creditsDurationMs': 0,
                        'creditsResumeBeforeEndMs': 0,
                      },
                      'updated_at': 1700000000200,
                    },
                  },
                ],
              }),
            );
          } else {
            req.response.write(
              jsonEncode({
                'code': 0,
                'reset_required': false,
                'latest_seq': 13,
                'min_retained_seq': 1,
                'next_since_seq': 13,
                'has_more': false,
                'changes': [
                  {
                    'seq': 12,
                    'entity': 'kv',
                    'entity_id': 'household|work.skip|tmdb%3Ashow%3A999',
                    'op': 'delete',
                    'data': {
                      'scope': 'household',
                      'namespace': 'work.skip',
                      'item_key': 'tmdb:show:999',
                      'deleted': true,
                    },
                  },
                  {
                    'seq': 13,
                    'entity': 'kv',
                    'entity_id': 'household|work.skip|tmdb%3Ashow%3A999',
                    'op': 'upsert',
                    'data': {
                      'scope': 'household',
                      'namespace': 'work.skip',
                      'item_key': 'tmdb:show:999',
                      'work_key': 'tmdb:show:999',
                      'value': {
                        'introEnabled': true,
                        'introStartMs': 4000,
                        'introEndMs': 92000,
                        'creditsEnabled': false,
                        'creditsDurationMs': 0,
                        'creditsResumeBeforeEndMs': 0,
                      },
                      'updated_at': 1700000000300,
                    },
                  },
                ],
              }),
            );
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'tok');
      addTearDown(api.close);
      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk, keyEpoch: 1);
      final mirror = CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry);
      final sync = CloudProjectionSyncClient(api);
      final syncConfigStore = SyncConfigStore(db);
      addTearDown(syncConfigStore.dispose);
      final engine = CloudProjectionEngine(
        db: db,
        syncClient: sync,
        mountMirror: mirror,
        syncConfigStore: syncConfigStore,
      );
      addTearDown(engine.stopListeningEvents);

      final skipStore = WorkSkipSettingsStore(db, syncConfigStore: syncConfigStore);
      final movieWork = WorkIdentity.fromCloudWorkKey('tmdb:movie:27205')!;
      final showWork = WorkIdentity.fromCloudWorkKey('tmdb:show:999')!;

      // Create an unmapped local-only playlist that must survive clearProjectedLists().
      final localRepo = LibraryRepository(db);
      await localRepo.createList(kind: LibraryListKinds.playlist, title: 'Local Only Mix');

      // 1. Full snapshot syncs KV entries and remote lists with entries.
      await engine.syncFullSnapshot();
      final movieRules = await skipStore.read(movieWork);
      expect(movieRules.introEnabled, isTrue);
      expect(movieRules.introStartMs, 3000);
      expect(movieRules.introEndMs, 85000);
      expect(movieRules.creditsEnabled, isTrue);
      expect(movieRules.creditsDurationMs, 120000);
      expect(movieRules.creditsResumeBeforeEndMs, 15000);
      expect((await skipStore.read(showWork)).introEnabled, isFalse);

      final speedRaw = await syncConfigStore.readRaw(
        SyncConfigScope.member,
        SyncConfigNamespaces.workSpeed,
        'tmdb:show:999',
      );
      expect(speedRaw?['speed'], 1.5);

      final cols = await localRepo.lists(LibraryListKinds.collection);
      expect(cols.single.title, 'Mind Benders');
      final colEntries = await localRepo.listItems(cols.single.id);
      expect(colEntries.single.item.title, 'Inception');

      // 2. Incremental sync enables show intro, then executes ordered delete+upsert on same key.
      final inc1 = await engine.syncIncremental();
      expect(inc1.hasChanges, isTrue);
      expect((await skipStore.read(showWork)).introEnabled, isTrue);
      expect((await skipStore.read(showWork)).introEndMs, 90000);

      changesPhase = 2;
      final inc2 = await engine.syncIncremental();
      expect(inc2.hasChanges, isTrue);
      final showAfterOrderedOps = await skipStore.read(showWork);
      expect(showAfterOrderedOps.introEnabled, isTrue);
      expect(showAfterOrderedOps.introStartMs, 4000);
      expect(showAfterOrderedOps.introEndMs, 92000);

      // 3. clearProjectedLists removes cloud-mapped lists while keeping local-only lists.
      await engine.clearProjectedLists();
      expect(await localRepo.lists(LibraryListKinds.collection), isEmpty);
      expect((await localRepo.lists(LibraryListKinds.playlist)).single.title, 'Local Only Mix');
    },
  );

  test('cloud-synced progress and favorites persist in work_watch_states across DB reopen without re-sync', () async {
    resetSharedPreferencesForTest();
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final dir = await Directory.systemTemp.createTemp('plezy_cloud_reopen_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final dbFile = File('${dir.path}/library.db');
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    var dbClosed = false;
    addTearDown(() async {
      if (!dbClosed) await db.close();
    });

    final hk = CloudKeyring.generateMasterKey();
    final quarkCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'cookie': 'uid=u123; pus=abc', 'root_id': '0'},
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'sources': [
              {
                'id': 'src_reopen',
                'kind': 'quark',
                'name': 'NAS',
                'identity_key': 'quark:u123',
                'status': 'active',
                'folders': [
                  {'id': 'f1', 'source_id': 'src_reopen', 'path': '/TV'},
                ],
              },
            ],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/sources/src_reopen/credential') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'credential': {
              'source_id': 'src_reopen',
              'ciphertext': quarkCipher,
              'version': 1,
              'key_epoch': 1,
              'status': 'valid',
            },
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        final kind = req.uri.queryParameters['kind'];
        final items = switch (kind) {
          'show' => [
            {
              'id': 200,
              'work_key': 'tmdb:show:9001',
              'kind': 'show',
              'library_type': 'show',
              'title': 'Reopen Show',
              'tmdb_id': '9001',
              'updated_at': 1000,
            },
          ],
          'season' => [
            {
              'id': 201,
              'work_key': 'tmdb:show:9001:s1',
              'kind': 'season',
              'library_type': 'show',
              'parent_id': 200,
              'show_id': 200,
              'title': 'Season 1',
              'season_number': 1,
              'updated_at': 1000,
            },
          ],
          'episode' => [
            {
              'id': 202,
              'work_key': 'tmdb:show:9001:s1:e1',
              'kind': 'episode',
              'library_type': 'show',
              'parent_id': 201,
              'show_id': 200,
              'title': 'Ep 1',
              'season_number': 1,
              'episode_number': 1,
              'runtime_ms': 2400000,
              'updated_at': 1000,
              'files': [
                {
                  'id': 1,
                  'source_id': 'src_reopen',
                  'path': '/TV/Reopen/S01E01.mkv',
                  'role': 'video',
                  'size': 1024,
                  'added_at': 1000,
                },
              ],
            },
          ],
          _ => <Map<String, dynamic>>[],
        };
        req.response.write(jsonEncode({'code': 0, 'snapshot_seq': 10, 'items': items, 'has_more': false}));
      } else if (req.method == 'GET' && path == '/api/v1/progress') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'items': [
              {
                'progress_key': 'tmdb:show:9001:s1:e1',
                'work_key': 'tmdb:show:9001',
                'season_number': 1,
                'episode_number': 1,
                'position_ms': 450000,
                'duration_ms': 2400000,
                'watched': false,
                'last_played_at': 1700000500000,
                'updated_at': 1700000500000,
              },
            ],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/favorites') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'items': [
              {'work_key': 'tmdb:show:9001'},
            ],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/kv') {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else if (req.method == 'GET' && path == '/api/v1/lists') {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_reopen');
    addTearDown(api.close);
    final engine = CloudProjectionEngine(
      db: db,
      syncClient: CloudProjectionSyncClient(api),
      mountMirror: CloudMountMirror(
        sourceRepository: CloudSourceRepository(api: api, masterKeyProvider: () => hk),
        mountRegistry: MountRegistry(db),
      ),
    );

    await engine.syncFullSnapshot();
    expect(await db.select(db.workWatchStates).get(), hasLength(2));
    expect((await LibraryRepository(db).continueWatching()).single.state!.positionMs, 450000);

    // Reopen DB (triggers beforeOpen -> LibraryWatchStateStore.restoreAll) without any cloud sync.
    await db.close();
    dbClosed = true;
    final reopened = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(reopened.close);

    final repoAfterReopen = LibraryRepository(reopened);
    final cw = await repoAfterReopen.continueWatching();
    expect(cw, hasLength(1));
    expect(cw.single.item.title, 'Ep 1');
    expect(cw.single.state!.positionMs, 450000);
    final showRows = await (reopened.select(
      reopened.libraryItems,
    )..where((t) => t.kind.equals(LibraryKinds.show))).get();
    expect((await repoAfterReopen.getItem(showRows.single.id))!.state!.favorite, isTrue);
  });

  test(
    'projected tvdb and work_key-fallback tmdb shows accept local setProgress, survive older cloud sync, and reopen immediately',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final dir = await Directory.systemTemp.createTemp('plezy_cloud_local_first_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final dbFile = File('${dir.path}/library.db');
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      var dbClosed = false;
      addTearDown(() async {
        if (!dbClosed) await db.close();
      });

      var serverProgressUpdatedAt = 1000;
      var serverProgressPosMs = 50000;

      final hk = CloudKeyring.generateMasterKey();
      final quarkCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {'cookie': 'uid=u456; pus=def', 'root_id': '0'},
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_lf',
                  'kind': 'quark',
                  'name': 'NAS',
                  'identity_key': 'quark:u456',
                  'status': 'active',
                  'folders': [
                    {'id': 'f2', 'source_id': 'src_lf', 'path': '/TV'},
                  ],
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/sources/src_lf/credential') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {
                'source_id': 'src_lf',
                'ciphertext': quarkCipher,
                'version': 1,
                'key_epoch': 1,
                'status': 'valid',
              },
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          final kind = req.uri.queryParameters['kind'];
          final items = switch (kind) {
            'show' => [
              {
                'id': 300,
                'work_key': 'tvdb:show:777',
                'kind': 'show',
                'library_type': 'show',
                'title': 'TVDB Show',
                'updated_at': 1000,
              },
              {
                'id': 400,
                'work_key': 'tmdb:show:888',
                'kind': 'show',
                'library_type': 'show',
                'title': 'Fallback TMDB Show',
                'updated_at': 1000,
              },
            ],
            'season' => [
              {
                'id': 301,
                'work_key': 'tvdb:show:777:s1',
                'kind': 'season',
                'library_type': 'show',
                'parent_id': 300,
                'show_id': 300,
                'title': 'Season 1',
                'season_number': 1,
                'updated_at': 1000,
              },
              {
                'id': 401,
                'work_key': 'tmdb:show:888:s1',
                'kind': 'season',
                'library_type': 'show',
                'parent_id': 400,
                'show_id': 400,
                'title': 'Season 1',
                'season_number': 1,
                'updated_at': 1000,
              },
            ],
            'episode' => [
              {
                'id': 302,
                'work_key': 'tvdb:show:777:s1:e1',
                'kind': 'episode',
                'library_type': 'show',
                'parent_id': 301,
                'show_id': 300,
                'title': 'TVDB Ep 1',
                'season_number': 1,
                'episode_number': 1,
                'runtime_ms': 2400000,
                'updated_at': 1000,
                'files': [
                  {
                    'id': 11,
                    'source_id': 'src_lf',
                    'path': '/TV/TVDB/S01E01.mkv',
                    'role': 'video',
                    'size': 1024,
                    'added_at': 1000,
                  },
                ],
              },
              {
                'id': 402,
                'work_key': 'tmdb:show:888:s1:e1',
                'kind': 'episode',
                'library_type': 'show',
                'parent_id': 401,
                'show_id': 400,
                'title': 'TMDB Ep 1',
                'season_number': 1,
                'episode_number': 1,
                'runtime_ms': 2400000,
                'updated_at': 1000,
                'files': [
                  {
                    'id': 12,
                    'source_id': 'src_lf',
                    'path': '/TV/TMDB/S01E01.mkv',
                    'role': 'video',
                    'size': 1024,
                    'added_at': 1000,
                  },
                ],
              },
            ],
            _ => <Map<String, dynamic>>[],
          };
          req.response.write(jsonEncode({'code': 0, 'snapshot_seq': 20, 'items': items, 'has_more': false}));
        } else if (req.method == 'GET' && path == '/api/v1/progress') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {
                  'progress_key': 'tvdb:show:777:s1:e1',
                  'work_key': 'tvdb:show:777',
                  'season_number': 1,
                  'episode_number': 1,
                  'position_ms': serverProgressPosMs,
                  'duration_ms': 2400000,
                  'watched': false,
                  'last_played_at': serverProgressUpdatedAt,
                  'updated_at': serverProgressUpdatedAt,
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/favorites') {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else if (req.method == 'GET' && path == '/api/v1/kv') {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else if (req.method == 'GET' && path == '/api/v1/lists') {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_lf');
      addTearDown(api.close);
      final engine = CloudProjectionEngine(
        db: db,
        syncClient: CloudProjectionSyncClient(api),
        mountMirror: CloudMountMirror(
          sourceRepository: CloudSourceRepository(api: api, masterKeyProvider: () => hk),
          mountRegistry: MountRegistry(db),
        ),
      );

      await engine.syncFullSnapshot();
      final repo = LibraryRepository(db);
      final tvdbEp = (await (db.select(
        db.libraryItems,
      )..where((t) => t.workKey.equals('tvdb:show:777:s1:e1'))).getSingle());
      final tmdbEp = (await (db.select(
        db.libraryItems,
      )..where((t) => t.workKey.equals('tmdb:show:888:s1:e1'))).getSingle());
      final tmdbShow = (await (db.select(
        db.libraryItems,
      )..where((t) => t.workKey.equals('tmdb:show:888'))).getSingle());
      expect(tmdbShow.tmdbId, '888');

      // Local playback writes progress to both tvdb and fallback tmdb episodes.
      await repo.setProgress(tvdbEp.id, positionMs: 900000, durationMs: 2400000);
      await repo.setProgress(tmdbEp.id, positionMs: 600000, durationMs: 2400000);
      expect(await repo.continueWatching(), hasLength(2));

      // An older cloud progress snapshot must NOT overwrite newer local progress.
      serverProgressUpdatedAt = 500;
      serverProgressPosMs = 10000;
      await engine.syncFullSnapshot();
      expect((await repo.getItem(tvdbEp.id))!.state!.positionMs, 900000);

      // Reopening DB immediately preserves both episodes in Continue Watching.
      await db.close();
      dbClosed = true;
      final reopened = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(reopened.close);
      final cw = await LibraryRepository(reopened).continueWatching();
      expect(cw.map((e) => e.item.title).toSet(), {'TVDB Ep 1', 'TMDB Ep 1'});
    },
  );

  test('remote progress >=90% is preserved verbatim as unwatched and explicit watched=true advances to Next Up', () async {
    resetSharedPreferencesForTest();
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final mountRegistry = MountRegistry(db);

    final hk = CloudKeyring.generateMasterKey();
    final quarkCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'cookie': 'uid=u789; pus=ghi', 'root_id': '0'},
    );
    var ep1Watched = false;
    var ep1PositionMs = 2600000;
    var progressUpdatedAt = 1700000900000;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'sources': [
              {
                'id': 'src_norm',
                'kind': 'quark',
                'name': 'NAS',
                'identity_key': 'quark:u789',
                'status': 'active',
                'folders': [
                  {'id': 'f1', 'source_id': 'src_norm', 'path': '/TV'},
                ],
              },
            ],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/sources/src_norm/credential') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'credential': {
              'source_id': 'src_norm',
              'ciphertext': quarkCipher,
              'version': 1,
              'key_epoch': 1,
              'status': 'valid',
            },
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        final kind = req.uri.queryParameters['kind'];
        final items = switch (kind) {
          'show' => [
            {
              'id': 500,
              'work_key': 'tmdb:show:203483',
              'kind': 'show',
              'library_type': 'show',
              'title': '两京十五日',
              'tmdb_id': '203483',
              'updated_at': 1000,
            },
          ],
          'season' => [
            {
              'id': 501,
              'work_key': 'tmdb:show:203483:s1',
              'kind': 'season',
              'library_type': 'show',
              'parent_id': 500,
              'show_id': 500,
              'title': '第1季',
              'season_number': 1,
              'updated_at': 1000,
            },
          ],
          'episode' => [
            {
              'id': 502,
              'work_key': 'tmdb:show:203483:s1:e1',
              'kind': 'episode',
              'library_type': 'show',
              'parent_id': 501,
              'show_id': 500,
              'title': '虎硫药',
              'season_number': 1,
              'episode_number': 1,
              'runtime_ms': 2767098,
              'updated_at': 1000,
              'files': [
                {'id': 21, 'source_id': 'src_norm', 'path': '/TV/LiangJing/S01E01.mkv', 'role': 'video', 'size': 1024},
              ],
            },
            {
              'id': 503,
              'work_key': 'tmdb:show:203483:s1:e2',
              'kind': 'episode',
              'library_type': 'show',
              'parent_id': 501,
              'show_id': 500,
              'title': '太子和捕快',
              'season_number': 1,
              'episode_number': 2,
              'runtime_ms': 2767098,
              'updated_at': 1000,
              'files': [
                {'id': 22, 'source_id': 'src_norm', 'path': '/TV/LiangJing/S01E02.mkv', 'role': 'video', 'size': 1024},
              ],
            },
          ],
          _ => <Map<String, dynamic>>[],
        };
        req.response.write(jsonEncode({'code': 0, 'snapshot_seq': 30, 'items': items, 'has_more': false}));
      } else if (req.method == 'GET' && path == '/api/v1/progress') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'items': [
              {
                'progress_key': 'tmdb:show:203483:s1:e1',
                'work_key': 'tmdb:show:203483',
                'season_number': 1,
                'episode_number': 1,
                'position_ms': ep1PositionMs,
                'duration_ms': 2767098,
                'watched': ep1Watched,
                'play_count': ep1Watched ? 1 : 0,
                'last_played_at': progressUpdatedAt,
                'updated_at': progressUpdatedAt,
              },
            ],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/favorites') {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else if (req.method == 'GET' && path == '/api/v1/kv') {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else if (req.method == 'GET' && path == '/api/v1/lists') {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_norm');
    addTearDown(api.close);
    final engine = CloudProjectionEngine(
      db: db,
      syncClient: CloudProjectionSyncClient(api),
      mountMirror: CloudMountMirror(
        sourceRepository: CloudSourceRepository(api: api, masterKeyProvider: () => hk),
        mountRegistry: mountRegistry,
      ),
    );

    await engine.syncFullSnapshot();
    final repo = LibraryRepository(db);
    final ep1 = await (db.select(
      db.libraryItems,
    )..where((t) => t.workKey.equals('tmdb:show:203483:s1:e1'))).getSingle();
    final ep1State = (await repo.getItem(ep1.id))!.state!;
    expect(ep1State.watched, isFalse);
    expect(ep1State.positionMs, 2600000);
    expect(ep1State.playCount, 0);

    var cw = await repo.continueWatching();
    expect(cw, hasLength(1));
    expect(cw.single.item.title, '虎硫药');

    // Explicit watched=true from server advances Continue Watching to Next Up (S1E2).
    ep1Watched = true;
    ep1PositionMs = 0;
    progressUpdatedAt = 1700001000000;
    await engine.syncFullSnapshot();
    final ep1WatchedState = (await repo.getItem(ep1.id))!.state!;
    expect(ep1WatchedState.watched, isTrue);
    expect(ep1WatchedState.playCount, 1);

    cw = await repo.continueWatching();
    expect(cw, hasLength(1));
    expect(cw.single.item.title, '太子和捕快');
    expect(cw.single.continueRecencyMs, 1700001000000);
  });

  test('persists _lastSeq across engine restarts so cold start syncs incrementally without full snapshot', () async {
    resetSharedPreferencesForTest();
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final hk = CloudKeyring.generateMasterKey();
    final quarkCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'cookie': 'uid=u_seq; pus=xyz', 'root_id': '0'},
    );

    var snapshotCalls = 0;
    final changesQueries = <int>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final path = req.uri.path;
      req.response.headers.contentType = ContentType.json;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'sources': [
              {
                'id': 'src_seq',
                'kind': 'quark',
                'name': 'Quark Seq',
                'status': 'active',
                'key_epoch': 1,
                'folders': [
                  {'id': 'f1', 'source_id': 'src_seq', 'path': '/Movies'},
                ],
              },
            ],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/sources/src_seq/credential') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'credential': {
              'source_id': 'src_seq',
              'ciphertext': quarkCipher,
              'version': 1,
              'key_epoch': 1,
              'status': 'valid',
            },
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        snapshotCalls++;
        final kind = req.uri.queryParameters['kind'];
        final items = kind == LibraryKinds.movie
            ? [
                {
                  'id': 301,
                  'kind': LibraryKinds.movie,
                  'library_type': 'movie',
                  'title': 'Seq Movie',
                  'work_key': 'tmdb:movie:301',
                  'tmdb_id': '301',
                  'scraped_at': 1000,
                  'added_at': 1000,
                  'updated_at': 1000,
                  'files': [
                    {
                      'id': 1,
                      'source_id': 'src_seq',
                      'path': '/Movies/SeqMovie.mkv',
                      'role': 'video',
                      'size': 1024,
                      'added_at': 1000,
                    },
                  ],
                },
              ]
            : const [];
        req.response.write(
          jsonEncode({'code': 0, 'snapshot_seq': 42, 'items': items, 'total': items.length, 'page': 1, 'has_more': false}),
        );
      } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
        final sinceSeq = int.tryParse(req.uri.queryParameters['since_seq'] ?? '') ?? 0;
        changesQueries.add(sinceSeq);
        req.response.write(
          jsonEncode({
            'code': 0,
            'reset_required': false,
            'latest_seq': 45,
            'min_retained_seq': 1,
            'next_since_seq': 45,
            'has_more': false,
            'changes': const [],
          }),
        );
      } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites' || path == '/api/v1/kv' || path == '/api/v1/lists')) {
        req.response.write(jsonEncode({'code': 0, 'items': const []}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_seq');
    addTearDown(api.close);

    CloudProjectionEngine makeEngine() => CloudProjectionEngine(
      db: db,
      syncClient: CloudProjectionSyncClient(api),
      mountMirror: CloudMountMirror(
        sourceRepository: CloudSourceRepository(api: api, masterKeyProvider: () => hk),
        mountRegistry: MountRegistry(db),
        accountScopeKey: 'scope_seq',
      ),
    );

    final first = makeEngine();
    final res1 = await first.syncFullSnapshot();
    expect(res1.latestSeq, 42);
    expect(snapshotCalls, 4);

    // A brand-new CloudProjectionEngine instance on the same DB must resume from seq=42.
    final second = makeEngine();
    final res2 = await second.syncIncremental();
    expect(res2.fullReset, isFalse);
    expect(res2.latestSeq, 45);
    expect(changesQueries, [42]);
    expect(snapshotCalls, 4);

    // If local library_items is emptied, a fresh engine automatically falls back to full snapshot.
    await db.delete(db.libraryItems).go();
    final third = makeEngine();
    final res3 = await third.syncIncremental();
    expect(res3.fullReset, isTrue);
    expect(snapshotCalls, 8);
  });
}

class _FakeQuarkIncrementalDriver implements StorageDriver {
  _FakeQuarkIncrementalDriver({required this.onList});

  final void Function() onList;

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    onList();
    return [
      StorageEntry(
        id: 'rk_2',
        path: '/TV/S01E02.mkv',
        name: 'S01E02.mkv',
        isDirectory: false,
        size: 4096,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(2500000),
      ),
    ];
  }

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int? start, int? end}) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
