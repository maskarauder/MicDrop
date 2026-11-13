// SPDX-License-Identifier: MPL-2.0
#if defined(__linux__) && defined(__x86_64__)

#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gtk_linux.h"
#include "_cgo_export.h"

// Minimal GTK3 / GDK3 / GLib / GObject / GIO / Cairo ABI declarations loaded via dlopen
// so micdrop-host retains zero DT_NEEDED GUI library dependencies on headless Linux servers.
typedef int gboolean;
typedef int gint;
typedef unsigned int guint;
typedef int32_t gint32;
typedef uint32_t guint32;
typedef unsigned long gulong;
typedef unsigned long GType;
typedef void* gpointer;
typedef void (*GCallback)(void);
typedef void (*GClosureNotify)(gpointer data, void* closure);
typedef gboolean (*GSourceFunc)(gpointer user_data);

typedef struct _GError {
  guint32 domain;
  gint code;
  char* message;
} GError;

typedef struct _GList {
  gpointer data;
  struct _GList* next;
  struct _GList* prev;
} GList;

typedef struct _GtkAllocation {
  int x;
  int y;
  int width;
  int height;
} GtkAllocation;

typedef struct _GtkTreeIter {
  gint stamp;
  gpointer user_data;
  gpointer user_data2;
  gpointer user_data3;
} GtkTreeIter;

typedef struct _GtkTextIter {
  gpointer dummy1;
  gpointer dummy2;
  gint dummy3;
  gint dummy4;
  gint dummy5;
  gint dummy6;
  gint dummy7;
  gint dummy8;
  gpointer dummy9;
  gpointer dummy10;
  gint dummy11;
  gint dummy12;
  gint dummy13;
  gpointer dummy14;
} GtkTextIter;

enum {
  MD_GTK_WINDOW_TOPLEVEL = 0,
  MD_GTK_WIN_POS_CENTER = 1,
  MD_GTK_POLICY_AUTOMATIC = 1,
  MD_GTK_POLICY_NEVER = 2,
  MD_GTK_POLICY_EXTERNAL = 3,
  MD_GTK_WRAP_WORD_CHAR = 3,
  MD_GTK_SELECTION_SINGLE = 1,
  MD_GTK_MESSAGE_INFO = 0,
  MD_GTK_MESSAGE_WARNING = 1,
  MD_GTK_MESSAGE_QUESTION = 2,
  MD_GTK_MESSAGE_ERROR = 3,
  MD_GTK_BUTTONS_NONE = 0,
  MD_GTK_BUTTONS_OK = 1,
  MD_GTK_RESPONSE_ACCEPT = -3,
  MD_GTK_RESPONSE_OK = -5,
  MD_GTK_RESPONSE_CANCEL = -6,
  MD_GTK_FILE_CHOOSER_ACTION_OPEN = 0,
  MD_GTK_STYLE_PROVIDER_PRIORITY_APPLICATION = 600,
  MD_PANGO_WRAP_WORD_CHAR = 2,
  MD_PANGO_ELLIPSIZE_END = 3,
  MD_CAIRO_FORMAT_ARGB32 = 0,
  MD_CAIRO_FILTER_NEAREST = 3,
  MD_G_TYPE_STRING = 64,
  MD_G_SIGNAL_MATCH_DATA = 16,
  MD_G_BUS_TYPE_SESSION = 2,
  MD_G_DBUS_CALL_FLAGS_NONE = 0,
  MD_APP_INDICATOR_CATEGORY_APPLICATION_STATUS = 0,
  MD_APP_INDICATOR_STATUS_ACTIVE = 1,
};

typedef struct {
  int loaded;
  void* glib;
  void* gobject;
  void* gio;
  void* cairo;
  void* gdk;
  void* gtk;
  void* indicator_lib;

  // GLib
  void (*g_free)(gpointer mem);
  void (*g_error_free)(GError* error);
  void (*g_list_free)(GList* list);
  void (*g_set_prgname)(const char* prgname);
  void (*g_set_application_name)(const char* application_name);
  guint (*g_timeout_add)(guint interval, GSourceFunc function, gpointer data);
  guint (*g_idle_add)(GSourceFunc function, gpointer data);
  gboolean (*g_source_remove)(guint tag);
  char* (*g_filename_to_uri)(const char* filename, const char* hostname, GError** error);
  void* (*g_variant_new)(const char* format_string, ...);

  // GObject
  gulong (*g_signal_connect_data)(gpointer instance, const char* detailed_signal, GCallback c_handler,
                                  gpointer data, GClosureNotify destroy_data, int connect_flags);
  guint (*g_signal_handlers_disconnect_matched)(gpointer instance, int mask, guint signal_id,
                                                guint32 detail, void* closure, gpointer func, gpointer data);
  void (*g_object_set)(gpointer object, const char* first_property_name, ...);
  void (*g_object_get)(gpointer object, const char* first_property_name, ...);
  void (*g_object_unref)(gpointer object);

  // GIO
  gboolean (*g_app_info_launch_default_for_uri)(const char* uri, void* context, GError** error);
  void* (*g_bus_get_sync)(int bus_type, void* cancellable, GError** error);
  void (*g_dbus_connection_call)(void* connection, const char* bus_name, const char* object_path,
                                 const char* interface_name, const char* method_name, void* parameters,
                                 const void* reply_type, int flags, gint timeout_msec,
                                 void* cancellable, void* callback, gpointer user_data);

  // Cairo
  void* (*cairo_image_surface_create)(int format, int width, int height);
  unsigned char* (*cairo_image_surface_get_data)(void* surface);
  int (*cairo_image_surface_get_stride)(void* surface);
  void (*cairo_surface_flush)(void* surface);
  void (*cairo_surface_mark_dirty)(void* surface);
  void (*cairo_surface_destroy)(void* surface);
  int (*cairo_surface_write_to_png)(void* surface, const char* filename);
  void* (*cairo_create)(void* target);
  void (*cairo_destroy)(void* cr);
  void (*cairo_save)(void* cr);
  void (*cairo_restore)(void* cr);
  void (*cairo_translate)(void* cr, double tx, double ty);
  void (*cairo_scale)(void* cr, double sx, double sy);
  void (*cairo_set_source_rgb)(void* cr, double r, double g, double b);
  void (*cairo_set_source_rgba)(void* cr, double r, double g, double b, double a);
  void (*cairo_set_source_surface)(void* cr, void* surface, double x, double y);
  void* (*cairo_get_source)(void* cr);
  void (*cairo_pattern_set_filter)(void* pattern, int filter);
  void (*cairo_set_line_width)(void* cr, double width);
  void (*cairo_set_line_cap)(void* cr, int line_cap);
  void (*cairo_set_line_join)(void* cr, int line_join);
  void (*cairo_move_to)(void* cr, double x, double y);
  void (*cairo_line_to)(void* cr, double x, double y);
  void (*cairo_new_sub_path)(void* cr);
  void (*cairo_arc)(void* cr, double xc, double yc, double radius, double angle1, double angle2);
  void (*cairo_close_path)(void* cr);
  void (*cairo_rectangle)(void* cr, double x, double y, double width, double height);
  void (*cairo_fill)(void* cr);
  void (*cairo_fill_preserve)(void* cr);
  void (*cairo_stroke)(void* cr);
  void (*cairo_paint)(void* cr);

  // GDK3
  void* (*gdk_screen_get_default)(void);
  void* (*gdk_atom_intern_static_string)(const char* atom_name);

  // GTK3
  gboolean (*gtk_init_check)(int* argc, char*** argv);
  void (*gtk_main)(void);
  void (*gtk_main_quit)(void);
  gboolean (*gtk_events_pending)(void);
  gboolean (*gtk_main_iteration_do)(gboolean blocking);

  void* (*gtk_settings_get_default)(void);
  void* (*gtk_css_provider_new)(void);
  gboolean (*gtk_css_provider_load_from_data)(void* provider, const char* data, long length, GError** error);
  void (*gtk_style_context_add_provider_for_screen)(void* screen, void* provider, guint priority);
  void* (*gtk_widget_get_style_context)(void* widget);
  void (*gtk_style_context_add_class)(void* context, const char* class_name);
  void (*gtk_style_context_remove_class)(void* context, const char* class_name);

  void* (*gtk_window_new)(int type);
  void (*gtk_window_set_title)(void* window, const char* title);
  void (*gtk_window_set_default_size)(void* window, gint width, gint height);
  void (*gtk_window_set_position)(void* window, int position);
  void (*gtk_window_set_default_icon_name)(const char* name);
  void (*gtk_window_present)(void* window);
  void (*gtk_window_iconify)(void* window);
  void (*gtk_window_deiconify)(void* window);
  void (*gtk_window_set_transient_for)(void* window, void* parent);
  void (*gtk_window_set_modal)(void* window, gboolean modal);

  void (*gtk_widget_show)(void* widget);
  void (*gtk_widget_show_all)(void* widget);
  void (*gtk_widget_hide)(void* widget);
  void (*gtk_widget_set_visible)(void* widget, gboolean visible);
  gboolean (*gtk_widget_get_visible)(void* widget);
  void (*gtk_widget_set_no_show_all)(void* widget, gboolean no_show_all);
  void (*gtk_widget_set_size_request)(void* widget, gint width, gint height);
  void (*gtk_widget_set_sensitive)(void* widget, gboolean sensitive);
  gboolean (*gtk_widget_get_sensitive)(void* widget);
  void (*gtk_widget_queue_draw)(void* widget);
  void (*gtk_widget_get_allocation)(void* widget, GtkAllocation* allocation);
  gboolean (*gtk_widget_translate_coordinates)(void* src_widget, void* dest_widget, gint src_x, gint src_y, gint* dest_x, gint* dest_y);
  void (*gtk_widget_draw)(void* widget, void* cr);
  void (*gtk_widget_destroy)(void* widget);
  void (*gtk_widget_set_margin_start)(void* widget, gint margin);
  void (*gtk_widget_set_margin_end)(void* widget, gint margin);

  void (*gtk_container_add)(void* container, void* widget);
  void (*gtk_container_check_resize)(void* container);
  void* (*gtk_fixed_new)(void);
  void (*gtk_fixed_put)(void* fixed, void* widget, gint x, gint y);
  void (*gtk_fixed_move)(void* fixed, void* widget, gint x, gint y);

  void* (*gtk_scrolled_window_new)(void* hadjustment, void* vadjustment);
  void (*gtk_scrolled_window_set_policy)(void* scrolled_window, int hscrollbar_policy, int vscrollbar_policy);
  void (*gtk_scrolled_window_set_propagate_natural_width)(void* scrolled_window, gboolean propagate);
  void (*gtk_scrolled_window_set_propagate_natural_height)(void* scrolled_window, gboolean propagate);

  void* (*gtk_overlay_new)(void);
  void (*gtk_overlay_add_overlay)(void* overlay, void* widget);
  void* (*gtk_drawing_area_new)(void);

  void* (*gtk_label_new)(const char* str);
  void (*gtk_label_set_text)(void* label, const char* str);
  const char* (*gtk_label_get_text)(void* label);
  void (*gtk_label_set_xalign)(void* label, float xalign);
  void (*gtk_label_set_yalign)(void* label, float yalign);
  void (*gtk_label_set_line_wrap)(void* label, gboolean wrap);
  void (*gtk_label_set_line_wrap_mode)(void* label, int wrap_mode);
  void (*gtk_label_set_justify)(void* label, int jtype);

  void* (*gtk_button_new_with_label)(const char* label);
  void (*gtk_button_set_label)(void* button, const char* label);
  const char* (*gtk_button_get_label)(void* button);

  void* (*gtk_check_button_new_with_label)(const char* label);
  void (*gtk_toggle_button_set_active)(void* toggle_button, gboolean is_active);
  gboolean (*gtk_toggle_button_get_active)(void* toggle_button);

  void* (*gtk_combo_box_text_new)(void);
  void (*gtk_combo_box_text_append_text)(void* combo_box, const char* text);
  void (*gtk_combo_box_text_remove_all)(void* combo_box);
  gint (*gtk_combo_box_get_active)(void* combo_box);
  void (*gtk_combo_box_set_active)(void* combo_box, gint index_);
  GList* (*gtk_cell_layout_get_cells)(void* cell_layout);

  void* (*gtk_entry_new)(void);
  void (*gtk_entry_set_text)(void* entry, const char* text);
  const char* (*gtk_entry_get_text)(void* entry);
  void (*gtk_entry_set_max_length)(void* entry, gint max);
  void (*gtk_entry_set_width_chars)(void* entry, gint n_chars);
  void (*gtk_editable_set_editable)(void* editable, gboolean is_editable);
  gboolean (*gtk_editable_get_editable)(void* editable);

  void* (*gtk_text_view_new)(void);
  void* (*gtk_text_view_get_buffer)(void* text_view);
  void (*gtk_text_view_set_editable)(void* text_view, gboolean setting);
  gboolean (*gtk_text_view_get_editable)(void* text_view);
  void (*gtk_text_view_set_cursor_visible)(void* text_view, gboolean setting);
  void (*gtk_text_view_set_wrap_mode)(void* text_view, int wrap_mode);
  void (*gtk_text_view_set_monospace)(void* text_view, gboolean monospace);
  void (*gtk_text_view_set_left_margin)(void* text_view, gint left_margin);
  void (*gtk_text_view_set_right_margin)(void* text_view, gint right_margin);
  void (*gtk_text_view_set_top_margin)(void* text_view, gint top_margin);
  void (*gtk_text_view_set_bottom_margin)(void* text_view, gint bottom_margin);
  void (*gtk_text_buffer_set_text)(void* buffer, const char* text, gint len);
  void (*gtk_text_buffer_get_bounds)(void* buffer, GtkTextIter* start, GtkTextIter* end);
  char* (*gtk_text_buffer_get_text)(void* buffer, const GtkTextIter* start, const GtkTextIter* end, gboolean include_hidden_chars);

  void* (*gtk_list_store_new)(gint n_columns, ...);
  void (*gtk_list_store_clear)(void* list_store);
  void (*gtk_list_store_append)(void* list_store, GtkTreeIter* iter);
  void (*gtk_list_store_set)(void* list_store, GtkTreeIter* iter, ...);
  void* (*gtk_tree_view_new_with_model)(void* model);
  void (*gtk_tree_view_set_headers_visible)(void* tree_view, gboolean headers_visible);
  void* (*gtk_cell_renderer_text_new)(void);
  void* (*gtk_tree_view_column_new_with_attributes)(const char* title, void* cell, ...);
  gint (*gtk_tree_view_append_column)(void* tree_view, void* column);
  void* (*gtk_tree_view_get_selection)(void* tree_view);
  void (*gtk_tree_selection_set_mode)(void* selection, int type);
  void (*gtk_tree_selection_unselect_all)(void* selection);
  void (*gtk_tree_selection_select_path)(void* selection, void* path);
  gboolean (*gtk_tree_selection_get_selected)(void* selection, void** model, GtkTreeIter* iter);
  void* (*gtk_tree_model_get_path)(void* tree_model, GtkTreeIter* iter);
  gint* (*gtk_tree_path_get_indices)(void* path);
  void* (*gtk_tree_path_new_from_indices)(gint first_index, ...);
  void (*gtk_tree_path_free)(void* path);

  void* (*gtk_menu_new)(void);
  void* (*gtk_menu_item_new_with_label)(const char* label);
  void (*gtk_menu_item_set_label)(void* menu_item, const char* label);
  void* (*gtk_separator_menu_item_new)(void);
  void (*gtk_menu_shell_append)(void* menu_shell, void* child);

  void* (*gtk_message_dialog_new)(void* parent, int flags, int type, int buttons, const char* message_format, ...);
  void (*gtk_message_dialog_format_secondary_text)(void* message_dialog, const char* message_format, ...);
  void* (*gtk_dialog_add_button)(void* dialog, const char* button_text, gint response_id);
  void (*gtk_dialog_set_default_response)(void* dialog, gint response_id);
  gint (*gtk_dialog_run)(void* dialog);

  void* (*gtk_file_chooser_native_new)(const char* title, void* parent, int action, const char* accept_label, const char* cancel_label);
  gint (*gtk_native_dialog_run)(void* self);
  void (*gtk_native_dialog_destroy)(void* self);
  void* (*gtk_file_filter_new)(void);
  void (*gtk_file_filter_set_name)(void* filter, const char* name);
  void (*gtk_file_filter_add_pattern)(void* filter, const char* pattern);
  void (*gtk_file_filter_add_mime_type)(void* filter, const char* mime_type);
  void (*gtk_file_chooser_add_filter)(void* chooser, void* filter);
  char* (*gtk_file_chooser_get_filename)(void* chooser);

  void* (*gtk_clipboard_get)(void* selection);
  void (*gtk_clipboard_set_text)(void* clipboard, const char* text, gint len);
  void (*gtk_clipboard_store)(void* clipboard);

  // Optional AppIndicator / Ayatana AppIndicator for StatusNotifierItem tray menu
  int has_indicator_api;
  void* (*app_indicator_new)(const char* id, const char* icon_name, int category);
  void (*app_indicator_set_status)(void* self, int status);
  void (*app_indicator_set_menu)(void* self, void* menu);
  void (*app_indicator_set_title)(void* self, const char* title);
  void (*app_indicator_set_icon_full)(void* self, const char* icon_name, const char* icon_desc);
} MdGtkSyms;

