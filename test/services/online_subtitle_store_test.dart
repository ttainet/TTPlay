import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/services/online_subtitle_store.dart';

void main() {
  group('OnlineSubtitleStore', () {
    late AppDatabase db;
    late Directory tempRoot;
    late OnlineSubtitleStore store;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      tempRoot = await Directory.systemTemp.createTemp('ttplay_online_sub_test_');
      store = OnlineSubtitleStore(db, rootDirResolver: () async => tempRoot);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('saveAndSelect writes UTF-8 file, deduplicates by sha256, and flips selection', () async {
      final first = await store.saveAndSelect(
        itemGlobalKey: 'local-library:42',
        mediaSourceId: '10',
        provider: 'xunlei',
        remoteId: 'xl-1',
        title: 'Inception CHS',
        language: 'zh',
        format: 'ass',
        sha256: 'a' * 64,
        contentUtf8: '[Script Info]\nTitle: First',
      );

      expect(File(first.absPath).existsSync(), isTrue);
      expect(first.isSelected, isTrue);
      expect(first.playableUri(forExoPlayer: false), first.absPath);
      expect(first.playableUri(forExoPlayer: true), startsWith('file://'));

      final second = await store.saveAndSelect(
        itemGlobalKey: 'local-library:42',
        mediaSourceId: '10',
        provider: 'subdl',
        remoteId: 'sd-2',
        title: 'Inception ENG',
        language: 'en',
        format: 'srt',
        sha256: 'b' * 64,
        contentUtf8: '1\n00:00:01,000 --> 00:00:02,000\nSecond\n',
      );

      final items = await store.listForItem('local-library:42', mediaSourceId: '10');
      expect(items, hasLength(2));
      expect(items.firstWhere((e) => e.id == second.id).isSelected, isTrue);
      expect(items.firstWhere((e) => e.id == first.id).isSelected, isFalse);

      await store.markSelected(first.id, itemGlobalKey: 'local-library:42', mediaSourceId: '10');
      final afterMark = await store.listForItem('local-library:42', mediaSourceId: '10');
      expect(afterMark.firstWhere((e) => e.id == first.id).isSelected, isTrue);
      expect(afterMark.firstWhere((e) => e.id == second.id).isSelected, isFalse);

      await store.clearSelection('local-library:42', mediaSourceId: '10');
      final afterClear = await store.listForItem('local-library:42', mediaSourceId: '10');
      expect(afterClear.every((e) => !e.isSelected), isTrue);
    });

    test('listForItem prunes rows whose files were removed from disk', () async {
      final saved = await store.saveAndSelect(
        itemGlobalKey: 'jf:100',
        provider: 'assrt',
        remoteId: '99',
        title: 'Missing Later',
        language: 'zh',
        format: 'srt',
        sha256: 'c' * 64,
        contentUtf8: 'hello',
      );
      await File(saved.absPath).delete();

      final items = await store.listForItem('jf:100');
      expect(items, isEmpty);
    });

    test('delete preserves shared sha256 file until last reference is deleted', () async {
      final sharedSha = 'd' * 64;
      final a = await store.saveAndSelect(
        itemGlobalKey: 'item:1',
        provider: 'xunlei',
        remoteId: '1',
        title: 'Sub A',
        language: 'zh',
        format: 'srt',
        sha256: sharedSha,
        contentUtf8: 'shared content',
      );
      final b = await store.saveAndSelect(
        itemGlobalKey: 'item:2',
        provider: 'xunlei',
        remoteId: '1',
        title: 'Sub B',
        language: 'zh',
        format: 'srt',
        sha256: sharedSha,
        contentUtf8: 'shared content',
      );

      final expectedFile = File(p.join(tempRoot.path, 'online_subtitles', '$sharedSha.srt'));
      expect(expectedFile.existsSync(), isTrue);

      await store.delete(a.id);
      expect(expectedFile.existsSync(), isTrue);

      await store.delete(b.id);
      expect(expectedFile.existsSync(), isFalse);
    });
  });
}
