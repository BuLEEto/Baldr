#+build darwin
package baldr

// The macOS keychain backend: the login Keychain, through
// Security.framework's generic-password items. Runs on the op's own thread,
// so every call here may block: the Keychain prompts the person the first
// time another binary asks for an item.
//
// `core:sys/darwin` ships CoreFoundation's types and `CFRelease` but none of
// the create functions, and Security's SecItem family not at all, so the
// calls are declared here; these are system frameworks, nothing is compiled
// into the tree. `service` and `account` go in their own fields, so an app's
// secret appears in Keychain Access under the name the app chose. A set is
// an add, then an update if the item exists: SecItemAdd answers
// errSecDuplicateItem rather than replacing, and the query that finds the
// old item must not carry the new value (passing both gives errSecParam).

import CF "core:sys/darwin/CoreFoundation"
import "core:fmt"

foreign import Security "system:Security.framework"
foreign import CoreFoundation "system:CoreFoundation.framework"

@(private = "file") OSStatus :: i32

// The handful of results worth telling apart. The rest are reported by
// number: a status nobody has seen before should arrive legible, not as
// "something went wrong".
@(private = "file") errSecSuccess              :: OSStatus(0)
@(private = "file") errSecUserCanceled         :: OSStatus(-128)   // the person closed the prompt
@(private = "file") errSecAuthFailed           :: OSStatus(-25293) // …or could not unlock it
@(private = "file") errSecDuplicateItem        :: OSStatus(-25299)
@(private = "file") errSecItemNotFound         :: OSStatus(-25300)
@(private = "file") errSecInteractionNotAllowed :: OSStatus(-25308) // a locked keychain, no UI allowed

@(private = "file") Dictionary :: distinct CF.TypeRef
@(private = "file") Data       :: distinct CF.TypeRef

// CFDictionaryKeyCallBacks is six pointers; only its *address* is ever
// passed, so an opaque block of the right size is all this needs.
@(private = "file") Dict_Callbacks :: struct { _: [48]u8 }

@(default_calling_convention = "c")
foreign Security {
	SecItemAdd          :: proc(attributes: Dictionary, result: ^CF.TypeRef) -> OSStatus ---
	SecItemCopyMatching :: proc(query: Dictionary, result: ^CF.TypeRef) -> OSStatus ---
	SecItemUpdate       :: proc(query: Dictionary, attributes_to_update: Dictionary) -> OSStatus ---
	SecItemDelete       :: proc(query: Dictionary) -> OSStatus ---

	// The dictionary keys and values, all CFStringRef constants the
	// framework exports.
	kSecClass:                CF.StringRef
	kSecClassGenericPassword: CF.StringRef
	kSecAttrService:          CF.StringRef
	kSecAttrAccount:          CF.StringRef
	kSecValueData:            CF.StringRef
	kSecReturnData:           CF.StringRef
	kSecMatchLimit:           CF.StringRef
	kSecMatchLimitOne:        CF.StringRef
}

@(default_calling_convention = "c")
foreign CoreFoundation {
	CFStringCreateWithBytes :: proc(alloc: CF.TypeRef, bytes: [^]u8, num: CF.Index, enc: CF.StringEncoding, external: b8) -> CF.StringRef ---
	CFDataCreate            :: proc(alloc: CF.TypeRef, bytes: [^]u8, length: CF.Index) -> Data ---
	CFDataGetBytePtr        :: proc(data: Data) -> [^]u8 ---
	CFDataGetLength         :: proc(data: Data) -> CF.Index ---
	CFDictionaryCreate      :: proc(alloc: CF.TypeRef, keys: [^]rawptr, values: [^]rawptr, num: CF.Index, key_cb: ^Dict_Callbacks, val_cb: ^Dict_Callbacks) -> Dictionary ---

	kCFBooleanTrue:                  CF.TypeRef
}

// cf_str is `s` as a CFString the caller releases. Nil only if the bytes
// are not valid UTF-8, which a service or an account name from an app may
// well not be — hence every caller checking.
@(private = "file")
cf_str :: proc(s: string) -> CF.StringRef {
	empty: [1]u8 // CFStringCreateWithBytes wants a pointer even for nothing
	bytes := raw_data(s) if len(s) > 0 else ([^]u8)(&empty[0])
	return CFStringCreateWithBytes(nil, bytes, CF.Index(len(s)), CF.StringEncoding(CF.StringBuiltInEncodings.UTF8), false)
}

