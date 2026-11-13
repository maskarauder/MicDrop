// SPDX-License-Identifier: MPL-2.0
#if defined(__APPLE__) && defined(__aarch64__)

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <UserNotifications/UserNotifications.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "appkit_darwin.h"
#include "_cgo_export.h"

static BOOL mdHighContrast(void) {
  return [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldIncreaseContrast];
}

static NSColor* mdBackgroundColor(void) {
  if (mdHighContrast()) {
    return [NSColor windowBackgroundColor];
  }
  return [NSColor colorWithSRGBRed:(CGFloat)0x20 / 255.0
                             green:(CGFloat)0x28 / 255.0
                              blue:(CGFloat)0x31 / 255.0
                             alpha:1.0];
}

static NSColor* mdPanelColor(void) {
  if (mdHighContrast()) {
    return [NSColor controlBackgroundColor];
  }
  return [NSColor colorWithSRGBRed:(CGFloat)0x2A / 255.0
                             green:(CGFloat)0x35 / 255.0
                              blue:(CGFloat)0x41 / 255.0
                             alpha:1.0];
}

static NSColor* mdBorderColor(void) {
  if (mdHighContrast()) {
    return [NSColor separatorColor];
  }
  return [NSColor colorWithSRGBRed:(CGFloat)0x3B / 255.0
                             green:(CGFloat)0x49 / 255.0
                              blue:(CGFloat)0x58 / 255.0
                             alpha:1.0];
}

static NSColor* mdForegroundColor(void) {
  if (mdHighContrast()) {
    return [NSColor labelColor];
  }
  return [NSColor colorWithSRGBRed:(CGFloat)0xE9 / 255.0
                             green:(CGFloat)0xEE / 255.0
                              blue:(CGFloat)0xF2 / 255.0
                             alpha:1.0];
}

static NSColor* mdGoldColor(void) {
  if (mdHighContrast()) {
    return [NSColor controlAccentColor];
  }
  return [NSColor colorWithSRGBRed:(CGFloat)0xD4 / 255.0
                             green:(CGFloat)0xAC / 255.0
                              blue:(CGFloat)0x45 / 255.0
                             alpha:1.0];
}

static NSString* mdString(const char* text) {
  if (text == NULL) {
    return @"";
  }
  NSString* s = [NSString stringWithUTF8String:text];
  return s != nil ? s : @"";
}

static char* mdDupUTF8(NSString* s) {
  if (s == nil) {
    s = @"";
  }
  const char* utf8 = [s UTF8String];
  if (utf8 == NULL) {
    utf8 = "";
  }
  size_t len = strlen(utf8);
  char* out = (char*)malloc(len + 1);
  if (out != NULL) {
    memcpy(out, utf8, len + 1);
  }
  return out;
}

@interface MicDropMaxLengthFormatter : NSFormatter
@property(nonatomic, assign) NSUInteger maxLength;
@end

@implementation MicDropMaxLengthFormatter
- (NSString*)stringForObjectValue:(id)obj {
  if ([obj isKindOfClass:[NSString class]]) {
    return (NSString*)obj;
  }
  return [obj description] ?: @"";
}

- (BOOL)getObjectValue:(out id _Nullable* _Nullable)obj
             forString:(NSString*)string
      errorDescription:(out NSString* _Nullable* _Nullable)error {
  (void)error;
  if (obj != NULL) {
    *obj = string ?: @"";
  }
  return YES;
}

- (BOOL)isPartialStringValid:(NSString* _Nonnull* _Nonnull)partialStringPtr
       proposedSelectedRange:(NSRangePointer)proposedSelRangePtr
              originalString:(NSString*)origString
       originalSelectedRange:(NSRange)origSelRange
            errorDescription:(NSString* _Nullable* _Nullable)error {
  (void)proposedSelRangePtr;
  (void)origString;
  (void)origSelRange;
  (void)error;
  if (self.maxLength > 0 && [*partialStringPtr length] > self.maxLength) {
    return NO;
  }
  return YES;
}
@end

@interface MicDropQRView : NSView
@property(nonatomic, strong, nullable) NSImage* qrImage;
- (void)setRGBAData:(nullable const uint8_t*)rgba size:(int)sizePx;
@end

@implementation MicDropQRView
- (BOOL)isFlipped {
  return YES;
}

- (void)setRGBAData:(nullable const uint8_t*)rgba size:(int)sizePx {
  if (rgba == NULL || sizePx <= 0) {
    self.qrImage = nil;
    [self setNeedsDisplay:YES];
    return;
  }
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL
                    pixelsWide:sizePx
                    pixelsHigh:sizePx
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace
                  bitmapFormat:0
                   bytesPerRow:sizePx * 4
                  bitsPerPixel:32];
  if (rep == nil || [rep bitmapData] == NULL) {
    self.qrImage = nil;
    [self setNeedsDisplay:YES];
    return;
  }
  memcpy([rep bitmapData], rgba, (size_t)sizePx * (size_t)sizePx * 4);
  NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(sizePx, sizePx)];
  [img addRepresentation:rep];
  self.qrImage = img;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSBezierPath* card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                       xRadius:8.0
                                                       yRadius:8.0];
  [mdPanelColor() setFill];
  [card fill];
  [mdBorderColor() setStroke];
  [card setLineWidth:1.0];
  [card stroke];

  if (self.qrImage != nil) {
    NSGraphicsContext* ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    [ctx setImageInterpolation:NSImageInterpolationNone];
    NSRect dest = NSInsetRect(self.bounds, 8.0, 8.0);
    [self.qrImage drawInRect:dest
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0
              respectFlipped:YES
                       hints:nil];
    [ctx restoreGraphicsState];
    return;
  }

  NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
  style.alignment = NSTextAlignmentCenter;
  style.lineBreakMode = NSLineBreakByWordWrapping;
  NSDictionary* attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : mdForegroundColor(),
    NSParagraphStyleAttributeName : style,
  };
  NSString* text = @"Start pairing to create a private QR code";
  NSRect textArea = NSInsetRect(self.bounds, 20.0, 0.0);
  NSRect measured = [text boundingRectWithSize:NSMakeSize(textArea.size.width, textArea.size.height)
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:attrs];
  NSRect drawBox = NSMakeRect(textArea.origin.x,
                              (self.bounds.size.height - measured.size.height) * 0.5,
                              textArea.size.width,
                              measured.size.height + 4.0);
  [text drawInRect:drawBox withAttributes:attrs];
}
@end

