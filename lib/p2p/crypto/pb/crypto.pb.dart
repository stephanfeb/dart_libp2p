// This is a generated file - do not edit.
//
// Generated from crypto.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'crypto.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'crypto.pbenum.dart';

class PublicKey extends $pb.GeneratedMessage {
  factory PublicKey({
    KeyType? type,
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (type != null) result.type = type;
    if (data != null) result.data = data;
    return result;
  }

  PublicKey._();

  factory PublicKey.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PublicKey.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PublicKey',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'crypto.pb'),
      createEmptyInstance: create)
    ..aE<KeyType>(1, _omitFieldNames ? '' : 'Type',
        protoName: 'Type',
        fieldType: $pb.PbFieldType.QE,
        enumValues: KeyType.values)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'Data', $pb.PbFieldType.QY,
        protoName: 'Data');

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublicKey clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublicKey copyWith(void Function(PublicKey) updates) =>
      super.copyWith((message) => updates(message as PublicKey)) as PublicKey;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PublicKey create() => PublicKey._();
  @$core.override
  PublicKey createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PublicKey getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PublicKey>(create);
  static PublicKey? _defaultInstance;

  @$pb.TagNumber(1)
  KeyType get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(KeyType value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get data => $_getN(1);
  @$pb.TagNumber(2)
  set data($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasData() => $_has(1);
  @$pb.TagNumber(2)
  void clearData() => $_clearField(2);
}

class PrivateKey extends $pb.GeneratedMessage {
  factory PrivateKey({
    KeyType? type,
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (type != null) result.type = type;
    if (data != null) result.data = data;
    return result;
  }

  PrivateKey._();

  factory PrivateKey.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PrivateKey.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PrivateKey',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'crypto.pb'),
      createEmptyInstance: create)
    ..aE<KeyType>(1, _omitFieldNames ? '' : 'Type',
        protoName: 'Type',
        fieldType: $pb.PbFieldType.QE,
        enumValues: KeyType.values)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'Data', $pb.PbFieldType.QY,
        protoName: 'Data');

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PrivateKey clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PrivateKey copyWith(void Function(PrivateKey) updates) =>
      super.copyWith((message) => updates(message as PrivateKey)) as PrivateKey;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PrivateKey create() => PrivateKey._();
  @$core.override
  PrivateKey createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PrivateKey getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PrivateKey>(create);
  static PrivateKey? _defaultInstance;

  @$pb.TagNumber(1)
  KeyType get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(KeyType value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get data => $_getN(1);
  @$pb.TagNumber(2)
  set data($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasData() => $_has(1);
  @$pb.TagNumber(2)
  void clearData() => $_clearField(2);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
