import 'dart:async';
import 'dart:mirrors';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import "package:serializer/serializer.dart";
import 'package:source_gen/source_gen.dart';

bool _logDebug = false;

// Copied from pkg/source_gen - lib/src/utils.
String friendlyNameForElement(Element element) {
  var friendlyName = element.displayName;

  if (friendlyName == null) {
    throw new ArgumentError('Cannot get friendly name for $element - ${element.runtimeType}.');
  }

  var names = <String>[friendlyName];
  if (element is ClassElement) {
    names.insert(0, 'class');
    if (element.isAbstract) {
      names.insert(0, 'abstract');
    }
  }
  if (element is VariableElement) {
    names.insert(0, element.type.toString());

    if (element.isConst) {
      names.insert(0, 'const');
    }

    if (element.isFinal) {
      names.insert(0, 'final');
    }
  }
  if (element is LibraryElement) {
    names.insert(0, 'library');
  }

  return names.join(' ');
}

void closeBrace(StringBuffer buffer) => buffer.writeln("}");

void generateClass(StringBuffer buffer, String classType, String name, [String extendsClass]) {
  buffer.writeln("$classType $name ${extendsClass != null ? 'extends $extendsClass' : ''} {");
}

void generateFunction(
    StringBuffer buffer, String returnType, String name, List<String> parameters, List<String> namedParameters) {
  buffer.writeln(
      "$returnType $name(${parameters.join((", "))}${namedParameters?.isNotEmpty == true ? ",{${namedParameters.join(", ")}}" : ''}) {");
}

void generateGetter(StringBuffer buffer, String returnType, String name, String value) {
  buffer.writeln("$returnType get $name => $value;");
}

void import(StringBuffer buffer, String import, {List<String> show, String as}) => buffer.writeln(
    "import '$import' ${show?.isNotEmpty == true ? "show ${show.join(",")}" : as?.isNotEmpty == true ? "as $as" : ""};");

void semiColumn(StringBuffer buffer) => buffer.writeln(";");

class SerializerGenerator extends GeneratorForAnnotation<Serializable> {
  final String library;

  Map<AssetId, StringBuffer> _codecsBuffer = <AssetId, StringBuffer>{};

  SerializerGenerator(this.library);

  String codescMapAsString(AssetId inputId) => (_codecsBuffer[inputId]..writeln("};")).toString();

  @override
  Future<String> generate(LibraryReader libraryReader, BuildStep buildStep) async {
    StringBuffer buffer = new StringBuffer();

    buffer.writeln("library ${buildStep.inputId.path.split("/").last.split(".").first}.codec;");
    import(buffer, "package:serializer/core.dart", show: ["Serializer", "cleanNullInMap"]);
    import(buffer, "package:serializer/codecs.dart");
    import(buffer, buildStep.inputId.path.split("/").last);

    initCodecsBuffer(buildStep.inputId);
    buffer.write(await super.generate(libraryReader, buildStep));

    String codecMapName = buildStep.inputId.path.split(".").first.replaceAll("/", "_");
    buffer.writeln("Map<String, TypeCodec<dynamic>> ${codecMapName}_codecs = ${codescMapAsString(buildStep.inputId)}");

    return buffer.toString();
  }

  @override
  FutureOr<String> generateForAnnotatedElement(Element element, ConstantReader annotation, BuildStep buildStep) {
    if (element is! ClassElement) {
      var friendlyName = friendlyNameForElement(element);
      throw new InvalidGenerationSourceError('Generator cannot target `$friendlyName`.',
          todo: 'Remove the Serializable annotation from `$friendlyName`.');
    }

    var classElement = element as ClassElement;
    var buffer = new StringBuffer();
    if (_isClassSerializable(element) == true && classElement.isAbstract == false && classElement.isPrivate == false) {
      Map<String, Field> fields = _getFields(classElement);
      _classCodec(buffer, classElement.displayName);
      _generateDecode(buffer, classElement, fields);
      _generateEncode(buffer, classElement, fields);
      _generateUtils(buffer, classElement);

      closeBrace(buffer);

      _codecsBuffer[buildStep.inputId].writeln("'${element.displayName}': new ${element.displayName}Codec(),");
    }
    return buffer.toString();
  }

  void initCodecsBuffer(AssetId inputId) {
    _codecsBuffer[inputId] = new StringBuffer("<String,TypeCodec<dynamic>>{");
  }

  String _withTypeInfo(Field field) {
    if (field.useType == null && (field.serializeWithTypeInfo || field.type.toString() == "dynamic")) {
      return "true";
    }
    return "false";
  }

