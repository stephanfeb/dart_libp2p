// This is a generated file - do not edit.
//
// Generated from payload.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use noiseExtensionsDescriptor instead')
const NoiseExtensions$json = {
  '1': 'NoiseExtensions',
  '2': [
    {
      '1': 'webtransport_certhashes',
      '3': 1,
      '4': 3,
      '5': 12,
      '10': 'webtransportCerthashes'
    },
    {'1': 'stream_muxers', '3': 2, '4': 3, '5': 9, '10': 'streamMuxers'},
  ],
};

/// Descriptor for `NoiseExtensions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List noiseExtensionsDescriptor = $convert.base64Decode(
    'Cg9Ob2lzZUV4dGVuc2lvbnMSNwoXd2VidHJhbnNwb3J0X2NlcnRoYXNoZXMYASADKAxSFndlYn'
    'RyYW5zcG9ydENlcnRoYXNoZXMSIwoNc3RyZWFtX211eGVycxgCIAMoCVIMc3RyZWFtTXV4ZXJz');

@$core.Deprecated('Use noiseHandshakePayloadDescriptor instead')
const NoiseHandshakePayload$json = {
  '1': 'NoiseHandshakePayload',
  '2': [
    {'1': 'identity_key', '3': 1, '4': 1, '5': 12, '10': 'identityKey'},
    {'1': 'identity_sig', '3': 2, '4': 1, '5': 12, '10': 'identitySig'},
    {
      '1': 'extensions',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.noise.pb.NoiseExtensions',
      '10': 'extensions'
    },
  ],
};

/// Descriptor for `NoiseHandshakePayload`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List noiseHandshakePayloadDescriptor = $convert.base64Decode(
    'ChVOb2lzZUhhbmRzaGFrZVBheWxvYWQSIQoMaWRlbnRpdHlfa2V5GAEgASgMUgtpZGVudGl0eU'
    'tleRIhCgxpZGVudGl0eV9zaWcYAiABKAxSC2lkZW50aXR5U2lnEjkKCmV4dGVuc2lvbnMYBCAB'
    'KAsyGS5ub2lzZS5wYi5Ob2lzZUV4dGVuc2lvbnNSCmV4dGVuc2lvbnM=');
