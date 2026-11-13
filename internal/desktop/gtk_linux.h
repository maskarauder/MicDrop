// SPDX-License-Identifier: MPL-2.0
#ifndef MICDROP_GTK_LINUX_H
#define MICDROP_GTK_LINUX_H

#include <stddef.h>
#include <stdint.h>

enum {
  MD_KIND_LABEL = 1,
  MD_KIND_TITLE = 2,
  MD_KIND_BUTTON = 3,
  MD_KIND_CHECKBOX = 4,
  MD_KIND_POPUP = 5,
  MD_KIND_EDIT = 6,
  MD_KIND_MULTILINE = 7,
  MD_KIND_LIST = 8,
  MD_KIND_QR = 9,
};

enum {
  MD_EVENT_CLICK = 0,
  MD_EVENT_CHANGE = 1,
  MD_EVENT_DBLCLK = 2,
};

int md_app_init(const char* window_title, int headless_test, int start_id, int stop_id, int exit_id, char* err_buf, size_t err_cap);
int md_app_has_tray(void);
void md_app_show_window(int activate);
void md_app_hide_window(void);
void md_app_minimize_window(void);
void md_app_run(void);
void md_app_stop_loop(void);
void md_app_cleanup(void);
void md_app_dispatch_wake(void);
void md_app_wake_test(void);

int md_ui_add_control(int id, int kind, const char* title, int page, int x, int y, int w, int h);
void md_ui_layout(void);
void md_ui_select_page(int page);
void md_ui_set_visible(int id, int visible);

void md_ui_set_text(int id, const char* text);
char* md_ui_copy_text(int id);
void md_ui_set_enabled(int id, int enabled);
int md_ui_is_enabled(int id);
void md_ui_set_readonly(int id, int readonly_flag);
int md_ui_is_readonly(int id);
void md_ui_set_checked(int id, int checked);
int md_ui_is_checked(int id);
void md_ui_set_max_length(int id, int max_len);

void md_ui_set_popup_items(int id, char** items, int count, int selected);
int md_ui_popup_selected(int id);
int md_ui_popup_count(int id);
int md_ui_popup_find_exact(int id, const char* title);

void md_ui_set_list_items(int id, char** items, int count, int selected);
int md_ui_list_selected(int id);
void md_ui_list_select(int id, int selected);

void md_ui_set_qr_rgba(const uint8_t* rgba, int size_px);

void md_ui_update_tray(const char* status, int running, int connected);
void md_ui_notify(const char* title, const char* body, int warning);

void md_ui_show_error(const char* message);
void md_ui_show_info(const char* title, const char* message);
int md_ui_confirm(const char* message);
char* md_ui_choose_json_file(void);
void md_ui_dismiss_modals(void);
int md_ui_has_active_modal(void);
int md_ui_copy_clipboard(const char* text);
int md_ui_open_path(const char* path);

int md_ui_check_bounds(int id, int* out_x, int* out_y, int* out_w, int* out_h, int* win_w, int* win_h);
int md_ui_capture_png(const char* out_path);
void md_ui_trigger(int id, int event_kind);
int md_ui_window_visible_for_test(void);
void md_ui_close_window_for_test(void);
void md_test_configure_tray(int simulated_indicator, int host_override, const char* dbus_addr);
void md_test_set_allow_modals(int allow);
int md_test_live_modal_objects(void);

#endif
