// This is a generated file - do not edit.
//
// Generated from voucher.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class ReservationVoucher extends $pb.GeneratedMessage {
  factory ReservationVoucher({
    $core.List<$core.int>? relay,
    $core.List<$core.int>? peer,
    $fixnum.Int64? expiration,
  }) {
    final result = create();
    if (relay != null) result.relay = relay;
    if (peer != null) result.peer = peer;
    if (expiration != null) result.expiration = expiration;
    return result;
  }

  ReservationVoucher._();

  factory ReservationVoucher.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReservationVoucher.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReservationVoucher',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'circuit.pb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'relay', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'peer', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'expiration', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReservationVoucher clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReservationVoucher copyWith(void Function(ReservationVoucher) updates) =>
      super.copyWith((message) => updates(message as ReservationVoucher))
          as ReservationVoucher;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReservationVoucher create() => ReservationVoucher._();
  @$core.override
  ReservationVoucher createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReservationVoucher getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReservationVoucher>(create);
  static ReservationVoucher? _defaultInstance;

  /// These fields are marked optional for backwards compatibility with proto2.
  /// Users should make sure to always set these.
  @$pb.TagNumber(1)
  $core.List<$core.int> get relay => $_getN(0);
  @$pb.TagNumber(1)
  set relay($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasRelay() => $_has(0);
  @$pb.TagNumber(1)
  void clearRelay() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get peer => $_getN(1);
  @$pb.TagNumber(2)
  set peer($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPeer() => $_has(1);
  @$pb.TagNumber(2)
  void clearPeer() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get expiration => $_getI64(2);
  @$pb.TagNumber(3)
  set expiration($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasExpiration() => $_has(2);
  @$pb.TagNumber(3)
  void clearExpiration() => $_clearField(3);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