static MdGtkSyms gGtk;

static void* mdSym(void* handle, const char* name, int* missing) {
  void* p = dlsym(handle, name);
  if (p == NULL) {
    *missing = 1;
  }
  return p;
}

#define LOAD_SYM(lib, fn) (*(void**)(&gGtk.fn) = mdSym(gGtk.lib, #fn, &missing))

static int mdLoadGtkSymbols(char* err_buf, size_t err_cap) {
  if (gGtk.loaded) {
    return 1;
  }
  gGtk.glib = dlopen("libglib-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
  gGtk.gobject = dlopen("libgobject-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
  gGtk.gio = dlopen("libgio-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
  gGtk.cairo = dlopen("libcairo.so.2", RTLD_LAZY | RTLD_LOCAL);
  gGtk.gdk = dlopen("libgdk-3.so.0", RTLD_LAZY | RTLD_LOCAL);
  gGtk.gtk = dlopen("libgtk-3.so.0", RTLD_LAZY | RTLD_LOCAL);

  if (!gGtk.glib || !gGtk.gobject || !gGtk.gio || !gGtk.cairo || !gGtk.gdk || !gGtk.gtk) {
    if (err_buf != NULL && err_cap > 0) {
      snprintf(err_buf, err_cap,
               "MicDrop desktop on Linux requires GTK 3 (libgtk-3.so.0); install libgtk-3-0 or use micdrop-host CLI subcommands");
    }
    return 0;
  }

  int missing = 0;
  LOAD_SYM(glib, g_free);
  LOAD_SYM(glib, g_error_free);
  LOAD_SYM(glib, g_list_free);
  LOAD_SYM(glib, g_set_prgname);
  LOAD_SYM(glib, g_set_application_name);
  LOAD_SYM(glib, g_timeout_add);
  LOAD_SYM(glib, g_idle_add);
  LOAD_SYM(glib, g_source_remove);
  LOAD_SYM(glib, g_filename_to_uri);
  LOAD_SYM(glib, g_variant_new);

  LOAD_SYM(gobject, g_signal_connect_data);
  LOAD_SYM(gobject, g_signal_handlers_disconnect_matched);
  LOAD_SYM(gobject, g_object_set);
  LOAD_SYM(gobject, g_object_get);
  LOAD_SYM(gobject, g_object_unref);

  LOAD_SYM(gio, g_app_info_launch_default_for_uri);
  LOAD_SYM(gio, g_bus_get_sync);
  LOAD_SYM(gio, g_dbus_connection_call);

  LOAD_SYM(cairo, cairo_image_surface_create);
  LOAD_SYM(cairo, cairo_image_surface_get_data);
  LOAD_SYM(cairo, cairo_image_surface_get_stride);
  LOAD_SYM(cairo, cairo_surface_flush);
  LOAD_SYM(cairo, cairo_surface_mark_dirty);
  LOAD_SYM(cairo, cairo_surface_destroy);
  LOAD_SYM(cairo, cairo_surface_write_to_png);
  LOAD_SYM(cairo, cairo_create);
  LOAD_SYM(cairo, cairo_destroy);
  LOAD_SYM(cairo, cairo_save);
  LOAD_SYM(cairo, cairo_restore);
  LOAD_SYM(cairo, cairo_translate);
  LOAD_SYM(cairo, cairo_scale);
  LOAD_SYM(cairo, cairo_set_source_rgb);
  LOAD_SYM(cairo, cairo_set_source_rgba);
  LOAD_SYM(cairo, cairo_set_source_surface);
  LOAD_SYM(cairo, cairo_get_source);
  LOAD_SYM(cairo, cairo_pattern_set_filter);
  LOAD_SYM(cairo, cairo_set_line_width);
  LOAD_SYM(cairo, cairo_set_line_cap);
  LOAD_SYM(cairo, cairo_set_line_join);
  LOAD_SYM(cairo, cairo_move_to);
  LOAD_SYM(cairo, cairo_line_to);
  LOAD_SYM(cairo, cairo_new_sub_path);
  LOAD_SYM(cairo, cairo_arc);
  LOAD_SYM(cairo, cairo_close_path);
  LOAD_SYM(cairo, cairo_rectangle);
  LOAD_SYM(cairo, cairo_fill);
  LOAD_SYM(cairo, cairo_fill_preserve);
  LOAD_SYM(cairo, cairo_stroke);
  LOAD_SYM(cairo, cairo_paint);

  LOAD_SYM(gdk, gdk_screen_get_default);
  LOAD_SYM(gdk, gdk_atom_intern_static_string);

  LOAD_SYM(gtk, gtk_init_check);
  LOAD_SYM(gtk, gtk_main);
  LOAD_SYM(gtk, gtk_main_quit);
  LOAD_SYM(gtk, gtk_events_pending);
  LOAD_SYM(gtk, gtk_main_iteration_do);
  LOAD_SYM(gtk, gtk_settings_get_default);
  LOAD_SYM(gtk, gtk_css_provider_new);
  LOAD_SYM(gtk, gtk_css_provider_load_from_data);
  LOAD_SYM(gtk, gtk_style_context_add_provider_for_screen);
  LOAD_SYM(gtk, gtk_widget_get_style_context);
  LOAD_SYM(gtk, gtk_style_context_add_class);
  LOAD_SYM(gtk, gtk_style_context_remove_class);
  LOAD_SYM(gtk, gtk_window_new);
  LOAD_SYM(gtk, gtk_window_set_title);
  LOAD_SYM(gtk, gtk_window_set_default_size);
  LOAD_SYM(gtk, gtk_window_set_position);
  LOAD_SYM(gtk, gtk_window_set_default_icon_name);
  LOAD_SYM(gtk, gtk_window_present);
  LOAD_SYM(gtk, gtk_window_iconify);
  LOAD_SYM(gtk, gtk_window_deiconify);
  LOAD_SYM(gtk, gtk_window_set_transient_for);
  LOAD_SYM(gtk, gtk_window_set_modal);
  LOAD_SYM(gtk, gtk_widget_show);
  LOAD_SYM(gtk, gtk_widget_show_all);
  LOAD_SYM(gtk, gtk_widget_hide);
  LOAD_SYM(gtk, gtk_widget_set_visible);
  LOAD_SYM(gtk, gtk_widget_get_visible);
  LOAD_SYM(gtk, gtk_widget_set_no_show_all);
  LOAD_SYM(gtk, gtk_widget_set_size_request);
  LOAD_SYM(gtk, gtk_widget_set_sensitive);
  LOAD_SYM(gtk, gtk_widget_get_sensitive);
  LOAD_SYM(gtk, gtk_widget_queue_draw);
  LOAD_SYM(gtk, gtk_widget_get_allocation);
  LOAD_SYM(gtk, gtk_widget_translate_coordinates);
  LOAD_SYM(gtk, gtk_widget_draw);
  LOAD_SYM(gtk, gtk_widget_destroy);
  LOAD_SYM(gtk, gtk_widget_set_margin_start);
  LOAD_SYM(gtk, gtk_widget_set_margin_end);
  LOAD_SYM(gtk, gtk_container_add);
  LOAD_SYM(gtk, gtk_container_check_resize);
  LOAD_SYM(gtk, gtk_fixed_new);
  LOAD_SYM(gtk, gtk_fixed_put);
  LOAD_SYM(gtk, gtk_fixed_move);
  LOAD_SYM(gtk, gtk_scrolled_window_new);
  LOAD_SYM(gtk, gtk_scrolled_window_set_policy);
  LOAD_SYM(gtk, gtk_scrolled_window_set_propagate_natural_width);
  LOAD_SYM(gtk, gtk_scrolled_window_set_propagate_natural_height);
  LOAD_SYM(gtk, gtk_overlay_new);
  LOAD_SYM(gtk, gtk_overlay_add_overlay);
  LOAD_SYM(gtk, gtk_drawing_area_new);
  LOAD_SYM(gtk, gtk_label_new);
  LOAD_SYM(gtk, gtk_label_set_text);
  LOAD_SYM(gtk, gtk_label_get_text);
  LOAD_SYM(gtk, gtk_label_set_xalign);
  LOAD_SYM(gtk, gtk_label_set_yalign);
  LOAD_SYM(gtk, gtk_label_set_line_wrap);
  LOAD_SYM(gtk, gtk_label_set_line_wrap_mode);
  LOAD_SYM(gtk, gtk_label_set_justify);
  LOAD_SYM(gtk, gtk_button_new_with_label);
  LOAD_SYM(gtk, gtk_button_set_label);
  LOAD_SYM(gtk, gtk_button_get_label);
  LOAD_SYM(gtk, gtk_check_button_new_with_label);
  LOAD_SYM(gtk, gtk_toggle_button_set_active);
  LOAD_SYM(gtk, gtk_toggle_button_get_active);
  LOAD_SYM(gtk, gtk_combo_box_text_new);
  LOAD_SYM(gtk, gtk_combo_box_text_append_text);
  LOAD_SYM(gtk, gtk_combo_box_text_remove_all);
  LOAD_SYM(gtk, gtk_combo_box_get_active);
  LOAD_SYM(gtk, gtk_combo_box_set_active);
  LOAD_SYM(gtk, gtk_cell_layout_get_cells);
  LOAD_SYM(gtk, gtk_entry_new);
  LOAD_SYM(gtk, gtk_entry_set_text);
  LOAD_SYM(gtk, gtk_entry_get_text);
  LOAD_SYM(gtk, gtk_entry_set_max_length);
  LOAD_SYM(gtk, gtk_entry_set_width_chars);
  LOAD_SYM(gtk, gtk_editable_set_editable);
  LOAD_SYM(gtk, gtk_editable_get_editable);
  LOAD_SYM(gtk, gtk_text_view_new);
  LOAD_SYM(gtk, gtk_text_view_get_buffer);
  LOAD_SYM(gtk, gtk_text_view_set_editable);
  LOAD_SYM(gtk, gtk_text_view_get_editable);
  LOAD_SYM(gtk, gtk_text_view_set_cursor_visible);
  LOAD_SYM(gtk, gtk_text_view_set_wrap_mode);
  LOAD_SYM(gtk, gtk_text_view_set_monospace);
  LOAD_SYM(gtk, gtk_text_view_set_left_margin);
  LOAD_SYM(gtk, gtk_text_view_set_right_margin);
  LOAD_SYM(gtk, gtk_text_view_set_top_margin);
  LOAD_SYM(gtk, gtk_text_view_set_bottom_margin);
  LOAD_SYM(gtk, gtk_text_buffer_set_text);
  LOAD_SYM(gtk, gtk_text_buffer_get_bounds);
  LOAD_SYM(gtk, gtk_text_buffer_get_text);
  LOAD_SYM(gtk, gtk_list_store_new);
  LOAD_SYM(gtk, gtk_list_store_clear);
  LOAD_SYM(gtk, gtk_list_store_append);
  LOAD_SYM(gtk, gtk_list_store_set);
  LOAD_SYM(gtk, gtk_tree_view_new_with_model);
  LOAD_SYM(gtk, gtk_tree_view_set_headers_visible);
  LOAD_SYM(gtk, gtk_cell_renderer_text_new);
  LOAD_SYM(gtk, gtk_tree_view_column_new_with_attributes);
  LOAD_SYM(gtk, gtk_tree_view_append_column);
  LOAD_SYM(gtk, gtk_tree_view_get_selection);
  LOAD_SYM(gtk, gtk_tree_selection_set_mode);
  LOAD_SYM(gtk, gtk_tree_selection_unselect_all);
  LOAD_SYM(gtk, gtk_tree_selection_select_path);
  LOAD_SYM(gtk, gtk_tree_selection_get_selected);
  LOAD_SYM(gtk, gtk_tree_model_get_path);
  LOAD_SYM(gtk, gtk_tree_path_get_indices);
  LOAD_SYM(gtk, gtk_tree_path_new_from_indices);
  LOAD_SYM(gtk, gtk_tree_path_free);
  LOAD_SYM(gtk, gtk_menu_new);
  LOAD_SYM(gtk, gtk_menu_item_new_with_label);
  LOAD_SYM(gtk, gtk_menu_item_set_label);
  LOAD_SYM(gtk, gtk_separator_menu_item_new);
  LOAD_SYM(gtk, gtk_menu_shell_append);
  LOAD_SYM(gtk, gtk_message_dialog_new);
  LOAD_SYM(gtk, gtk_message_dialog_format_secondary_text);
  LOAD_SYM(gtk, gtk_dialog_add_button);
  LOAD_SYM(gtk, gtk_dialog_set_default_response);
  LOAD_SYM(gtk, gtk_dialog_run);
  LOAD_SYM(gtk, gtk_file_chooser_native_new);
  LOAD_SYM(gtk, gtk_native_dialog_run);
  LOAD_SYM(gtk, gtk_native_dialog_destroy);
  LOAD_SYM(gtk, gtk_file_filter_new);
  LOAD_SYM(gtk, gtk_file_filter_set_name);
  LOAD_SYM(gtk, gtk_file_filter_add_pattern);
  LOAD_SYM(gtk, gtk_file_filter_add_mime_type);
  LOAD_SYM(gtk, gtk_file_chooser_add_filter);
  LOAD_SYM(gtk, gtk_file_chooser_get_filename);
  LOAD_SYM(gtk, gtk_clipboard_get);
  LOAD_SYM(gtk, gtk_clipboard_set_text);
  LOAD_SYM(gtk, gtk_clipboard_store);

  if (missing) {
    if (err_buf != NULL && err_cap > 0) {
      snprintf(err_buf, err_cap, "installed GTK 3 library is missing required symbols");
    }
    return 0;
  }

  gGtk.indicator_lib = dlopen("libayatana-appindicator3.so.1", RTLD_LAZY | RTLD_LOCAL);
  if (gGtk.indicator_lib == NULL) {
    gGtk.indicator_lib = dlopen("libappindicator3.so.1", RTLD_LAZY | RTLD_LOCAL);
  }
  if (gGtk.indicator_lib != NULL) {
    int ind_missing = 0;
    *(void**)(&gGtk.app_indicator_new) = mdSym(gGtk.indicator_lib, "app_indicator_new", &ind_missing);
    *(void**)(&gGtk.app_indicator_set_status) = mdSym(gGtk.indicator_lib, "app_indicator_set_status", &ind_missing);
    *(void**)(&gGtk.app_indicator_set_menu) = mdSym(gGtk.indicator_lib, "app_indicator_set_menu", &ind_missing);
    *(void**)(&gGtk.app_indicator_set_icon_full) = mdSym(gGtk.indicator_lib, "app_indicator_set_icon_full", &ind_missing);
    *(void**)(&gGtk.app_indicator_set_title) = dlsym(gGtk.indicator_lib, "app_indicator_set_title");
    if (!ind_missing) {
      gGtk.has_indicator_api = 1;
    }
  }

  gGtk.loaded = 1;
  return 1;
}

#undef LOAD_SYM

typedef struct MdControlEntry {
  int id;
  int kind;
  int page;
  int x, y, w, h;
  int readonly_flag;
  int suppress_events;
  void* outer;
  void* widget;
  void* extra;
  void* selection;
  char** popup_items;
  int item_count;
  struct MdControlEntry* next;
} MdControlEntry;

typedef struct {
  int initialized;
  int gtk_inited;
  int css_installed;
  int high_contrast;
  int headless_test;
  int loop_running;
  int quit_requested;
  pthread_t main_thread;
  uintptr_t generation;
  int start_id;
  int stop_id;
  int exit_id;
  int toggle_target_id;
  guint timer_id;
  void* window;
  void* root_scroll;
  void* fixed;
  void* indicator;
  void* tray_menu;
  void* tray_header_item;
  void* tray_toggle_item;
  void* dbus_conn;
  void* qr_surface;
  int qr_size;
  MdControlEntry* controls;
} MdAppState;

static MdAppState gApp;

static char* mdDupStr(const char* s) {
  if (s == NULL) {
    s = "";
  }
  size_t len = strlen(s);
  char* out = (char*)malloc(len + 1);
  if (out != NULL) {
    memcpy(out, s, len + 1);
  }
  return out;
}

static void mdFreePopupItems(MdControlEntry* e) {
  if (e == NULL || e->popup_items == NULL) {
    return;
  }
  for (int i = 0; i < e->item_count; i++) {
    free(e->popup_items[i]);
  }
  free(e->popup_items);
  e->popup_items = NULL;
  e->item_count = 0;
}

static MdControlEntry* mdFindEntry(int id) {
  for (MdControlEntry* cur = gApp.controls; cur != NULL; cur = cur->next) {
    if (cur->id == id) {
      return cur;
    }
  }
  return NULL;
}

static int mdDetectHighContrast(void) {
  void* settings = gGtk.gtk_settings_get_default();
  if (settings == NULL) {
    return 0;
  }
  char* theme_name = NULL;
  gGtk.g_object_get(settings, "gtk-theme-name", &theme_name, NULL);
  int hc = 0;
  if (theme_name != NULL) {
    if (strstr(theme_name, "HighContrast") != NULL || strstr(theme_name, "highcontrast") != NULL) {
      hc = 1;
    }
    gGtk.g_free(theme_name);
  }
  return hc;
}

static void mdInstallCss(int high_contrast) {
  if (gApp.css_installed) {
    return;
  }
  void* screen = gGtk.gdk_screen_get_default();
  if (screen == NULL) {
    return;
  }
  const char* layout_only_css =
      ".micdrop-slot, .micdrop-slot viewport { background-color: transparent; border: none; box-shadow: none; padding: 0; margin: 0; }\n"
      ".micdrop-root button { min-height: 0; min-width: 0; padding: 2px 10px; }\n"
      ".micdrop-root entry { min-height: 0; min-width: 0; padding: 2px 8px; }\n"
      ".micdrop-root combobox button { min-height: 0; min-width: 0; padding: 2px 8px; }\n"
      ".micdrop-root checkbutton { min-height: 0; min-width: 0; padding: 0; }\n"
      ".micdrop-readonly { opacity: 0.72; }\n";

  const char* dark_css =
      ".micdrop-window, .micdrop-root { background-color: #202831; color: #E9EEF2; }\n"
      ".micdrop-slot, .micdrop-slot viewport { background-color: transparent; border: none; box-shadow: none; padding: 0; margin: 0; }\n"
      ".micdrop-label { color: #E9EEF2; font-size: 13px; background-color: transparent; }\n"
      ".micdrop-title { color: #D4AC45; font-size: 22px; font-weight: 600; background-color: transparent; }\n"
      ".micdrop-root button {\n"
      "  min-height: 0; min-width: 0; padding: 2px 10px;\n"
      "  background-image: none; background-color: #2E3B49;\n"
      "  color: #E9EEF2; border: 1px solid #48596B; border-radius: 6px;\n"
      "  font-size: 13px; font-weight: 500; box-shadow: none; text-shadow: none;\n"
      "}\n"
      ".micdrop-root button:hover { background-color: #384758; border-color: #D4AC45; }\n"
      ".micdrop-root button:active { background-color: #25303C; }\n"
      ".micdrop-root button:disabled { background-color: #242E38; color: #7C8B99; border-color: #33404D; opacity: 0.85; }\n"
      ".micdrop-root entry {\n"
      "  min-height: 0; min-width: 0; padding: 2px 8px;\n"
      "  background-image: none; background-color: #2A3541; color: #E9EEF2;\n"
      "  border: 1px solid #3B4958; border-radius: 5px; caret-color: #E9EEF2; font-size: 13px;\n"
      "}\n"
      ".micdrop-readonly { opacity: 0.72; }\n"
      ".micdrop-root checkbutton { min-height: 0; min-width: 0; padding: 0; color: #E9EEF2; font-size: 13px; }\n"
      ".micdrop-root checkbutton label { color: #E9EEF2; font-size: 13px; }\n"
      ".micdrop-root checkbutton:disabled label { color: #7C8B99; }\n"
      ".micdrop-root checkbutton check {\n"
      "  -gtk-icon-source: none; min-width: 14px; min-height: 14px;\n"
      "  background-image: none; background-color: #2A3541; border: 1px solid #48596B; border-radius: 4px; color: #202831;\n"
      "}\n"
      ".micdrop-root checkbutton check:checked {\n"
      "  -gtk-icon-source: none; background-color: #D4AC45; border-color: #D4AC45; color: #182028;\n"
      "}\n"
      ".micdrop-root combobox button {\n"
      "  min-height: 0; min-width: 0; padding: 2px 8px;\n"
      "  background-image: none; background-color: #2A3541; color: #E9EEF2;\n"
      "  border: 1px solid #3B4958; border-radius: 5px; font-size: 13px;\n"
      "}\n"
      ".micdrop-panel-scroll {\n"
      "  background-color: #2A3541; border: 1px solid #3B4958; border-radius: 5px;\n"
      "}\n"
      ".micdrop-panel-scroll textview, .micdrop-panel-scroll textview text {\n"
      "  background-color: #2A3541; color: #E9EEF2; font-size: 12px;\n"
      "}\n"
      ".micdrop-panel-scroll treeview {\n"
      "  background-color: #2A3541; color: #E9EEF2; font-size: 13px;\n"
      "}\n"
      ".micdrop-panel-scroll treeview:selected {\n"
      "  background-color: #3E5368; color: #FFFFFF;\n"
      "}\n"
      ".micdrop-panel-scroll:disabled { opacity: 0.65; }\n";

  void* provider = gGtk.gtk_css_provider_new();
  if (provider == NULL) {
    return;
  }
  const char* css = high_contrast ? layout_only_css : dark_css;
  gGtk.gtk_css_provider_load_from_data(provider, css, -1, NULL);
  gGtk.gtk_style_context_add_provider_for_screen(screen, provider, MD_GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  gGtk.g_object_unref(provider);
  gApp.css_installed = 1;
}

static void mdRoundedRect(void* cr, double x, double y, double w, double h, double r) {
  const double pi = 3.14159265358979323846;
  if (w <= 0.0 || h <= 0.0) {
    return;
  }
  if (r > w * 0.5) r = w * 0.5;
  if (r > h * 0.5) r = h * 0.5;
  gGtk.cairo_new_sub_path(cr);
  gGtk.cairo_arc(cr, x + w - r, y + r, r, -pi * 0.5, 0.0);
  gGtk.cairo_arc(cr, x + w - r, y + h - r, r, 0.0, pi * 0.5);
  gGtk.cairo_arc(cr, x + r, y + h - r, r, pi * 0.5, pi);
  gGtk.cairo_arc(cr, x + r, y + r, r, pi, pi * 1.5);
  gGtk.cairo_close_path(cr);
}

static int mdIsActiveMainThread(void) {
  return __atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE) != 0 &&
         pthread_equal(pthread_self(), gApp.main_thread) != 0;
}

static gboolean mdOnRootDraw(void* widget, void* cr, gpointer user_data) {
  (void)user_data;
  if (!mdIsActiveMainThread() || gApp.high_contrast) {
    return 0;
  }
  GtkAllocation alloc;
  gGtk.gtk_widget_get_allocation(widget, &alloc);
  double width = (double)alloc.width;
  double height = (double)alloc.height;

  gGtk.cairo_set_source_rgb(cr, 0x20 / 255.0, 0x28 / 255.0, 0x31 / 255.0);
  gGtk.cairo_rectangle(cr, 0.0, 0.0, width, height);
  gGtk.cairo_fill(cr);

  if (width > 40.0 && height > 240.0) {
    mdRoundedRect(cr, 14.5, 10.5, width - 29.0, 131.0, 8.0);
    gGtk.cairo_set_source_rgb(cr, 0x2A / 255.0, 0x35 / 255.0, 0x41 / 255.0);
    gGtk.cairo_fill_preserve(cr);
    gGtk.cairo_set_source_rgb(cr, 0x3B / 255.0, 0x49 / 255.0, 0x58 / 255.0);
    gGtk.cairo_set_line_width(cr, 1.0);
    gGtk.cairo_stroke(cr);

    gGtk.cairo_set_source_rgb(cr, 0xD4 / 255.0, 0xAC / 255.0, 0x45 / 255.0);
    gGtk.cairo_rectangle(cr, 24.0, 190.0, width - 48.0, 2.0);
    gGtk.cairo_fill(cr);
    gGtk.cairo_rectangle(cr, 24.0, height - 96.0, width - 48.0, 2.0);
    gGtk.cairo_fill(cr);
  }
  return 0;
}

static gboolean mdOnQrDraw(void* widget, void* cr, gpointer user_data) {
  (void)user_data;
  if (!mdIsActiveMainThread()) {
    return 0;
  }
  GtkAllocation alloc;
  gGtk.gtk_widget_get_allocation(widget, &alloc);
  double w = (double)alloc.width;
  double h = (double)alloc.height;
  if (w < 4.0 || h < 4.0) {
    return 0;
  }

  if (!gApp.high_contrast) {
    mdRoundedRect(cr, 0.5, 0.5, w - 1.0, h - 1.0, 8.0);
    gGtk.cairo_set_source_rgb(cr, 0x2A / 255.0, 0x35 / 255.0, 0x41 / 255.0);
    gGtk.cairo_fill_preserve(cr);
    gGtk.cairo_set_source_rgb(cr, 0x3B / 255.0, 0x49 / 255.0, 0x58 / 255.0);
    gGtk.cairo_set_line_width(cr, 1.0);
    gGtk.cairo_stroke(cr);
  }

  if (gApp.qr_surface != NULL && gApp.qr_size > 0 && w > 20.0 && h > 20.0) {
    double dest_w = w - 16.0;
    double dest_h = h - 16.0;
    gGtk.cairo_save(cr);
    gGtk.cairo_translate(cr, 8.0, 8.0);
    gGtk.cairo_scale(cr, dest_w / (double)gApp.qr_size, dest_h / (double)gApp.qr_size);
    gGtk.cairo_set_source_surface(cr, gApp.qr_surface, 0.0, 0.0);
    gGtk.cairo_pattern_set_filter(gGtk.cairo_get_source(cr), MD_CAIRO_FILTER_NEAREST);
    gGtk.cairo_paint(cr);
    gGtk.cairo_restore(cr);
  }
  return 0;
}

static void mdOnSizeAllocate(void* widget, GtkAllocation* allocation, gpointer user_data) {
  (void)widget;
  (void)allocation;
  (void)user_data;
  if (!mdIsActiveMainThread()) {
    return;
  }
  md_ui_layout();
}

static gboolean mdOnWindowDelete(void* widget, void* event, gpointer user_data) {
  (void)event;
  (void)user_data;
  if (!mdIsActiveMainThread()) {
    return 1;
  }
  if (gApp.indicator != NULL) {
    gGtk.gtk_widget_hide(widget);
    return 1;
  }
  goMicDropEvent(gApp.exit_id, MD_EVENT_CLICK);
  return 1;
}

static gboolean mdOnTimer(gpointer user_data) {
  uintptr_t gen = (uintptr_t)user_data;
  if (!mdIsActiveMainThread() || gen != __atomic_load_n(&gApp.generation, __ATOMIC_ACQUIRE)) {
    return 0;
  }
  goMicDropTick();
  return __atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE) ? 1 : 0;
}

static gboolean mdOnWake(gpointer user_data) {
  uintptr_t gen = (uintptr_t)user_data;
  if (mdIsActiveMainThread() && gen == __atomic_load_n(&gApp.generation, __ATOMIC_ACQUIRE)) {
    goMicDropTick();
  }
  return 0;
}

static gboolean mdOnWakeTest(gpointer user_data) {
  uintptr_t gen = (uintptr_t)user_data;
  if (mdIsActiveMainThread() && gen == __atomic_load_n(&gApp.generation, __ATOMIC_ACQUIRE)) {
    goMicDropDrainTestQueue();
  }
  return 0;
}

static void mdOnButtonClicked(void* widget, gpointer user_data) {
  (void)widget;
  if (!mdIsActiveMainThread()) {
    return;
  }
  MdControlEntry* entry = (MdControlEntry*)user_data;
  if (entry != NULL && !entry->suppress_events) {
    goMicDropEvent(entry->id, MD_EVENT_CLICK);
  }
}

static void mdOnCheckToggled(void* widget, gpointer user_data) {
  (void)widget;
  if (!mdIsActiveMainThread()) {
    return;
  }
  MdControlEntry* entry = (MdControlEntry*)user_data;
  if (entry != NULL && !entry->suppress_events) {
    goMicDropEvent(entry->id, MD_EVENT_CLICK);
  }
}

static gboolean mdOnCheckDrawAfter(void* widget, void* cr, gpointer user_data) {
  (void)user_data;
  if (!mdIsActiveMainThread() || gApp.high_contrast || !gGtk.gtk_toggle_button_get_active(widget)) {
    return 0;
  }
  GtkAllocation alloc;
  gGtk.gtk_widget_get_allocation(widget, &alloc);
  double cy = (double)alloc.height * 0.5;
  gGtk.cairo_save(cr);
  gGtk.cairo_set_source_rgb(cr, 0x18 / 255.0, 0x20 / 255.0, 0x28 / 255.0);
  gGtk.cairo_set_line_width(cr, 2.2);
  gGtk.cairo_set_line_cap(cr, 1);
  gGtk.cairo_set_line_join(cr, 1);
  gGtk.cairo_move_to(cr, 6.0, cy + 0.2);
  gGtk.cairo_line_to(cr, 9.0, cy + 3.2);
  gGtk.cairo_line_to(cr, 14.4, cy - 3.0);
  gGtk.cairo_stroke(cr);
  gGtk.cairo_restore(cr);
  return 0;
}

static void mdOnPopupChanged(void* widget, gpointer user_data) {
  (void)widget;
  if (!mdIsActiveMainThread()) {
    return;
  }
  MdControlEntry* entry = (MdControlEntry*)user_data;
  if (entry != NULL && !entry->suppress_events) {
    goMicDropEvent(entry->id, MD_EVENT_CHANGE);
  }
}

static void mdOnListSelectionChanged(void* selection, gpointer user_data) {
  (void)selection;
  if (!mdIsActiveMainThread()) {
    return;
  }
  MdControlEntry* entry = (MdControlEntry*)user_data;
  if (entry != NULL && !entry->suppress_events) {
    goMicDropEvent(entry->id, MD_EVENT_CHANGE);
  }
}

static void mdOnListRowActivated(void* tree_view, void* path, void* column, gpointer user_data) {
  (void)path;
  (void)column;
  if (!mdIsActiveMainThread()) {
    return;
  }
  MdControlEntry* entry = (MdControlEntry*)user_data;
  if (entry != NULL && !entry->suppress_events && gGtk.gtk_widget_get_sensitive(tree_view)) {
    goMicDropEvent(entry->id, MD_EVENT_DBLCLK);
  }
}

static void mdOnTrayOpen(void* menu_item, gpointer user_data) {
  (void)menu_item;
  (void)user_data;
  if (mdIsActiveMainThread()) {
    goMicDropShow();
  }
}

static void mdOnTrayToggle(void* menu_item, gpointer user_data) {
  (void)menu_item;
  (void)user_data;
  if (mdIsActiveMainThread()) {
    goMicDropEvent(gApp.toggle_target_id, MD_EVENT_CLICK);
  }
}

static void mdOnTrayQuit(void* menu_item, gpointer user_data) {
  (void)menu_item;
  (void)user_data;
  if (mdIsActiveMainThread()) {
    goMicDropEvent(gApp.exit_id, MD_EVENT_CLICK);
  }
}

static void mdAddClass(void* widget, const char* cls) {
  void* ctx = gGtk.gtk_widget_get_style_context(widget);
  if (ctx != NULL) {
    gGtk.gtk_style_context_add_class(ctx, cls);
  }
}

static void mdRemoveClass(void* widget, const char* cls) {
  void* ctx = gGtk.gtk_widget_get_style_context(widget);
  if (ctx != NULL) {
    gGtk.gtk_style_context_remove_class(ctx, cls);
  }
}

static void mdSetupTray(void) {
  if (gApp.headless_test || !gGtk.has_indicator_api) {
    return;
  }
  void* ind = gGtk.app_indicator_new("micdrop-host", "audio-input-microphone-symbolic",
                                     MD_APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  if (ind == NULL) {
    return;
  }
  if (gGtk.app_indicator_set_title != NULL) {
    gGtk.app_indicator_set_title(ind, "MicDrop");
  }
  gGtk.app_indicator_set_status(ind, MD_APP_INDICATOR_STATUS_ACTIVE);

  void* menu = gGtk.gtk_menu_new();
  void* header = gGtk.gtk_menu_item_new_with_label("MicDrop · Stopped");
  gGtk.gtk_widget_set_sensitive(header, 0);
  gGtk.gtk_menu_shell_append(menu, header);
  gGtk.gtk_menu_shell_append(menu, gGtk.gtk_separator_menu_item_new());

  void* open_item = gGtk.gtk_menu_item_new_with_label("Open MicDrop");
  gGtk.g_signal_connect_data(open_item, "activate", (GCallback)mdOnTrayOpen, NULL, NULL, 0);
  gGtk.gtk_menu_shell_append(menu, open_item);

  void* toggle_item = gGtk.gtk_menu_item_new_with_label("Start host");
  gGtk.g_signal_connect_data(toggle_item, "activate", (GCallback)mdOnTrayToggle, NULL, NULL, 0);
  gGtk.gtk_menu_shell_append(menu, toggle_item);

  gGtk.gtk_menu_shell_append(menu, gGtk.gtk_separator_menu_item_new());

  void* quit_item = gGtk.gtk_menu_item_new_with_label("Quit MicDrop");
  gGtk.g_signal_connect_data(quit_item, "activate", (GCallback)mdOnTrayQuit, NULL, NULL, 0);
  gGtk.gtk_menu_shell_append(menu, quit_item);

  gGtk.gtk_widget_show_all(menu);
  gGtk.app_indicator_set_menu(ind, menu);

  gApp.indicator = ind;
  gApp.tray_menu = menu;
  gApp.tray_header_item = header;
  gApp.tray_toggle_item = toggle_item;
  gApp.toggle_target_id = gApp.start_id;
}

int md_app_init(const char* window_title, int headless_test, int start_id, int stop_id, int exit_id, char* err_buf, size_t err_cap) {
  const char* disp = getenv("DISPLAY");
  const char* wayland = getenv("WAYLAND_DISPLAY");
  if ((disp == NULL || disp[0] == '\0') && (wayland == NULL || wayland[0] == '\0')) {
    if (err_buf != NULL && err_cap > 0) {
      snprintf(err_buf, err_cap,
               "MicDrop desktop on Linux requires an active Wayland or X11 display; use micdrop-host CLI subcommands on headless systems");
    }
    return 0;
  }

  if (!mdLoadGtkSymbols(err_buf, err_cap)) {
    return 0;
  }

  if (!gApp.gtk_inited) {
    gGtk.g_set_prgname("micdrop");
    gGtk.g_set_application_name("MicDrop");
    int argc = 0;
    char** argv = NULL;
    if (!gGtk.gtk_init_check(&argc, &argv)) {
      if (err_buf != NULL && err_cap > 0) {
        snprintf(err_buf, err_cap,
                 "GTK 3 could not connect to the display server; verify DISPLAY or WAYLAND_DISPLAY");
      }
      return 0;
    }
    gGtk.gtk_window_set_default_icon_name("audio-input-microphone");
    gApp.gtk_inited = 1;
  }

  gApp.main_thread = pthread_self();
  uintptr_t gen = __atomic_add_fetch(&gApp.generation, 1, __ATOMIC_SEQ_CST);
  gApp.quit_requested = 0;
  gApp.loop_running = 0;

  gApp.high_contrast = mdDetectHighContrast();
  mdInstallCss(gApp.high_contrast);

  gApp.headless_test = headless_test != 0;
  gApp.start_id = start_id;
  gApp.stop_id = stop_id;
  gApp.exit_id = exit_id;
  gApp.toggle_target_id = start_id;

  void* window = gGtk.gtk_window_new(MD_GTK_WINDOW_TOPLEVEL);
  if (window == NULL) {
    if (err_buf != NULL && err_cap > 0) {
      snprintf(err_buf, err_cap, "cannot create GTK desktop window");
    }
    return 0;
  }
  gGtk.gtk_window_set_title(window, window_title != NULL ? window_title : "MicDrop");
  gGtk.gtk_window_set_default_size(window, 880, 720);
  if (!gApp.headless_test) {
    gGtk.gtk_window_set_position(window, MD_GTK_WIN_POS_CENTER);
  }
  mdAddClass(window, "micdrop-window");
  gGtk.g_signal_connect_data(window, "delete-event", (GCallback)mdOnWindowDelete, NULL, NULL, 0);

  void* root_scroll = gGtk.gtk_scrolled_window_new(NULL, NULL);
  gGtk.gtk_scrolled_window_set_policy(root_scroll, MD_GTK_POLICY_EXTERNAL, MD_GTK_POLICY_EXTERNAL);
  gGtk.gtk_widget_set_size_request(root_scroll, 860, 700);
  mdAddClass(root_scroll, "micdrop-slot");

  void* fixed = gGtk.gtk_fixed_new();
  mdAddClass(fixed, "micdrop-root");
  gGtk.g_signal_connect_data(fixed, "draw", (GCallback)mdOnRootDraw, NULL, NULL, 0);
  gGtk.g_signal_connect_data(fixed, "size-allocate", (GCallback)mdOnSizeAllocate, NULL, NULL, 0);

  gGtk.gtk_container_add(root_scroll, fixed);
  gGtk.gtk_container_add(window, root_scroll);
  gGtk.gtk_widget_show(fixed);
  gGtk.gtk_widget_show(root_scroll);

  gApp.window = window;
  gApp.root_scroll = root_scroll;
  gApp.fixed = fixed;
  __atomic_store_n(&gApp.initialized, 1, __ATOMIC_RELEASE);

  mdSetupTray();
  gApp.timer_id = gGtk.g_timeout_add(250, mdOnTimer, (gpointer)gen);
  return 1;
}

int md_app_has_tray(void) {
  return gApp.indicator != NULL ? 1 : 0;
}

static void mdFlushEvents(void) {
  if (!gGtk.loaded || !gApp.gtk_inited) {
    return;
  }
  int guard = 0;
  while (gGtk.gtk_events_pending() && guard < 256) {
    gGtk.gtk_main_iteration_do(0);
    guard++;
  }
}

static void mdCheckAllContainers(void) {
  if (!__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE)) {
    return;
  }
  if (gApp.window != NULL) {
    gGtk.gtk_container_check_resize(gApp.window);
  }
  if (gApp.root_scroll != NULL) {
    gGtk.gtk_container_check_resize(gApp.root_scroll);
  }
  if (gApp.fixed != NULL) {
    gGtk.gtk_container_check_resize(gApp.fixed);
  }
  for (MdControlEntry* e = gApp.controls; e != NULL; e = e->next) {
    if (e->outer != NULL && gGtk.gtk_widget_get_visible(e->outer)) {
      gGtk.gtk_container_check_resize(e->outer);
    }
  }
}

static void mdSyncLayout(void) {
  if (!gGtk.loaded || !gApp.gtk_inited || !__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE)) {
    return;
  }
  if (gApp.headless_test && gApp.window != NULL) {
    gGtk.gtk_widget_show(gApp.window);
  }
  md_ui_layout();
  mdCheckAllContainers();
  mdFlushEvents();
  md_ui_layout();
  mdCheckAllContainers();
  mdFlushEvents();
}

void md_app_show_window(int activate) {
  if (!__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE) || gApp.window == NULL) {
    return;
  }
  gGtk.gtk_widget_show(gApp.window);
  if (gApp.headless_test) {
    mdSyncLayout();
    return;
  }
  gGtk.gtk_window_deiconify(gApp.window);
  if (activate) {
    gGtk.gtk_window_present(gApp.window);
  }
}