  void _classCodec(StringBuffer buffer, String className) =>
      generateClass(buffer, "class", "${className}Codec", "TypeCodec<$className>");

  String _findGenericOfList(DartType type) {
    if (type is ParameterizedType) {
      if (type.typeArguments.length == 1) {
        var name = type.typeArguments[0].name;
        return name;
      }
    }
    return null;
  }

  String _findGenericOfMap(DartType type) {
    if (type is ParameterizedType) {
      if (type.typeArguments.length == 2) {
        var name = type.typeArguments[1].name;
        return name;
      }
    }
    return null;
  }

  bool _decodeWithTypeInfo(Field field) {
    if (field.useType == null) {
      Element elem = field.type.element;

      return field.type.element.displayName == "dynamic" ||
          field.serializeWithTypeInfo == true ||
          (_isClassSerializable(elem) == true && (elem as ClassElement).isAbstract == true);
    }
    return false;
  }

  List<String> _numTypes = ["int", "double"];

  String _toNum(String value, String type) {
    if (type == "int") {
      return "$value?.toInt()";
    } else {
      return "$value?.toDouble()";
    }
  }

  String _castNum(String value, String type) {
    if (type == "int") {
      return "($value as num)?.toInt()";
    } else {
      return "($value as num)?.toDouble()";
    }
  }

  String _castType(String value, Field field, [bool as = true]) {
    String type = field.useType ?? field.type.toString();
    if (as == true) {
      if (_numTypes.contains(type)) {
        return _castNum(value, type);
      }
      return "$value as $type";
    } else {
      if (_numTypes.contains(type)) {
        return _toNum(value, type);
      }
    }
    return value;
  }

  void _debug(StringBuffer buffer, String log) {
    if (_logDebug == true) {
      buffer.writeln(log);
    }
  }

  void _generateDecode(StringBuffer buffer, ClassElement element, Map<String, Field> fields) {
    buffer.writeln("@override");
    generateFunction(buffer, "${element.displayName}", "decode", ["dynamic value"], ["Serializer serializer"]);

    buffer.writeln("${element.displayName} obj = new ${element.displayName}();");

    fields.forEach((String name, Field field) {
      if (field.isSetter && field.ignore == false) {
        String genericType = _getType(field).split("<").first;
        if (field.useType != null) {
          genericType = field.useType;
        }
        if (isPrimaryTypeString(genericType) && genericType == "${field.type}") {
          _debug(buffer, "// decode with primary type");
          var value = "value['${field.key}']";
          buffer.write("obj.$name = ${_castType(value, field)}");
        } else if (_decodeWithTypeInfo(field)) {
          _debug(buffer, "// decode with useType");
          buffer.write("obj.$name = serializer?.decode(value['${field.key}'], useTypeInfo: true) as ${field.type} ");
        } else if (field.type.toString().split("<").first == "Map") {
          _debug(buffer, "// decode as Map");
          buffer
              .writeln("Map _$name = serializer?.decode(value['${field.key}'], mapOf: const [String, $genericType]);");
          if (_numTypes.contains(genericType)) {
            _debug(buffer, "// With $genericType as num");
            var value = "_$name[key]";
            buffer.write(
                "obj.$name = (_$name != null ? new Map.fromIterable(_$name.keys, key: (key) => key as String, value: (key) => ${_castNum(value, genericType)}) : null)");
          } else {
            buffer.write("obj.$name = (_$name != null ? new Map.from(_$name) : null)");
          }
        } else {
          if (field.type.toString().split("<").first == "List") {
            _debug(buffer, "// decode as list of generic ($genericType)");
            buffer.writeln("List _$name = serializer?.decode(value['${field.key}'], type: $genericType);");
            if (_numTypes.contains(genericType)) {
              _debug(buffer, "// With $genericType as num");
              buffer.write(
                  "obj.$name = (_$name != null ? new List<$genericType>.from(_$name.map((item) => ${_castNum('item', genericType)})) : null)");
            } else if (genericType == "null") {
              buffer.write("obj.$name = _$name");
            } else {
              buffer.write("obj.$name = (_$name != null ? new List<$genericType>.from(_$name) : null)");
            }
          } else {
            _debug(buffer, "// decode as generic ($genericType)");
            buffer.write("obj.$name = serializer?.decode(value['${field.key}'], type: $genericType) as $genericType");
          }
        }
        buffer.writeln("?? obj.$name;");
      }
    });

    buffer.writeln("return obj;");

    closeBrace(buffer);
  }