@interface MicDropFlippedView : NSView
@end

@implementation MicDropFlippedView
- (BOOL)isFlipped {
  return YES;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  md_ui_layout();
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [mdBackgroundColor() setFill];
  NSRectFill(self.bounds);

  CGFloat width = self.bounds.size.width;
  CGFloat height = self.bounds.size.height;
  if (width > 40.0 && height > 240.0) {
    NSRect headerRect = NSMakeRect(14.0, 10.0, width - 28.0, 132.0);
    NSBezierPath* headerCard = [NSBezierPath bezierPathWithRoundedRect:headerRect xRadius:8.0 yRadius:8.0];
    [mdPanelColor() setFill];
    [headerCard fill];
    [mdBorderColor() setStroke];
    [headerCard setLineWidth:1.0];
    [headerCard stroke];

    [mdGoldColor() setFill];
    NSRectFill(NSMakeRect(24.0, 190.0, width - 48.0, 2.0));
    NSRectFill(NSMakeRect(24.0, height - 96.0, width - 48.0, 2.0));
  }
}
@end

@interface MicDropListSource : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, assign) int controlID;
@property(nonatomic, assign) BOOL suppressEvents;
@property(nonatomic, strong) NSMutableArray<NSString*>* items;
@property(nonatomic, weak) NSTableView* tableView;
- (void)handleDoubleClick:(id)sender;
@end

@implementation MicDropListSource
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _items = [[NSMutableArray alloc] init];
  }
  return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
  (void)tableView;
  return (NSInteger)self.items.count;
}

- (nullable NSView*)tableView:(NSTableView*)tableView
           viewForTableColumn:(nullable NSTableColumn*)tableColumn
                          row:(NSInteger)row {
  (void)tableColumn;
  if (row < 0 || (NSUInteger)row >= self.items.count) {
    return nil;
  }
  NSUserInterfaceItemIdentifier ident = @"MicDropRowCell";
  NSTableCellView* cell = [tableView makeViewWithIdentifier:ident owner:nil];
  if (cell == nil) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    cell.identifier = ident;
    NSTextField* label = [NSTextField labelWithString:@""];
    label.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
    label.textColor = mdForegroundColor();
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.frame = NSMakeRect(6, 3, 188, 18);
    label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    [cell addSubview:label];
    cell.textField = label;
  }
  cell.textField.textColor = mdForegroundColor();
  cell.textField.stringValue = self.items[(NSUInteger)row];
  return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
  (void)notification;
  if (!self.suppressEvents) {
    goMicDropEvent(self.controlID, MD_EVENT_CHANGE);
  }
}

- (void)handleDoubleClick:(id)sender {
  (void)sender;
  NSTableView* tv = self.tableView;
  if (tv != nil && tv.isEnabled && (tv.clickedRow >= 0 || tv.selectedRow >= 0)) {
    goMicDropEvent(self.controlID, MD_EVENT_DBLCLK);
  }
}
@end

@interface MicDropControlEntry : NSObject
@property(nonatomic, assign) int controlID;
@property(nonatomic, assign) int kind;
@property(nonatomic, assign) int page;
@property(nonatomic, assign) int x;
@property(nonatomic, assign) int y;
@property(nonatomic, assign) int w;
@property(nonatomic, assign) int h;
@property(nonatomic, assign) BOOL readOnlyFlag;
@property(nonatomic, strong) NSView* view;
@property(nonatomic, strong, nullable) NSTextField* textField;
@property(nonatomic, strong, nullable) NSButton* button;
@property(nonatomic, strong, nullable) NSPopUpButton* popUp;
@property(nonatomic, strong, nullable) NSTextView* textView;
@property(nonatomic, strong, nullable) NSTableView* tableView;
@property(nonatomic, strong, nullable) MicDropListSource* listSource;
@property(nonatomic, strong, nullable) MicDropQRView* qrView;
@end

@implementation MicDropControlEntry
@end

