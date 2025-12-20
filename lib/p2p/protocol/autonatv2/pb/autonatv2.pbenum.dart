// This is a generated file - do not edit.
//
// Generated from autonatv2.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class DialStatus extends $pb.ProtobufEnum {
  static const DialStatus UNUSED =
      DialStatus._(0, _omitEnumNames ? '' : 'UNUSED');
  static const DialStatus E_DIAL_ERROR =
      DialStatus._(100, _omitEnumNames ? '' : 'E_DIAL_ERROR');
  static const DialStatus E_DIAL_BACK_ERROR =
      DialStatus._(101, _omitEnumNames ? '' : 'E_DIAL_BACK_ERROR');
  static const DialStatus OK = DialStatus._(200, _omitEnumNames ? '' : 'OK');

  static const $core.List<DialStatus> values = <DialStatus>[
    UNUSED,
    E_DIAL_ERROR,
    E_DIAL_BACK_ERROR,
    OK,
  ];

  static final $core.Map<$core.int, DialStatus> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static DialStatus? valueOf($core.int value) => _byValue[value];

  const DialStatus._(super.value, super.name);
}

class DialResponse_ResponseStatus extends $pb.ProtobufEnum {
  static const DialResponse_ResponseStatus E_INTERNAL_ERROR =
      DialResponse_ResponseStatus._(
          0, _omitEnumNames ? '' : 'E_INTERNAL_ERROR');
  static const DialResponse_ResponseStatus E_REQUEST_REJECTED =
      DialResponse_ResponseStatus._(
          100, _omitEnumNames ? '' : 'E_REQUEST_REJECTED');
  static const DialResponse_ResponseStatus E_DIAL_REFUSED =
      DialResponse_ResponseStatus._(
          101, _omitEnumNames ? '' : 'E_DIAL_REFUSED');
  static const DialResponse_ResponseStatus OK =
      DialResponse_ResponseStatus._(200, _omitEnumNames ? '' : 'OK');

  static const $core.List<DialResponse_ResponseStatus> values =
      <DialResponse_ResponseStatus>[
    E_INTERNAL_ERROR,
    E_REQUEST_REJECTED,
    E_DIAL_REFUSED,
    OK,
  ];

  static final $core.Map<$core.int, DialResponse_ResponseStatus> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static DialResponse_ResponseStatus? valueOf($core.int value) =>
      _byValue[value];

  const DialResponse_ResponseStatus._(super.value, super.name);
}

class DialBackResponse_DialBackStatus extends $pb.ProtobufEnum {
  static const DialBackResponse_DialBackStatus OK =
      DialBackResponse_DialBackStatus._(0, _omitEnumNames ? '' : 'OK');

  static const $core.List<DialBackResponse_DialBackStatus> values =
      <DialBackResponse_DialBackStatus>[
    OK,
  ];

  static final $core.List<DialBackResponse_DialBackStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 0);
  static DialBackResponse_DialBackStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const DialBackResponse_DialBackStatus._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