// keychain_query is the pair that names one item: a generic password with
// this service and this account. `extra` keys are appended (the value to
// store, or "give me the data back").
@(private = "file")
keychain_query :: proc(service, account: CF.StringRef, extra_keys, extra_vals: []rawptr) -> Dictionary {
	keys: [6]rawptr
	vals: [6]rawptr
	n := 3
	keys[0], vals[0] = rawptr(kSecClass), rawptr(kSecClassGenericPassword)
	keys[1], vals[1] = rawptr(kSecAttrService), rawptr(service)
	keys[2], vals[2] = rawptr(kSecAttrAccount), rawptr(account)
	for i in 0 ..< min(len(extra_keys), len(keys) - n) {
		keys[n + i], vals[n + i] = extra_keys[i], extra_vals[i]
	}
	n += min(len(extra_keys), len(keys) - n)
	return CFDictionaryCreate(nil, raw_data(keys[:n]), raw_data(vals[:n]), CF.Index(n),
		(^Dict_Callbacks)(&CF.kTypeDictionaryKeyCallBacks), (^Dict_Callbacks)(&CF.kTypeDictionaryValueCallBacks))
}

// keychain_status turns an OSStatus into the answer an app gets. Anything
// not named arrives with its number, because a secret that will not store
// is worth more than "Failed".
@(private = "file")
keychain_status :: proc(op: ^Secret_Op($Msg), st: OSStatus, what: string) {
	switch st {
	case errSecSuccess:
		op.status = .Ok
	case errSecItemNotFound:
		op.status = .Not_Found
	case errSecUserCanceled, errSecAuthFailed:
		secret_fail(op, .Denied, "the Keychain was not unlocked")
	case errSecInteractionNotAllowed:
		secret_fail(op, .Locked, "the Keychain is locked")
	case:
		secret_fail(op, .Failed, fmt.tprintf("the Keychain would not %s it (OSStatus %d)", what, st))
	}
}

@(private)
secret_platform :: proc(op: ^Secret_Op($Msg)) {
	service, account := cf_str(op.service), cf_str(op.account)
	if service == nil || account == nil {
		if service != nil do CF.Release(CF.TypeRef(service))
		if account != nil do CF.Release(CF.TypeRef(account))
		secret_fail(op, .Failed, "the service or account name is not valid UTF-8")
		return
	}
	defer CF.Release(CF.TypeRef(service))
	defer CF.Release(CF.TypeRef(account))

	#partial switch op.kind {
	case .Secret_Set:
		blob: [1]u8
		bytes := raw_data(op.value) if len(op.value) > 0 else ([^]u8)(&blob[0])
		data := CFDataCreate(nil, bytes, CF.Index(len(op.value)))
		if data == nil {
			secret_fail(op, .Failed, "the value could not be wrapped for the Keychain")
			return
		}
		defer CF.Release(CF.TypeRef(data))
		add := keychain_query(service, account, {rawptr(kSecValueData)}, {rawptr(data)})
		if add == nil {
			secret_fail(op, .Failed, "the Keychain query could not be built")
			return
		}
		st := SecItemAdd(add, nil)
		CF.Release(CF.TypeRef(add))
		if st == errSecDuplicateItem {
			// It is already there, so this is an update — and the query
			// that finds it must not carry the new value.
			find := keychain_query(service, account, nil, nil)
			vkeys := [1]rawptr{rawptr(kSecValueData)}
			vvals := [1]rawptr{rawptr(data)}
			upd := CFDictionaryCreate(nil, raw_data(vkeys[:]), raw_data(vvals[:]), 1,
				(^Dict_Callbacks)(&CF.kTypeDictionaryKeyCallBacks), (^Dict_Callbacks)(&CF.kTypeDictionaryValueCallBacks))
			if find == nil || upd == nil {
				if find != nil do CF.Release(CF.TypeRef(find))
				if upd != nil do CF.Release(CF.TypeRef(upd))
				secret_fail(op, .Failed, "the Keychain update could not be built")
				return
			}
			st = SecItemUpdate(find, upd)
			CF.Release(CF.TypeRef(find))
			CF.Release(CF.TypeRef(upd))
		}
		keychain_status(op, st, "store")

	case .Secret_Get:
		keys := [2]rawptr{rawptr(kSecReturnData), rawptr(kSecMatchLimit)}
		vals := [2]rawptr{rawptr(kCFBooleanTrue), rawptr(kSecMatchLimitOne)}
		q := keychain_query(service, account, keys[:], vals[:])
		if q == nil {
			secret_fail(op, .Failed, "the Keychain query could not be built")
			return
		}
		out: CF.TypeRef
		st := SecItemCopyMatching(q, &out)
		CF.Release(CF.TypeRef(q))
		if st == errSecSuccess && out != nil {
			// A Copy call hands over a reference: ours to release.
			defer CF.Release(out)
			d := Data(out)
			if n := int(CFDataGetLength(d)); n > 0 {
				if p := CFDataGetBytePtr(d); p != nil {
					op.value = make([]u8, n, op.allocator)
					copy(op.value, p[:n])
				}
			}
		}
		keychain_status(op, st, "read")

	case .Secret_Delete:
		q := keychain_query(service, account, nil, nil)
		if q == nil {
			secret_fail(op, .Failed, "the Keychain query could not be built")
			return
		}
		st := SecItemDelete(q)
		CF.Release(CF.TypeRef(q))
		keychain_status(op, st, "delete") // nothing to remove answers .Not_Found, which is not a failure
	}
}
