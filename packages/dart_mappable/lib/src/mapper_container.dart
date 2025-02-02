import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
// ignore: implementation_imports
import 'package:type_plus/src/types_registry.dart' show TypeRegistry;
import 'package:type_plus/type_plus.dart' hide typeOf;

import '../dart_mappable.dart';

/// Additional options to be passed to [MapperContainer.toValue].
///
/// {@category Generics}
/// {@category Mapper Container}
class EncodingOptions {
  EncodingOptions({this.includeTypeId, this.inheritOptions = true});

  /// Whether to include the type id of the encoding object.
  ///
  /// If set, this adds a '__type' property with the specific runtime type
  /// of the encoding object.
  /// If left untouched, the container automatically decides whether to include
  /// the type id based on the static and dynamic type of an object.
  final bool? includeTypeId;

  /// Whether to inherit this options for nested calls to [MapperContainer.toValue],
  /// like for encoding fields of a class.
  final bool inheritOptions;
}

/// The mapper container manages a set of mappers and is the main interface for
/// accessing mapping functionalities.
///
/// `MapperContainer`s are the backbone of `dart_mappable`. A `MapperContainer`s
/// job is to lookup the correct mapper for a given type or value and call its
/// respective method.
/// To find the mapper for a given type, the container first looks at its own
/// **set of mappers** and when there is no match it refers to its **linked containers**.
///
/// {@category Generics}
/// {@category Mapper Container}
@sealed
abstract class MapperContainer {
  factory MapperContainer({
    Set<MapperBase>? mappers,
    Set<MapperContainer>? linked,
    Map<String, Function>? types,
  }) = _MapperContainerBase;

  /// A container that holds the standard set of mappers for all core types,
  /// including all primitives, List, Set, Map and DateTime.
  ///
  /// All other container will automatically be linked to this container.
  static final MapperContainer defaults = _MapperContainerBase._({
    PrimitiveMapper<Object>((v) => v, dynamic),
    PrimitiveMapper<Object>((v) => v, Object),
    PrimitiveMapper<String>((v) => v.toString()),
    PrimitiveMapper<int>((v) => num.parse(v.toString()).round()),
    PrimitiveMapper<double>((v) => double.parse(v.toString())),
    PrimitiveMapper<num>((v) => num.parse(v.toString()), num),
    PrimitiveMapper<bool>((v) => v is num ? v != 0 : v.toString() == 'true'),
    DateTimeMapper(),
    IterableMapper<List>(<T>(i) => i.toList(), <T>(f) => f<List<T>>()),
    IterableMapper<Set>(<T>(i) => i.toSet(), <T>(f) => f<Set<T>>()),
    MapMapper<Map>(<K, V>(map) => map, <K, V>(f) => f<Map<K, V>>()),
  });

  /// A container that holds all globally registered mappers.
  ///
  /// This container does not define any mappers itself. Rather each generated
  /// mapper will register itself with this container when calling `ensureInitialized()`.
  static final MapperContainer globals = _MapperContainerBase();

  /// The core method to decode any value to a given type [T].
  T fromValue<T>(Object? value);

  /// The core method to encode any value.
  ///
  /// The value is expected to be of type [T], but this is not statically
  /// enforced. When the exact type of the value is different, a type discriminator
  /// may be added to the resulting encoded value.
  dynamic toValue<T>(Object? value, [EncodingOptions? options]);

  /// Decodes a map to a given type [T].
  ///
  /// This is a typed wrapper around the [fromValue] method.
  T fromMap<T>(Map<String, dynamic> map);

  /// Encodes a value to a map.
  ///
  /// This is a typed wrapper around the [toValue] method.
  Map<String, dynamic> toMap<T>(T object);

  /// Decodes an iterable to a given type [T].
  ///
  /// This is a typed wrapper around the [fromValue] method.
  T fromIterable<T>(Iterable<dynamic> iterable);

  /// Encodes a value to an iterable.
  ///
  /// This is a typed wrapper around the [toValue] method.
  Iterable<dynamic> toIterable<T>(T object);

  /// Decodes a json string to a given type [T].
  ///
  /// This is a typed wrapper around the [fromValue] method.
  T fromJson<T>(String json);

  /// Encodes a value to a json string.
  ///
  /// This is a typed wrapper around the [toValue] method.
  String toJson<T>(T object);

  /// Checks whether two values are deeply equal.
  bool isEqual(dynamic value, Object? other);

  /// Calculates the hash of a value.
  int hash(dynamic value);

  /// Returns the string representation of a value.
  String asString(dynamic value);

  /// Adds a new mapper to the set of mappers this container holds.
  void use<T extends Object>(MapperBase<T> mapper);

  /// Removes the mapper for type [T] this container currently holds.
  MapperBase<T>? unuse<T extends Object>();

  /// Adds a list of mappers to the set of mappers this container holds.
  void useAll(Iterable<MapperBase> mappers);

  /// Returns the current mapper for type [T] of this container.
  MapperBase<T>? get<T extends Object>([Type? type]);