@interface MicDropAppController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, assign) BOOL headlessTest;
@property(nonatomic, assign) BOOL requestedNotifAuth;
@property(nonatomic, assign) BOOL pendingSystemTerminate;
@property(nonatomic, assign) int exitControlID;
@property(nonatomic, assign) int startControlID;
@property(nonatomic, assign) int stopControlID;
@property(nonatomic, strong, nullable) NSWindow* window;
@property(nonatomic, strong, nullable) MicDropFlippedView* contentView;
@property(nonatomic, strong, nullable) NSTimer* timer;
@property(nonatomic, strong, nullable) NSStatusItem* statusItem;
@property(nonatomic, strong, nullable) NSMenuItem* statusHeaderItem;
@property(nonatomic, strong, nullable) NSMenuItem* statusToggleItem;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, MicDropControlEntry*>* controls;
- (void)handleControlAction:(id)sender;
- (void)handlePopupAction:(id)sender;
- (void)handleTimer:(NSTimer*)timer;
- (void)handleOpenWindow:(id)sender;
- (void)handleToggleHost:(id)sender;
- (void)handleQuit:(id)sender;
- (void)completeSystemTerminate;
@end

static MicDropAppController* gApp = nil;
static int gTestTerminateApprovedCount = 0;

static void mdPostStopLoop(void) {
  [NSApp stop:nil];
  NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                     location:NSMakePoint(0, 0)
                                modifierFlags:0
                                    timestamp:0
                                 windowNumber:0
                                      context:nil
                                      subtype:0
                                        data1:0
                                        data2:0];
  if (wake != nil) {
    [NSApp postEvent:wake atStart:YES];
  }
}

@implementation MicDropAppController
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _controls = [[NSMutableDictionary alloc] init];
    _startControlID = 100;
    _stopControlID = 101;
    _exitControlID = 107;
  }
  return self;
}

- (void)handleControlAction:(id)sender {
  if ([sender isKindOfClass:[NSControl class]]) {
    NSControl* ctrl = (NSControl*)sender;
    goMicDropEvent((int)ctrl.tag, MD_EVENT_CLICK);
  }
}

- (void)handlePopupAction:(id)sender {
  if ([sender isKindOfClass:[NSControl class]]) {
    NSControl* ctrl = (NSControl*)sender;
    goMicDropEvent((int)ctrl.tag, MD_EVENT_CHANGE);
  }
}

- (void)handleTimer:(NSTimer*)timer {
  (void)timer;
  goMicDropTick();
}

- (void)handleOpenWindow:(id)sender {
  (void)sender;
  goMicDropShow();
}

- (void)handleToggleHost:(id)sender {
  if ([sender isKindOfClass:[NSMenuItem class]]) {
    NSMenuItem* item = (NSMenuItem*)sender;
    goMicDropEvent((int)item.tag, MD_EVENT_CLICK);
  }
}

- (void)handleQuit:(id)sender {
  (void)sender;
  if ([NSApp modalWindow] != nil) {
    [NSApp abortModal];
  }
  goMicDropEvent(self.exitControlID, MD_EVENT_CLICK);
}

- (void)completeSystemTerminate {
  if (!self.pendingSystemTerminate) {
    return;
  }
  self.pendingSystemTerminate = NO;
  if (self.headlessTest) {
    gTestTerminateApprovedCount += 1;
    mdPostStopLoop();
    return;
  }
  md_app_cleanup();
  [NSApp replyToApplicationShouldTerminate:YES];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  (void)sender;
  self.pendingSystemTerminate = YES;
  if ([NSApp modalWindow] != nil) {
    [NSApp abortModal];
  }
  goMicDropEvent(self.exitControlID, MD_EVENT_CLICK);
  return NSTerminateLater;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag {
  (void)sender;
  if (!flag) {
    goMicDropShow();
  }
  return YES;
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (self.statusItem != nil) {
    [sender orderOut:nil];
    return NO;
  }
  goMicDropEvent(self.exitControlID, MD_EVENT_CLICK);
  return NO;
}
@end

static void mdSetupMainMenu(MicDropAppController* controller) {
  NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];

  NSMenuItem* appMenuItem = [[NSMenuItem alloc] initWithTitle:@"MicDrop" action:nil keyEquivalent:@""];
  NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"MicDrop"];
  [appMenu addItemWithTitle:@"About MicDrop"
                     action:@selector(orderFrontStandardAboutPanel:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Hide MicDrop" action:@selector(hide:) keyEquivalent:@"h"];
  NSMenuItem* hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                              action:@selector(hideOtherApplications:)
                                       keyEquivalent:@"h"];
  hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit MicDrop"
                                                    action:@selector(handleQuit:)
                                             keyEquivalent:@"q"];
  quitItem.target = controller;
  [appMenu addItem:quitItem];
  appMenuItem.submenu = appMenu;
  [mainMenu addItem:appMenuItem];

  NSMenuItem* editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
  NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  editMenuItem.submenu = editMenu;
  [mainMenu addItem:editMenuItem];

  NSMenuItem* windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
  NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
  windowMenuItem.submenu = windowMenu;
  [mainMenu addItem:windowMenuItem];

  [NSApp setMainMenu:mainMenu];
}

