// This is a generated file - do not edit.
//
// Generated from envelope.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import '../../../core/crypto/pb/crypto.pb.dart' as $0;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// Envelope encloses a signed payload produced by a peer, along with the public
/// key of the keypair it was signed with so that it can be statelessly validated
/// by the receiver.
///
/// The payload is prefixed with a byte string that determines the type, so it
/// can be deserialized deterministically. Often, this byte string is a
/// multicodec.
class Envelope extends $pb.GeneratedMessage {
  factory Envelope({
    $0.PublicKey? publicKey,
    $core.List<$core.int>? payloadType,
    $core.List<$core.int>? payload,
    $core.List<$core.int>? signature,
  }) {
    final result = create();
    if (publicKey != null) result.publicKey = publicKey;
    if (payloadType != null) result.payloadType = payloadType;
    if (payload != null) result.payload = payload;
    if (signature != null) result.signature = signature;
    return result;
  }

  Envelope._();

  factory Envelope.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Envelope.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Envelope',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'record.pb'),
      createEmptyInstance: create)
    ..aOM<$0.PublicKey>(1, _omitFieldNames ? '' : 'publicKey',
        subBuilder: $0.PublicKey.create)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'payloadType', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'payload', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'signature', $pb.PbFieldType.OY);

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Envelope clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Envelope copyWith(void Function(Envelope) updates) =>
      super.copyWith((message) => updates(message as Envelope)) as Envelope;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Envelope create() => Envelope._();
  @$core.override
  Envelope createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Envelope getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Envelope>(create);
  static Envelope? _defaultInstance;

  /// public_key is the public key of the keypair the enclosed payload was
  /// signed with.
  @$pb.TagNumber(1)
  $0.PublicKey get publicKey => $_getN(0);
  @$pb.TagNumber(1)
  set publicKey($0.PublicKey value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPublicKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearPublicKey() => $_clearField(1);
  @$pb.TagNumber(1)
  $0.PublicKey ensurePublicKey() => $_ensure(0);

  /// payload_type encodes the type of payload, so that it can be deserialized
  /// deterministically.
  @$pb.TagNumber(2)
  $core.List<$core.int> get payloadType => $_getN(1);
  @$pb.TagNumber(2)
  set payloadType($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPayloadType() => $_has(1);
  @$pb.TagNumber(2)
  void clearPayloadType() => $_clearField(2);

  /// payload is the actual payload carried inside this envelope.
  @$pb.TagNumber(3)
  $core.List<$core.int> get payload => $_getN(2);
  @$pb.TagNumber(3)
  set payload($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPayload() => $_has(2);
  @$pb.TagNumber(3)
  void clearPayload() => $_clearField(3);

  /// signature is the signature produced by the private key corresponding to
  /// the enclosed public key, over the payload, prefixing a domain string for
  /// additional security.
  @$pb.TagNumber(5)
  $core.List<$core.int> get signature => $_getN(3);
  @$pb.TagNumber(5)
  set signature($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(5)
  $core.bool hasSignature() => $_has(3);
  @$pb.TagNumber(5)
  void clearSignature() => $_clearField(5);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
