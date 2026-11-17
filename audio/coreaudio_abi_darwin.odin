#+build darwin
// The CoreAudio types and entry points this backend uses, written out
// whole rather than cut down to the interesting ones: an enum copied in
// part shifts every value after the gap. The error codes are the whole
// `kAudioQueueErr_*` block in order, and the struct layouts are spelled out
// field for field with their C types beside them.
package audio

foreign import audio_toolbox "system:AudioToolbox.framework"
foreign import core_foundation "system:CoreFoundation.framework"

OS_Status :: i32

Audio_Queue_Ref        :: rawptr
Audio_Queue_Buffer_Ref :: ^Audio_Queue_Buffer
CF_String_Ref          :: rawptr
CF_Run_Loop_Ref        :: rawptr

// AudioStreamBasicDescription (CoreAudioTypes.h)
Audio_Stream_Basic_Description :: struct {
	sample_rate:        f64, // Float64 mSampleRate
	format_id:          u32, // AudioFormatID
	format_flags:       u32, // AudioFormatFlags
	bytes_per_packet:   u32,
	frames_per_packet:  u32,
	bytes_per_frame:    u32,
	channels_per_frame: u32,
	bits_per_channel:   u32,
	reserved:           u32,
}

// SMPTETime, only ever as padding inside an AudioTimeStamp.
Smpte_Time :: struct {
	subframes:        i16,
	subframe_divisor: i16,
	counter:          u32,
	type:             u32,
	flags:            u32,
	hours:            i16,
	minutes:          i16,
	seconds:          i16,
	frames:           i16,
}

// AudioTimeStamp — 64 bytes; the input callback is handed one.
Audio_Time_Stamp :: struct {
	sample_time:     f64,
	host_time:       u64,
	rate_scalar:     f64,
	word_clock_time: u64,
	smpte_time:      Smpte_Time,
	flags:           u32,
	reserved:        u32,
}

// AudioQueueBuffer. `audio_data_bytes_capacity` and `audio_data` are const
// in C: the queue owns the memory, the callback fills it and sets
// `audio_data_byte_size` to how much of it is real.
Audio_Queue_Buffer :: struct {
	audio_data_bytes_capacity:   u32,
	audio_data:                  rawptr,
	audio_data_byte_size:        u32,
	user_data:                   rawptr,
	packet_description_capacity: u32,
	packet_descriptions:         rawptr,
	packet_description_count:    u32,
}

Audio_Queue_Output_Callback :: #type proc "c" (user: rawptr, aq: Audio_Queue_Ref, buf: Audio_Queue_Buffer_Ref)
Audio_Queue_Input_Callback :: #type proc "c" (user: rawptr, aq: Audio_Queue_Ref, buf: Audio_Queue_Buffer_Ref,
	start: ^Audio_Time_Stamp, n_packets: u32, descs: rawptr)

// kAudioFormatLinearPCM, as the four-character code 'lpcm'.
K_AUDIO_FORMAT_LINEAR_PCM :: u32(0x6C70636D)

// AudioFormatFlags
K_FLAG_IS_FLOAT          :: u32(1 << 0)
K_FLAG_IS_BIG_ENDIAN     :: u32(1 << 1)
K_FLAG_IS_SIGNED_INTEGER :: u32(1 << 2)
K_FLAG_IS_PACKED         :: u32(1 << 3)
K_FLAG_IS_ALIGNED_HIGH   :: u32(1 << 4)
K_FLAG_IS_NON_INTERLEAVED :: u32(1 << 5)

// 'aqdv' — the device a queue runs on, as a CFString of its UID.
K_AUDIO_QUEUE_PROPERTY_CURRENT_DEVICE :: u32(0x61716476)

// kCFStringEncodingUTF8
K_CF_STRING_ENCODING_UTF8 :: u32(0x08000100)