void md_app_hide_window(void) {
  if (!__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE) || gApp.window == NULL) {
    return;
  }
  if (gApp.headless_test) {
    gGtk.gtk_widget_show(gApp.window);
    mdSyncLayout();
    return;
  }
  gGtk.gtk_widget_hide(gApp.window);
}

void md_app_minimize_window(void) {
  if (!__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE) || gApp.window == NULL) {
    return;
  }
  if (gApp.headless_test) {
    gGtk.gtk_widget_show(gApp.window);
    mdSyncLayout();
    return;
  }
  gGtk.gtk_window_iconify(gApp.window);
  gGtk.gtk_widget_show(gApp.window);
}

void md_app_run(void) {
  if (!__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE) || gApp.quit_requested) {
    return;
  }
  gApp.loop_running = 1;
  gGtk.gtk_main();
  gApp.loop_running = 0;
}

void md_app_stop_loop(void) {
  gApp.quit_requested = 1;
  if (gApp.loop_running) {
    gApp.loop_running = 0;
    gGtk.gtk_main_quit();
  }
}

void md_app_cleanup(void) {
  if (!__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE)) {
    return;
  }
  __atomic_store_n(&gApp.initialized, 0, __ATOMIC_RELEASE);
  gApp.quit_requested = 1;
  if (gApp.timer_id != 0) {
    gGtk.g_source_remove(gApp.timer_id);
    gApp.timer_id = 0;
  }

  MdControlEntry* controls = gApp.controls;
  gApp.controls = NULL;
  for (MdControlEntry* cur = controls; cur != NULL; cur = cur->next) {
    cur->suppress_events = 1;
    if (cur->selection != NULL) {
      gGtk.g_signal_handlers_disconnect_matched(cur->selection, MD_G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, cur);
    }
    if (cur->widget != NULL) {
      gGtk.g_signal_handlers_disconnect_matched(cur->widget, MD_G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, cur);
    }
  }

  if (gApp.qr_surface != NULL) {
    gGtk.cairo_surface_destroy(gApp.qr_surface);
    gApp.qr_surface = NULL;
    gApp.qr_size = 0;
  }
  if (gApp.indicator != NULL) {
    gGtk.g_object_unref(gApp.indicator);
    gApp.indicator = NULL;
  }
  if (gApp.tray_menu != NULL) {
    gGtk.gtk_widget_destroy(gApp.tray_menu);
    gApp.tray_menu = NULL;
    gApp.tray_header_item = NULL;
    gApp.tray_toggle_item = NULL;
  }
  if (gApp.dbus_conn != NULL) {
    gGtk.g_object_unref(gApp.dbus_conn);
    gApp.dbus_conn = NULL;
  }
  if (gApp.window != NULL) {
    gGtk.gtk_widget_destroy(gApp.window);
    gApp.window = NULL;
    gApp.root_scroll = NULL;
    gApp.fixed = NULL;
  }

  while (controls != NULL) {
    MdControlEntry* next = controls->next;
    mdFreePopupItems(controls);
    free(controls);
    controls = next;
  }
  mdFlushEvents();
}