  /// Returns all mapper this container currently holds.
  List<MapperBase> getAll();

  /// Links another container to this container.
  void link(MapperContainer container);

  /// Links a list of containers to this container.
  void linkAll(Iterable<MapperContainer> containers);
}

class _MapperContainerBase implements MapperContainer, TypeProvider {
  _MapperContainerBase._([
    Set<MapperBase>? mappers,
    Set<MapperContainer>? linked,
    Map<String, Function>? types,
  ]) {
    TypeRegistry.instance.register(this);
    if (types != null) {
      _types.addAll(types);
    }
    if (linked != null) {
      linkAll(linked);
    }
    useAll(mappers ?? {});
  }

  factory _MapperContainerBase({
    Set<MapperBase>? mappers,
    Set<MapperContainer>? linked,
    Map<String, Function>? types,
  }) {
    return _MapperContainerBase._(
      mappers ?? {},
      {...?linked, MapperContainer.defaults},
      types ?? {},
    );
  }

  final Map<Type, MapperBase> _mappers = {};
  final Map<String, Function> _types = {};

  final Set<_MapperContainerBase> _parents = {};
  final Set<_MapperContainerBase> _children = {};

  final Map<Type, MapperBase?> _cachedMappers = {};
  final Map<Type, MapperBase?> _cachedTypeMappers = {};

  void _invalidateCachedMappers([Set<MapperContainer>? invalidated]) {
    // for avoiding hanging on circular links
    if (invalidated != null && invalidated.contains(this)) return;

    _cachedMappers.clear();
    _cachedTypeMappers.clear();
    _cachedInheritedMappers = null;
    for (var c in _parents) {
      c._invalidateCachedMappers({...?invalidated, this});
    }
  }

  Map<Type, MapperBase>? _cachedInheritedMappers;
  Map<Type, MapperBase> get _inheritedMappers {
    return _cachedInheritedMappers ??= _getInheritedMappers();
  }

  Map<Type, MapperBase> _getInheritedMappers([Set<MapperContainer>? parents]) {
    // for avoiding hanging on circular links
    if (parents != null && parents.contains(this)) return {};

    return {
      for (var c in _children) ...(c)._getInheritedMappers({...?parents, this}),
      ..._mappers,
    };
  }

  MapperBase? _mapperFor(dynamic value) {
    var baseType = value.runtimeType.base;
    if (baseType == UnresolvedType) {
      baseType = value.runtimeType;
    }
    if (_cachedMappers[baseType] != null) {
      return _cachedMappers[baseType];
    }

    var mapper = //
        // direct type
        _mappers[baseType] ??
            // indirect type ie. subtype
            _mappers.values.where((m) => m.isFor(value)).firstOrNull ??
            // inherited direct type
            _inheritedMappers[baseType] ??
            // inherited indirect type ie. subclasses
            _inheritedMappers.values.where((m) => m.isFor(value)).firstOrNull;

    if (mapper != null) {
      if (mapper is ClassMapperBase) {
        mapper = mapper.subOrSelfFor(value);
      }
      _cachedMappers[baseType] = mapper;
    }

    return mapper;
  }

  MapperBase? _mapperForType(Type type) {
    var baseType = type.base;
    if (baseType == UnresolvedType) {
      baseType = type;
    }
    if (_cachedTypeMappers[baseType] != null) {
      return _cachedTypeMappers[baseType];
    }
    var mapper = _mappers[baseType] ?? _inheritedMappers[baseType];

    if (mapper != null) {
      _cachedTypeMappers[baseType] = mapper;
    }
    return mapper;
  }

  @override
  Function? getFactoryById(String id) {
    return _mappers.values.where((m) => m.id == id).firstOrNull?.typeFactory ??
        _types[id];
  }

  @override
  List<Function> getFactoriesByName(String name) {
    return [
      ..._mappers.values
          .where((m) => m.type.name == name)
          .map((m) => m.typeFactory),
      ..._types.values.where((f) => (f(<T>() => T) as Type).name == name)
    ];
  }

  @override
  String? idOf(Type type) {
    return _mappers[type]?.id ??
        _types.entries
            .where((e) => e.value(<T>() => T == type) as bool)
            .map((e) => e.key)
            .firstOrNull;
  }

  @override
  T fromValue<T>(Object? value) {
    if (value == null) {
      return value as T;
    }

    var type = T;
    if (value is Map<String, dynamic> && value['__type'] != null) {
      type = TypePlus.fromId(value['__type'] as String);
      if (type == UnresolvedType) {
        var e = MapperException.unresolvedType(value['__type'] as String);
        throw MapperException.chain(MapperMethod.decode, '($T)', e);
      }
    } else if (value is T) {
      return value as T;
    }

    var mapper = _mapperForType(type);
    if (mapper != null) {
      try {
        return mapper.decoder(
            value, DecodingContext(container: this, args: type.args)) as T;
      } catch (e, stacktrace) {
        Error.throwWithStackTrace(
          MapperException.chain(MapperMethod.decode, '($type)', e),
          stacktrace,
        );
      }
    } else {
      throw MapperException.chain(
          MapperMethod.decode, '($type)', MapperException.unknownType(type));
    }
  }

