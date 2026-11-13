// SPDX-License-Identifier: MPL-2.0
//go:build darwin && arm64

package main

import "runtime"

func init() {
	// AppKit requires NSApplication and its event loop to run on OS thread 0.
	runtime.LockOSThread()
}
