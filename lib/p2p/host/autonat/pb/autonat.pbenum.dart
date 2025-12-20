// This is a generated file - do not edit.
//
// Generated from autonat.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class Message_MessageType extends $pb.ProtobufEnum {
  static const Message_MessageType DIAL =
      Message_MessageType._(0, _omitEnumNames ? '' : 'DIAL');
  static const Message_MessageType DIAL_RESPONSE =
      Message_MessageType._(1, _omitEnumNames ? '' : 'DIAL_RESPONSE');

  static const $core.List<Message_MessageType> values = <Message_MessageType>[
    DIAL,
    DIAL_RESPONSE,
  ];

  static final $core.List<Message_MessageType?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static Message_MessageType? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Message_MessageType._(super.value, super.name);
}

class Message_ResponseStatus extends $pb.ProtobufEnum {
  static const Message_ResponseStatus OK =
      Message_ResponseStatus._(0, _omitEnumNames ? '' : 'OK');
  static const Message_ResponseStatus E_DIAL_ERROR =
      Message_ResponseStatus._(100, _omitEnumNames ? '' : 'E_DIAL_ERROR');
  static const Message_ResponseStatus E_DIAL_REFUSED =
      Message_ResponseStatus._(101, _omitEnumNames ? '' : 'E_DIAL_REFUSED');
  static const Message_ResponseStatus E_BAD_REQUEST =
      Message_ResponseStatus._(200, _omitEnumNames ? '' : 'E_BAD_REQUEST');
  static const Message_ResponseStatus E_INTERNAL_ERROR =
      Message_ResponseStatus._(300, _omitEnumNames ? '' : 'E_INTERNAL_ERROR');

  static const $core.List<Message_ResponseStatus> values =
      <Message_ResponseStatus>[
    OK,
    E_DIAL_ERROR,
    E_DIAL_REFUSED,
    E_BAD_REQUEST,
    E_INTERNAL_ERROR,
  ];

  static final $core.Map<$core.int, Message_ResponseStatus> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static Message_ResponseStatus? valueOf($core.int value) => _byValue[value];

  const Message_ResponseStatus._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