  @override
  dynamic toValue<T>(Object? value, [EncodingOptions? options]) {
    if (value == null) return null;
    var mapper = _mapperFor(value);
    if (mapper != null) {
      try {
        Type type = T;

        var includeTypeId = options?.includeTypeId;
        includeTypeId ??= mapper.includeTypeId<T>(value);

        if (includeTypeId) {
          type = value.runtimeType;
        }

        var typeArgs = type.args.map((t) => t == UnresolvedType ? dynamic : t);

        var fallback = mapper.type.base.args;
        if (typeArgs.length != fallback.length) {
          typeArgs = fallback;
        }

        var result = mapper.encoder(
          value,
          EncodingContext(
            container: this,
            options: options?.inheritOptions ?? false ? options : null,
            args: typeArgs.toList(),
          ),
        );

        if (includeTypeId && result is Map<String, dynamic>) {
          result['__type'] = value.runtimeType.id;
        }

        return result;
      } catch (e, stacktrace) {
        Error.throwWithStackTrace(
          MapperException.chain(
              MapperMethod.encode, '(${value.runtimeType})', e),
          stacktrace,
        );
      }
    } else {
      throw MapperException.chain(
        MapperMethod.encode,
        '[$value]',
        MapperException.unknownType(value.runtimeType),
      );
    }
  }

  @override
  T fromMap<T>(Map<String, dynamic> map) => fromValue<T>(map);

  @override
  Map<String, dynamic> toMap<T>(T object) {
    var value = toValue<T>(object);
    if (value is Map<String, dynamic>) {
      return value;
    } else {
      throw MapperException.incorrectEncoding(
          object.runtimeType, 'Map', value.runtimeType);
    }
  }

  @override
  T fromIterable<T>(Iterable<dynamic> iterable) => fromValue<T>(iterable);

  @override
  Iterable<dynamic> toIterable<T>(T object) {
    var value = toValue<T>(object);
    if (value is Iterable<dynamic>) {
      return value;
    } else {
      throw MapperException.incorrectEncoding(
          object.runtimeType, 'Iterable', value.runtimeType);
    }
  }

  @override
  T fromJson<T>(String json) => fromValue<T>(jsonDecode(json));

  @override
  String toJson<T>(T object) => jsonEncode(toValue<T>(object));

  @override
  bool isEqual(Object? value, Object? other) {
    if (value == null) {
      return other == null;
    }
    return guardMappable(
      value,
      (m, v, c) => m.isFor(other) && m.equals(v, other!, c),
      () => value == other,
      MapperMethod.equals,
      () => '[$value]',
    );
  }

  @override
  int hash(Object? value) {
    if (value == null) {
      return value.hashCode;
    }
    return guardMappable(
      value,
      (m, v, c) => m.hash(v, c),
      () => value.hashCode,
      MapperMethod.hash,
      () => '[$value]',
    );
  }

  @override
  String asString(Object? value) {
    if (value == null) {
      return value.toString();
    }
    return guardMappable(
      value,
      (m, v, c) => m.stringify(v, c),
      () => value.toString(),
      MapperMethod.stringify,
      () => '(Instance of \'${value.runtimeType}\')',
    );
  }

  T guardMappable<T>(
    Object value,
    T Function(MapperBase, Object, MappingContext) fn,
    T Function() fallback,
    MapperMethod method,
    String Function() hint,
  ) {
    var mapper = _mapperFor(value);
    if (mapper != null) {
      try {
        return fn(mapper, value, MappingContext(container: this));
      } catch (e, stacktrace) {
        Error.throwWithStackTrace(
          MapperException.chain(method, hint(), e),
          stacktrace,
        );
      }
    } else {
      return fallback();
    }
  }

  @override
  void use<T extends Object>(MapperBase<T> mapper) => useAll([mapper]);

  @override
  MapperBase<T>? unuse<T extends Object>() {
    var mapper = _mappers.remove(T.base) as MapperBase<T>?;
    _invalidateCachedMappers();
    return mapper;
  }

  @override
  void useAll(Iterable<MapperBase> mappers) {
    _mappers.addEntries(mappers.map((m) => MapEntry(m.type, m)));
    _invalidateCachedMappers();
  }

  @override
  MapperBase<T>? get<T extends Object>([Type? type]) {
    return _mappers[(type ?? T).base] as MapperBase<T>?;
  }

  @override
  List<MapperBase> getAll() {
    return [..._mappers.values];
  }

  @override
  void link(MapperContainer container) => linkAll({container});

  @override
  void linkAll(Iterable<MapperContainer> containers) {
    assert(containers.every((c) => c is _MapperContainerBase));
    for (var c in containers.cast<_MapperContainerBase>()) {
      _children.add(c);
      c._parents.add(this);
    }
    _invalidateCachedMappers();
  }
}
