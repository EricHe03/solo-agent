package proto

import (
	reflect "reflect"
	sync "sync"
	unsafe "unsafe"

	protoreflect "google.golang.org/protobuf/reflect/protoreflect"
	protoimpl "google.golang.org/protobuf/runtime/protoimpl"
	emptypb "google.golang.org/protobuf/types/known/emptypb"
)

const (
	// Verify that this generated code is sufficiently up-to-date.
	_ = protoimpl.EnforceVersion(20 - protoimpl.MinVersion)
	// Verify that runtime/protoimpl is sufficiently up-to-date.
	_ = protoimpl.EnforceVersion(protoimpl.MaxVersion - 20)
)

type GetInfoResponse struct {
	state            protoimpl.MessageState `protogen:"open.v1"`
	ServerVersion    string                 `protobuf:"bytes,1,opt,name=server_version,json=serverVersion,proto3" json:"server_version,omitempty"`
	DeviceName       string                 `protobuf:"bytes,2,opt,name=device_name,json=deviceName,proto3" json:"device_name,omitempty"`
	Udid             string                 `protobuf:"bytes,3,opt,name=udid,proto3" json:"udid,omitempty"`
	DeviceConnection *DeviceConnection      `protobuf:"bytes,4,opt,name=device_connection,json=deviceConnection,proto3" json:"device_connection,omitempty"`
	unknownFields    protoimpl.UnknownFields
	sizeCache        protoimpl.SizeCache
}

func (x *GetInfoResponse) Reset() {
	*x = GetInfoResponse{}
	mi := &file_system_proto_msgTypes[0]
	ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
	ms.StoreMessageInfo(mi)
}

func (x *GetInfoResponse) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*GetInfoResponse) ProtoMessage() {}

func (x *GetInfoResponse) ProtoReflect() protoreflect.Message {
	mi := &file_system_proto_msgTypes[0]
	if x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use GetInfoResponse.ProtoReflect.Descriptor instead.
func (*GetInfoResponse) Descriptor() ([]byte, []int) {
	return file_system_proto_rawDescGZIP(), []int{0}
}

func (x *GetInfoResponse) GetServerVersion() string {
	if x != nil {
		return x.ServerVersion
	}
	return ""
}

func (x *GetInfoResponse) GetDeviceName() string {
	if x != nil {
		return x.DeviceName
	}
	return ""
}

func (x *GetInfoResponse) GetUdid() string {
	if x != nil {
		return x.Udid
	}
	return ""
}

func (x *GetInfoResponse) GetDeviceConnection() *DeviceConnection {
	if x != nil {
		return x.DeviceConnection
	}
	return nil
}

var File_system_proto protoreflect.FileDescriptor

const file_system_proto_rawDesc = "" +
	"\n" +
	"\fsystem.proto\x12\x05swipt\x1a\x1bgoogle/protobuf/empty.proto\x1a\fcommon.proto\"\xb3\x01\n" +
	"\x0fGetInfoResponse\x12%\n" +
	"\x0eserver_version\x18\x01 \x01(\tR\rserverVersion\x12\x1f\n" +
	"\vdevice_name\x18\x02 \x01(\tR\n" +
	"deviceName\x12\x12\n" +
	"\x04udid\x18\x03 \x01(\tR\x04udid\x12D\n" +
	"\x11device_connection\x18\x04 \x01(\v2\x17.swipt.DeviceConnectionR\x10deviceConnection2J\n" +
	"\rSystemService\x129\n" +
	"\aGetInfo\x12\x16.google.protobuf.Empty\x1a\x16.swipt.GetInfoResponseB2Z0github.com/swipt-automation/swipt/internal/protob\x06proto3"

var (
	file_system_proto_rawDescOnce sync.Once
	file_system_proto_rawDescData []byte
)

func file_system_proto_rawDescGZIP() []byte {
	file_system_proto_rawDescOnce.Do(func() {
		file_system_proto_rawDescData = protoimpl.X.CompressGZIP(unsafe.Slice(unsafe.StringData(file_system_proto_rawDesc), len(file_system_proto_rawDesc)))
	})
	return file_system_proto_rawDescData
}

var (
	file_system_proto_msgTypes = make([]protoimpl.MessageInfo, 1)
	file_system_proto_goTypes  = []any{
		(*GetInfoResponse)(nil),  // 0: swipt.GetInfoResponse
		(*DeviceConnection)(nil), // 1: swipt.DeviceConnection
		(*emptypb.Empty)(nil),    // 2: google.protobuf.Empty
	}
)

var file_system_proto_depIdxs = []int32{
	1, // 0: swipt.GetInfoResponse.device_connection:type_name -> swipt.DeviceConnection
	2, // 1: swipt.SystemService.GetInfo:input_type -> google.protobuf.Empty
	0, // 2: swipt.SystemService.GetInfo:output_type -> swipt.GetInfoResponse
	2, // [2:3] is the sub-list for method output_type
	1, // [1:2] is the sub-list for method input_type
	1, // [1:1] is the sub-list for extension type_name
	1, // [1:1] is the sub-list for extension extendee
	0, // [0:1] is the sub-list for field type_name
}

func init() { file_system_proto_init() }
func file_system_proto_init() {
	if File_system_proto != nil {
		return
	}
	file_common_proto_init()
	type x struct{}
	out := protoimpl.TypeBuilder{
		File: protoimpl.DescBuilder{
			GoPackagePath: reflect.TypeOf(x{}).PkgPath(),
			RawDescriptor: unsafe.Slice(unsafe.StringData(file_system_proto_rawDesc), len(file_system_proto_rawDesc)),
			NumEnums:      0,
			NumMessages:   1,
			NumExtensions: 0,
			NumServices:   1,
		},
		GoTypes:           file_system_proto_goTypes,
		DependencyIndexes: file_system_proto_depIdxs,
		MessageInfos:      file_system_proto_msgTypes,
	}.Build()
	File_system_proto = out.File
	file_system_proto_goTypes = nil
	file_system_proto_depIdxs = nil
}