void md_app_dispatch_wake(void) {
  if (__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE)) {
    uintptr_t gen = __atomic_load_n(&gApp.generation, __ATOMIC_ACQUIRE);
    gGtk.g_idle_add(mdOnWake, (gpointer)gen);
  }
}

void md_app_wake_test(void) {
  if (__atomic_load_n(&gApp.initialized, __ATOMIC_ACQUIRE)) {
    uintptr_t gen = __atomic_load_n(&gApp.generation, __ATOMIC_ACQUIRE);
    gGtk.g_idle_add(mdOnWakeTest, (gpointer)gen);
  }
}

static void* mdWrapSlot(void* child, int w, int h) {
  void* sw = gGtk.gtk_scrolled_window_new(NULL, NULL);
  gGtk.gtk_scrolled_window_set_policy(sw, MD_GTK_POLICY_EXTERNAL, MD_GTK_POLICY_EXTERNAL);
  gGtk.gtk_widget_set_size_request(sw, w > 0 ? w : 100, h > 0 ? h : 28);
  mdAddClass(sw, "micdrop-slot");
  gGtk.gtk_container_add(sw, child);
  gGtk.gtk_widget_show_all(sw);
  gGtk.gtk_widget_set_no_show_all(sw, 1);
  return sw;
}

int md_ui_add_control(int id, int kind, const char* title, int page, int x, int y, int w, int h) {
  if (!gApp.initialized || gApp.fixed == NULL) {
    return 0;
  }
  MdControlEntry* entry = (MdControlEntry*)calloc(1, sizeof(MdControlEntry));
  if (entry == NULL) {
    return 0;
  }
  entry->id = id;
  entry->kind = kind;
  entry->page = page;
  entry->x = x;
  entry->y = y;
  entry->w = w;
  entry->h = h;

  const char* text = title != NULL ? title : "";
  int init_w = w > 0 ? w : 100;
  int init_h = h > 0 ? h : 28;

  switch (kind) {
    case MD_KIND_TITLE:
    case MD_KIND_LABEL: {
      void* lbl = gGtk.gtk_label_new(text);
      gGtk.gtk_label_set_xalign(lbl, 0.0f);
      gGtk.gtk_label_set_yalign(lbl, 0.0f);
      gGtk.gtk_label_set_line_wrap(lbl, 1);
      gGtk.gtk_label_set_line_wrap_mode(lbl, MD_PANGO_WRAP_WORD_CHAR);
      mdAddClass(lbl, kind == MD_KIND_TITLE ? "micdrop-title" : "micdrop-label");
      entry->widget = lbl;
      entry->outer = mdWrapSlot(lbl, init_w, init_h);
      break;
    }
    case MD_KIND_BUTTON: {
      void* btn = gGtk.gtk_button_new_with_label(text);
      gGtk.g_signal_connect_data(btn, "clicked", (GCallback)mdOnButtonClicked, entry, NULL, 0);
      entry->widget = btn;
      entry->outer = mdWrapSlot(btn, init_w, init_h);
      break;
    }
    case MD_KIND_CHECKBOX: {
      void* cb = gGtk.gtk_check_button_new_with_label(text);
      gGtk.g_signal_connect_data(cb, "toggled", (GCallback)mdOnCheckToggled, entry, NULL, 0);
      gGtk.g_signal_connect_data(cb, "draw", (GCallback)mdOnCheckDrawAfter, entry, NULL, 1);
      entry->widget = cb;
      entry->outer = mdWrapSlot(cb, init_w, init_h);
      break;
    }
    case MD_KIND_POPUP: {
      void* combo = gGtk.gtk_combo_box_text_new();
      GList* cells = gGtk.gtk_cell_layout_get_cells(combo);
      if (cells != NULL) {
        if (cells->data != NULL) {
          gGtk.g_object_set(cells->data, "ellipsize", MD_PANGO_ELLIPSIZE_END, NULL);
        }
        gGtk.g_list_free(cells);
      }
      gGtk.g_signal_connect_data(combo, "changed", (GCallback)mdOnPopupChanged, entry, NULL, 0);
      entry->widget = combo;
      entry->outer = mdWrapSlot(combo, init_w, init_h);
      break;
    }
    case MD_KIND_EDIT: {
      void* ed = gGtk.gtk_entry_new();
      gGtk.gtk_entry_set_width_chars(ed, 1);
      gGtk.gtk_entry_set_text(ed, text);
      entry->widget = ed;
      entry->outer = mdWrapSlot(ed, init_w, init_h);
      break;
    }
    case MD_KIND_MULTILINE: {
      void* sw = gGtk.gtk_scrolled_window_new(NULL, NULL);
      gGtk.gtk_scrolled_window_set_policy(sw, MD_GTK_POLICY_NEVER, MD_GTK_POLICY_AUTOMATIC);
      gGtk.gtk_scrolled_window_set_propagate_natural_width(sw, 0);
      gGtk.gtk_scrolled_window_set_propagate_natural_height(sw, 0);
      gGtk.gtk_widget_set_size_request(sw, init_w, init_h);
      mdAddClass(sw, "micdrop-panel-scroll");

      void* tv = gGtk.gtk_text_view_new();
      gGtk.gtk_text_view_set_editable(tv, 0);
      gGtk.gtk_text_view_set_cursor_visible(tv, 0);
      gGtk.gtk_text_view_set_wrap_mode(tv, MD_GTK_WRAP_WORD_CHAR);
      gGtk.gtk_text_view_set_monospace(tv, 1);
      gGtk.gtk_text_view_set_left_margin(tv, 8);
      gGtk.gtk_text_view_set_right_margin(tv, 8);
      gGtk.gtk_text_view_set_top_margin(tv, 6);
      gGtk.gtk_text_view_set_bottom_margin(tv, 6);
      void* buf = gGtk.gtk_text_view_get_buffer(tv);
      gGtk.gtk_text_buffer_set_text(buf, text, -1);

      gGtk.gtk_container_add(sw, tv);
      gGtk.gtk_widget_show_all(sw);
      gGtk.gtk_widget_set_no_show_all(sw, 1);
      entry->readonly_flag = 1;
      entry->widget = tv;
      entry->extra = buf;
      entry->outer = sw;
      break;
    }
    case MD_KIND_LIST: {
      void* sw = gGtk.gtk_scrolled_window_new(NULL, NULL);
      gGtk.gtk_scrolled_window_set_policy(sw, MD_GTK_POLICY_NEVER, MD_GTK_POLICY_AUTOMATIC);
      gGtk.gtk_scrolled_window_set_propagate_natural_width(sw, 0);
      gGtk.gtk_scrolled_window_set_propagate_natural_height(sw, 0);
      gGtk.gtk_widget_set_size_request(sw, init_w, init_h);
      mdAddClass(sw, "micdrop-panel-scroll");

      void* store = gGtk.gtk_list_store_new(1, (GType)MD_G_TYPE_STRING);
      void* tv = gGtk.gtk_tree_view_new_with_model(store);
      gGtk.g_object_unref(store);
      gGtk.gtk_tree_view_set_headers_visible(tv, 0);

      void* renderer = gGtk.gtk_cell_renderer_text_new();
      gGtk.g_object_set(renderer, "ellipsize", MD_PANGO_ELLIPSIZE_END, "xpad", 6, "ypad", 3, NULL);
      void* col = gGtk.gtk_tree_view_column_new_with_attributes("", renderer, "text", 0, NULL);
      gGtk.gtk_tree_view_append_column(tv, col);

      void* sel = gGtk.gtk_tree_view_get_selection(tv);
      gGtk.gtk_tree_selection_set_mode(sel, MD_GTK_SELECTION_SINGLE);
      gGtk.g_signal_connect_data(sel, "changed", (GCallback)mdOnListSelectionChanged, entry, NULL, 0);
      gGtk.g_signal_connect_data(tv, "row-activated", (GCallback)mdOnListRowActivated, entry, NULL, 0);

      gGtk.gtk_container_add(sw, tv);
      gGtk.gtk_widget_show_all(sw);
      gGtk.gtk_widget_set_no_show_all(sw, 1);
      entry->widget = tv;
      entry->extra = store;
      entry->selection = sel;
      entry->outer = sw;
      break;
    }
    case MD_KIND_QR: {
      void* overlay = gGtk.gtk_overlay_new();
      void* area = gGtk.gtk_drawing_area_new();
      gGtk.g_signal_connect_data(area, "draw", (GCallback)mdOnQrDraw, entry, NULL, 0);
      gGtk.gtk_container_add(overlay, area);

      void* placeholder = gGtk.gtk_label_new("Start pairing to create a private QR code");
      gGtk.gtk_label_set_line_wrap(placeholder, 1);
      gGtk.gtk_label_set_line_wrap_mode(placeholder, MD_PANGO_WRAP_WORD_CHAR);
      gGtk.gtk_label_set_justify(placeholder, 2); // GTK_JUSTIFY_CENTER
      gGtk.gtk_label_set_xalign(placeholder, 0.5f);
      gGtk.gtk_label_set_yalign(placeholder, 0.5f);
      gGtk.gtk_widget_set_margin_start(placeholder, 20);
      gGtk.gtk_widget_set_margin_end(placeholder, 20);
      mdAddClass(placeholder, "micdrop-label");
      gGtk.gtk_overlay_add_overlay(overlay, placeholder);

      entry->widget = area;
      entry->extra = placeholder;
      entry->outer = mdWrapSlot(overlay, init_w, init_h);
      gGtk.gtk_widget_set_no_show_all(placeholder, 1);
      gGtk.gtk_widget_set_visible(placeholder, gApp.qr_surface == NULL ? 1 : 0);
      break;
    }
    default:
      free(entry);
      return 0;
  }

  gGtk.gtk_fixed_put(gApp.fixed, entry->outer, 0, 0);
  entry->next = gApp.controls;
  gApp.controls = entry;
  return 1;
}

