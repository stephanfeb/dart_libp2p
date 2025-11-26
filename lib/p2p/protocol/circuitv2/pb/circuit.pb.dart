// This is a generated file - do not edit.
//
// Generated from circuit.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'circuit.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'circuit.pbenum.dart';

class HopMessage extends $pb.GeneratedMessage {
  factory HopMessage({
    HopMessage_Type? type,
    Peer? peer,
    Reservation? reservation,
    Limit? limit,
    Status? status,
  }) {
    final result = create();
    if (type != null) result.type = type;
    if (peer != null) result.peer = peer;
    if (reservation != null) result.reservation = reservation;
    if (limit != null) result.limit = limit;
    if (status != null) result.status = status;
    return result;
  }

  HopMessage._();

  factory HopMessage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HopMessage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HopMessage',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'circuit.pb'),
      createEmptyInstance: create)
    ..aE<HopMessage_Type>(1, _omitFieldNames ? '' : 'type',
        enumValues: HopMessage_Type.values)
    ..aOM<Peer>(2, _omitFieldNames ? '' : 'peer', subBuilder: Peer.create)
    ..aOM<Reservation>(3, _omitFieldNames ? '' : 'reservation',
        subBuilder: Reservation.create)
    ..aOM<Limit>(4, _omitFieldNames ? '' : 'limit', subBuilder: Limit.create)
    ..aE<Status>(5, _omitFieldNames ? '' : 'status', enumValues: Status.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HopMessage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HopMessage copyWith(void Function(HopMessage) updates) =>
      super.copyWith((message) => updates(message as HopMessage)) as HopMessage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HopMessage create() => HopMessage._();
  @$core.override
  HopMessage createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HopMessage getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HopMessage>(create);
  static HopMessage? _defaultInstance;

  /// This field is marked optional for backwards compatibility with proto2.
  /// Users should make sure to always set this.
  @$pb.TagNumber(1)
  HopMessage_Type get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(HopMessage_Type value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => $_clearField(1);

  @$pb.TagNumber(2)
  Peer get peer => $_getN(1);
  @$pb.TagNumber(2)
  set peer(Peer value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPeer() => $_has(1);
  @$pb.TagNumber(2)
  void clearPeer() => $_clearField(2);
  @$pb.TagNumber(2)
  Peer ensurePeer() => $_ensure(1);

  @$pb.TagNumber(3)
  Reservation get reservation => $_getN(2);
  @$pb.TagNumber(3)
  set reservation(Reservation value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasReservation() => $_has(2);
  @$pb.TagNumber(3)
  void clearReservation() => $_clearField(3);
  @$pb.TagNumber(3)
  Reservation ensureReservation() => $_ensure(2);

  @$pb.TagNumber(4)
  Limit get limit => $_getN(3);
  @$pb.TagNumber(4)
  set limit(Limit value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasLimit() => $_has(3);
  @$pb.TagNumber(4)
  void clearLimit() => $_clearField(4);
  @$pb.TagNumber(4)
  Limit ensureLimit() => $_ensure(3);

  @$pb.TagNumber(5)
  Status get status => $_getN(4);
  @$pb.TagNumber(5)
  set status(Status value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasStatus() => $_has(4);
  @$pb.TagNumber(5)
  void clearStatus() => $_clearField(5);
}

class StopMessage extends $pb.GeneratedMessage {
  factory StopMessage({
    StopMessage_Type? type,
    Peer? peer,
    Limit? limit,
    Status? status,
  }) {
    final result = create();
    if (type != null) result.type = type;
    if (peer != null) result.peer = peer;
    if (limit != null) result.limit = limit;
    if (status != null) result.status = status;
    return result;
  }

  StopMessage._();

  factory StopMessage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory StopMessage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StopMessage',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'circuit.pb'),
      createEmptyInstance: create)
    ..aE<StopMessage_Type>(1, _omitFieldNames ? '' : 'type',
        enumValues: StopMessage_Type.values)
    ..aOM<Peer>(2, _omitFieldNames ? '' : 'peer', subBuilder: Peer.create)
    ..aOM<Limit>(3, _omitFieldNames ? '' : 'limit', subBuilder: Limit.create)
    ..aE<Status>(4, _omitFieldNames ? '' : 'status', enumValues: Status.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopMessage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopMessage copyWith(void Function(StopMessage) updates) =>
      super.copyWith((message) => updates(message as StopMessage))
          as StopMessage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StopMessage create() => StopMessage._();
  @$core.override
  StopMessage createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StopMessage getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StopMessage>(create);
  static StopMessage? _defaultInstance;

  /// This field is marked optional for backwards compatibility with proto2.
  /// Users should make sure to always set this.
  @$pb.TagNumber(1)
  StopMessage_Type get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(StopMessage_Type value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => $_clearField(1);

  @$pb.TagNumber(2)
  Peer get peer => $_getN(1);
  @$pb.TagNumber(2)
  set peer(Peer value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPeer() => $_has(1);
  @$pb.TagNumber(2)
  void clearPeer() => $_clearField(2);
  @$pb.TagNumber(2)
  Peer ensurePeer() => $_ensure(1);

  @$pb.TagNumber(3)
  Limit get limit => $_getN(2);
  @$pb.TagNumber(3)
  set limit(Limit value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasLimit() => $_has(2);
  @$pb.TagNumber(3)
  void clearLimit() => $_clearField(3);
  @$pb.TagNumber(3)
  Limit ensureLimit() => $_ensure(2);

  @$pb.TagNumber(4)
  Status get status => $_getN(3);
  @$pb.TagNumber(4)
  set status(Status value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasStatus() => $_has(3);
  @$pb.TagNumber(4)
  void clearStatus() => $_clearField(4);
}

class Peer extends $pb.GeneratedMessage {
  factory Peer({
    $core.List<$core.int>? id,
    $core.Iterable<$core.List<$core.int>>? addrs,
  }) {
    final result = create();
    if (id != null) result.id = id;
    if (addrs != null) result.addrs.addAll(addrs);
    return result;
  }

  Peer._();

  factory Peer.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Peer.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Peer',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'circuit.pb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'id', $pb.PbFieldType.OY)
    ..p<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'addrs', $pb.PbFieldType.PY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Peer clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Peer copyWith(void Function(Peer) updates) =>
      super.copyWith((message) => updates(message as Peer)) as Peer;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Peer create() => Peer._();
  @$core.override
  Peer createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Peer getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Peer>(create);
  static Peer? _defaultInstance;

  /// This field is marked optional for backwards compatibility with proto2.
  /// Users should make sure to always set this.
  @$pb.TagNumber(1)
  $core.List<$core.int> get id => $_getN(0);
  @$pb.TagNumber(1)
  set id($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.List<$core.int>> get addrs => $_getList(1);
}

class Reservation extends $pb.GeneratedMessage {
  factory Reservation({
    $fixnum.Int64? expire,
    $core.Iterable<$core.List<$core.int>>? addrs,
    $core.List<$core.int>? voucher,
  }) {
    final result = create();
    if (expire != null) result.expire = expire;
    if (addrs != null) result.addrs.addAll(addrs);
    if (voucher != null) result.voucher = voucher;
    return result;
  }

  Reservation._();

  factory Reservation.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Reservation.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Reservation',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'circuit.pb'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'expire', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..p<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'addrs', $pb.PbFieldType.PY)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'voucher', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Reservation clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Reservation copyWith(void Function(Reservation) updates) =>
      super.copyWith((message) => updates(message as Reservation))
          as Reservation;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Reservation create() => Reservation._();
  @$core.override
  Reservation createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Reservation getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Reservation>(create);
  static Reservation? _defaultInstance;

  /// This field is marked optional for backwards compatibility with proto2.
  /// Users should make sure to always set this.
  @$pb.TagNumber(1)
  $fixnum.Int64 get expire => $_getI64(0);
  @$pb.TagNumber(1)
  set expire($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasExpire() => $_has(0);
  @$pb.TagNumber(1)
  void clearExpire() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.List<$core.int>> get addrs => $_getList(1);

  @$pb.TagNumber(3)
  $core.List<$core.int> get voucher => $_getN(2);
  @$pb.TagNumber(3)
  set voucher($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasVoucher() => $_has(2);
  @$pb.TagNumber(3)
  void clearVoucher() => $_clearField(3);
}

class Limit extends $pb.GeneratedMessage {
  factory Limit({
    $core.int? duration,
    $fixnum.Int64? data,
  }) {
    final result = create();
    if (duration != null) result.duration = duration;
    if (data != null) result.data = data;
    return result;
  }

  Limit._();

  factory Limit.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Limit.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Limit',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'circuit.pb'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'duration', fieldType: $pb.PbFieldType.OU3)
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Limit clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Limit copyWith(void Function(Limit) updates) =>
      super.copyWith((message) => updates(message as Limit)) as Limit;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Limit create() => Limit._();
  @$core.override
  Limit createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Limit getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Limit>(create);
  static Limit? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get duration => $_getIZ(0);
  @$pb.TagNumber(1)
  set duration($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDuration() => $_has(0);
  @$pb.TagNumber(1)
  void clearDuration() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get data => $_getI64(1);
  @$pb.TagNumber(2)
  set data($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasData() => $_has(1);
  @$pb.TagNumber(2)
  void clearData() => $_clearField(2);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
