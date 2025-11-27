// This is a generated file - do not edit.
//
// Generated from peer_record.proto.

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

/// AddressInfo is a wrapper around a binary multiaddr. It is defined as a
/// separate message to allow us to add per-address metadata in the future.
class PeerRecord_AddressInfo extends $pb.GeneratedMessage {
  factory PeerRecord_AddressInfo({
    $core.List<$core.int>? multiaddr,
  }) {
    final result = create();
    if (multiaddr != null) result.multiaddr = multiaddr;
    return result;
  }

  PeerRecord_AddressInfo._();

  factory PeerRecord_AddressInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PeerRecord_AddressInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PeerRecord.AddressInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'peer.pb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'multiaddr', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PeerRecord_AddressInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PeerRecord_AddressInfo copyWith(
          void Function(PeerRecord_AddressInfo) updates) =>
      super.copyWith((message) => updates(message as PeerRecord_AddressInfo))
          as PeerRecord_AddressInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PeerRecord_AddressInfo create() => PeerRecord_AddressInfo._();
  @$core.override
  PeerRecord_AddressInfo createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PeerRecord_AddressInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PeerRecord_AddressInfo>(create);
  static PeerRecord_AddressInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get multiaddr => $_getN(0);
  @$pb.TagNumber(1)
  set multiaddr($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMultiaddr() => $_has(0);
  @$pb.TagNumber(1)
  void clearMultiaddr() => $_clearField(1);
}

/// PeerRecord messages contain information that is useful to share with other peers.
/// Currently, a PeerRecord contains the public listen addresses for a peer, but this
/// is expected to expand to include other information in the future.
///
/// PeerRecords are designed to be serialized to bytes and placed inside of
/// SignedEnvelopes before sharing with other peers.
/// See https://github.com/libp2p/go-libp2p/blob/master/core/record/pb/envelope.proto for
/// the SignedEnvelope definition.
class PeerRecord extends $pb.GeneratedMessage {
  factory PeerRecord({
    $core.List<$core.int>? peerId,
    $fixnum.Int64? seq,
    $core.Iterable<PeerRecord_AddressInfo>? addresses,
  }) {
    final result = create();
    if (peerId != null) result.peerId = peerId;
    if (seq != null) result.seq = seq;
    if (addresses != null) result.addresses.addAll(addresses);
    return result;
  }

  PeerRecord._();

  factory PeerRecord.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PeerRecord.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PeerRecord',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'peer.pb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'peerId', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'seq', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..pPM<PeerRecord_AddressInfo>(3, _omitFieldNames ? '' : 'addresses',
        subBuilder: PeerRecord_AddressInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PeerRecord clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PeerRecord copyWith(void Function(PeerRecord) updates) =>
      super.copyWith((message) => updates(message as PeerRecord)) as PeerRecord;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PeerRecord create() => PeerRecord._();
  @$core.override
  PeerRecord createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PeerRecord getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PeerRecord>(create);
  static PeerRecord? _defaultInstance;

  /// peer_id contains a libp2p peer id in its binary representation.
  @$pb.TagNumber(1)
  $core.List<$core.int> get peerId => $_getN(0);
  @$pb.TagNumber(1)
  set peerId($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPeerId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPeerId() => $_clearField(1);

  /// seq contains a monotonically-increasing sequence counter to order PeerRecords in time.
  @$pb.TagNumber(2)
  $fixnum.Int64 get seq => $_getI64(1);
  @$pb.TagNumber(2)
  set seq($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSeq() => $_has(1);
  @$pb.TagNumber(2)
  void clearSeq() => $_clearField(2);

  /// addresses is a list of public listen addresses for the peer.
  @$pb.TagNumber(3)
  $pb.PbList<PeerRecord_AddressInfo> get addresses => $_getList(2);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