void md_ui_layout(void) {
  if (!gApp.initialized || gApp.fixed == NULL) {
    return;
  }
  GtkAllocation alloc;
  gGtk.gtk_widget_get_allocation(gApp.fixed, &alloc);
  int width = alloc.width >= 860 ? alloc.width : 880;
  int height = alloc.height >= 700 ? alloc.height : 720;

  for (MdControlEntry* e = gApp.controls; e != NULL; e = e->next) {
    int x = e->x;
    int y = e->y;
    int w = e->w;
    int h = e->h;
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
    if (h < 1) {
      h = 1;
    }
    gGtk.gtk_widget_set_size_request(e->outer, w, h);
    gGtk.gtk_fixed_move(gApp.fixed, e->outer, x, y);
  }
  gGtk.gtk_widget_queue_draw(gApp.fixed);
}

void md_ui_select_page(int page) {
  if (!gApp.initialized) {
    return;
  }
  for (MdControlEntry* e = gApp.controls; e != NULL; e = e->next) {
    int show = (e->page < 0 || e->page == page) ? 1 : 0;
    gGtk.gtk_widget_set_visible(e->outer, show);
  }
  if (gApp.fixed != NULL) {
    gGtk.gtk_widget_queue_draw(gApp.fixed);
  }
}

void md_ui_set_visible(int id, int visible) {
  MdControlEntry* e = mdFindEntry(id);
  if (e != NULL) {
    gGtk.gtk_widget_set_visible(e->outer, visible != 0 ? 1 : 0);
  }
}

