#+build windows
// The WASAPI interfaces this backend uses. `core:sys/windows` has OLE, the
// GUID type and the wave formats but none of the audio endpoint COM, so the
// five vtables are declared here, as `platform/win32` does for OLE's drag
// and drop.
//
// Each vtable is written out in full, in IDL order, with the entries never
// called declared as `rawptr`: after a missing entry, every call lands on
// its neighbour.
package audio

import win "core:sys/windows"

foreign import avrt "system:Avrt.lib"

// CLSID_MMDeviceEnumerator {BCDE0395-E52F-467C-8E3D-C4579291692E}
CLSID_MMDeviceEnumerator := win.GUID{0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
// IID_IMMDeviceEnumerator {A95664D2-9614-4F35-A746-DE8DB63617E6}
IID_IMMDeviceEnumerator := win.GUID{0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
// IID_IAudioClient {1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}
IID_IAudioClient := win.GUID{0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}}
// IID_IAudioRenderClient {F294ACFC-3146-4483-A7BF-ADDCA7C260E2}
IID_IAudioRenderClient := win.GUID{0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}}
// IID_IAudioCaptureClient {C8ADBD64-E71E-48A0-A4DE-185C395CD317}
IID_IAudioCaptureClient := win.GUID{0xC8ADBD64, 0xE71E, 0x48A0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}}
// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT {00000003-0000-0010-8000-00AA00389B71}
KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := win.GUID{0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}

// EDataFlow / ERole, as GetDefaultAudioEndpoint takes them.
E_RENDER  :: i32(0)
E_CAPTURE :: i32(1)
E_CONSOLE :: i32(0) // games, system sounds and *voice*, which is this package

WAVE_FORMAT_EXTENSIBLE :: u16(0xFFFE)

AUDCLNT_SHAREMODE_SHARED :: i32(0)

AUDCLNT_STREAMFLAGS_EVENTCALLBACK     :: u32(0x00040000)
AUDCLNT_STREAMFLAGS_NOPERSIST         :: u32(0x00080000)
AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM    :: u32(0x80000000)
AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY :: u32(0x08000000)

AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY :: u32(0x1)
AUDCLNT_BUFFERFLAGS_SILENT             :: u32(0x2)
AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR    :: u32(0x4)

// The AUDCLNT_E_* codes this maps to an `Error`, as HRESULTs.
AUDCLNT_E_NOT_INITIALIZED        :: win.HRESULT(-2004287487) // 0x88890001
AUDCLNT_E_WRONG_ENDPOINT_TYPE    :: win.HRESULT(-2004287485) // 0x88890003
AUDCLNT_E_DEVICE_INVALIDATED     :: win.HRESULT(-2004287484) // 0x88890004
AUDCLNT_E_NOT_STOPPED            :: win.HRESULT(-2004287483) // 0x88890005
AUDCLNT_E_UNSUPPORTED_FORMAT     :: win.HRESULT(-2004287480) // 0x88890008
AUDCLNT_E_DEVICE_IN_USE          :: win.HRESULT(-2004287478) // 0x8889000A
AUDCLNT_E_ENDPOINT_CREATE_FAILED :: win.HRESULT(-2004287473) // 0x8889000F
AUDCLNT_E_SERVICE_NOT_RUNNING    :: win.HRESULT(-2004287472) // 0x88890010
AUDCLNT_E_RESOURCES_INVALIDATED  :: win.HRESULT(-2004287465) // 0x88890017
AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED:: win.HRESULT(-2004287463) // 0x88890019
E_NOTFOUND_HR                    :: win.HRESULT(-2147023728) // 0x80070490: no endpoint of that kind
E_ACCESSDENIED_HR                :: win.HRESULT(-2147024891) // 0x80070005: the microphone privacy setting

// REFERENCE_TIME is 100-nanosecond units.
REFERENCE_TIME :: i64
REF_TIMES_PER_MS :: REFERENCE_TIME(10_000)

IMMDeviceEnumerator :: struct { using vtbl: ^IMMDeviceEnumerator_Vtbl }
IMMDeviceEnumerator_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IMMDeviceEnumerator, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IMMDeviceEnumerator) -> win.ULONG,
	Release:        proc "system" (this: ^IMMDeviceEnumerator) -> win.ULONG,
	EnumAudioEndpoints: rawptr,
	GetDefaultAudioEndpoint: proc "system" (this: ^IMMDeviceEnumerator, flow: i32, role: i32, out: ^^IMMDevice) -> win.HRESULT,
	GetDevice:      proc "system" (this: ^IMMDeviceEnumerator, id: win.LPCWSTR, out: ^^IMMDevice) -> win.HRESULT,
	RegisterEndpointNotificationCallback:   rawptr,
	UnregisterEndpointNotificationCallback: rawptr,
}