static void mdSetupStatusItem(MicDropAppController* controller) {
  if (controller.headlessTest) {
    return;
  }
  NSStatusItem* item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  if (item == nil) {
    return;
  }
  NSStatusBarButton* button = item.button;
  if (button != nil) {
    NSImage* img = [NSImage imageWithSystemSymbolName:@"mic"
                             accessibilityDescription:@"MicDrop"];
    if (img != nil) {
      [img setTemplate:YES];
      button.image = img;
    } else {
      button.title = @"MicDrop";
    }
    button.toolTip = @"MicDrop · Stopped";
  }

  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"MicDrop"];
  NSMenuItem* header = [[NSMenuItem alloc] initWithTitle:@"MicDrop · Stopped"
                                                  action:nil
                                           keyEquivalent:@""];
  header.enabled = NO;
  [menu addItem:header];
  [menu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* openItem = [[NSMenuItem alloc] initWithTitle:@"Open MicDrop"
                                                    action:@selector(handleOpenWindow:)
                                             keyEquivalent:@""];
  openItem.target = controller;
  [menu addItem:openItem];

  NSMenuItem* toggleItem = [[NSMenuItem alloc] initWithTitle:@"Start host"
                                                      action:@selector(handleToggleHost:)
                                               keyEquivalent:@""];
  toggleItem.target = controller;
  toggleItem.tag = controller.startControlID;
  [menu addItem:toggleItem];

  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit MicDrop"
                                                    action:@selector(handleQuit:)
                                             keyEquivalent:@""];
  quitItem.target = controller;
  [menu addItem:quitItem];

  item.menu = menu;
  controller.statusItem = item;
  controller.statusHeaderItem = header;
  controller.statusToggleItem = toggleItem;
}

int md_app_is_main_thread(void) {
  return pthread_main_np() == 1 ? 1 : 0;
}