void md_ui_set_text(int id, const char* text) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL) {
    return;
  }
  const char* s = text != NULL ? text : "";
  switch (e->kind) {
    case MD_KIND_TITLE:
    case MD_KIND_LABEL:
      gGtk.gtk_label_set_text(e->widget, s);
      break;
    case MD_KIND_BUTTON:
    case MD_KIND_CHECKBOX:
      gGtk.gtk_button_set_label(e->widget, s);
      break;
    case MD_KIND_EDIT:
      gGtk.gtk_entry_set_text(e->widget, s);
      break;
    case MD_KIND_MULTILINE:
      if (e->extra != NULL) {
        gGtk.gtk_text_buffer_set_text(e->extra, s, -1);
      }
      break;
    default:
      break;
  }
}

char* md_ui_copy_text(int id) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL) {
    return mdDupStr("");
  }
  switch (e->kind) {
    case MD_KIND_TITLE:
    case MD_KIND_LABEL:
      return mdDupStr(gGtk.gtk_label_get_text(e->widget));
    case MD_KIND_BUTTON:
    case MD_KIND_CHECKBOX:
      return mdDupStr(gGtk.gtk_button_get_label(e->widget));
    case MD_KIND_EDIT:
      return mdDupStr(gGtk.gtk_entry_get_text(e->widget));
    case MD_KIND_MULTILINE: {
      if (e->extra == NULL) {
        return mdDupStr("");
      }
      GtkTextIter start, end;
      gGtk.gtk_text_buffer_get_bounds(e->extra, &start, &end);
      char* raw = gGtk.gtk_text_buffer_get_text(e->extra, &start, &end, 0);
      char* copy = mdDupStr(raw);
      if (raw != NULL) {
        gGtk.g_free(raw);
      }
      return copy;
    }
    default:
      return mdDupStr("");
  }
}