  void _generateEncode(StringBuffer buffer, ClassElement element, Map<String, Field> fields) {
    buffer.writeln("@override");
    generateFunction(buffer, "dynamic", "encode", ["${element.displayName} value"],
        ["Serializer serializer", "bool useTypeInfo", "bool withTypeInfo"]);

    buffer.writeln("Map<String, dynamic> map = new Map<String, dynamic>();");

    buffer.writeln("if (serializer.enableTypeInfo(useTypeInfo, withTypeInfo)) {");
    buffer.writeln("map[serializer.typeInfoKey] = typeInfo;");
    closeBrace(buffer);
    fields.forEach((String name, Field field) {
      if (field.isGetter && field.ignore == false) {
        buffer.write("map['${field.key}'] = ");
        if (isPrimaryTypeString(_getType(field)) == false) {
          buffer.write(
              "serializer?.toPrimaryObject(value.$name, useTypeInfo: useTypeInfo, withTypeInfo: ${_withTypeInfo(field)} );");
        } else {
          var value = "value.$name";
          buffer.write("${_castType(value, field, false)};");
        }
      }
    });

    buffer.writeln("return cleanNullInMap(map);");

    closeBrace(buffer);
  }

  void _generateUtils(StringBuffer buffer, Element element) {
    buffer.writeln("@override");
    generateGetter(buffer, "String", "typeInfo", "'${element.displayName}'");
  }

  String _getType(Field field) {
    String t = _findGenericOfMap(field.type);
    if (t == null) {
      t = _findGenericOfList(field.type);
    }
    t ??= field.type.toString();
    if (t == "dynamic") {
      return "null";
    }
    return t;
  }

  //fixme dirty
  bool _isInSameLibrary(ClassElement element) {
    return element.displayName != "Object" && element.librarySource.fullName.split("|").first == library;
  }

  List<Element> _getFieldsFromMixins(ClassElement element) {
    var list = <Element>[];

    for (InterfaceType m in element.mixins) {
      for (InterfaceType s in m.element.allSupertypes) {
        if (_isInSameLibrary(s.element)) {
          list.addAll(s.element.accessors);
          list.addAll(s.element.fields);
          list.addAll(_getFieldsFromMixins(s.element));
        }
      }
      if (_isInSameLibrary(m.element)) {
        list.addAll(m.element.accessors);
        list.addAll(m.element.fields);
        list.addAll(_getFieldsFromMixins(m.element));
      }
    }
    return list;
  }

  Map<String, Field> _getFields(ClassElement element) {
    Map<String, Field> fields = {};

    var all = <Element>[];

    element.allSupertypes.forEach((InterfaceType t) {
      if (_isInSameLibrary(t.element)) {
        all.addAll(t.element.accessors);
        all.addAll(t.element.fields);
        all.addAll(_getFieldsFromMixins(t.element));
      }
    });
    all.addAll(_getFieldsFromMixins(element));
    all.addAll(element.accessors);
    all.addAll(element.fields);

    all.forEach((e) {
      if (e.isPrivate == false &&
          ((e is ClassMemberElement && e.isStatic == false) || (!(e is ClassMemberElement))) &&
          (e is PropertyAccessorElement || (e is FieldElement && e.isFinal == false))) {
        if (fields.containsKey(_getElementName(e)) == false && _isFieldSerializable(e) == true) {
          fields[_getElementName(e)] = new Field(e);
        } else {
          fields[_getElementName(e)]?.update(e);
        }
      }
    });

    return fields;
  }
}

class Field {
  String key;
  bool ignore;
  bool serializeWithTypeInfo;
  bool isSerializable;
  bool isGetter;
  bool isSetter;

  DartType type;
  String useType;

  Field(Element element) {
    isSerializable = _isFieldSerializable(element);
    update(element);
  }

  _setType(Element element) {
    useType ??= _getUseType(element);
    if (element is FieldElement) {
      type = element.type;
    } else if (element is PropertyAccessorElement) {
      if (isGetter == true) {
        type = element.returnType;
      } else if (isSetter == true) {
        type = element.type.normalParameterTypes.first;
      }
    }
  }

  _setIsGetter(Element element) {
    bool g;
    if (element is FieldElement) {
      g = true;
    } else if (element is PropertyAccessorElement) {
      g = element.isGetter;
    }
    if (isGetter != true) {
      isGetter = g;
    }
  }

  _setIsSetter(Element element) {
    bool s;
    if (element is FieldElement) {
      s = true;
    } else if (element is PropertyAccessorElement) {
      s = element.isSetter;
    }
    if (isSetter != true) {
      isSetter = s;
    }
  }