int md_app_init(const char* window_title, int headless_test, int start_id, int stop_id, int exit_id, char* err_buf, size_t err_cap) {
  @autoreleasepool {
    if (pthread_main_np() != 1) {
      if (err_buf != NULL && err_cap > 0) {
        snprintf(err_buf, err_cap, "macOS AppKit UI must run on the main thread");
      }
      return 0;
    }
    NSApplication* app = [NSApplication sharedApplication];
    if (app == nil) {
      if (err_buf != NULL && err_cap > 0) {
        snprintf(err_buf, err_cap, "NSApplication is unavailable");
      }
      return 0;
    }
    if (headless_test) {
      [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
    } else {
      [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    }

    gTestTerminateApprovedCount = 0;
    MicDropAppController* controller = [[MicDropAppController alloc] init];
    controller.headlessTest = headless_test != 0;
    controller.startControlID = start_id;
    controller.stopControlID = stop_id;
    controller.exitControlID = exit_id;
    gApp = controller;
    [app setDelegate:controller];

    if (!controller.headlessTest) {
      mdSetupMainMenu(controller);
    }

    NSUInteger mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSRect contentRect = NSMakeRect(0, 0, 880, 720);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:contentRect
                                                   styleMask:mask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if (window == nil) {
      if (err_buf != NULL && err_cap > 0) {
        snprintf(err_buf, err_cap, "cannot create macOS desktop window");
      }
      gApp = nil;
      return 0;
    }
    [window setReleasedWhenClosed:NO];
    window.title = mdString(window_title);
    window.minSize = NSMakeSize(860, 728);
    [window setContentMinSize:NSMakeSize(860, 700)];
    if (!mdHighContrast()) {
      NSAppearance* dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
      if (dark != nil) {
        window.appearance = dark;
      }
    }
    window.backgroundColor = mdBackgroundColor();
    window.delegate = controller;

    MicDropFlippedView* content = [[MicDropFlippedView alloc] initWithFrame:contentRect];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = content;
    if (!controller.headlessTest) {
      [window center];
    }

    controller.window = window;
    controller.contentView = content;
    mdSetupStatusItem(controller);

    NSTimer* timer = [NSTimer timerWithTimeInterval:0.25
                                             target:controller
                                           selector:@selector(handleTimer:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    controller.timer = timer;
    return 1;
  }
}

void md_app_show_window(int activate) {
  @autoreleasepool {
    if (gApp == nil || gApp.window == nil) {
      return;
    }
    if (gApp.headlessTest) {
      [gApp.window layoutIfNeeded];
      return;
    }
    [gApp.window makeKeyAndOrderFront:nil];
    if (activate) {
      [NSApp activate];
    }
  }
}

void md_app_hide_window(void) {
  @autoreleasepool {
    if (gApp != nil && gApp.window != nil) {
      [gApp.window orderOut:nil];
    }
  }
}

void md_app_run(void) {
  @autoreleasepool {
    [NSApp run];
  }
}

void md_app_stop_loop(void) {
  @autoreleasepool {
    if (gApp != nil && gApp.pendingSystemTerminate) {
      [NSObject cancelPreviousPerformRequestsWithTarget:gApp
                                               selector:@selector(completeSystemTerminate)
                                                 object:nil];
      [gApp performSelector:@selector(completeSystemTerminate)
                 withObject:nil
                 afterDelay:0.0
                    inModes:@[ NSRunLoopCommonModes, NSModalPanelRunLoopMode ]];
      return;
    }
    mdPostStopLoop();
  }
}

void md_app_cleanup(void) {
  @autoreleasepool {
    if (gApp == nil) {
      return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:gApp];
    if (gApp.timer != nil) {
      [gApp.timer invalidate];
      gApp.timer = nil;
    }
    if (gApp.statusItem != nil) {
      [[NSStatusBar systemStatusBar] removeStatusItem:gApp.statusItem];
      gApp.statusItem = nil;
    }
    if (gApp.window != nil) {
      gApp.window.delegate = nil;
      [gApp.window orderOut:nil];
      [gApp.window close];
      gApp.window = nil;
    }
    [gApp.controls removeAllObjects];
    gApp.contentView = nil;
    if ([NSApp delegate] == gApp) {
      [NSApp setDelegate:nil];
    }
    gApp = nil;
  }
}

void md_app_dispatch_wake(void) {
  CFRunLoopRef mainLoop = CFRunLoopGetMain();
  if (mainLoop == NULL) {
    return;
  }
  NSArray<NSRunLoopMode>* modes = @[ NSRunLoopCommonModes, NSModalPanelRunLoopMode ];
  CFRunLoopPerformBlock(mainLoop, (__bridge CFTypeRef)modes, ^{
    @autoreleasepool {
      if (gApp != nil) {
        goMicDropTick();
      }
    }
  });
  CFRunLoopWakeUp(mainLoop);
}

void md_app_wake_test(void) {
  CFRunLoopRef mainLoop = CFRunLoopGetMain();
  if (mainLoop == NULL) {
    return;
  }
  NSArray<NSRunLoopMode>* modes = @[ NSRunLoopCommonModes, NSModalPanelRunLoopMode ];
  CFRunLoopPerformBlock(mainLoop, (__bridge CFTypeRef)modes, ^{
    @autoreleasepool {
      goMicDropDrainTestQueue();
    }
  });
  CFRunLoopWakeUp(mainLoop);
}

static MicDropControlEntry* mdEntry(int controlID) {
  if (gApp == nil) {
    return nil;
  }
  return gApp.controls[@(controlID)];
}

int md_ui_add_control(int controlID, int kind, const char* title, int page, int x, int y, int w, int h) {
  @autoreleasepool {
    if (gApp == nil || gApp.contentView == nil) {
      return 0;
    }
    MicDropControlEntry* entry = [[MicDropControlEntry alloc] init];
    entry.controlID = controlID;
    entry.kind = kind;
    entry.page = page;
    entry.x = x;
    entry.y = y;
    entry.w = w;
    entry.h = h;

    NSString* text = mdString(title);
    NSRect initialFrame = NSMakeRect(0, 0, w > 0 ? w : 100, h > 0 ? h : 28);

    switch (kind) {
      case MD_KIND_TITLE:
      case MD_KIND_LABEL: {
        NSTextField* label = [NSTextField wrappingLabelWithString:text];
        label.frame = initialFrame;
        label.editable = NO;
        label.selectable = NO;
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.textColor = mdForegroundColor();
        if (kind == MD_KIND_TITLE) {
          label.font = [NSFont systemFontOfSize:24.0 weight:NSFontWeightSemibold];
          label.textColor = mdGoldColor();
        } else {
          label.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
        }
        entry.textField = label;
        entry.view = label;
        break;
      }
      case MD_KIND_BUTTON: {
        NSButton* btn = [NSButton buttonWithTitle:text
                                           target:gApp
                                           action:@selector(handleControlAction:)];
        btn.frame = initialFrame;
        btn.bezelStyle = NSBezelStyleRounded;
        btn.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
        btn.tag = controlID;
        entry.button = btn;
        entry.view = btn;
        break;
      }
      case MD_KIND_CHECKBOX: {
        NSButton* cb = [NSButton checkboxWithTitle:text
                                            target:gApp
                                            action:@selector(handleControlAction:)];
        cb.frame = initialFrame;
        cb.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
        cb.contentTintColor = mdGoldColor();
        cb.tag = controlID;
        entry.button = cb;
        entry.view = cb;
        break;
      }
      case MD_KIND_POPUP: {
        NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:initialFrame pullsDown:NO];
        popup.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
        popup.target = gApp;
        popup.action = @selector(handlePopupAction:);
        popup.tag = controlID;
        entry.popUp = popup;
        entry.view = popup;
        break;
      }
      case MD_KIND_EDIT: {
        NSTextField* tf = [[NSTextField alloc] initWithFrame:initialFrame];
        tf.stringValue = text;
        tf.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
        tf.editable = YES;
        tf.selectable = YES;
        tf.bezeled = YES;
        tf.bezelStyle = NSTextFieldSquareBezel;
        tf.drawsBackground = YES;
        tf.backgroundColor = mdPanelColor();
        tf.textColor = mdForegroundColor();
        tf.usesSingleLineMode = YES;
        tf.tag = controlID;
        entry.textField = tf;
        entry.view = tf;
        break;
      }
      case MD_KIND_MULTILINE: {
        NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:initialFrame];
        scroll.hasVerticalScroller = YES;
        scroll.hasHorizontalScroller = NO;
        scroll.borderType = NSLineBorder;
        scroll.drawsBackground = YES;
        scroll.backgroundColor = mdPanelColor();

        NSTextView* tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, initialFrame.size.width, initialFrame.size.height)];
        tv.minSize = NSMakeSize(0.0, initialFrame.size.height);
        tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
        tv.verticallyResizable = YES;
        tv.horizontallyResizable = NO;
        tv.autoresizingMask = NSViewWidthSizable;
        tv.textContainer.containerSize = NSMakeSize(initialFrame.size.width, FLT_MAX);
        tv.textContainer.widthTracksTextView = YES;
        tv.editable = NO;
        tv.selectable = YES;
        tv.richText = NO;
        tv.drawsBackground = YES;
        tv.backgroundColor = mdPanelColor();
        tv.textColor = mdForegroundColor();
        tv.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
        tv.string = text;
        scroll.documentView = tv;

        entry.readOnlyFlag = YES;
        entry.textView = tv;
        entry.view = scroll;
        break;
      }
      case MD_KIND_LIST: {
        NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:initialFrame];
        scroll.hasVerticalScroller = YES;
        scroll.hasHorizontalScroller = NO;
        scroll.borderType = NSLineBorder;
        scroll.drawsBackground = YES;
        scroll.backgroundColor = mdPanelColor();

        NSTableView* table = [[NSTableView alloc] initWithFrame:initialFrame];
        table.headerView = nil;
        table.rowHeight = 24.0;
        table.backgroundColor = mdPanelColor();
        table.allowsEmptySelection = YES;
        table.allowsMultipleSelection = NO;
        table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

        NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"MainColumn"];
        col.width = initialFrame.size.width;
        col.resizingMask = NSTableColumnAutoresizingMask;
        [table addTableColumn:col];

        MicDropListSource* source = [[MicDropListSource alloc] init];
        source.controlID = controlID;
        source.tableView = table;
        table.dataSource = source;
        table.delegate = source;
        table.target = source;
        table.doubleAction = @selector(handleDoubleClick:);
        scroll.documentView = table;

        entry.tableView = table;
        entry.listSource = source;
        entry.view = scroll;
        break;
      }
      case MD_KIND_QR: {
        MicDropQRView* qr = [[MicDropQRView alloc] initWithFrame:initialFrame];
        entry.qrView = qr;
        entry.view = qr;
        break;
      }
      default:
        return 0;
    }

    [gApp.contentView addSubview:entry.view];
    gApp.controls[@(controlID)] = entry;
    return 1;
  }
}

