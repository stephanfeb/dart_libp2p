// This is a generated file - do not edit.
//
// Generated from holepunch.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'holepunch.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'holepunch.pbenum.dart';

/// spec: https://github.com/libp2p/specs/blob/master/relay/DCUtR.md
class HolePunch extends $pb.GeneratedMessage {
  factory HolePunch({
    HolePunch_Type? type,
    $core.Iterable<$core.List<$core.int>>? obsAddrs,
  }) {
    final result = create();
    if (type != null) result.type = type;
    if (obsAddrs != null) result.obsAddrs.addAll(obsAddrs);
    return result;
  }

  HolePunch._();

  factory HolePunch.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HolePunch.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HolePunch',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'holepunch.pb'),
      createEmptyInstance: create)
    ..aE<HolePunch_Type>(1, _omitFieldNames ? '' : 'type',
        fieldType: $pb.PbFieldType.QE, enumValues: HolePunch_Type.values)
    ..p<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'ObsAddrs', $pb.PbFieldType.PY,
        protoName: 'ObsAddrs');

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HolePunch clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HolePunch copyWith(void Function(HolePunch) updates) =>
      super.copyWith((message) => updates(message as HolePunch)) as HolePunch;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HolePunch create() => HolePunch._();
  @$core.override
  HolePunch createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HolePunch getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<HolePunch>(create);
  static HolePunch? _defaultInstance;

  @$pb.TagNumber(1)
  HolePunch_Type get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(HolePunch_Type value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.List<$core.int>> get obsAddrs => $_getList(1);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