IMMDevice :: struct { using vtbl: ^IMMDevice_Vtbl }
IMMDevice_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IMMDevice, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IMMDevice) -> win.ULONG,
	Release:        proc "system" (this: ^IMMDevice) -> win.ULONG,
	Activate:       proc "system" (this: ^IMMDevice, iid: ^win.GUID, cls_ctx: win.DWORD, params: rawptr, out: ^rawptr) -> win.HRESULT,
	OpenPropertyStore: rawptr,
	GetId:          proc "system" (this: ^IMMDevice, out: ^win.LPWSTR) -> win.HRESULT,
	GetState:       rawptr,
}

IAudioClient :: struct { using vtbl: ^IAudioClient_Vtbl }
IAudioClient_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IAudioClient, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IAudioClient) -> win.ULONG,
	Release:        proc "system" (this: ^IAudioClient) -> win.ULONG,
	Initialize:     proc "system" (this: ^IAudioClient, mode: i32, flags: u32, buffer_duration: REFERENCE_TIME,
		periodicity: REFERENCE_TIME, format: ^win.WAVEFORMATEX, session: ^win.GUID) -> win.HRESULT,
	GetBufferSize:  proc "system" (this: ^IAudioClient, out_frames: ^u32) -> win.HRESULT,
	GetStreamLatency: proc "system" (this: ^IAudioClient, out: ^REFERENCE_TIME) -> win.HRESULT,
	GetCurrentPadding: proc "system" (this: ^IAudioClient, out_frames: ^u32) -> win.HRESULT,
	IsFormatSupported: proc "system" (this: ^IAudioClient, mode: i32, format: ^win.WAVEFORMATEX, closest: ^^win.WAVEFORMATEX) -> win.HRESULT,
	GetMixFormat:   proc "system" (this: ^IAudioClient, out: ^^win.WAVEFORMATEX) -> win.HRESULT,
	GetDevicePeriod: proc "system" (this: ^IAudioClient, default_period: ^REFERENCE_TIME, min_period: ^REFERENCE_TIME) -> win.HRESULT,
	Start:          proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Stop:           proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Reset:          proc "system" (this: ^IAudioClient) -> win.HRESULT,
	SetEventHandle: proc "system" (this: ^IAudioClient, handle: win.HANDLE) -> win.HRESULT,
	GetService:     proc "system" (this: ^IAudioClient, iid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
}

IAudioRenderClient :: struct { using vtbl: ^IAudioRenderClient_Vtbl }
IAudioRenderClient_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IAudioRenderClient, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IAudioRenderClient) -> win.ULONG,
	Release:        proc "system" (this: ^IAudioRenderClient) -> win.ULONG,
	GetBuffer:      proc "system" (this: ^IAudioRenderClient, frames: u32, out: ^[^]u8) -> win.HRESULT,
	ReleaseBuffer:  proc "system" (this: ^IAudioRenderClient, frames: u32, flags: u32) -> win.HRESULT,
}

IAudioCaptureClient :: struct { using vtbl: ^IAudioCaptureClient_Vtbl }
IAudioCaptureClient_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IAudioCaptureClient, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IAudioCaptureClient) -> win.ULONG,
	Release:        proc "system" (this: ^IAudioCaptureClient) -> win.ULONG,
	GetBuffer:      proc "system" (this: ^IAudioCaptureClient, out: ^[^]u8, frames: ^u32, flags: ^u32,
		position: ^u64, qpc: ^u64) -> win.HRESULT,
	ReleaseBuffer:  proc "system" (this: ^IAudioCaptureClient, frames: u32) -> win.HRESULT,
	GetNextPacketSize: proc "system" (this: ^IAudioCaptureClient, out_frames: ^u32) -> win.HRESULT,
}

// The Multimedia Class Scheduler, so the audio thread is not preempted by
// whatever else the machine is doing. Without it a busy desktop glitches a
// stream that is otherwise perfectly fed.
@(default_calling_convention = "system")
foreign avrt {
	AvSetMmThreadCharacteristicsW :: proc(task: win.LPCWSTR, task_index: ^win.DWORD) -> win.HANDLE ---
	AvRevertMmThreadCharacteristics :: proc(handle: win.HANDLE) -> win.BOOL ---
}