void md_ui_layout(void) {
  @autoreleasepool {
    if (gApp == nil || gApp.contentView == nil) {
      return;
    }
    NSRect bounds = gApp.contentView.bounds;
    int width = (int)bounds.size.width;
    int height = (int)bounds.size.height;
    for (MicDropControlEntry* entry in [gApp.controls objectEnumerator]) {
      int x = entry.x;
      int y = entry.y;
      int w = entry.w;
      int h = entry.h;
      if (x < 0) {
        x = width + x;
      }
      if (y < 0) {
        y = height + y;
      }
      if (w < 0) {
        w = width - x + w;
      }
      if (w < 1) {
        w = 1;
      }
      entry.view.frame = NSMakeRect((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h);
      if (entry.tableView != nil && entry.tableView.tableColumns.count > 0) {
        CGFloat colW = (CGFloat)w - 18.0;
        if (colW < 40.0) {
          colW = 40.0;
        }
        entry.tableView.tableColumns[0].width = colW;
      }
    }
    [gApp.contentView setNeedsDisplay:YES];
  }
}

void md_ui_select_page(int page) {
  @autoreleasepool {
    if (gApp == nil) {
      return;
    }
    for (MicDropControlEntry* entry in [gApp.controls objectEnumerator]) {
      BOOL show = (entry.page < 0 || entry.page == page);
      entry.view.hidden = !show;
    }
    [gApp.contentView setNeedsDisplay:YES];
  }
}

void md_ui_set_visible(int controlID, int visible) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil) {
      entry.view.hidden = (visible == 0);
    }
  }
}

void md_ui_set_text(int controlID, const char* text) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil) {
      return;
    }
    NSString* s = mdString(text);
    if (entry.textField != nil) {
      entry.textField.stringValue = s;
    } else if (entry.button != nil) {
      entry.button.title = s;
    } else if (entry.textView != nil) {
      entry.textView.string = s;
    }
  }
}

char* md_ui_copy_text(int controlID) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil) {
      return mdDupUTF8(@"");
    }
    if (entry.textField != nil) {
      return mdDupUTF8(entry.textField.stringValue);
    }
    if (entry.button != nil) {
      return mdDupUTF8(entry.button.title);
    }
    if (entry.textView != nil) {
      return mdDupUTF8(entry.textView.string);
    }
    return mdDupUTF8(@"");
  }
}

void md_ui_set_enabled(int controlID, int enabled) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil) {
      return;
    }
    BOOL flag = enabled != 0;
    if ([entry.view isKindOfClass:[NSControl class]]) {
      [(NSControl*)entry.view setEnabled:flag];
    } else if (entry.tableView != nil) {
      entry.tableView.enabled = flag;
      entry.view.alphaValue = flag ? 1.0 : 0.6;
    }
  }
}

int md_ui_is_enabled(int controlID) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil) {
      return 0;
    }
    if ([entry.view isKindOfClass:[NSControl class]]) {
      return [(NSControl*)entry.view isEnabled] ? 1 : 0;
    }
    if (entry.tableView != nil) {
      return entry.tableView.isEnabled ? 1 : 0;
    }
    return 1;
  }
}

void md_ui_set_readonly(int controlID, int readonly_flag) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil) {
      return;
    }
    BOOL ro = readonly_flag != 0;
    entry.readOnlyFlag = ro;
    if (entry.textField != nil) {
      if (entry.textField.isEditable == !ro) {
        return;
      }
      entry.textField.editable = !ro;
      entry.textField.selectable = YES;
      entry.textField.alphaValue = ro ? 0.72 : 1.0;
    } else if (entry.textView != nil) {
      entry.textView.editable = !ro;
      entry.textView.selectable = YES;
    }
  }
}

int md_ui_is_readonly(int controlID) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil) {
      return 0;
    }
    if (entry.textField != nil) {
      return entry.textField.isEditable ? 0 : 1;
    }
    return entry.readOnlyFlag ? 1 : 0;
  }
}

void md_ui_set_checked(int controlID, int checked) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil && entry.button != nil) {
      entry.button.state = checked != 0 ? NSControlStateValueOn : NSControlStateValueOff;
    }
  }
}

int md_ui_is_checked(int controlID) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil && entry.button != nil) {
      return entry.button.state == NSControlStateValueOn ? 1 : 0;
    }
    return 0;
  }
}