// The whole kAudioQueueErr_* block, in its own order, plus the two
// general codes a queue call can return.
K_AUDIO_ERR_PARAM                   :: OS_Status(-50)    // kAudio_ParamError
K_AUDIO_FORMAT_UNSUPPORTED          :: OS_Status(1718449215) // 'fmt?'
K_AQ_ERR_INVALID_BUFFER             :: OS_Status(-66687)
K_AQ_ERR_BUFFER_EMPTY               :: OS_Status(-66686)
K_AQ_ERR_DISPOSAL_PENDING           :: OS_Status(-66685)
K_AQ_ERR_INVALID_PROPERTY           :: OS_Status(-66684)
K_AQ_ERR_INVALID_PROPERTY_SIZE      :: OS_Status(-66683)
K_AQ_ERR_INVALID_PARAMETER          :: OS_Status(-66682)
K_AQ_ERR_CANNOT_START               :: OS_Status(-66681)
K_AQ_ERR_INVALID_DEVICE             :: OS_Status(-66680)
K_AQ_ERR_BUFFER_IN_QUEUE            :: OS_Status(-66679)
K_AQ_ERR_INVALID_RUN_STATE          :: OS_Status(-66678)
K_AQ_ERR_INVALID_QUEUE_TYPE         :: OS_Status(-66677)
K_AQ_ERR_PERMISSIONS                :: OS_Status(-66676)
K_AQ_ERR_INVALID_PROPERTY_VALUE     :: OS_Status(-66675)
K_AQ_ERR_PRIME_TIMED_OUT            :: OS_Status(-66674)
K_AQ_ERR_CODEC_NOT_FOUND            :: OS_Status(-66673)
K_AQ_ERR_INVALID_CODEC_ACCESS       :: OS_Status(-66672)
K_AQ_ERR_QUEUE_INVALIDATED          :: OS_Status(-66671)
K_AQ_ERR_TOO_MANY_TASKS             :: OS_Status(-66670)
K_AQ_ERR_INVALID_OFFLINE_MODE       :: OS_Status(-66626)
// Not in that block, and the one that matters most here: enqueueing from
// inside the callback a reset itself provoked.
K_AQ_ERR_ENQUEUE_DURING_RESET       :: OS_Status(-66632)

@(default_calling_convention = "c")
foreign audio_toolbox {
	AudioQueueNewOutput :: proc(format: ^Audio_Stream_Basic_Description, callback: Audio_Queue_Output_Callback,
		user: rawptr, run_loop: CF_Run_Loop_Ref, run_loop_mode: CF_String_Ref, flags: u32,
		out_aq: ^Audio_Queue_Ref) -> OS_Status ---
	AudioQueueNewInput :: proc(format: ^Audio_Stream_Basic_Description, callback: Audio_Queue_Input_Callback,
		user: rawptr, run_loop: CF_Run_Loop_Ref, run_loop_mode: CF_String_Ref, flags: u32,
		out_aq: ^Audio_Queue_Ref) -> OS_Status ---
	AudioQueueAllocateBuffer :: proc(aq: Audio_Queue_Ref, bytes: u32, out_buf: ^Audio_Queue_Buffer_Ref) -> OS_Status ---
	AudioQueueFreeBuffer :: proc(aq: Audio_Queue_Ref, buf: Audio_Queue_Buffer_Ref) -> OS_Status ---
	AudioQueueEnqueueBuffer :: proc(aq: Audio_Queue_Ref, buf: Audio_Queue_Buffer_Ref, n_descs: u32, descs: rawptr) -> OS_Status ---
	AudioQueueStart :: proc(aq: Audio_Queue_Ref, start: ^Audio_Time_Stamp) -> OS_Status ---
	AudioQueueStop :: proc(aq: Audio_Queue_Ref, immediate: b8) -> OS_Status ---
	AudioQueueFlush :: proc(aq: Audio_Queue_Ref) -> OS_Status ---
	AudioQueueReset :: proc(aq: Audio_Queue_Ref) -> OS_Status ---
	AudioQueueDispose :: proc(aq: Audio_Queue_Ref, immediate: b8) -> OS_Status ---
	AudioQueueSetProperty :: proc(aq: Audio_Queue_Ref, id: u32, data: rawptr, size: u32) -> OS_Status ---
}

@(default_calling_convention = "c")
foreign core_foundation {
	CFStringCreateWithBytes :: proc(allocator: rawptr, bytes: [^]u8, length: int, encoding: u32,
		external_representation: b8) -> CF_String_Ref ---
	CFRelease :: proc(cf: rawptr) ---
}
