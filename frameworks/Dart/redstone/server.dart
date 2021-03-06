import "dart:core";
import "dart:io";
import "dart:isolate";
import 'dart:async' show Future;
import 'dart:math' show Random, max;
import "package:redstone/server.dart" as app;
import "package:redstone_mapper/mapper.dart";
import "package:redstone_mapper/plugin.dart";
import "package:redstone_mapper_mongo/manager.dart";
import "package:redstone_mapper_pg/manager.dart";
import "package:postgresql/postgresql.dart" as pg;
import "package:di/di.dart";
import 'package:yaml/yaml.dart' as yaml;
import 'package:mustache/mustache.dart' as mustache;
import 'package:system_info/system_info.dart';

final _NUM_PROCESSORS = SysInfo.processors.length;

const _WORLD_TABLE_SIZE = 10000;

final _RANDOM = new Random();

class Fortune implements Comparable<Fortune> {
  
  @Field()
  int id;
  
  @Field()
  String message;
  
  Fortune([this.id, this.message]);

  compareTo(Fortune other) => message.compareTo(other.message);
  
}

class World {
  
  @Field()
  int id;

  @Field(model: "randomnumber")
  int randomNumber;

}

class MongoFortune implements Comparable<MongoFortune> {
  
  int _id;
  
  @Field(model: "_id")
  int get id => _id;
  
  @Field(model: "_id")
  set id(num value) => _id = value.toInt();
  
  @Field()
  String message;
  
  MongoFortune([this._id, this.message]);

  compareTo(MongoFortune other) => message.compareTo(other.message);
  
}

class MongoWorld {
  
  int _id;
  int _randomNumber;
    
  @Field(model: "_id")
  int get id => _id;
  
  @Field(model: "_id")
  set id(num value) => _id = value.toInt();

  @Field()
  int get randomNumber => _randomNumber;
  
  @Field()
  set randomNumber(num value) => _randomNumber = value.toInt();

}

///Handle PostgreSql connections
@app.Interceptor(r'/pg/.+')
pgSqlManager(PostgreSqlManager pgSql) {
  pgSql.getConnection().then((conn) {
    app.request.attributes["dbConn"] = conn;
    app.chain.next(() {
      pgSql.closeConnection(conn, error: app.chain.error);
    });
  });
}

///Handle MongoDb connections
@app.Interceptor(r'/mongo/.+')
mongoDbManager(MongoDbManager mongoDb) {
  mongoDb.getConnection().then((conn) {
    app.request.attributes["dbConn"] = conn;
    app.chain.next(() {
      mongoDb.closeConnection(conn, error: app.chain.error);
    });
  });
}

///JSON test
@app.Route("/json")
getJson() => {"message": "Hello, World!"};

///PlainText test
@app.Route("/plaintext")
getPlainText() => "Hello, World!";

///PostgreSql tests
@app.Group("/pg")
@Encode()
class PgTests {
  
  static const worldQuery = 'SELECT id, randomnumber FROM world WHERE id = @id;';
  static const worldUpdt = 'UPDATE world SET randomnumber = @randomnumber WHERE id = @id;';
  
  static const fortuneQuery = 'SELECT id, message FROM fortune;';
  
  PostgreSql get pgSql => app.request.attributes["dbConn"];
  
  @app.Route("/db")
  Future<World> queryTest() {
    var params = { 'id': _RANDOM.nextInt(_WORLD_TABLE_SIZE) + 1 };
    return pgSql.query(worldQuery, World, params).then((list) => list[0]);
  }

  @app.Route("/queries")
  Future<List<World>> queriesTest() {
    var queries = _parseQueriesParam(app.request.queryParams.queries);
    return Future.wait(new List.generate(queries, (_) => queryTest()));
  } 
  
  @app.Route("/updates")
  Future<List<World>> updateTest() {
    var queries = _parseQueriesParam(app.request.queryParams.queries);
    return Future.wait(new List.generate(queries, (_) => queryTest().then((world) {
      world.randomNumber = _RANDOM.nextInt(_WORLD_TABLE_SIZE) + 1;
      return pgSql.execute(worldUpdt, world).then((_) => world);
    })));
  }
  