  _setKey(Element element) {
    String k = _getSerializedName(element);
    if ((key == element.name && k != element.name) || key == null) {
      key = k;
    }
  }

  _setIgnore(Element element) {
    if (ignore != true) {
      ignore = _ignoreField(element);
    }
  }

  _setSerializeWithType(Element element) {
    if (serializeWithTypeInfo != true) {
      serializeWithTypeInfo = _serializeFieldWithType(element);
    }
  }

  update(Element element) {
    _setIgnore(element);
    _setIsGetter(element);
    _setIsSetter(element);
    _setSerializeWithType(element);
    _setKey(element);
    _setType(element);
  }

  String toString() => {
        "name": key,
        "type": type?.displayName,
        "ignore": ignore,
        "serializeWithType": serializeWithTypeInfo,
        "isSerializable": isSerializable
      }.toString();
}

bool _ignoreField(Element field) =>
    field.metadata.firstWhere((ElementAnnotation a) => _matchAnnotation(Ignore, a), orElse: () => null) != null;
bool _serializeFieldWithType(Element field) =>
    field.metadata
        .firstWhere((ElementAnnotation a) => _matchAnnotation(SerializedWithTypeInfo, a), orElse: () => null) !=
    null;

//fixme: very dirty
String _getSerializedName(Element field) {
  String key = _getElementName(field);
  field.metadata.forEach((ElementAnnotation a) {
    if (a.toString().contains("@SerializedName(String name) → SerializedName")) {
      key = a.computeConstantValue().getField("name").toStringValue();
    }
  });
  return key;
}

//fixme: very dirty
String _getUseType(Element field) {
  String key = null;
  field.metadata.forEach((ElementAnnotation a) {
    if (a.toString().contains("@UseType(Type type) → UseType")) {
      key = a.computeConstantValue().getField("type").toTypeValue()?.toString();
    }
  });
  return key;
}

bool _matchAnnotation(Type annotationType, ElementAnnotation annotation) {
  try {
    var annotationValueType = annotation.computeConstantValue()?.type;
    if (annotationValueType == null) {
      throw new ArgumentError.value(
          annotation, 'annotation', 'Could not determine type of annotation. Are you missing a dependency?');
    }

    return _matchTypes(annotationType, annotationValueType);
  } catch (e, _) {
    //print(e);
    //print(s);
  }
  return false;
}

bool _matchTypes(Type annotationType, ParameterizedType annotationValueType) {
  var classMirror = reflectClass(annotationType);
  var classMirrorSymbol = classMirror.simpleName;

  var annTypeName = annotationValueType.name;
  var annotationTypeSymbol = new Symbol(annTypeName);

  if (classMirrorSymbol != annotationTypeSymbol) {
    return false;
  }

  var annotationLibSource = annotationValueType.element.library.source;

  var libOwnerUri = (classMirror.owner as LibraryMirror).uri;
  var annotationLibSourceUri = annotationLibSource.uri;

  if (annotationLibSourceUri.scheme == 'file' && libOwnerUri.scheme == 'package') {
    // try to turn the libOwnerUri into a file uri
    libOwnerUri = _fileUriFromPackageUri(libOwnerUri);
  } else if (annotationLibSourceUri.scheme == 'asset' && libOwnerUri.scheme == 'package') {
    // try to turn the libOwnerUri into a asset uri
    libOwnerUri = _assetUriFromPackageUri(libOwnerUri);
  }

  return annotationLibSource.uri == libOwnerUri;
}

Uri _fileUriFromPackageUri(Uri libraryPackageUri) {
  assert(libraryPackageUri.scheme == 'package');

  return libraryPackageUri;
}

Uri _assetUriFromPackageUri(Uri libraryPackageUri) {
  assert(libraryPackageUri.scheme == 'package');
  var originalSegments = libraryPackageUri.pathSegments;
  var newSegments = [originalSegments[0]]
    ..add('lib')
    ..addAll(originalSegments.getRange(1, originalSegments.length));

  return new Uri(scheme: 'asset', pathSegments: newSegments);
}

bool _isFieldSerializable(Element field) =>
    field is PropertyAccessorElement && field.isStatic == false && field.isPrivate == false;

bool _isClassSerializable(Element elem) =>
    elem is ClassElement && elem.metadata.any((ElementAnnotation a) => _matchAnnotation(Serializable, a)) == true;

String _getElementName(Element element) => element.name.split(("=")).first;