void md_ui_set_enabled(int id, int enabled) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL) {
    return;
  }
  int flag = enabled != 0 ? 1 : 0;
  gGtk.gtk_widget_set_sensitive(e->widget, flag);
  if (e->kind == MD_KIND_LIST) {
    gGtk.gtk_widget_set_sensitive(e->outer, flag);
  }
}

int md_ui_is_enabled(int id) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL) {
    return 0;
  }
  return gGtk.gtk_widget_get_sensitive(e->widget) ? 1 : 0;
}

void md_ui_set_readonly(int id, int readonly_flag) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL) {
    return;
  }
  int ro = readonly_flag != 0 ? 1 : 0;
  e->readonly_flag = ro;
  if (e->kind == MD_KIND_EDIT) {
    gGtk.gtk_editable_set_editable(e->widget, !ro);
    if (ro) {
      mdAddClass(e->widget, "micdrop-readonly");
    } else {
      mdRemoveClass(e->widget, "micdrop-readonly");
    }
  } else if (e->kind == MD_KIND_MULTILINE) {
    gGtk.gtk_text_view_set_editable(e->widget, !ro);
  }
}

int md_ui_is_readonly(int id) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL) {
    return 0;
  }
  if (e->kind == MD_KIND_EDIT) {
    return gGtk.gtk_editable_get_editable(e->widget) ? 0 : 1;
  }
  return e->readonly_flag ? 1 : 0;
}

void md_ui_set_checked(int id, int checked) {
  MdControlEntry* e = mdFindEntry(id);
  if (e != NULL && e->kind == MD_KIND_CHECKBOX) {
    e->suppress_events = 1;
    gGtk.gtk_toggle_button_set_active(e->widget, checked != 0 ? 1 : 0);
    e->suppress_events = 0;
  }
}

int md_ui_is_checked(int id) {
  MdControlEntry* e = mdFindEntry(id);
  if (e != NULL && e->kind == MD_KIND_CHECKBOX) {
    return gGtk.gtk_toggle_button_get_active(e->widget) ? 1 : 0;
  }
  return 0;
}

void md_ui_set_max_length(int id, int max_len) {
  MdControlEntry* e = mdFindEntry(id);
  if (e != NULL && e->kind == MD_KIND_EDIT && max_len > 0) {
    gGtk.gtk_entry_set_max_length(e->widget, max_len);
  }
}

void md_ui_set_popup_items(int id, char** items, int count, int selected) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL || e->kind != MD_KIND_POPUP) {
    return;
  }
  e->suppress_events = 1;
  mdFreePopupItems(e);
  gGtk.gtk_combo_box_text_remove_all(e->widget);

  if (count > 0 && items != NULL) {
    e->popup_items = (char**)calloc((size_t)count, sizeof(char*));
    if (e->popup_items != NULL) {
      e->item_count = count;
    }
    for (int i = 0; i < count; i++) {
      const char* s = items[i] != NULL ? items[i] : "";
      if (e->popup_items != NULL) {
        e->popup_items[i] = mdDupStr(s);
      }
      gGtk.gtk_combo_box_text_append_text(e->widget, s);
    }
  }
  if (selected >= 0 && selected < count) {
    gGtk.gtk_combo_box_set_active(e->widget, selected);
  } else {
    gGtk.gtk_combo_box_set_active(e->widget, -1);
  }
  e->suppress_events = 0;
}

int md_ui_popup_selected(int id) {
  MdControlEntry* e = mdFindEntry(id);
  if (e != NULL && e->kind == MD_KIND_POPUP) {
    return gGtk.gtk_combo_box_get_active(e->widget);
  }
  return -1;
}

int md_ui_popup_count(int id) {
  MdControlEntry* e = mdFindEntry(id);
  if (e != NULL && e->kind == MD_KIND_POPUP) {
    return e->item_count;
  }
  return 0;
}

int md_ui_popup_find_exact(int id, const char* title) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL || e->kind != MD_KIND_POPUP || e->popup_items == NULL) {
    return -1;
  }
  const char* target = title != NULL ? title : "";
  for (int i = 0; i < e->item_count; i++) {
    if (e->popup_items[i] != NULL && strcmp(e->popup_items[i], target) == 0) {
      return i;
    }
  }
  return -1;
}

void md_ui_set_list_items(int id, char** items, int count, int selected) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL || e->kind != MD_KIND_LIST || e->extra == NULL || e->selection == NULL) {
    return;
  }
  e->suppress_events = 1;
  gGtk.gtk_list_store_clear(e->extra);
  e->item_count = count > 0 ? count : 0;

  for (int i = 0; i < count; i++) {
    GtkTreeIter iter;
    gGtk.gtk_list_store_append(e->extra, &iter);
    gGtk.gtk_list_store_set(e->extra, &iter, 0, items[i] != NULL ? items[i] : "", -1);
  }
  if (selected >= 0 && selected < count) {
    void* path = gGtk.gtk_tree_path_new_from_indices(selected, -1);
    if (path != NULL) {
      gGtk.gtk_tree_selection_select_path(e->selection, path);
      gGtk.gtk_tree_path_free(path);
    }
  } else {
    gGtk.gtk_tree_selection_unselect_all(e->selection);
  }
  e->suppress_events = 0;
}

int md_ui_list_selected(int id) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL || e->kind != MD_KIND_LIST || e->selection == NULL) {
    return -1;
  }
  void* model = NULL;
  GtkTreeIter iter;
  if (!gGtk.gtk_tree_selection_get_selected(e->selection, &model, &iter) || model == NULL) {
    return -1;
  }
  void* path = gGtk.gtk_tree_model_get_path(model, &iter);
  if (path == NULL) {
    return -1;
  }
  gint* indices = gGtk.gtk_tree_path_get_indices(path);
  int idx = indices != NULL ? (int)indices[0] : -1;
  gGtk.gtk_tree_path_free(path);
  return idx;
}

void md_ui_list_select(int id, int selected) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL || e->kind != MD_KIND_LIST || e->selection == NULL) {
    return;
  }
  e->suppress_events = 1;
  if (selected >= 0 && selected < e->item_count) {
    void* path = gGtk.gtk_tree_path_new_from_indices(selected, -1);
    if (path != NULL) {
      gGtk.gtk_tree_selection_select_path(e->selection, path);
      gGtk.gtk_tree_path_free(path);
    }
  } else {
    gGtk.gtk_tree_selection_unselect_all(e->selection);
  }
  e->suppress_events = 0;
}

