/// Support for doing something awesome.
///
/// More dartdocs go here.
library;

import 'dart:async';

import 'package:drift/backends.dart';
import 'package:drift/drift.dart';
import 'package:hrana/hrana.dart';

final class HranaDatabase extends DelegatedDatabase {
  HranaDatabase._(super.delegate);

  HranaDatabase(Uri uri, {String? jwtToken})
      : this._(_HranaDelegate(uri: uri, jwtToken: jwtToken));
}

abstract class _BaseHranaDelegate extends QueryDelegate {
  Future<T> _run<T>(Future<T> Function(DatabaseSession session) inner);

  @override
  Future<void> runCustom(String statement, List<Object?> args) async {
    await _run((s) async => s.execute(statement, arguments: args));
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async {
    final res = await _run((s) async => s.execute(statement, arguments: args));
    return res.lastInsertRowId ?? 0;
  }

  @override
  Future<QueryResult> runSelect(String statement, List<Object?> args) async {
    final res = await _run((s) async => s.select(statement, arguments: args));
    return QueryResult(res.columnNames, res.rows);
  }

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async {
    final res = await _run((s) async => s.execute(statement, arguments: args));
    return res.affectedRows;
  }

  @override
  Future<void> runBatched(BatchedStatements statements) async {
    await _run((s) async {
      final prepared = <StoredSql>[];

      for (final statement in statements.statements) {
        final stored = await s.storeSql(statement);
        prepared.add(stored);
      }

      await s.batch((b) {
        for (final arg in statements.arguments) {
          b.executeStored(prepared[arg.statementIndex],
              arguments: arg.arguments);
        }
      });
    });
  }
}

final class _HranaDelegate extends _BaseHranaDelegate
    implements DatabaseDelegate {
  Database? _database;
  var _isClosed = false;

  final Uri uri;
  final String? jwtToken;

  @override
  bool isInTransaction = false;

  _HranaDelegate({required this.uri, required this.jwtToken});

  @override
  Future<T> _run<T>(Future<T> Function(DatabaseSession session) inner) async {
    return _database!.withSession(inner);
  }

  @override
  FutureOr<bool> get isOpen => Future.value(!_isClosed && _database != null);

  @override
  Future<void> open(QueryExecutorUser db) async {
    if (_database != null) {
      throw const ConnectionClosed();
    }

    final database =
        _database = await Database.connect(uri, jwtToken: jwtToken);
    database.closed.whenComplete(() {
      _isClosed = true;
    });
  }

  @override
  void notifyDatabaseOpened(OpeningDetails details) {}

  @override
  Future<void> close() async {
    await _database?.close();
  }

  @override
  late final TransactionDelegate transactionDelegate =
      _HranaTransactionDelegate(this);

  @override
  DbVersionDelegate get versionDelegate =>
      _HranaVersionDelegate(delegate: this);
}

final class _HranaTransactionDelegate extends SupportedTransactionDelegate {
  final _HranaDelegate _delegate;

  _HranaTransactionDelegate(this._delegate);

  @override
  bool get managesLockInternally => true;

  @override
  FutureOr<void> startTransaction(
      Future<void> Function(QueryDelegate) run) async {
    await _delegate._run((s) async {
      await s.execute('BEGIN');
      try {
        await run(_HranaTransaction(s));
        await s.execute('COMMIT');
      } catch (e) {
        await s.execute('ROLLBACK');
        rethrow;
      }
    });
  }
}

final class _HranaTransaction extends _BaseHranaDelegate {
  final DatabaseSession _session;

  _HranaTransaction(this._session);

  @override
  Future<T> _run<T>(Future<T> Function(DatabaseSession session) inner) async {
    return await inner(_session);
  }
}

final class _HranaVersionDelegate extends DynamicVersionDelegate {
  final _HranaDelegate delegate;

  _HranaVersionDelegate({required this.delegate});

  @override
  Future<int> get schemaVersion async {
    final result = await delegate
        ._run((s) async => await s.select('pragma user_version;'));
    return result.rows.first.first as int;
  }

  @override
  Future<void> setSchemaVersion(int version) async {
    await delegate
        ._run((s) async => s.execute('pragma user_version = $version;'));
  }
}