void md_ui_set_max_length(int controlID, int max_len) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil && entry.textField != nil && max_len > 0) {
      MicDropMaxLengthFormatter* fmt = [[MicDropMaxLengthFormatter alloc] init];
      fmt.maxLength = (NSUInteger)max_len;
      entry.textField.formatter = fmt;
    }
  }
}

void md_ui_set_popup_items(int controlID, char** items, int count, int selected) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil || entry.popUp == nil) {
      return;
    }
    NSMenu* menu = entry.popUp.menu;
    [menu removeAllItems];
    for (int i = 0; i < count; i++) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:mdString(items[i])
                                                    action:nil
                                             keyEquivalent:@""];
      [menu addItem:item];
    }
    if (selected >= 0 && selected < count) {
      [entry.popUp selectItemAtIndex:selected];
    } else if (count == 0) {
      [entry.popUp selectItem:nil];
    }
  }
}

int md_ui_popup_selected(int controlID) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil && entry.popUp != nil) {
      return (int)entry.popUp.indexOfSelectedItem;
    }
    return -1;
  }
}

int md_ui_popup_count(int controlID) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil && entry.popUp != nil) {
      return (int)entry.popUp.numberOfItems;
    }
    return 0;
  }
}

int md_ui_popup_find_exact(int controlID, const char* title) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil || entry.popUp == nil) {
      return -1;
    }
    NSString* target = mdString(title);
    NSArray<NSMenuItem*>* items = entry.popUp.itemArray;
    for (NSUInteger i = 0; i < items.count; i++) {
      if ([items[i].title isEqualToString:target]) {
        return (int)i;
      }
    }
    return -1;
  }
}

void md_ui_set_list_items(int controlID, char** items, int count, int selected) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil || entry.listSource == nil || entry.tableView == nil) {
      return;
    }
    entry.listSource.suppressEvents = YES;
    [entry.listSource.items removeAllObjects];
    for (int i = 0; i < count; i++) {
      [entry.listSource.items addObject:mdString(items[i])];
    }
    [entry.tableView reloadData];
    if (selected >= 0 && selected < count) {
      NSIndexSet* indexes = [NSIndexSet indexSetWithIndex:(NSUInteger)selected];
      [entry.tableView selectRowIndexes:indexes byExtendingSelection:NO];
    } else {
      [entry.tableView deselectAll:nil];
    }
    entry.listSource.suppressEvents = NO;
  }
}

int md_ui_list_selected(int controlID) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil && entry.tableView != nil) {
      return (int)entry.tableView.selectedRow;
    }
    return -1;
  }
}

void md_ui_list_select(int controlID, int selected) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil || entry.tableView == nil || entry.listSource == nil) {
      return;
    }
    entry.listSource.suppressEvents = YES;
    if (selected >= 0 && (NSUInteger)selected < entry.listSource.items.count) {
      [entry.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selected]
                   byExtendingSelection:NO];
    } else {
      [entry.tableView deselectAll:nil];
    }
    entry.listSource.suppressEvents = NO;
  }
}

void md_ui_set_qr_rgba(const uint8_t* rgba, int size_px) {
  @autoreleasepool {
    if (gApp == nil) {
      return;
    }
    for (MicDropControlEntry* entry in [gApp.controls objectEnumerator]) {
      if (entry.qrView != nil) {
        [entry.qrView setRGBAData:rgba size:size_px];
      }
    }
  }
}

void md_ui_update_tray(const char* status, int running, int connected) {
  @autoreleasepool {
    if (gApp == nil || gApp.statusItem == nil) {
      return;
    }
    NSString* statusText = [NSString stringWithFormat:@"MicDrop · %@", mdString(status)];
    NSStatusBarButton* button = gApp.statusItem.button;
    if (button != nil) {
      button.toolTip = statusText;
      NSString* symbolName = @"mic";
      if (connected != 0) {
        symbolName = @"waveform";
      } else if (running != 0) {
        symbolName = @"mic.fill";
      }
      NSImage* img = [NSImage imageWithSystemSymbolName:symbolName
                               accessibilityDescription:statusText];
      if (img != nil) {
        [img setTemplate:YES];
        button.image = img;
        button.title = @"";
      } else {
        button.title = @"MicDrop";
      }
    }
    if (gApp.statusHeaderItem != nil) {
      gApp.statusHeaderItem.title = statusText;
    }
    if (gApp.statusToggleItem != nil) {
      if (running != 0) {
        gApp.statusToggleItem.title = @"Stop host";
        gApp.statusToggleItem.tag = gApp.stopControlID;
      } else {
        gApp.statusToggleItem.title = @"Start host";
        gApp.statusToggleItem.tag = gApp.startControlID;
      }
    }
  }
}

void md_ui_notify(const char* title, const char* body, int warning) {
  (void)warning;
  @autoreleasepool {
    if (gApp == nil || gApp.headlessTest) {
      return;
    }
    NSString* bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleID == nil || bundleID.length == 0) {
      return;
    }
    NSString* nTitle = mdString(title);
    NSString* nBody = mdString(body);
    @try {
      UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
      if (!gApp.requestedNotifAuth) {
        gApp.requestedNotifAuth = YES;
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                              completionHandler:^(BOOL granted, NSError* _Nullable error) {
                                (void)granted;
                                (void)error;
                              }];
      }
      UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
      content.title = nTitle;
      content.body = nBody;
      UNNotificationRequest* req =
          [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                               content:content
                                               trigger:nil];
      [center addNotificationRequest:req
               withCompletionHandler:^(NSError* _Nullable error) {
                 (void)error;
               }];
    } @catch (NSException* exception) {
      (void)exception;
    }
  }
}