  @app.Route("/fortunes", responseType: "text/html;charset=utf-8")
  Future<String> fortunesTest(@app.Inject() mustache.Template template) {
    return pgSql.query(fortuneQuery, Fortune).then((values) {
      values
          ..add(new Fortune(0, 'Additional fortune added at request time.'))
          ..sort();
      
      return template.renderString({
        "fortunes": encode(values)
      });
    });
  }
  
}

///MongoDb tests
@app.Group("/mongo")
@Encode()
class MongoTests {
  
  static const worldCollection = "world";
  static const fortuneCollection = "fortune";
  
  MongoDb get mongoDb => app.request.attributes["dbConn"];
  
  @app.Route("/db")
  Future<MongoWorld> queryTest() {
    return mongoDb.findOne(worldCollection, MongoWorld, {
      "_id": _RANDOM.nextInt(_WORLD_TABLE_SIZE) + 1
    });
  }
  
  @app.Route("/queries")
  Future<List<MongoWorld>> queriesTest() {
    var queries = _parseQueriesParam(app.request.queryParams.queries);
    return Future.wait(new List.generate(queries, (_) => queryTest()));
  }
  
  @app.Route("/updates")
  Future<List<MongoWorld>> updateTest() {
    var queries = _parseQueriesParam(app.request.queryParams.queries);
    return Future.wait(new List.generate(queries, (_) => queryTest().then((world) {
      world.randomNumber = _RANDOM.nextInt(_WORLD_TABLE_SIZE) + 1;
      return mongoDb.update(worldCollection, { "_id": world.id }, world)
          .then((_) => world);
    })));
  }
  
  @app.Route("/fortunes", responseType: "text/html;charset=utf-8")
  Future<String> fortunesTest(@app.Inject() mustache.Template template) {
    return mongoDb.find(fortuneCollection, MongoFortune).then((values) {
      values
          ..add(new MongoFortune(0, 'Additional fortune added at request time.'))
          ..sort();
      
      return template.renderString({
        "fortunes": encode(values)
      });
    });
  }
  
}

main(List<String> args) {
  ReceivePort errorPort = new ReceivePort();
  errorPort.listen((e) => print(e));
  for (int i = 0; i < _NUM_PROCESSORS; i++) {
    Isolate.spawn(
        startInIsolate,
        [],
        onError: errorPort.sendPort);
  }
}

startInIsolate(List args) {
  _startServer();
}

_startServer() {
  var dbConnections = max(1, (256 / _NUM_PROCESSORS).floor());

  var mongoDbManager = new MongoDbManager(
      "mongodb://tfb-database/hello_world",
      poolSize: dbConnections);

  var pgSqlManager = new PostgreSqlManager(
      "postgres://benchmarkdbuser:benchmarkdbpass@tfb-database:5432/hello_world",
      min: dbConnections,
      max: dbConnections);

  mustache.Template fortunesTemplate;
  
  Future.wait([

    HttpServer.bind("0.0.0.0", 8080, shared: true),

    new File('fortunes.mustache').readAsString().then((template) {
      fortunesTemplate = mustache.parse(template);
    })

  ]).then((List waitResults) {
    var server = waitResults[0];

    //app.setupConsoleLog();
    
    //install module for dependency injection
    app.addModule(new Module()
                      ..bind(MongoDbManager, toValue: mongoDbManager)
                      ..bind(PostgreSqlManager, toValue: pgSqlManager)
                      ..bind(mustache.Template, toValue: fortunesTemplate));
    
    //initialize mapper plugin
    app.addPlugin(getMapperPlugin());
    
    //start the server
    app.serveRequests(server);
    
  });

}

_parseQueriesParam(param) {
  return param == null || param.isEmpty ? 1 : 
    int.parse(param, radix: 10, onError: (_) => 1).clamp(1, 500);
}
