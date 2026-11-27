use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::Arc;

use crate::config::{LinkUpdatePayload, PlaybackDemandUpdate, StreamRegistration};
use crate::link_manager::RefreshCallback;
use crate::NativeEngine;

pub type NativeRefreshFn = extern "C" fn(*mut c_char, u64);

/// Starts the native streaming engine and its local HTTP loopback server.
/// The optional [on_refresh] callback receives a Rust-allocated UTF-8 token pointer
/// that the callee must free using [ttplay_string_free].
#[no_mangle]
pub extern "C" fn ttplay_engine_start(on_refresh: Option<NativeRefreshFn>) -> *mut NativeEngine {
    catch_unwind(AssertUnwindSafe(|| {
        let cb: Option<RefreshCallback> = on_refresh.map(|func| {
            Arc::new(move |token: &str, req_id: u64| {
                if let Ok(c_str) = CString::new(token) {
                    func(c_str.into_raw(), req_id);
                }
            }) as RefreshCallback
        });
        match NativeEngine::start(cb) {
            Ok(engine) => Box::into_raw(Box::new(engine)),
            Err(_) => ptr::null_mut(),
        }
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn ttplay_engine_port(engine: *mut NativeEngine) -> u16 {
    if engine.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| unsafe { (*engine).port() })).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn ttplay_engine_register_stream(
    engine: *mut NativeEngine,
    json: *const c_char,
) -> i32 {
    if engine.is_null() || json.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let raw = unsafe { CStr::from_ptr(json) };
        let Ok(str_json) = raw.to_str() else {
            return -2;
        };
        let Ok(reg) = serde_json::from_str::<StreamRegistration>(str_json) else {
            return -3;
        };
        let eng = unsafe { &*engine };
        if eng.register_stream(reg).is_ok() {
            0
        } else {
            -4
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn ttplay_engine_update_link(
    engine: *mut NativeEngine,
    token: *const c_char,
    req_id: u64,
    json: *const c_char,
) -> i32 {
    if engine.is_null() || token.is_null() || json.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(token_str) = unsafe { CStr::from_ptr(token) }.to_str() else {
            return -2;
        };
        let Ok(json_str) = unsafe { CStr::from_ptr(json) }.to_str() else {
            return -2;
        };
        let Ok(payload) = serde_json::from_str::<LinkUpdatePayload>(json_str) else {
            return -3;
        };
        let eng = unsafe { &*engine };
        if eng.update_link(token_str, req_id, payload) {
            0
        } else {
            -4
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn ttplay_engine_update_demand(
    engine: *mut NativeEngine,
    token: *const c_char,
    json: *const c_char,
) -> i32 {
    if engine.is_null() || token.is_null() || json.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(token_str) = unsafe { CStr::from_ptr(token) }.to_str() else {
            return -2;
        };
        let Ok(json_str) = unsafe { CStr::from_ptr(json) }.to_str() else {
            return -2;
        };
        let Ok(update) = serde_json::from_str::<PlaybackDemandUpdate>(json_str) else {
            return -3;
        };
        let eng = unsafe { &*engine };
        if eng.update_demand(token_str, update) {
            0
        } else {
            -4
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn ttplay_engine_unregister_stream(
    engine: *mut NativeEngine,
    token: *const c_char,
) -> i32 {
    if engine.is_null() || token.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(token_str) = unsafe { CStr::from_ptr(token) }.to_str() else {
            return -2;
        };
        let eng = unsafe { &*engine };
        if eng.unregister_stream(token_str) {
            0
        } else {
            1
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn ttplay_engine_poll_stats(engine: *mut NativeEngine) -> *mut c_char {
    if engine.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let eng = unsafe { &*engine };
        let snaps = eng.poll_stats();
        let Ok(json) = serde_json::to_string(&snaps) else {
            return ptr::null_mut();
        };
        CString::new(json).map(CString::into_raw).unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn ttplay_engine_peek_status(
    engine: *mut NativeEngine,
    token: *const c_char,
) -> *mut c_char {
    if engine.is_null() || token.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(token_str) = unsafe { CStr::from_ptr(token) }.to_str() else {
            return ptr::null_mut();
        };
        let eng = unsafe { &*engine };
        let Some(status) = eng.peek_stream_status(token_str) else {
            return ptr::null_mut();
        };
        let Ok(json) = serde_json::to_string(&status) else {
            return ptr::null_mut();
        };
        CString::new(json).map(CString::into_raw).unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn ttplay_engine_stop(engine: *mut NativeEngine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let boxed = unsafe { Box::from_raw(engine) };
        boxed.stop();
    }));
}

#[no_mangle]
pub extern "C" fn ttplay_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        let _ = CString::from_raw(ptr);
    }));
}

/// Allocates [len] bytes on the Rust heap so FFI callers without a libc allocator
/// (e.g. pure `dart:ffi` without `package:ffi`) can pass UTF-8 strings safely.
#[no_mangle]
pub extern "C" fn ttplay_bytes_alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return ptr::null_mut();
    }
    let mut buf = vec![0u8; len].into_boxed_slice();
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

#[no_mangle]
pub extern "C" fn ttplay_bytes_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
    }));
}
