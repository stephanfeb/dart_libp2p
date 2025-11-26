// This is a generated file - do not edit.
//
// Generated from payload.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class NoiseExtensions extends $pb.GeneratedMessage {
  factory NoiseExtensions({
    $core.Iterable<$core.List<$core.int>>? webtransportCerthashes,
    $core.Iterable<$core.String>? streamMuxers,
  }) {
    final result = create();
    if (webtransportCerthashes != null)
      result.webtransportCerthashes.addAll(webtransportCerthashes);
    if (streamMuxers != null) result.streamMuxers.addAll(streamMuxers);
    return result;
  }

  NoiseExtensions._();

  factory NoiseExtensions.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory NoiseExtensions.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NoiseExtensions',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'noise.pb'),
      createEmptyInstance: create)
    ..p<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'webtransportCerthashes', $pb.PbFieldType.PY)
    ..pPS(2, _omitFieldNames ? '' : 'streamMuxers')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NoiseExtensions clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NoiseExtensions copyWith(void Function(NoiseExtensions) updates) =>
      super.copyWith((message) => updates(message as NoiseExtensions))
          as NoiseExtensions;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static NoiseExtensions create() => NoiseExtensions._();
  @$core.override
  NoiseExtensions createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static NoiseExtensions getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NoiseExtensions>(create);
  static NoiseExtensions? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.List<$core.int>> get webtransportCerthashes => $_getList(0);

  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get streamMuxers => $_getList(1);
}

class NoiseHandshakePayload extends $pb.GeneratedMessage {
  factory NoiseHandshakePayload({
    $core.List<$core.int>? identityKey,
    $core.List<$core.int>? identitySig,
    NoiseExtensions? extensions,
  }) {
    final result = create();
    if (identityKey != null) result.identityKey = identityKey;
    if (identitySig != null) result.identitySig = identitySig;
    if (extensions != null) result.extensions = extensions;
    return result;
  }

  NoiseHandshakePayload._();

  factory NoiseHandshakePayload.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory NoiseHandshakePayload.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NoiseHandshakePayload',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'noise.pb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'identityKey', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'identitySig', $pb.PbFieldType.OY)
    ..aOM<NoiseExtensions>(4, _omitFieldNames ? '' : 'extensions',
        subBuilder: NoiseExtensions.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NoiseHandshakePayload clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NoiseHandshakePayload copyWith(
          void Function(NoiseHandshakePayload) updates) =>
      super.copyWith((message) => updates(message as NoiseHandshakePayload))
          as NoiseHandshakePayload;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static NoiseHandshakePayload create() => NoiseHandshakePayload._();
  @$core.override
  NoiseHandshakePayload createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static NoiseHandshakePayload getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NoiseHandshakePayload>(create);
  static NoiseHandshakePayload? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get identityKey => $_getN(0);
  @$pb.TagNumber(1)
  set identityKey($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdentityKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdentityKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get identitySig => $_getN(1);
  @$pb.TagNumber(2)
  set identitySig($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasIdentitySig() => $_has(1);
  @$pb.TagNumber(2)
  void clearIdentitySig() => $_clearField(2);

  @$pb.TagNumber(4)
  NoiseExtensions get extensions => $_getN(2);
  @$pb.TagNumber(4)
  set extensions(NoiseExtensions value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasExtensions() => $_has(2);
  @$pb.TagNumber(4)
  void clearExtensions() => $_clearField(4);
  @$pb.TagNumber(4)
  NoiseExtensions ensureExtensions() => $_ensure(2);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
