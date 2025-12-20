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

class HolePunch_Type extends $pb.ProtobufEnum {
  static const HolePunch_Type CONNECT =
      HolePunch_Type._(100, _omitEnumNames ? '' : 'CONNECT');
  static const HolePunch_Type SYNC =
      HolePunch_Type._(300, _omitEnumNames ? '' : 'SYNC');

  static const $core.List<HolePunch_Type> values = <HolePunch_Type>[
    CONNECT,
    SYNC,
  ];

  static final $core.Map<$core.int, HolePunch_Type> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static HolePunch_Type? valueOf($core.int value) => _byValue[value];

  const HolePunch_Type._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