void md_ui_set_qr_rgba(const uint8_t* rgba, int size_px) {
  if (!gApp.initialized) {
    return;
  }
  if (gApp.qr_surface != NULL) {
    gGtk.cairo_surface_destroy(gApp.qr_surface);
    gApp.qr_surface = NULL;
    gApp.qr_size = 0;
  }
  if (rgba != NULL && size_px > 0) {
    void* surf = gGtk.cairo_image_surface_create(MD_CAIRO_FORMAT_ARGB32, size_px, size_px);
    if (surf != NULL) {
      gGtk.cairo_surface_flush(surf);
      unsigned char* dst = gGtk.cairo_image_surface_get_data(surf);
      int stride = gGtk.cairo_image_surface_get_stride(surf);
      if (dst != NULL && stride >= size_px * 4) {
        for (int y = 0; y < size_px; y++) {
          uint32_t* row = (uint32_t*)(dst + (size_t)y * (size_t)stride);
          const uint8_t* src = rgba + (size_t)y * (size_t)size_px * 4;
          for (int x = 0; x < size_px; x++) {
            uint32_t r = src[x * 4 + 0];
            uint32_t g = src[x * 4 + 1];
            uint32_t b = src[x * 4 + 2];
            uint32_t a = src[x * 4 + 3];
            uint32_t pr = (r * a + 127) / 255;
            uint32_t pg = (g * a + 127) / 255;
            uint32_t pb = (b * a + 127) / 255;
            row[x] = (a << 24) | (pr << 16) | (pg << 8) | pb;
          }
        }
        gGtk.cairo_surface_mark_dirty(surf);
        gApp.qr_surface = surf;
        gApp.qr_size = size_px;
      } else {
        gGtk.cairo_surface_destroy(surf);
      }
    }
  }
  for (MdControlEntry* e = gApp.controls; e != NULL; e = e->next) {
    if (e->kind == MD_KIND_QR) {
      if (e->extra != NULL) {
        gGtk.gtk_widget_set_visible(e->extra, gApp.qr_surface == NULL ? 1 : 0);
      }
      gGtk.gtk_widget_queue_draw(e->widget);
    }
  }
}

void md_ui_update_tray(const char* status, int running, int connected) {
  if (!gApp.initialized || gApp.indicator == NULL) {
    return;
  }
  char label[256];
  snprintf(label, sizeof(label), "MicDrop · %s", status != NULL ? status : "");
  const char* icon_name = "audio-input-microphone-symbolic";
  if (connected != 0) {
    icon_name = "audio-input-microphone";
  }
  gGtk.app_indicator_set_icon_full(gApp.indicator, icon_name, label);
  if (gApp.tray_header_item != NULL) {
    gGtk.gtk_menu_item_set_label(gApp.tray_header_item, label);
  }
  if (gApp.tray_toggle_item != NULL) {
    if (running != 0) {
      gGtk.gtk_menu_item_set_label(gApp.tray_toggle_item, "Stop host");
      gApp.toggle_target_id = gApp.stop_id;
    } else {
      gGtk.gtk_menu_item_set_label(gApp.tray_toggle_item, "Start host");
      gApp.toggle_target_id = gApp.start_id;
    }
  }
}

void md_ui_notify(const char* title, const char* body, int warning) {
  (void)warning;
  if (!gApp.initialized || gApp.headless_test) {
    return;
  }
  if (gApp.dbus_conn == NULL) {
    GError* err = NULL;
    gApp.dbus_conn = gGtk.g_bus_get_sync(MD_G_BUS_TYPE_SESSION, NULL, &err);
    if (err != NULL) {
      gGtk.g_error_free(err);
    }
  }
  if (gApp.dbus_conn == NULL) {
    return;
  }
  void* params = gGtk.g_variant_new("(susssasa{sv}i)",
                                    "MicDrop",
                                    (guint32)0,
                                    "audio-input-microphone",
                                    title != NULL ? title : "MicDrop",
                                    body != NULL ? body : "",
                                    NULL,
                                    NULL,
                                    (gint32)-1);
  if (params == NULL) {
    return;
  }
  gGtk.g_dbus_connection_call(gApp.dbus_conn,
                              "org.freedesktop.Notifications",
                              "/org/freedesktop/Notifications",
                              "org.freedesktop.Notifications",
                              "Notify",
                              params,
                              NULL,
                              MD_G_DBUS_CALL_FLAGS_NONE,
                              2000,
                              NULL,
                              NULL,
                              NULL);
}

void md_ui_show_error(const char* message) {
  if (gApp.headless_test || !gGtk.loaded || !gApp.gtk_inited) {
    return;
  }
  void* dlg = gGtk.gtk_message_dialog_new(gApp.window, 1, MD_GTK_MESSAGE_WARNING, MD_GTK_BUTTONS_OK, "%s", "MicDrop");
  if (dlg == NULL) {
    return;
  }
  gGtk.gtk_message_dialog_format_secondary_text(dlg, "%s", message != NULL ? message : "");
  gGtk.gtk_dialog_run(dlg);
  gGtk.gtk_widget_destroy(dlg);
}

void md_ui_show_info(const char* title, const char* message) {
  if (gApp.headless_test || !gGtk.loaded || !gApp.gtk_inited) {
    return;
  }
  void* dlg = gGtk.gtk_message_dialog_new(gApp.window, 1, MD_GTK_MESSAGE_INFO, MD_GTK_BUTTONS_OK, "%s",
                                          title != NULL ? title : "MicDrop");
  if (dlg == NULL) {
    return;
  }
  gGtk.gtk_message_dialog_format_secondary_text(dlg, "%s", message != NULL ? message : "");
  gGtk.gtk_dialog_run(dlg);
  gGtk.gtk_widget_destroy(dlg);
}

int md_ui_confirm(const char* message) {
  if (gApp.headless_test || !gGtk.loaded || !gApp.gtk_inited) {
    return 0;
  }
  void* dlg = gGtk.gtk_message_dialog_new(gApp.window, 1, MD_GTK_MESSAGE_QUESTION, MD_GTK_BUTTONS_NONE, "%s", "MicDrop");
  if (dlg == NULL) {
    return 0;
  }
  gGtk.gtk_message_dialog_format_secondary_text(dlg, "%s", message != NULL ? message : "");
  gGtk.gtk_dialog_add_button(dlg, "Cancel", MD_GTK_RESPONSE_CANCEL);
  gGtk.gtk_dialog_add_button(dlg, "Confirm", MD_GTK_RESPONSE_ACCEPT);
  gGtk.gtk_dialog_set_default_response(dlg, MD_GTK_RESPONSE_CANCEL);
  int resp = gGtk.gtk_dialog_run(dlg);
  gGtk.gtk_widget_destroy(dlg);
  return resp == MD_GTK_RESPONSE_ACCEPT ? 1 : 0;
}

char* md_ui_choose_json_file(void) {
  if (gApp.headless_test || !gGtk.loaded || !gApp.gtk_inited) {
    return NULL;
  }
  void* chooser = gGtk.gtk_file_chooser_native_new("Import private MicDrop remote configuration",
                                                   gApp.window,
                                                   MD_GTK_FILE_CHOOSER_ACTION_OPEN,
                                                   "_Import",
                                                   "_Cancel");
  if (chooser == NULL) {
    return NULL;
  }
  void* filter = gGtk.gtk_file_filter_new();
  if (filter != NULL) {
    gGtk.gtk_file_filter_set_name(filter, "JSON configuration (*.json)");
    gGtk.gtk_file_filter_add_pattern(filter, "*.json");
    gGtk.gtk_file_filter_add_mime_type(filter, "application/json");
    gGtk.gtk_file_chooser_add_filter(chooser, filter);
  }
  char* out = NULL;
  if (gGtk.gtk_native_dialog_run(chooser) == MD_GTK_RESPONSE_ACCEPT) {
    char* path = gGtk.gtk_file_chooser_get_filename(chooser);
    if (path != NULL) {
      out = mdDupStr(path);
      gGtk.g_free(path);
    }
  }
  gGtk.gtk_native_dialog_destroy(chooser);
  return out;
}

int md_ui_copy_clipboard(const char* text) {
  if (!gGtk.loaded || !gApp.gtk_inited || text == NULL) {
    return 0;
  }
  void* atom = gGtk.gdk_atom_intern_static_string("CLIPBOARD");
  void* cb = gGtk.gtk_clipboard_get(atom);
  if (cb == NULL) {
    return 0;
  }
  gGtk.gtk_clipboard_set_text(cb, text, -1);
  gGtk.gtk_clipboard_store(cb);
  return 1;
}

int md_ui_open_path(const char* path) {
  if (!gGtk.loaded || path == NULL) {
    return 0;
  }
  GError* err = NULL;
  char* uri = gGtk.g_filename_to_uri(path, NULL, &err);
  if (err != NULL) {
    gGtk.g_error_free(err);
    err = NULL;
  }
  if (uri == NULL) {
    return 0;
  }
  gboolean ok = gGtk.g_app_info_launch_default_for_uri(uri, NULL, &err);
  if (err != NULL) {
    gGtk.g_error_free(err);
  }
  gGtk.g_free(uri);
  return ok ? 1 : 0;
}

int md_ui_check_bounds(int id, int* out_x, int* out_y, int* out_w, int* out_h, int* win_w, int* win_h) {
  MdControlEntry* e = mdFindEntry(id);
  if (e == NULL || !gApp.initialized || gApp.fixed == NULL) {
    return 0;
  }
  mdSyncLayout();
  GtkAllocation root_alloc, ctrl_alloc;
  gGtk.gtk_widget_get_allocation(gApp.fixed, &root_alloc);
  gGtk.gtk_widget_get_allocation(e->outer, &ctrl_alloc);

  int rel_x = ctrl_alloc.x - root_alloc.x;
  int rel_y = ctrl_alloc.y - root_alloc.y;
  gint tx = 0, ty = 0;
  if (gGtk.gtk_widget_translate_coordinates(e->outer, gApp.fixed, 0, 0, &tx, &ty)) {
    rel_x = tx;
    rel_y = ty;
  }

  if (out_x != NULL) *out_x = rel_x;
  if (out_y != NULL) *out_y = rel_y;
  if (out_w != NULL) *out_w = ctrl_alloc.width;
  if (out_h != NULL) *out_h = ctrl_alloc.height;
  if (win_w != NULL) *win_w = root_alloc.width;
  if (win_h != NULL) *win_h = root_alloc.height;
  return 1;
}

int md_ui_capture_png(const char* out_path) {
  if (!gApp.initialized || gApp.window == NULL || gApp.fixed == NULL || out_path == NULL) {
    return 0;
  }
  mdSyncLayout();

  GtkAllocation alloc;
  gGtk.gtk_widget_get_allocation(gApp.fixed, &alloc);
  if (alloc.width < 1 || alloc.height < 1) {
    return 0;
  }
  void* surf = gGtk.cairo_image_surface_create(MD_CAIRO_FORMAT_ARGB32, alloc.width, alloc.height);
  if (surf == NULL) {
    return 0;
  }
  void* cr = gGtk.cairo_create(surf);
  if (cr == NULL) {
    gGtk.cairo_surface_destroy(surf);
    return 0;
  }
  gGtk.cairo_set_source_rgb(cr, 0x20 / 255.0, 0x28 / 255.0, 0x31 / 255.0);
  gGtk.cairo_paint(cr);
  gGtk.gtk_widget_draw(gApp.fixed, cr);
  gGtk.cairo_destroy(cr);

  int status = gGtk.cairo_surface_write_to_png(surf, out_path);
  gGtk.cairo_surface_destroy(surf);
  return status == 0 ? 1 : 0;
}

void md_ui_trigger(int id, int event_kind) {
  MdControlEntry* e = mdFindEntry(id);
  if (e != NULL && e->kind == MD_KIND_CHECKBOX && event_kind == MD_EVENT_CLICK) {
    if (!gGtk.gtk_widget_get_sensitive(e->widget)) {
      return;
    }
    e->suppress_events = 1;
    gboolean cur = gGtk.gtk_toggle_button_get_active(e->widget);
    gGtk.gtk_toggle_button_set_active(e->widget, !cur);
    e->suppress_events = 0;
  }
  goMicDropEvent(id, event_kind);
}

#endif
