//go:build windows

package desktop

import (
	"errors"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

// COLORREF values use 0x00BBGGRR. Flat black labels stay readable even when a
// control is disabled; the slate surface, rather than embossed text, shows that state.
type controlPalette struct {
	Surface, Disabled, Text, DisabledText, Border, Accent, AccentText uint32
}

type themeMeasureItem struct {
	Type, ID, ItemID, Width, Height uint32
	Data                            uintptr
}
type themeComboBoxInfo struct {
	Size              uint32
	Item, Button      rect
	ButtonState       uint32
	Combo, Edit, List uintptr
}
type themePaintStruct struct {
	DC              uintptr
	Erase           int32
	Paint           rect
	Restore, Update int32
	Reserved        [32]byte
}

var (
	themeSetWindowTheme = windows.NewLazySystemDLL("uxtheme.dll").NewProc("SetWindowTheme")
	themeDwmAttribute   = windows.NewLazySystemDLL("dwmapi.dll").NewProc("DwmSetWindowAttribute")
	themeComctl32       = windows.NewLazySystemDLL("comctl32.dll")
	themeSetSubclass    = themeComctl32.NewProc("SetWindowSubclass")
	themeRemoveSubclass = themeComctl32.NewProc("RemoveWindowSubclass")
	themeDefSubclass    = themeComctl32.NewProc("DefSubclassProc")
	themeSubclass       uintptr
)

func init() { themeSubclass = windows.NewCallback(themeControlProcedure) }

const (
	themeCheckbox = 1
	themeCombo    = 2
)

func themeSystemColor(index uintptr) uint32 {
	value, _, _ := getSystemColor.Call(index)
	return uint32(value)
}
func themeVisualStyle(hwnd uintptr, highContrast bool) {
	if highContrast {
		themeSetWindowTheme.Call(hwnd, 0, 0)
		return
	}
	empty := wide("")
	themeSetWindowTheme.Call(hwnd, uintptr(unsafe.Pointer(empty)), uintptr(unsafe.Pointer(empty)))
	runtime.KeepAlive(empty)
}

func (u *desktopWindow) updateControlTheme() {
	u.palette = controlPalette{Surface: 0xAE9E8F, Disabled: 0x8E7E6F, Text: 0, DisabledText: 0, Border: 0x514539, Accent: u.gold, AccentText: 0}
	if u.highContrast {
		u.palette = controlPalette{Surface: themeSystemColor(15), Disabled: themeSystemColor(15), Text: themeSystemColor(18), DisabledText: themeSystemColor(17), Border: themeSystemColor(8), Accent: themeSystemColor(13), AccentText: themeSystemColor(14)}
	}
	if u.hwnd != 0 {
		dark := uint32(1)
		caption, text, border := u.background, u.foreground, u.panel
		if u.highContrast {
			dark = 0
			caption, text, border = 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
		}
		// These documented attributes are best effort on older Windows builds.
		for _, attribute := range []struct{ id, value uint32 }{{20, dark}, {34, border}, {35, caption}, {36, text}} {
			value := attribute.value
			themeDwmAttribute.Call(u.hwnd, uintptr(attribute.id), uintptr(unsafe.Pointer(&value)), unsafe.Sizeof(value))
		}
	}
	for _, c := range u.controls {
		switch c.class {
		case "BUTTON", "COMBOBOX", "LISTBOX", "EDIT":
			themeVisualStyle(c.handle, u.highContrast)
		}
		invalidateRect.Call(c.handle, 0, 1)
	}
}

func (u *desktopWindow) themeControl(hwnd uintptr, class string, style uintptr) error {
	switch class {
	case "BUTTON", "COMBOBOX", "LISTBOX", "EDIT":
		themeVisualStyle(hwnd, u.highContrast)
	}
	kind := uintptr(0)
	if class == "BUTTON" && style&0xF == 3 { // Keep BS_AUTOCHECKBOX's native behavior.
		kind = themeCheckbox
	} else if class == "COMBOBOX" {
		kind = themeCombo
	}
	if kind != 0 {
		ok, _, _ := themeSetSubclass.Call(hwnd, themeSubclass, 1, kind)
		if ok == 0 {
			return errors.New("cannot apply the Windows control theme")
		}
	}
	return nil
}

func (u *desktopWindow) resizeControl(hwnd uintptr, class string) {
	height := uintptr(u.scale(24))
	switch class {
	case "COMBOBOX":
		send(hwnd, 0x153, 0, height)           // CB_SETITEMHEIGHT: fixed list rows.
		send(hwnd, 0x153, ^uintptr(0), height) // Selection field is index -1.
	case "LISTBOX":
		send(hwnd, 0x1A0, 0, height) // LB_SETITEMHEIGHT.
	}
}

func (u *desktopWindow) measureControl(lparam uintptr) bool {
	var item themeMeasureItem
	moveMemory.Call(uintptr(unsafe.Pointer(&item)), lparam, unsafe.Sizeof(item))
	if item.Type != 2 && item.Type != 3 { // ODT_LISTBOX / ODT_COMBOBOX.
		return false
	}
	// This can arrive inside CreateWindow, before the control is in u.controls.
	item.Height = uint32(u.scale(24))
	moveMemory.Call(lparam, uintptr(unsafe.Pointer(&item)), unsafe.Sizeof(item))
	return true
}

func themeFill(dc uintptr, area rect, color uint32) {
	brush, _, _ := gdi32.NewProc("GetStockObject").Call(18) // DC_BRUSH; no owned GDI object.
	gdi32.NewProc("SetDCBrushColor").Call(dc, uintptr(color))
	fillRect.Call(dc, uintptr(unsafe.Pointer(&area)), brush)
}
func themeFrame(dc uintptr, area rect, color uint32) {
	brush, _, _ := gdi32.NewProc("GetStockObject").Call(18)
	gdi32.NewProc("SetDCBrushColor").Call(dc, uintptr(color))
	user32.NewProc("FrameRect").Call(dc, uintptr(unsafe.Pointer(&area)), brush)
}
func themeInset(area rect, inset int) rect {
	d := int32(inset)
	return rect{area.Left + d, area.Top + d, area.Right - d, area.Bottom - d}
}
func themeEnabled(hwnd uintptr) bool {
	value, _, _ := user32.NewProc("IsWindowEnabled").Call(hwnd)
	return value != 0
}
func (u *desktopWindow) themeText(dc uintptr, area rect, text string, color uint32, flags uintptr) {
	gdi32.NewProc("SelectObject").Call(dc, u.font)
	gdi32.NewProc("SetBkMode").Call(dc, 1) // TRANSPARENT: never embossed.
	setTextColor.Call(dc, uintptr(color))
	wideText := wide(text)
	user32.NewProc("DrawTextW").Call(dc, uintptr(unsafe.Pointer(wideText)), ^uintptr(0), uintptr(unsafe.Pointer(&area)), flags|4|0x20|0x8000)
	runtime.KeepAlive(wideText)
	runtime.KeepAlive(&area)
}
func themeItemText(hwnd uintptr, kind, index uint32) string {
	if index == ^uint32(0) {
		return ""
	}
	lengthMessage, textMessage := uint32(0x149), uint32(0x148) // CB_GETLBTEXTLEN / TEXT.
	if kind == 2 {
		lengthMessage, textMessage = 0x18A, 0x189 // LB_GETTEXTLEN / TEXT.
	}
	length := int32(send(hwnd, lengthMessage, uintptr(index), 0))
	if length < 0 || length > 8191 {
		return ""
	}
	buffer := make([]uint16, int(length)+1)
	if int32(sendPointer(hwnd, textMessage, uintptr(index), &buffer[0])) < 0 {
		return ""
	}
	return windows.UTF16ToString(buffer)
}

func (u *desktopWindow) drawControl(item *drawItem) bool {
	if item.Type != 2 && item.Type != 3 && item.Type != 4 {
		return false
	}
	saved, _, _ := gdi32.NewProc("SaveDC").Call(item.DC)
	defer gdi32.NewProc("RestoreDC").Call(item.DC, saved)
	background, foreground := u.palette.Surface, u.palette.Text
	disabled := item.State&4 != 0 || !themeEnabled(item.Window)
	selected := item.State&1 != 0
	if item.Type == 4 {
		for page, id := range []int{idAudio, idConnection, idPhones, idOptions} {
			selected = selected || int(item.ID) == id && u.page == page
		}
	} else if item.Type == 3 && item.State&0x1000 != 0 {
		selected = false // Closed selection field; focus is shown on its frame.
	}
	if selected {
		background, foreground = u.palette.Accent, u.palette.AccentText
	}
	if disabled {
		background, foreground = u.palette.Disabled, u.palette.DisabledText
	}
	themeFill(item.DC, item.Rect, background)
	area := item.Rect
	area.Left += int32(u.scale(5))
	area.Right -= int32(u.scale(5))
	flags := uintptr(0x800) // DT_NOPREFIX for literal device labels.
	text := ""
	if item.Type == 4 {
		themeFrame(item.DC, item.Rect, u.palette.Border)
		flags = 1 // DT_CENTER; preserve actual control mnemonics.
		if item.State&0x100 != 0 {
			flags |= 0x100000 // DT_HIDEPREFIX.
		}
		text = textAt(item.Window)
	} else {
		text = themeItemText(item.Window, item.Type, item.ItemID)
	}
	u.themeText(item.DC, area, text, foreground, flags)
	if item.State&0x10 != 0 && item.State&0x200 == 0 && !disabled {
		focus := themeInset(item.Rect, u.scale(3))
		if u.highContrast {
			user32.NewProc("DrawFocusRect").Call(item.DC, uintptr(unsafe.Pointer(&focus)))
		} else {
			color := u.palette.Accent
			if selected {
				color = u.palette.Border
			}
			themeFrame(item.DC, focus, color)
		}
	}
	return true
}

func (u *desktopWindow) drawCheckbox(hwnd, dc uintptr) {
	saved, _, _ := gdi32.NewProc("SaveDC").Call(dc)
	defer gdi32.NewProc("RestoreDC").Call(dc, saved)
	var area rect
	getClientRect.Call(hwnd, uintptr(unsafe.Pointer(&area)))
	background, foreground := u.palette.Surface, u.palette.Text
	if !themeEnabled(hwnd) {
		background, foreground = u.palette.Disabled, u.palette.DisabledText
	}
	themeFill(dc, area, background)
	size := int32(u.scale(16))
	top := (area.Bottom - size) / 2
	box := rect{int32(u.scale(6)), top, int32(u.scale(6)) + size, top + size}
	if checked(hwnd) {
		fill := u.palette.Accent
		if !themeEnabled(hwnd) {
			fill = background
		}
		themeFill(dc, box, fill)
		u.themeText(dc, box, "✓", foreground, 1|0x800)
	}
	themeFrame(dc, box, u.palette.Border)
	label := area
	label.Left = box.Right + int32(u.scale(7))
	label.Right -= int32(u.scale(5))
	uiState := send(hwnd, 0x129, 0, 0) // WM_QUERYUISTATE.
	flags := uintptr(0)
	if uiState&2 != 0 {
		flags |= 0x100000
	}
	u.themeText(dc, label, textAt(hwnd), foreground, flags)
	if send(hwnd, 0xF2, 0, 0)&8 != 0 && uiState&1 == 0 { // BST_FOCUS.
		focus := themeInset(area, u.scale(3))
		themeFrame(dc, focus, u.palette.Accent)
	}
}

func (u *desktopWindow) drawComboFrame(hwnd, dc uintptr) {
	var info themeComboBoxInfo
	info.Size = uint32(unsafe.Sizeof(info))
	ok, _, _ := user32.NewProc("GetComboBoxInfo").Call(hwnd, uintptr(unsafe.Pointer(&info)))
	if ok == 0 {
		return
	}
	saved, _, _ := gdi32.NewProc("SaveDC").Call(dc)
	defer gdi32.NewProc("RestoreDC").Call(dc, saved)
	background, foreground := u.palette.Surface, u.palette.Text
	if !themeEnabled(hwnd) {
		background, foreground = u.palette.Disabled, u.palette.DisabledText
	} else if info.ButtonState&8 != 0 { // STATE_SYSTEM_PRESSED.
		background, foreground = u.palette.Accent, u.palette.AccentText
	}
	if info.ButtonState&0x8000 == 0 { // STATE_SYSTEM_INVISIBLE.
		themeFill(dc, info.Button, background)
		u.themeText(dc, info.Button, "▾", foreground, 1|0x800)
	}
	var area rect
	getClientRect.Call(hwnd, uintptr(unsafe.Pointer(&area)))
	themeFrame(dc, area, u.palette.Border)
}

func themeControlProcedure(hwnd uintptr, message uint32, wparam, lparam, subclassID, kind uintptr) uintptr {
	if message == 0x82 { // WM_NCDESTROY: never retain a subclass after HWND reuse.
		themeRemoveSubclass.Call(hwnd, themeSubclass, subclassID)
		r, _, _ := themeDefSubclass.Call(hwnd, uintptr(message), wparam, lparam)
		return r
	}
	u := activeWindow
	if u != nil && !u.highContrast && kind == themeCheckbox {
		switch message {
		case 0x14: // Complete custom painting erases the entire client area.
			return 1
		case 0xF:
			var paint themePaintStruct
			dc, _, _ := user32.NewProc("BeginPaint").Call(hwnd, uintptr(unsafe.Pointer(&paint)))
			if dc != 0 {
				u.drawCheckbox(hwnd, dc)
			}
			user32.NewProc("EndPaint").Call(hwnd, uintptr(unsafe.Pointer(&paint)))
			return 0
		case 0x317, 0x318:
			if wparam != 0 {
				u.drawCheckbox(hwnd, wparam)
			}
			return 0
		}
	}
	r, _, _ := themeDefSubclass.Call(hwnd, uintptr(message), wparam, lparam)
	if u == nil || u.highContrast {
		return r
	}
	if kind == themeCombo && (message == 0xF || message == 0x317 || message == 0x318) {
		dc := wparam
		if message == 0xF {
			dc, _, _ = user32.NewProc("GetDC").Call(hwnd)
			defer user32.NewProc("ReleaseDC").Call(hwnd, dc)
		}
		if dc != 0 {
			u.drawComboFrame(hwnd, dc)
		}
	}
	switch message {
	case 0x7, 0x8, 0xA, 0xC, 0x30, 0xF1, 0xF3, 0x127, 0x128, 0x143, 0x14B, 0x14E, 0x31A:
		// Native BUTTON can repaint during state changes without WM_PAINT.
		// Repaint our flat appearance after preserving its native behavior/state.
		invalidateRect.Call(hwnd, 0, 0)
	case 0x100, 0x101, 0x201, 0x202, 0x14F:
		if kind == themeCombo {
			// Native combo input/dropdown changes can redraw its arrow directly.
			invalidateRect.Call(hwnd, 0, 0)
		}
	}
	return r
}
