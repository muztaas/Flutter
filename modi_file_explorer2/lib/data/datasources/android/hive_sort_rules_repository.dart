import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../../../domain/entities/sort_rule.dart';
import '../../../domain/repositories/sort_rules_repository.dart';

class HiveSortRulesRepository implements SortRulesRepository {
  static const _boxName = 'sort.rules';
  final Future<Directory> Function() _supportDirectoryProvider;
  Future<Box<Map>>? _boxFuture;

  HiveSortRulesRepository({
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  Future<Box<Map>> _box() async {
    try {
      return await (_boxFuture ??= _openBox());
    } catch (_) {
      _boxFuture = null;
      rethrow;
    }
  }

  Future<Box<Map>> _openBox() async {
    final directory = await _supportDirectoryProvider();
    if (!Hive.isBoxOpen(_boxName)) Hive.init(directory.path);
    return Hive.openBox<Map>(_boxName);
  }

  @override
  Future<List<SortRule>> getAll() async {
    final box = await _box();
    final rules = <SortRule>[];
    for (final raw in box.values) {
      try {
        rules.add(SortRule.fromJson(raw));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    rules.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return rules;
  }

  @override
  Future<void> save(SortRule rule) async {
    final box = await _box();
    await box.put(rule.id, rule.toJson());
  }

  @override
  Future<void> delete(String id) async {
    final box = await _box();
    await box.delete(id);
  }
}