void md_ui_show_error(const char* message) {
  @autoreleasepool {
    if (gApp != nil && gApp.headlessTest) {
      return;
    }
    if ([NSApplication sharedApplication] == nil) {
      return;
    }
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"MicDrop";
    alert.informativeText = mdString(message);
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
  }
}

void md_ui_show_info(const char* title, const char* message) {
  @autoreleasepool {
    if (gApp != nil && gApp.headlessTest) {
      return;
    }
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = mdString(title);
    alert.informativeText = mdString(message);
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
  }
}

int md_ui_confirm(const char* message) {
  @autoreleasepool {
    if (gApp != nil && gApp.headlessTest) {
      return 0;
    }
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"MicDrop";
    alert.informativeText = mdString(message);
    [alert addButtonWithTitle:@"Confirm"];
    [alert addButtonWithTitle:@"Cancel"];
    NSArray<NSButton*>* buttons = alert.buttons;
    if (buttons.count >= 2) {
      buttons[0].keyEquivalent = @"";
      buttons[1].keyEquivalent = @"\r";
    }
    return [alert runModal] == NSAlertFirstButtonReturn ? 1 : 0;
  }
}

char* md_ui_choose_json_file(void) {
  @autoreleasepool {
    if (gApp != nil && gApp.headlessTest) {
      return NULL;
    }
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = @"Import private MicDrop remote configuration";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.treatsFilePackagesAsDirectories = NO;
    if (UTTypeJSON != nil) {
      panel.allowedContentTypes = @[ UTTypeJSON ];
    }
    if ([panel runModal] == NSModalResponseOK && panel.URL != nil && panel.URL.isFileURL) {
      return mdDupUTF8(panel.URL.path);
    }
    return NULL;
  }
}

int md_ui_copy_clipboard(const char* text) {
  @autoreleasepool {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    if (pb == nil) {
      return 0;
    }
    [pb clearContents];
    return [pb setString:mdString(text) forType:NSPasteboardTypeString] ? 1 : 0;
  }
}

int md_ui_open_path(const char* path) {
  @autoreleasepool {
    NSURL* url = [NSURL fileURLWithPath:mdString(path)];
    if (url == nil) {
      return 0;
    }
    return [[NSWorkspace sharedWorkspace] openURL:url] ? 1 : 0;
  }
}

int md_ui_open_firewall_settings(void) {
  @autoreleasepool {
    NSURL* firewallURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Network-Settings.extension"];
    if (firewallURL != nil && [[NSWorkspace sharedWorkspace] openURL:firewallURL]) {
      return 1;
    }
    NSURL* settingsApp = [NSURL fileURLWithPath:@"/System/Applications/System Settings.app"];
    if (settingsApp != nil && [[NSWorkspace sharedWorkspace] openURL:settingsApp]) {
      return 1;
    }
    return 0;
  }
}

int md_ui_check_bounds(int controlID, int* out_x, int* out_y, int* out_w, int* out_h, int* win_w, int* win_h) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry == nil || gApp == nil || gApp.contentView == nil) {
      return 0;
    }
    NSRect frame = entry.view.frame;
    NSRect client = gApp.contentView.bounds;
    if (out_x != NULL) *out_x = (int)frame.origin.x;
    if (out_y != NULL) *out_y = (int)frame.origin.y;
    if (out_w != NULL) *out_w = (int)frame.size.width;
    if (out_h != NULL) *out_h = (int)frame.size.height;
    if (win_w != NULL) *win_w = (int)client.size.width;
    if (win_h != NULL) *win_h = (int)client.size.height;
    return 1;
  }
}

int md_ui_capture_png(const char* out_path) {
  @autoreleasepool {
    if (gApp == nil || gApp.contentView == nil || out_path == NULL) {
      return 0;
    }
    [gApp.contentView layoutSubtreeIfNeeded];
    NSRect bounds = gApp.contentView.bounds;
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0) {
      return 0;
    }
    NSBitmapImageRep* rep = [gApp.contentView bitmapImageRepForCachingDisplayInRect:bounds];
    if (rep == nil) {
      return 0;
    }
    [gApp.contentView cacheDisplayInRect:bounds toBitmapImageRep:rep];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png == nil || png.length == 0) {
      return 0;
    }
    return [png writeToFile:mdString(out_path) atomically:YES] ? 1 : 0;
  }
}

void md_ui_trigger(int controlID, int event_kind) {
  @autoreleasepool {
    MicDropControlEntry* entry = mdEntry(controlID);
    if (entry != nil && entry.kind == MD_KIND_CHECKBOX && event_kind == MD_EVENT_CLICK && entry.button != nil) {
      if (!entry.button.isEnabled) {
        return;
      }
      entry.button.state =
          (entry.button.state == NSControlStateValueOn) ? NSControlStateValueOff : NSControlStateValueOn;
    }
    goMicDropEvent(controlID, event_kind);
  }
}

int md_ui_request_terminate_for_test(void) {
  @autoreleasepool {
    if (gApp == nil) {
      return -1;
    }
    return (int)[gApp applicationShouldTerminate:NSApp];
  }
}

int md_ui_terminate_approved_count_for_test(void) {
  return gTestTerminateApprovedCount;
}

#endif
