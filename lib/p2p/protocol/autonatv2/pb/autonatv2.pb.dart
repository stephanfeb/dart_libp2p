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

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'autonatv2.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'autonatv2.pbenum.dart';

enum Message_Msg {
  dialRequest,
  dialResponse,
  dialDataRequest,
  dialDataResponse,
  notSet
}

class Message extends $pb.GeneratedMessage {
  factory Message({
    DialRequest? dialRequest,
    DialResponse? dialResponse,
    DialDataRequest? dialDataRequest,
    DialDataResponse? dialDataResponse,
  }) {
    final result = create();
    if (dialRequest != null) result.dialRequest = dialRequest;
    if (dialResponse != null) result.dialResponse = dialResponse;
    if (dialDataRequest != null) result.dialDataRequest = dialDataRequest;
    if (dialDataResponse != null) result.dialDataResponse = dialDataResponse;
    return result;
  }

  Message._();

  factory Message.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Message.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, Message_Msg> _Message_MsgByTag = {
    1: Message_Msg.dialRequest,
    2: Message_Msg.dialResponse,
    3: Message_Msg.dialDataRequest,
    4: Message_Msg.dialDataResponse,
    0: Message_Msg.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Message',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'autonatv2.pb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4])
    ..aOM<DialRequest>(1, _omitFieldNames ? '' : 'dialRequest',
        protoName: 'dialRequest', subBuilder: DialRequest.create)
    ..aOM<DialResponse>(2, _omitFieldNames ? '' : 'dialResponse',
        protoName: 'dialResponse', subBuilder: DialResponse.create)
    ..aOM<DialDataRequest>(3, _omitFieldNames ? '' : 'dialDataRequest',
        protoName: 'dialDataRequest', subBuilder: DialDataRequest.create)
    ..aOM<DialDataResponse>(4, _omitFieldNames ? '' : 'dialDataResponse',
        protoName: 'dialDataResponse', subBuilder: DialDataResponse.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Message clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Message copyWith(void Function(Message) updates) =>
      super.copyWith((message) => updates(message as Message)) as Message;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Message create() => Message._();
  @$core.override
  Message createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Message getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Message>(create);
  static Message? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  Message_Msg whichMsg() => _Message_MsgByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  void clearMsg() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  DialRequest get dialRequest => $_getN(0);
  @$pb.TagNumber(1)
  set dialRequest(DialRequest value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasDialRequest() => $_has(0);
  @$pb.TagNumber(1)
  void clearDialRequest() => $_clearField(1);
  @$pb.TagNumber(1)
  DialRequest ensureDialRequest() => $_ensure(0);

  @$pb.TagNumber(2)
  DialResponse get dialResponse => $_getN(1);
  @$pb.TagNumber(2)
  set dialResponse(DialResponse value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasDialResponse() => $_has(1);
  @$pb.TagNumber(2)
  void clearDialResponse() => $_clearField(2);
  @$pb.TagNumber(2)
  DialResponse ensureDialResponse() => $_ensure(1);

  @$pb.TagNumber(3)
  DialDataRequest get dialDataRequest => $_getN(2);
  @$pb.TagNumber(3)
  set dialDataRequest(DialDataRequest value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasDialDataRequest() => $_has(2);
  @$pb.TagNumber(3)
  void clearDialDataRequest() => $_clearField(3);
  @$pb.TagNumber(3)
  DialDataRequest ensureDialDataRequest() => $_ensure(2);

  @$pb.TagNumber(4)
  DialDataResponse get dialDataResponse => $_getN(3);
  @$pb.TagNumber(4)
  set dialDataResponse(DialDataResponse value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasDialDataResponse() => $_has(3);
  @$pb.TagNumber(4)
  void clearDialDataResponse() => $_clearField(4);
  @$pb.TagNumber(4)
  DialDataResponse ensureDialDataResponse() => $_ensure(3);
}

class DialRequest extends $pb.GeneratedMessage {
  factory DialRequest({
    $core.Iterable<$core.List<$core.int>>? addrs,
    $fixnum.Int64? nonce,
  }) {
    final result = create();
    if (addrs != null) result.addrs.addAll(addrs);
    if (nonce != null) result.nonce = nonce;
    return result;
  }

  DialRequest._();

  factory DialRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DialRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DialRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'autonatv2.pb'),
      createEmptyInstance: create)
    ..p<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'addrs', $pb.PbFieldType.PY)
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'nonce', $pb.PbFieldType.OF6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialRequest copyWith(void Function(DialRequest) updates) =>
      super.copyWith((message) => updates(message as DialRequest))
          as DialRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DialRequest create() => DialRequest._();
  @$core.override
  DialRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DialRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DialRequest>(create);
  static DialRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.List<$core.int>> get addrs => $_getList(0);

  @$pb.TagNumber(2)
  $fixnum.Int64 get nonce => $_getI64(1);
  @$pb.TagNumber(2)
  set nonce($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNonce() => $_has(1);
  @$pb.TagNumber(2)
  void clearNonce() => $_clearField(2);
}

class DialDataRequest extends $pb.GeneratedMessage {
  factory DialDataRequest({
    $core.int? addrIdx,
    $fixnum.Int64? numBytes,
  }) {
    final result = create();
    if (addrIdx != null) result.addrIdx = addrIdx;
    if (numBytes != null) result.numBytes = numBytes;
    return result;
  }

  DialDataRequest._();

  factory DialDataRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DialDataRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DialDataRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'autonatv2.pb'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'addrIdx',
        protoName: 'addrIdx', fieldType: $pb.PbFieldType.OU3)
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'numBytes', $pb.PbFieldType.OU6,
        protoName: 'numBytes', defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialDataRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialDataRequest copyWith(void Function(DialDataRequest) updates) =>
      super.copyWith((message) => updates(message as DialDataRequest))
          as DialDataRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DialDataRequest create() => DialDataRequest._();
  @$core.override
  DialDataRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DialDataRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DialDataRequest>(create);
  static DialDataRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get addrIdx => $_getIZ(0);
  @$pb.TagNumber(1)
  set addrIdx($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAddrIdx() => $_has(0);
  @$pb.TagNumber(1)
  void clearAddrIdx() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get numBytes => $_getI64(1);
  @$pb.TagNumber(2)
  set numBytes($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNumBytes() => $_has(1);
  @$pb.TagNumber(2)
  void clearNumBytes() => $_clearField(2);
}

class DialResponse extends $pb.GeneratedMessage {
  factory DialResponse({
    DialResponse_ResponseStatus? status,
    $core.int? addrIdx,
    DialStatus? dialStatus,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (addrIdx != null) result.addrIdx = addrIdx;
    if (dialStatus != null) result.dialStatus = dialStatus;
    return result;
  }

  DialResponse._();

  factory DialResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DialResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DialResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'autonatv2.pb'),
      createEmptyInstance: create)
    ..aE<DialResponse_ResponseStatus>(1, _omitFieldNames ? '' : 'status',
        enumValues: DialResponse_ResponseStatus.values)
    ..aI(2, _omitFieldNames ? '' : 'addrIdx',
        protoName: 'addrIdx', fieldType: $pb.PbFieldType.OU3)
    ..aE<DialStatus>(3, _omitFieldNames ? '' : 'dialStatus',
        protoName: 'dialStatus', enumValues: DialStatus.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialResponse copyWith(void Function(DialResponse) updates) =>
      super.copyWith((message) => updates(message as DialResponse))
          as DialResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DialResponse create() => DialResponse._();
  @$core.override
  DialResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DialResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DialResponse>(create);
  static DialResponse? _defaultInstance;

  @$pb.TagNumber(1)
  DialResponse_ResponseStatus get status => $_getN(0);
  @$pb.TagNumber(1)
  set status(DialResponse_ResponseStatus value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get addrIdx => $_getIZ(1);
  @$pb.TagNumber(2)
  set addrIdx($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAddrIdx() => $_has(1);
  @$pb.TagNumber(2)
  void clearAddrIdx() => $_clearField(2);

  @$pb.TagNumber(3)
  DialStatus get dialStatus => $_getN(2);
  @$pb.TagNumber(3)
  set dialStatus(DialStatus value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasDialStatus() => $_has(2);
  @$pb.TagNumber(3)
  void clearDialStatus() => $_clearField(3);
}

class DialDataResponse extends $pb.GeneratedMessage {
  factory DialDataResponse({
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (data != null) result.data = data;
    return result;
  }

  DialDataResponse._();

  factory DialDataResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DialDataResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DialDataResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'autonatv2.pb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialDataResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialDataResponse copyWith(void Function(DialDataResponse) updates) =>
      super.copyWith((message) => updates(message as DialDataResponse))
          as DialDataResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DialDataResponse create() => DialDataResponse._();
  @$core.override
  DialDataResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DialDataResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DialDataResponse>(create);
  static DialDataResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get data => $_getN(0);
  @$pb.TagNumber(1)
  set data($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
}

class DialBack extends $pb.GeneratedMessage {
  factory DialBack({
    $fixnum.Int64? nonce,
  }) {
    final result = create();
    if (nonce != null) result.nonce = nonce;
    return result;
  }

  DialBack._();

  factory DialBack.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DialBack.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DialBack',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'autonatv2.pb'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'nonce', $pb.PbFieldType.OF6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialBack clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialBack copyWith(void Function(DialBack) updates) =>
      super.copyWith((message) => updates(message as DialBack)) as DialBack;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DialBack create() => DialBack._();
  @$core.override
  DialBack createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DialBack getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<DialBack>(create);
  static DialBack? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get nonce => $_getI64(0);
  @$pb.TagNumber(1)
  set nonce($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasNonce() => $_has(0);
  @$pb.TagNumber(1)
  void clearNonce() => $_clearField(1);
}

class DialBackResponse extends $pb.GeneratedMessage {
  factory DialBackResponse({
    DialBackResponse_DialBackStatus? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  DialBackResponse._();

  factory DialBackResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DialBackResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DialBackResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'autonatv2.pb'),
      createEmptyInstance: create)
    ..aE<DialBackResponse_DialBackStatus>(1, _omitFieldNames ? '' : 'status',
        enumValues: DialBackResponse_DialBackStatus.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialBackResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DialBackResponse copyWith(void Function(DialBackResponse) updates) =>
      super.copyWith((message) => updates(message as DialBackResponse))
          as DialBackResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DialBackResponse create() => DialBackResponse._();
  @$core.override
  DialBackResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DialBackResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DialBackResponse>(create);
  static DialBackResponse? _defaultInstance;

  @$pb.TagNumber(1)
  DialBackResponse_DialBackStatus get status => $_getN(0);
  @$pb.TagNumber(1)
  set status(DialBackResponse_DialBackStatus value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
